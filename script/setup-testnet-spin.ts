/**
 * Testnet only, after deploy-testnet.ts: makes the test network behave like
 * mainnet's mint. Launches a test $SPIN on TestPons (the deployer's creator
 * buy gives it plenty to hand to testers), then prices the mint in it
 * (10,000 public, 8,000 whitelist) and sets activation (5,000, 70% burned),
 * with the mints closed while it does, and opens the public mint again.
 * Safe to run again: it only changes what differs.
 *
 *   npm run setup:testnet-spin
 *
 * Settings as deploy-testnet.ts: RPC_URL, DEPLOYER_KEY, DEPLOYMENT_FILE.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import {
  createPublicClient,
  createWalletClient,
  defineChain,
  getAddress,
  http,
  parseAbi,
  parseEther,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { ROOT, setting } from "./env";

const E = 10n ** 18n;
const PRICE = 10_000n * E;
const WHITELIST_PRICE = 8_000n * E;
const ACTIVATION_FEE = 5_000n * E;
const BURN_BPS = 7_000;
/** The deployer's creator buy at launch: test $SPIN for testers. */
const CREATOR_BUY = parseEther("0.002");

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

const file = setting(
  "DEPLOYMENT_FILE",
  join(ROOT, "deployments", `${chainId}.json`),
);
if (!existsSync(file))
  throw new Error(
    `no deployment at ${file}: run "npm run deploy:testnet" first`,
  );
const deployment = JSON.parse(readFileSync(file, "utf8")) as {
  contracts: Record<string, Address>;
  blocks?: Record<string, number>;
};
const save = () =>
  writeFileSync(file, `${JSON.stringify(deployment, null, 2)}\n`);
const c = deployment.contracts;

const factoryAbi = parseAbi([
  "function launch(string name, string symbol) payable returns (address token, address curve)",
]);
const spinnersAbi = parseAbi([
  "function mintOpen() view returns (bool)",
  "function whitelistMintOpen() view returns (bool)",
  "function paymentToken() view returns (address)",
  "function price() view returns (uint256)",
  "function whitelistPrice() view returns (uint256)",
  "function activationToken() view returns (address)",
  "function activationFee() view returns (uint256)",
  "function activationBurnBps() view returns (uint16)",
  "function setMintOpen(bool open)",
  "function setWhitelistMintOpen(bool open)",
  "function setPrice(address paymentToken, uint256 price, uint256 whitelistPrice)",
  "function setActivation(address token, uint256 fee, uint16 burnBps)",
]);
const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
]);

const send = async (
  address: Address,
  abi: readonly unknown[],
  functionName: string,
  args: unknown[],
  value?: bigint,
) => {
  const hash = await wallet.writeContract({
    address,
    abi,
    functionName,
    args,
    value,
    chain,
    account: deployer,
  } as never);
  const r = await client.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`${functionName} reverted`);
  console.log(`${functionName.padEnd(16)} ${hash}`);
  return r;
};
const read = <T>(functionName: string) =>
  client.readContract({
    address: c.Spinners!,
    abi: spinnersAbi,
    functionName,
  } as never) as Promise<T>;

// 1. Test $SPIN on TestPons; the launch log names the token and its curve.
if (!c.SPIN) {
  const r = await send(
    c.TestPonsFactory!,
    factoryAbi,
    "launch",
    ["Spin (testnet)", "SPIN"],
    CREATOR_BUY,
  );
  const launched = r.logs.find(
    (l) => getAddress(l.address) === getAddress(c.TestPonsFactory!),
  ) as unknown as { topics: Hex[] };
  c.SPIN = getAddress(`0x${launched.topics[1]!.slice(26)}`);
  c.SPINCurve = getAddress(`0x${launched.topics[2]!.slice(26)}`);
  deployment.blocks = { ...deployment.blocks, SPIN: Number(r.blockNumber) };
  save();
}
console.log(
  `SPIN             ${c.SPIN} (deployer holds ${(await client.readContract({ address: c.SPIN, abi: erc20Abi, functionName: "balanceOf", args: [deployer.address] })) / E} SPIN)`,
);

// 2. The mint priced in $SPIN, and activation; both mints closed while the price changes.
const priced =
  getAddress(await read<Address>("paymentToken")) === c.SPIN &&
  (await read<bigint>("price")) === PRICE &&
  (await read<bigint>("whitelistPrice")) === WHITELIST_PRICE;
if (!priced) {
  const wasOpen = await read<boolean>("mintOpen");
  if (wasOpen) await send(c.Spinners!, spinnersAbi, "setMintOpen", [false]);
  if (await read<boolean>("whitelistMintOpen"))
    await send(c.Spinners!, spinnersAbi, "setWhitelistMintOpen", [false]);
  await send(c.Spinners!, spinnersAbi, "setPrice", [
    c.SPIN,
    PRICE,
    WHITELIST_PRICE,
  ]);
}
const activationSet =
  getAddress(await read<Address>("activationToken")) === c.SPIN &&
  (await read<bigint>("activationFee")) === ACTIVATION_FEE &&
  (await read<number>("activationBurnBps")) === BURN_BPS;
if (!activationSet)
  await send(c.Spinners!, spinnersAbi, "setActivation", [
    c.SPIN,
    ACTIVATION_FEE,
    BURN_BPS,
  ]);
if (!(await read<boolean>("mintOpen")))
  await send(c.Spinners!, spinnersAbi, "setMintOpen", [true]);

console.log(
  `\nmint: 10,000 SPIN (whitelist 8,000), activation 5,000 SPIN (70% burned); public mint open\nwrote ${file}`,
);
