/**
 * Deploys the spin bots stack to a test network (Robinhood Chain testnet,
 * 46630, or a local anvil), and writes the addresses to
 * deployments/<chainId>.json. Safe to run again: whatever is already deployed
 * (and listed in that file) is kept.
 *
 * The testnet has none of the shared contracts mainnet has, so this deploys
 * them too: Tokenbound v0.3.1 (EntryPoint v0.6, authenticated Multicall3,
 * ERC-6551 registry, AccountGuardian, AccountV3Upgradable) and TestPons, a
 * small bonding curve with Pons V2's interface, as the trading venue. On
 * Robinhood Chain testnet it also adds the UP adapter, for UP's testnet pools.
 *
 *   npm run setup:tokenbound && forge build   # once
 *   npm run deploy:testnet      # DEPLOYER_KEY in .env
 *
 * Settings, from the environment or the repo's .env: RPC_URL
 * (default: Robinhood's public testnet RPC), DEPLOYER_KEY, DEPLOYMENT_FILE
 * (default: deployments/<chainId>.json), and the operators (script/operators.ts:
 * OPERATOR_MNEMONIC with SEND_LANES, or OPERATOR_ADDRESSES / OPERATOR_ADDRESS /
 * OPERATOR_PRIVATE_KEY; with none, the deployer itself, for local chains), each
 * funded to OPERATOR_FLOAT_ETH. The deployer manages them: run again to top
 * the floats up or change the set.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  zeroAddress,
  type Abi,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { manageOperators, operatorAddresses, operatorFloat } from "./operators";

import { ROOT, setting } from "./env";

const rpc = setting("RPC_URL", "https://rpc.testnet.chain.robinhood.com");
const rawKey = setting("DEPLOYER_KEY");
// With or without the 0x prefix.
const deployer = privateKeyToAccount(
  (rawKey.startsWith("0x") ? rawKey : `0x${rawKey}`) as Hex,
);
const probe = createPublicClient({ transport: http(rpc) });
const chainId = await probe.getChainId();
if (chainId === 4663)
  throw new Error("this is mainnet; this script is for test networks only");
const chain = defineChain({
  id: chainId,
  name: `test network ${chainId}`,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [rpc] } },
});
const client = createPublicClient({ chain, transport: http(rpc) });
const wallet = createWalletClient({
  account: deployer,
  chain,
  transport: http(rpc),
});
const operators = operatorAddresses(setting);
if (!operators.length) operators.push(deployer.address);

const outFile = setting(
  "DEPLOYMENT_FILE",
  join(ROOT, "deployments", `${chainId}.json`),
);
mkdirSync(dirname(outFile), { recursive: true });
/** `blocks`: the block each contract was deployed in, where readers of its events start. */
type Deployment = {
  chainId: number;
  deployer: Address;
  /** The guard's operators (the senders' keys), managed by the deployer. `operator`: the single one of older files. */
  operators?: Address[];
  operator?: Address;
  contracts: Record<string, Address>;
  blocks?: Record<string, number>;
};
const deployment: Deployment = existsSync(outFile)
  ? JSON.parse(readFileSync(outFile, "utf8"))
  : { chainId, deployer: deployer.address, contracts: {}, blocks: {} };
const save = () =>
  writeFileSync(outFile, `${JSON.stringify(deployment, null, 2)}\n`);

const artifact = (out: string, file: string, name: string) => {
  const path = join(ROOT, out, file, `${name}.json`);
  if (!existsSync(path))
    throw new Error(
      `missing ${path}: run "npm run setup:tokenbound" and "forge build" at the repo root`,
    );
  const a = JSON.parse(readFileSync(path, "utf8"));
  return { abi: a.abi as Abi, bytecode: a.bytecode.object as Hex };
};
const tokenbound = (file: string, name = file.replace(".sol", "")) =>
  artifact("lib/tokenbound/out", file, name);
const ours = (file: string, name = file.replace(".sol", "")) =>
  artifact("out", file, name);

/** Deploys `key` unless the file already has it and it has code. */
async function deploy(
  key: string,
  a: { abi: Abi; bytecode: Hex },
  args: unknown[] = [],
) {
  const known = deployment.contracts[key];
  if (known && (await client.getCode({ address: known }))) {
    console.log(`${key.padEnd(20)} ${known} (kept)`);
    return known;
  }
  const hash = await wallet.deployContract({
    abi: a.abi,
    bytecode: a.bytecode,
    args,
  });
  const receipt = await client.waitForTransactionReceipt({ hash });
  const address = receipt.contractAddress!;
  deployment.contracts[key] = address;
  deployment.blocks = {
    ...deployment.blocks,
    [key]: Number(receipt.blockNumber),
  };
  save();
  console.log(`${key.padEnd(20)} ${address}`);
  return address;
}

async function send(
  address: Address,
  abi: Abi,
  functionName: string,
  args: unknown[],
) {
  const hash = await wallet.writeContract({
    address,
    abi,
    functionName,
    args,
    chain,
    account: deployer,
  });
  const r = await client.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`${functionName} reverted`);
}

const balance = await client.getBalance({ address: deployer.address });
console.log(
  `chain ${chainId}, deployer ${deployer.address} (${Number(balance) / 1e18} ETH), operators ${operators.join(", ")}`,
);

// Tokenbound v0.3.1, as mainnet's AccountV3Upgradable is deployed.
const entryPoint = await deploy("EntryPoint", tokenbound("EntryPoint.sol"));
const multicall = await deploy("Multicall3", tokenbound("Multicall3.sol"));
const registry = await deploy(
  "ERC6551Registry",
  tokenbound("ERC6551Registry.sol"),
);
const guardian = await deploy(
  "AccountGuardian",
  tokenbound("AccountGuardian.sol"),
  [deployer.address],
);
const accountImpl = await deploy(
  "AccountV3",
  tokenbound("AccountV3Upgradable.sol"),
  [entryPoint, multicall, registry, guardian],
);

// The venue, the collection, the guard and its adapter.
const ponsFactory = await deploy(
  "TestPonsFactory",
  ours("TestPons.sol", "TestPonsFactory"),
);
const spinnersArtifact = ours("Spinners.sol");
const spinners = await deploy("Spinners", spinnersArtifact, [
  "Spinners (testnet)",
  "tSPIN",
  7777n,
  deployer.address,
  deployer.address,
  500,
  // The token metadata's base URI (BASE_URI); the owner can set it later with setBaseURI.
  setting("BASE_URI", ""),
  // Each token's wallet: a locked one is not transferred.
  registry,
  accountImpl,
]);
const guardArtifact = ours("SpinBotGuard.sol");
// Fee 0.5%; gas refunds priced at most at 1 gwei and at most 0.001 ETH a trade; 110k gas of overhead a trade, 80k a
// trade in a tradeMany.
const guard = await deploy("SpinBotGuard", guardArtifact, [
  registry,
  accountImpl,
  spinners,
  deployer.address,
  deployer.address,
  50,
  10n ** 9n,
  10n ** 15n,
  110_000,
  80_000,
]);
const ponsAdapter = await deploy("PonsAdapter", ours("PonsAdapter.sol"), [
  ponsFactory,
]);
// UP's own testnet deployment (up33.xyz): its v2-style router and factory, its CL swap router, and its wrapped ETH.
const upAdapter =
  chainId === 46630
    ? await deploy("UpAdapter", ours("UpAdapter.sol"), [
        "0xAE846E12D6cDB178ae1467207d9Cfb0a38437656",
        "0xfd491Ce89257b6d744e593542E7726A7f9735E8a",
        "0xd712abe4D96B4f8Fd00795131000F8aE9C52B427",
        "0x7943e237c7F95DA44E0301572D358911207852Fa",
      ])
    : undefined;

// Settings, only where they differ.
const read = (
  address: Address,
  abi: Abi,
  functionName: string,
  args: unknown[] = [],
) =>
  client.readContract({ address, abi, functionName, args }) as Promise<unknown>;
// The operators: on the guard, funded; those no longer in the set removed (a new guard starts with none).
const previous =
  deployment.operators ?? (deployment.operator ? [deployment.operator] : []);
deployment.operators = await manageOperators({
  client,
  wallet,
  guard,
  guardAbi: guardArtifact.abi,
  wanted: operators,
  previous,
  floatWei: operatorFloat(setting),
});
delete deployment.operator;
if (!(await read(guard, guardArtifact.abi, "isVenue", [ponsAdapter])))
  await send(guard, guardArtifact.abi, "addVenue", [ponsAdapter]);
if (
  upAdapter &&
  !(await read(guard, guardArtifact.abi, "isVenue", [upAdapter]))
)
  await send(guard, guardArtifact.abi, "addVenue", [upAdapter]);
// The adapters' withdrawals go to the guard's treasury (the deployer, on a test network) only.
for (const [adapter, file] of [
  [ponsAdapter, "PonsAdapter.sol"],
  ...(upAdapter ? [[upAdapter, "UpAdapter.sol"]] : []),
] as [Address, string][]) {
  const abi = ours(file).abi;
  if ((await read(adapter, abi, "treasury")) !== deployer.address)
    await send(adapter, abi, "setTreasury", [deployer.address]);
}
// On a test network the mint is open and free, for testing.
if (!(await read(spinners, spinnersArtifact.abi, "mintOpen")))
  await send(spinners, spinnersArtifact.abi, "setMintOpen", [true]);
// Every transfer is checked by Limit Break's transfer validator, Robinhood testnet's included. A
// local chain has none at its address, and a call to it would revert every transfer: none there.
const validator = (await read(
  spinners,
  spinnersArtifact.abi,
  "getTransferValidator",
)) as Address;
if (
  validator !== zeroAddress &&
  !(await client.getCode({ address: validator }))
)
  await send(spinners, spinnersArtifact.abi, "setTransferValidator", [
    zeroAddress,
  ]);

save();
console.log(`\nwrote ${outFile}`);
