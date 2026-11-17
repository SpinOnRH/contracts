/**
 * Deploys the protocol to Robinhood Chain mainnet (4663), or a local fork of it, for the closed
 * beta: the Spinners collection with both mints
 * closed and the beta settings (free whitelist mint of 1 per wallet, free activation), the dev
 * mint, the FeeSplitter, the guard and its venues, the creator vaults, the operators, and the USDG
 * positions. Writes deployments/4663.json (and positions-4663.json), and prints the settings for
 * the services and the app.
 *
 *   forge build                                    # once
 *   npm run deploy:mainnet            # a dry run: the plan, nothing sent
 *   npm run deploy:mainnet -- --send
 *   npm run deploy:mainnet -- --send --remove-replaced   # after the worker and app use replaced adapters' successors
 *
 * Safe to run again: whatever the file lists and has code is kept, and a setting already in place
 * is not sent again (a run that stopped half-way picks up where it stopped). The deployer is the
 * admin (owner) of everything it deploys; each address below is an initial value that the admin
 * can change later.
 *
 * Settings, from the environment or the repo's .env:
 *   RPC_URL               the mainnet RPC (or a fork of it)
 *   DEPLOYER_KEY          the deploying key (else DEPLOYER_PRIVATE_KEY)
 *   WHITELIST_SIGNER_KEY  the beta whitelist key: its address is set on the collection
 *   OPERATOR_MNEMONIC, SEND_LANES   the senders' keys (script/operators.ts), funded to
 *                         OPERATOR_FLOAT_ETH (default 0.01); index 100 is the positions' operator
 *   WHITELIST_SUPPLY      optional (default 100): how many whitelist mints in all
 *   DEV_MINT              optional (default 50): Spinners minted to the deployer at deployment
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import {
  createPublicClient,
  createWalletClient,
  defineChain,
  formatEther,
  http,
  parseAbi,
  toFunctionSelector,
  type Abi,
  type Address,
  type Hex,
} from "viem";
import { mnemonicToAccount, privateKeyToAccount } from "viem/accounts";

import { manageOperators, operatorAddresses, operatorFloat } from "./operators";
import { deployPositions, type PositionsDeployment } from "./positions";

import { ROOT, setting, deployerKey } from "./env";

const hex = (k: string) => (k.startsWith("0x") ? k : `0x${k}`) as Hex;

/** The protocol's wallets: initial values. */
const TREASURY: Address = "0x6d5dc628dAf2C6608D9DE1C9Af19564D36f46Fbf";
const BURN_WALLET: Address = "0x05edC7023B2fd152191ca0c46e6942b76334B0F8";

/** Robinhood Chain mainnet's shared contracts. */
const M = {
  registry: "0x000000006551c19487814612e58FE06813775758",
  accountV3: "0x41C8f39463A868d3A88af00cd0fe7102F30E44eC",
  ponsFactory: "0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e",
  ponsHook: "0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044",
  ponsEscrow: "0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e",
  torchFactory: "0x7891eA889899928aFE637e4Cca8106188427776a",
  torchRouter: "0x340278A0eF7c7e83418771504871619453bd0fA6",
  upRouter: "0xf5198743240fAC98db71868F34c70139b1eb0474",
  upFactory: "0xFA5429AEBa338BEa2BFcc1b9a889862Ee395bc28",
  upClRouter: "0xC062b870E813fcA720f1e002c234369Ab3aB9415",
  universalRouter: "0x8876789976dEcBfCbBbe364623C63652db8C0904",
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  weth: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
  dopplerAirlock: "0xeb7C034704eF8Dcd2D32324c1545f62fB4aD0862",
  /** FoboHook: every fobo.fun pool's hook, and its record of them (FoboAdapter checks each pool there). */
  foboHook: "0x0Af57F62982D03066ef917AcAd87F771c06528Ec",
  dopplerInitializer: "0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544",
} as const satisfies Record<string, Address>;

/** The V4 hooks the HookList allows, for the Uniswap, Pair and Long adapters (reviewed). */
const HOOKS: Address[] = [
  "0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044", // Pons
  "0x06a889870C8f83640D6816319f72e2aA579b6080", // Fables ETH/USDG
  "0x08E52564Bad99E05a694b4809F397edcA417A080",
  "0xB608a78761f179f7C56f15E7D13921B92F00a080",
  "0xA0E8fBFf13E24Af2b5e61A72800E08a161bDe080",
  "0x5Eb87F69bE00Df39981622Fd60A8De4b7837e080",
  "0x594e8e6281eDf2d363a0293a50004Cf868E7a080",
  "0xF1eE073811B14359D850825E48d200483200eDcd", // TaxHook
  "0xC15b155a3094934171A15625d1a80Aba267B6080", // SessionFeeHook
  "0x64E9ae1066c47Ac4a3cc0a5bd7B135908590e088", // ZiaFeeHook
  "0xb3cA29cF721380CEe8b8e4755F3865Ebc68Fe8cC", // Hookr
];

/** The Doppler hooks a Long pool may have (reviewed). */
const DOPPLER_HOOKS: Address[] = [
  "0x6f02324d20CC679d0E585290CAa6b16baCbC0F77", // Rehype, on every Long pool
];

const BASE_URI = "https://spin.trading/api/spinners/";
const ZERO: Address = "0x0000000000000000000000000000000000000000";

const sending = process.argv.includes("--send");
/** Earlier adapters stay venues until the worker and app use the new ones; a later run with this flag removes them. */
const removeReplaced = process.argv.includes("--remove-replaced");
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

const whitelistSigner = privateKeyToAccount(
  hex(setting("WHITELIST_SIGNER_KEY")),
).address;
const whitelistSupply = BigInt(setting("WHITELIST_SUPPLY", "100"));
const devMint = BigInt(setting("DEV_MINT", "50"));
const operators = operatorAddresses(setting);
if (!operators.length)
  throw new Error("set OPERATOR_MNEMONIC (and SEND_LANES)");
const positionsOperator = mnemonicToAccount(setting("OPERATOR_MNEMONIC"), {
  addressIndex: Number(setting("POSITIONS_OPERATOR_INDEX", "100")),
}).address;
const floatWei = operatorFloat(setting);

const outFile = setting(
  "DEPLOYMENT_FILE",
  join(ROOT, "deployments", `${chainId}.json`),
);
const positionsFile = join(dirname(outFile), `positions-${chainId}.json`);
/**
 * `retired`: contracts this deployment replaced (an earlier Spinners and the guard and positions
 * made for it), kept for the record; their guard and positions are paused and lose their operators.
 * `replaced`: earlier versions of a contract this file still names (by name, oldest first); an
 * adapter among them is no longer a venue on the guard. The worker reads them to name old trades.
 */
type Deployment = {
  chainId: number;
  deployer: Address;
  operators?: Address[];
  devMinted?: boolean;
  contracts: Record<string, Address>;
  blocks: Record<string, number>;
  retired?: {
    contracts: Record<string, Address>;
    positions?: Address;
    note?: string;
  };
  replaced?: Record<string, Address[]>;
};
const deployment: Deployment = existsSync(outFile)
  ? JSON.parse(readFileSync(outFile, "utf8"))
  : { chainId, deployer: deployer.address, contracts: {}, blocks: {} };
const save = () => {
  mkdirSync(dirname(outFile), { recursive: true });
  writeFileSync(outFile, `${JSON.stringify(deployment, null, 2)}\n`);
};

const balance = await client.getBalance({ address: deployer.address });
console.log(`chain ${chainId} via ${new URL(rpc).host}`);
console.log(
  `deployer (admin, owner, dev mint) ${deployer.address}, ${formatEther(balance)} ETH`,
);
console.log(`treasury ${TREASURY}, burn wallet ${BURN_WALLET}`);
console.log(
  `whitelist signer ${whitelistSigner}, whitelist supply ${whitelistSupply}, dev mint ${devMint}`,
);
console.log(
  `operators ${operators.join(", ")} (float ${formatEther(floatWei)} ETH each); positions operator ${positionsOperator}`,
);
console.log(`file ${outFile}${existsSync(outFile) ? " (resuming)" : ""}`);
if (!sending) {
  console.log(`
The plan (each step skipped when already done):
  1. Spinners ("Spinners", SPINNERS, 7,777; owner the deployer; treasury and royalty 7.77% to the treasury;
     ${BASE_URI}), both mints closed: free whitelist mint, 1 a transaction and 1 a wallet,
     the whitelist signer and supply, free activation; ${devMint} Spinners to the deployer
  2. FeeSplitter (70% to the burn wallet, 30% to the treasury)
  3. SpinBotGuard (treasury: the FeeSplitter; fee 0.5%)
  4. HookList (${HOOKS.length} hooks), PonsAdapter, UpAdapter, UniswapAdapter (reading the HookList)
  5. SpinnerCreatorVaults (treasury: the FeeSplitter; fee 0.5%) and its implementation, set
  6. PonsLaunchAdapter, TorchLaunchAdapter, PairLaunchAdapter, LongAdapter (${DOPPLER_HOOKS.length} Doppler hook), FoboAdapter
     An earlier UniswapAdapter, PairLaunchAdapter or LongAdapter (one with no HookList) is replaced;
     each that reads another HookList is pointed at this one
  7. The seven venues on the guard; every adapter's treasury: the treasury; with --remove-replaced
     (once the worker and app use the new adapters), the replaced ones are no longer venues
  8. The operators on the guard, each funded to its float
  9. The USDG positions (script/positions.ts; fee to the FeeSplitter), its operator funded

A dry run: nothing sent. Add --send to deploy.`);
  process.exit(0);
}

const artifact = (file: string, name = file.replace(".sol", "")) => {
  const path = join(ROOT, "out", file, `${name}.json`);
  if (!existsSync(path))
    throw new Error(`missing ${path}: run "forge build" at the repo root`);
  const a = JSON.parse(readFileSync(path, "utf8"));
  return { abi: a.abi as Abi, bytecode: a.bytecode.object as Hex };
};

/** Deploys `key` unless the file already has it and it has code. */
/** Deploys `key` unless the file names it and it has code; `outdated` says a kept one is an earlier version to replace (recorded in `replaced`). */
const deploy = async (
  key: string,
  a: { abi: Abi; bytecode: Hex },
  args: unknown[],
  outdated?: (code: Hex) => boolean,
) => {
  const known = deployment.contracts[key];
  const code = known && (await client.getCode({ address: known }));
  if (known && code && !outdated?.(code)) {
    console.log(`${key.padEnd(22)} ${known} (kept)`);
    return known;
  }
  if (known && code) {
    deployment.replaced = {
      ...deployment.replaced,
      [key]: [...(deployment.replaced?.[key] ?? []), known],
    };
    console.log(`${key.padEnd(22)} ${known} (an earlier version: replaced)`);
  }
  const hash = await wallet.deployContract({
    abi: a.abi,
    bytecode: a.bytecode,
    args,
  });
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success" || !receipt.contractAddress)
    throw new Error(`${key}: deploy reverted`);
  deployment.contracts[key] = receipt.contractAddress;
  deployment.blocks[key] = Number(receipt.blockNumber);
  save();
  console.log(`${key.padEnd(22)} ${receipt.contractAddress}`);
  return receipt.contractAddress;
};
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
  console.log(`  ${label}.${functionName}(${args.map(String).join(", ")})`);
};
const same = (a: unknown, b: string) =>
  String(a).toLowerCase() === b.toLowerCase();
/** Whether deployed code has a function: its selector is in the dispatcher. */
const hasFunction = (signature: string) => (code: Hex) =>
  code.includes(toFunctionSelector(signature).slice(2));
const readsNoHookList = (code: Hex) =>
  !hasFunction("setHookList(address)")(code);

// 1. The collection: both mints stay closed; the beta's settings can change only while they are.
const S = artifact("Spinners.sol");
// Each token's wallet is its Tokenbound account: a locked one is not transferred.
const spinners = await deploy("Spinners", S, [
  "Spinners",
  "SPINNERS",
  7777n,
  deployer.address,
  TREASURY,
  777n,
  BASE_URI,
  M.registry,
  M.accountV3,
]);
// Limit Break's transfer validator (ERC721-C): its default ruleset and list (only Payment Processor and
// authorized sales, such as OpenSea's), with direct transfers by smart wallets and 7702 accounts allowed.
const VALIDATOR: Address = "0x721C008fdff27BF06E7E123956E2Fe03B63342e3";
const RULESET_OPTIONS = 2 | 4; // FLAG_RULESET_WHITELIST_ALLOW_OTC_FOR_7702_DELEGATES | _FOR_SMART_WALLETS
const validatorAbi = parseAbi([
  "function getCollectionSecurityPolicy(address) view returns ((uint8 rulesetId, uint48 listId, address customRuleset, uint8 globalOptions, uint16 rulesetOptions, uint16 tokenType))",
  "function setRulesetOfCollection(address collection, uint8 rulesetId, address customRuleset, uint8 globalOptions, uint16 rulesetOptions)",
]);
if (same(await read(spinners, S.abi, "getTransferValidator"), VALIDATOR)) {
  const policy = (await read(
    VALIDATOR,
    validatorAbi,
    "getCollectionSecurityPolicy",
    [spinners],
  )) as { rulesetId: number; rulesetOptions: number };
  if (policy.rulesetId !== 0 || policy.rulesetOptions !== RULESET_OPTIONS)
    await call(
      VALIDATOR,
      validatorAbi,
      "setRulesetOfCollection",
      [spinners, 0, ZERO, 0, RULESET_OPTIONS],
      "TransferValidator",
    );
}
const open =
  (await read(spinners, S.abi, "mintOpen")) ||
  (await read(spinners, S.abi, "whitelistMintOpen"));
if (open)
  console.log(
    "  a mint is open: the beta's mint settings are left as they are",
  );
else {
  if (
    !same(await read(spinners, S.abi, "paymentToken"), ZERO) ||
    (await read(spinners, S.abi, "price")) !== 0n ||
    (await read(spinners, S.abi, "whitelistPrice")) !== 0n
  )
    await call(spinners, S.abi, "setPrice", [ZERO, 0n, 0n], "Spinners");
  if (
    (await read(spinners, S.abi, "maxPerTx")) !== 1n ||
    (await read(spinners, S.abi, "maxPerWallet")) !== 1n
  )
    await call(spinners, S.abi, "setLimits", [1n, 1n], "Spinners");
  if ((await read(spinners, S.abi, "whitelistSupply")) !== whitelistSupply)
    await call(
      spinners,
      S.abi,
      "setWhitelistSupply",
      [whitelistSupply],
      "Spinners",
    );
}
if (!same(await read(spinners, S.abi, "whitelistSigner"), whitelistSigner))
  await call(
    spinners,
    S.abi,
    "setWhitelistSigner",
    [whitelistSigner],
    "Spinners",
  );
if (
  !same(await read(spinners, S.abi, "activationToken"), ZERO) ||
  (await read(spinners, S.abi, "activationFee")) !== 0n
)
  await call(spinners, S.abi, "setActivation", [ZERO, 0n, 0], "Spinners");
if (!deployment.devMinted && devMint > 0n) {
  if ((await read(spinners, S.abi, "totalMinted")) !== 0n)
    throw new Error(
      "Spinners has mints already: the dev mint is not sent again (set devMinted in the file if it was)",
    );
  await call(
    spinners,
    S.abi,
    "reserve",
    [deployer.address, devMint],
    "Spinners",
  );
  deployment.devMinted = true;
  save();
}

// 2-6. The fees, the guard, its venues and the creator vaults.
const splitter = await deploy("FeeSplitter", artifact("FeeSplitter.sol"), [
  TREASURY,
  BURN_WALLET,
  7000,
]);
const G = artifact("SpinBotGuard.sol");
// Fee 0.5%; gas refunds priced at most at 1 gwei and at most 0.001 ETH a trade; 85k gas of overhead a trade (the gas the
// guard cannot measure was at most 78k, a Pons buy on a new day's limits, in mainnet trades to 2026-11-07), 80k in a tradeMany.
const guard = await deploy("SpinBotGuard", G, [
  M.registry,
  M.accountV3,
  spinners,
  deployer.address,
  splitter,
  50,
  10n ** 9n,
  10n ** 15n,
  85_000,
  80_000,
]);
const pons = await deploy("PonsAdapter", artifact("PonsAdapter.sol"), [
  M.ponsFactory,
]);
const up = await deploy("UpAdapter", artifact("UpAdapter.sol"), [
  M.upRouter,
  M.upFactory,
  M.upClRouter,
  M.weth,
]);
const H = artifact("HookList.sol");
const hookList = await deploy("HookList", H, [HOOKS]);
for (const hook of HOOKS)
  if (!(await read(hookList, H.abi, "allowedHook", [hook])))
    await call(hookList, H.abi, "setHook", [hook, true], "HookList");
const uniswap = await deploy(
  "UniswapAdapter",
  artifact("UniswapAdapter.sol"),
  [
    M.universalRouter,
    M.permit2,
    M.weth,
    M.ponsFactory,
    M.ponsHook,
    deployer.address,
    hookList,
  ],
  readsNoHookList,
);
const V = artifact("SpinnerCreatorVaults.sol");
const vaults = await deploy("SpinnerCreatorVaults", V, [splitter, 50]);
const vault = await deploy(
  "SpinnerCreatorVault",
  artifact("SpinnerCreatorVaults.sol", "SpinnerCreatorVault"),
  [vaults, M.torchRouter, M.torchFactory, M.ponsFactory, M.ponsEscrow],
);
if (!same(await read(vaults, V.abi, "implementation"), vault))
  await call(
    vaults,
    V.abi,
    "setImplementation",
    [vault],
    "SpinnerCreatorVaults",
  );
const ponsLaunch = await deploy(
  "PonsLaunchAdapter",
  artifact("PonsLaunchAdapter.sol"),
  [M.ponsFactory, vaults],
);
const torchLaunch = await deploy(
  "TorchLaunchAdapter",
  artifact("TorchLaunchAdapter.sol"),
  [M.torchFactory, vaults],
);
const pair = await deploy(
  "PairLaunchAdapter",
  artifact("PairLaunchAdapter.sol"),
  [
    M.universalRouter,
    M.permit2,
    M.weth,
    M.ponsFactory,
    M.ponsHook,
    M.torchFactory,
    3000,
    60,
    hookList,
  ],
  readsNoHookList,
);
const long = await deploy(
  "LongAdapter",
  artifact("LongAdapter.sol"),
  [
    M.universalRouter,
    M.permit2,
    M.weth,
    M.dopplerAirlock,
    M.dopplerInitializer,
    hookList,
    DOPPLER_HOOKS,
  ],
  readsNoHookList,
);
const fobo = await deploy("FoboAdapter", artifact("FoboAdapter.sol"), [
  M.universalRouter,
  M.permit2,
  M.weth,
  M.foboHook,
  hookList,
]);
// Each reads this HookList (one kept from before a new list was deployed is pointed at it).
for (const [name, address] of [
  ["UniswapAdapter", uniswap],
  ["PairLaunchAdapter", pair],
  ["LongAdapter", long],
  ["FoboAdapter", fobo],
] as const) {
  const abi = artifact(`${name}.sol`).abi;
  if (!same(await read(address, abi, "hookList"), hookList))
    await call(address, abi, "setHookList", [hookList], name);
}

// 7. The venues, and where each adapter's withdrawals go.
const venues: [string, Address][] = [
  ["PonsAdapter", pons],
  ["UpAdapter", up],
  ["UniswapAdapter", uniswap],
  ["PonsLaunchAdapter", ponsLaunch],
  ["TorchLaunchAdapter", torchLaunch],
  ["PairLaunchAdapter", pair],
  ["LongAdapter", long],
  ["FoboAdapter", fobo],
];
for (const [name, address] of venues) {
  if (!(await read(guard, G.abi, "isVenue", [address])))
    await call(guard, G.abi, "addVenue", [address], "SpinBotGuard");
  const abi = artifact(`${name}.sol`).abi;
  if (!same(await read(address, abi, "treasury"), TREASURY))
    await call(address, abi, "setTreasury", [TREASURY], name);
}
// Earlier versions of an adapter: no longer venues, once the worker and app trade through their replacements
// (until then, trading goes on through them).
for (const [name, addresses] of Object.entries(deployment.replaced ?? {})) {
  if (!venues.some(([n]) => n === name)) continue;
  for (const old of addresses) {
    if (!(await read(guard, G.abi, "isVenue", [old]))) continue;
    if (removeReplaced)
      await call(
        guard,
        G.abi,
        "removeVenue",
        [old],
        `SpinBotGuard (earlier ${name})`,
      );
    else
      console.log(
        `  ${old} (earlier ${name}) is still a venue: run again with --remove-replaced once the worker and app use ${name} ${deployment.contracts[name]}`,
      );
  }
}

// 8. The operators: on the guard, funded; those no longer in the set removed.
deployment.operators = await manageOperators({
  client,
  wallet,
  guard,
  guardAbi: G.abi,
  wanted: operators,
  previous: deployment.operators ?? [],
  floatWei,
});
save();

// 9. The USDG positions, with their fee to the FeeSplitter; their operator funded like the senders.
const existing: Partial<PositionsDeployment> = existsSync(positionsFile)
  ? JSON.parse(readFileSync(positionsFile, "utf8"))
  : {};
const positions = await deployPositions(client, wallet, {
  collection: spinners,
  treasury: TREASURY,
  feeTo: splitter,
  operator: positionsOperator,
  existing,
  save: (d) =>
    writeFileSync(
      positionsFile,
      `${JSON.stringify({ chainId, admin: deployer.address, collection: spinners, treasury: TREASURY, operator: positionsOperator, ...d }, null, 2)}\n`,
    ),
  log: (l) => console.log(l),
});
const opBalance = await client.getBalance({ address: positionsOperator });
if (opBalance < floatWei) {
  const hash = await wallet.sendTransaction({
    to: positionsOperator,
    value: floatWei - opBalance,
    chain,
    account: deployer,
  });
  await client.waitForTransactionReceipt({ hash });
  console.log(
    `  funded the positions operator with ${formatEther(floatWei - opBalance)} ETH`,
  );
}

// Retired contracts: their guard and positions are paused, and their operators removed.
for (const [name, address] of Object.entries(
  deployment.retired?.contracts ?? {},
)) {
  if (name !== "SpinBotGuard") continue;
  if (!(await read(address, G.abi, "paused")))
    await call(address, G.abi, "setPaused", [true], "retired SpinBotGuard");
  for (const op of operators)
    if (await read(address, G.abi, "isOperator", [op]))
      await call(
        address,
        G.abi,
        "setOperator",
        [op, false],
        "retired SpinBotGuard",
      );
}
if (deployment.retired?.positions) {
  const P = artifact("SpinPositions.sol");
  const old = deployment.retired.positions;
  if (!(await read(old, P.abi, "paused")))
    await call(old, P.abi, "setPaused", [true], "retired SpinPositions");
  if (await read(old, P.abi, "isOperator", [positionsOperator]))
    await call(
      old,
      P.abi,
      "setOperator",
      [positionsOperator, false],
      "retired SpinPositions",
    );
}

save();
const spent =
  balance - (await client.getBalance({ address: deployer.address }));
console.log(`
wrote ${outFile} and ${positionsFile}; the deployer spent ${formatEther(spent)} ETH this run

Commit these two files. The worker and the app need the new addresses:
The app's mint config (4663): collection "${spinners}"
HookList "${hookList}"
The app's bots config (4663): guard "${guard}", creatorVaults "${vaults}", positions "${positions.spinPositions}",
  adapters { pons: "${pons}", up: "${up}", uniswap: "${uniswap}", ponsLaunch: "${ponsLaunch}", torchLaunch: "${torchLaunch}", pair: "${pair}", long: "${long}", fobo: "${fobo}" }`);
