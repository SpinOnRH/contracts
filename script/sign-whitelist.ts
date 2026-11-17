/**
 * Signs whitelist mints for Spinners: one EIP-712 signature per address over
 * (minter, allowance), with the contract's own domain (its name, version "1",
 * the chain id and its address).
 *
 *   node --import tsx script/sign-whitelist.ts <spinners address> <list.csv> [out.json]
 *
 * list.csv: `address,allowance` per line (a header line is skipped).
 * Settings: WHITELIST_SIGNER_KEY (must be the contract's whitelistSigner),
 * SIGN_RPC_URL (default: RPC_URL). From the environment or the repo's .env.
 */
import { readFileSync, writeFileSync } from "node:fs";

import {
  createPublicClient,
  getAddress,
  hashTypedData,
  http,
  isAddress,
  parseAbi,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { setting } from "./env";

export const WHITELIST_TYPES = {
  WhitelistMint: [
    { name: "minter", type: "address" },
    { name: "allowance", type: "uint256" },
  ],
} as const;

/** The domain Spinners signs under: its ERC-721 name, version "1", the chain and the contract. */
export const whitelistDomain = (
  name: string,
  chainId: number,
  contract: Address,
) => ({ name, version: "1", chainId, verifyingContract: contract }) as const;

const [contractArg, listFile, outFile = "whitelist-signatures.json"] =
  process.argv.slice(2);
if (!contractArg || !listFile || !isAddress(contractArg)) {
  console.error(
    "usage: sign-whitelist.ts <spinners address> <list.csv> [out.json]",
  );
  process.exit(1);
}
const contract = getAddress(contractArg);
const client = createPublicClient({
  transport: http(setting("SIGN_RPC_URL", setting("RPC_URL", ""))),
});
const signer = privateKeyToAccount(setting("WHITELIST_SIGNER_KEY") as Hex);
const abi = parseAbi([
  "function name() view returns (string)",
  "function whitelistSigner() view returns (address)",
  "function whitelistDigest(address minter, uint256 allowance) view returns (bytes32)",
]);

const [name, chainId, onChainSigner] = await Promise.all([
  client.readContract({ address: contract, abi, functionName: "name" }),
  client.getChainId(),
  client.readContract({
    address: contract,
    abi,
    functionName: "whitelistSigner",
  }),
]);
if (getAddress(onChainSigner) !== signer.address)
  throw new Error(
    `the contract's whitelistSigner is ${onChainSigner}, not this key's ${signer.address}`,
  );
const domain = whitelistDomain(name, chainId, contract);

const rows = readFileSync(listFile, "utf8")
  .split("\n")
  .map((l) => l.split(",").map((x) => x.trim()))
  .filter(([a, n]) => a && isAddress(a) && /^\d+$/.test(n ?? ""));
if (!rows.length) throw new Error("no address,allowance rows in the list");

const out: Record<string, { allowance: string; signature: Hex }> = {};
for (const [a, n] of rows) {
  const message = { minter: getAddress(a!), allowance: BigInt(n!) };
  out[message.minter] = {
    allowance: n!,
    signature: await signer.signTypedData({
      domain,
      types: WHITELIST_TYPES,
      primaryType: "WhitelistMint",
      message,
    }),
  };
}

// One on-chain check that this domain is the contract's: the digests must match.
const [first] = rows;
const local = hashTypedData({
  domain,
  types: WHITELIST_TYPES,
  primaryType: "WhitelistMint",
  message: { minter: getAddress(first![0]!), allowance: BigInt(first![1]!) },
});
const onChain = await client.readContract({
  address: contract,
  abi,
  functionName: "whitelistDigest",
  args: [getAddress(first![0]!), BigInt(first![1]!)],
});
if (local !== onChain)
  throw new Error("the EIP-712 domain does not match the contract's");

writeFileSync(outFile, `${JSON.stringify(out, null, 2)}\n`);
console.log(
  `signed ${rows.length} addresses for ${name} (${contract}, chain ${chainId}) -> ${outFile}`,
);
