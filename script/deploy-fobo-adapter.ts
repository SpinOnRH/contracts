/**
 * The FoboAdapter alone, on Robinhood Chain mainnet: deploys it (reading the deployed HookList),
 * sets its treasury, adds it as a venue on the deployed guard, and records it in
 * deployments/4663.json. Nothing else is read or sent (deploy-mainnet.ts would also set the
 * collection's beta settings and the operators' floats again).
 *
 *   forge build                                              # once
 *   npm run deploy:fobo                         # a dry run: the plan, nothing sent
 *   npm run deploy:fobo -- --send
 *
 * Safe to run again: a FoboAdapter the file names and that has code is kept; a step already done is
 * not sent again. Settings, as deploy-mainnet.ts: RPC_URL, and DEPLOYER_KEY (else DEPLOYER_PRIVATE_KEY),
 * from the environment or the repo's .env: the guard's admin.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import {
  createPublicClient,
  createWalletClient,
  defineChain,
  formatEther,
  http,
  type Abi,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { ROOT, setting, deployerKey } from "./env";

const hex = (k: string) => (k.startsWith("0x") ? k : `0x${k}`) as Hex;

/** As deploy-mainnet.ts. */
const TREASURY: Address = "0x6d5dc628dAf2C6608D9DE1C9Af19564D36f46Fbf";
const UNIVERSAL_ROUTER: Address = "0x8876789976dEcBfCbBbe364623C63652db8C0904";
const PERMIT2: Address = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
const WETH: Address = "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73";
const FOBO_HOOK: Address = "0x0Af57F62982D03066ef917AcAd87F771c06528Ec";

const sending = process.argv.includes("--send");
const rpc = setting("RPC_URL");
const deployer = privateKeyToAccount(hex(deployerKey()));
const probe = createPublicClient({ transport: http(rpc) });
const chainId = await probe.getChainId();
if (chainId !== 4663)
  throw new Error(
    `chain ${chainId}: this script is for Robinhood Chain mainnet (4663) or a fork of it`,
  );
const chain = defineChain({
  id: chainId,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [rpc] } },
});
const client = createPublicClient({ chain, transport: http(rpc) });
const wallet = createWalletClient({
  account: deployer,
  chain,
  transport: http(rpc),
});

const outFile = join(ROOT, "deployments", `${chainId}.json`);
const deployment = JSON.parse(readFileSync(outFile, "utf8")) as {
  contracts: Record<string, Address>;
  blocks: Record<string, number>;
};
const guard = deployment.contracts.SpinBotGuard;
const hookList = deployment.contracts.HookList;
if (!guard || !hookList)
  throw new Error("the file names no SpinBotGuard or HookList");

const artifact = (file: string) => {
  const path = join(ROOT, "out", file, `${file.replace(".sol", "")}.json`);
  if (!existsSync(path))
    throw new Error(`missing ${path}: run "forge build" at the repo root`);
  const a = JSON.parse(readFileSync(path, "utf8"));
  return { abi: a.abi as Abi, bytecode: a.bytecode.object as Hex };
};
const F = artifact("FoboAdapter.sol");
const G = artifact("SpinBotGuard.sol");
const read = (
  address: Address,
  abi: Abi,
  functionName: string,
  args: unknown[] = [],
) =>
  client.readContract({ address, abi, functionName, args }) as Promise<unknown>;
const call = async (
  address: Address,
  abi: Abi,
  functionName: string,
  args: unknown[],
  label: string,
) => {
  const hash = await wallet.writeContract({
    address,
    abi,
    functionName,
    args,
    chain,
    account: deployer,
  });
  if ((await client.waitForTransactionReceipt({ hash })).status !== "success")
    throw new Error(`${label}.${functionName} reverted`);
  console.log(
    `  ${label}.${functionName}(${args.map(String).join(", ")}): ${hash}`,
  );
};
const same = (a: unknown, b: string) =>
  String(a).toLowerCase() === b.toLowerCase();

const admin = (await read(guard, G.abi, "admin")) as Address;
const known = deployment.contracts.FoboAdapter;
const kept = known && (await client.getCode({ address: known }));
console.log(`chain ${chainId} via ${new URL(rpc).host}`);
console.log(
  `deployer ${deployer.address}, ${formatEther(await client.getBalance({ address: deployer.address }))} ETH; the guard's admin ${admin}`,
);
if (!same(admin, deployer.address))
  throw new Error(
    "the deployer is not the guard's admin: it cannot add a venue",
  );
console.log(`guard ${guard}, HookList ${hookList}`);
console.log(
  `FoboAdapter: ${kept ? `${known} (kept)` : `new (router ${UNIVERSAL_ROUTER}, Permit2, WETH, FoboHook ${FOBO_HOOK}, the HookList)`}`,
);
if (!sending) {
  console.log(
    "A dry run: nothing sent. Add --send to deploy FoboAdapter, set its treasury and add it as a venue.",
  );
  process.exit(0);
}

let fobo = known;
if (!kept) {
  const hash = await wallet.deployContract({
    abi: F.abi,
    bytecode: F.bytecode,
    args: [UNIVERSAL_ROUTER, PERMIT2, WETH, FOBO_HOOK, hookList],
  });
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success" || !receipt.contractAddress)
    throw new Error("FoboAdapter: deploy reverted");
  fobo = receipt.contractAddress;
  deployment.contracts.FoboAdapter = fobo;
  deployment.blocks.FoboAdapter = Number(receipt.blockNumber);
  writeFileSync(outFile, `${JSON.stringify(deployment, null, 2)}\n`);
  console.log(`FoboAdapter ${fobo} (block ${receipt.blockNumber}): ${hash}`);
}
if (!same(await read(fobo!, F.abi, "treasury"), TREASURY))
  await call(fobo!, F.abi, "setTreasury", [TREASURY], "FoboAdapter");
if (!(await read(guard, G.abi, "isVenue", [fobo])))
  await call(guard, G.abi, "addVenue", [fobo], "SpinBotGuard");
console.log(
  `done: FoboAdapter ${fobo} is a venue. Add it to the app's bots config (adapters.fobo).`,
);
