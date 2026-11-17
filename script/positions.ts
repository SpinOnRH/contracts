/**
 * Deploys SpinPositions and the USDG position venues' adapters with their mainnet settings
 * lists each adapter in its risk class and sets the operator.
 * The names are the worker's venue names: the worker's
 * POSITION_ADAPTERS is `name=address` for each.
 *
 * Used by `npm run deploy:positions` (deploy-positions.ts) and `npm run deploy:mainnet`. The
 * deploying wallet is SpinPositions' admin; handing it to the team's Safe (setAdmin) is a later step.
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import type {
  Abi,
  Account,
  Address,
  Chain,
  Hex,
  PublicClient,
  WalletClient,
} from "viem";

const CONTRACTS = join(dirname(fileURLToPath(import.meta.url)), "..");

export const artifact = (file: string, name = file.replace(/\..*$/, "")) => {
  const path = join(CONTRACTS, "out", file, `${name}.json`);
  if (!existsSync(path))
    throw new Error(`missing ${path}: run "forge build" at the repo root`);
  const a = JSON.parse(readFileSync(path, "utf8"));
  return { abi: a.abi as Abi, bytecode: a.bytecode.object as Hex };
};

const M = {
  registry: "0x000000006551c19487814612e58FE06813775758",
  accountV3: "0x41C8f39463A868d3A88af00cd0fe7102F30E44eC",
  usdg: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
  weth: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
  up: "0x57C0E45cB534413D1C20A4240955d6bB250BB4F1",
  upWeth: "0x23D641FeCcD207E8794c593e8240444A0674C4Ba",
  route: "0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca",
  ethUsd: "0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9",
  usdgUsd: "0x61B7e5650328764B076A108EFF5fa7282a1B9aD2",
  v3Npm: "0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3",
  posm: "0x58daec3116aae6D93017bAAea7749052E8a04fA7",
  stateView: "0xF3334192D15450CdD385c8B70e03f9A6bD9E673b",
  upNpm: "0x07F44c47743A2f36414A82b9F558ECFCf0EEdCEf",
} as const satisfies Record<string, Address>;

/** Chainlink band 1%, feeds at most 25 h old; UP sales within 300 ticks of a 30-minute average. */
const DEV_BPS = 100;
const FEED_AGE_S = 25 * 3600;
const TWAP_S = 1800;
const UP_TICKS = 300;

const upConfig = (
  pool: Address,
  gauge: Address,
  minWidth: number,
  maxWidth: number,
) => ({
  pool,
  gauge,
  positionManager: M.upNpm,
  weth: M.weth,
  usdg: M.usdg,
  up: M.up,
  upPool: M.upWeth,
  swapPool: M.route,
  ethUsd: M.ethUsd,
  usdgUsd: M.usdgUsd,
  maxDeviationBps: DEV_BPS,
  maxFeedAge: FEED_AGE_S,
  minWidth,
  maxWidth,
  twapWindow: TWAP_S,
  maxUpTickDeviation: UP_TICKS,
});

/** Each venue: its adapter's artifact and constructor arguments, and its risk class. */
export const VENUES: {
  name: string;
  riskClass: number;
  file: string;
  args: unknown[];
}[] = [
  {
    name: "steakhouse",
    riskClass: 1,
    file: "MorphoVaultAdapter.sol",
    args: ["0xBeEff033F34C046626B8D0A041844C5d1A5409dd"],
  },
  {
    name: "spark",
    riskClass: 1,
    file: "MorphoVaultAdapter.sol",
    args: ["0xde770c84FE66E063336b31737cFE9790f18c4087"],
  },
  {
    name: "uniswap-v3",
    riskClass: 2,
    file: "UniswapV3LpAdapter.sol",
    args: [
      "0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a",
      M.v3Npm,
      M.route,
      M.weth,
      M.usdg,
      M.ethUsd,
      M.usdgUsd,
      DEV_BPS,
      FEED_AGE_S,
      200,
      14_000,
    ],
  },
  {
    name: "fables",
    riskClass: 2,
    file: "UniswapV4LpAdapter.sol",
    args: [
      {
        currency0: "0x0000000000000000000000000000000000000000",
        currency1: M.usdg,
        fee: 0x800000,
        tickSpacing: 10,
        hooks: "0x06a889870C8f83640D6816319f72e2aA579b6080",
      },
      M.posm,
      M.stateView,
      M.route,
      M.weth,
      M.usdg,
      M.ethUsd,
      M.usdgUsd,
      DEV_BPS,
      FEED_AGE_S,
      200,
      14_000,
    ],
  },
  {
    name: "up-weth",
    riskClass: 3,
    file: "UpGaugeAdapter.sol",
    args: [
      upConfig(
        "0x16679e2ac1A798865eCf1c1639e67693ddB1C220",
        "0xC39791dF403a77E8Fb0f614d60eD96f790b69343",
        200,
        14_000,
      ),
    ],
  },
  {
    name: "nvda",
    riskClass: 3,
    file: "UpFeedGaugeAdapter.sol",
    args: [
      upConfig(
        "0x18A5aF4E442F8be68968Cc1f00D537F8af2D12Cd",
        "0xCeE5D9356415A28407F723b1F5837F79de7D67EC",
        240,
        15_000,
      ),
      "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15",
      80 * 3600,
    ],
  },
  {
    name: "gld",
    riskClass: 3,
    file: "UpFeedGaugeAdapter.sol",
    args: [
      upConfig(
        "0xc9dc17b3fa4d12022E980B1e8Ed118d29c58F2a8",
        "0xc14Bdc429EFBD882ac7CbDf2e36cdEA9fC3941c9",
        200,
        14_000,
      ),
      "0x470A51258068043bd43dC0a56245625C9fE86eB0",
      80 * 3600,
    ],
  },
  {
    name: "coin",
    riskClass: 3,
    file: "UpFeedGaugeAdapter.sol",
    args: [
      upConfig(
        "0xF13a2d87E13904E0B38270686D5953A7D8207b91",
        "0xFF0FB4B6af08c4b33855f24b6aE0ECc262D61Ba0",
        240,
        15_000,
      ),
      "0xA3a468A452940B7D6b69991207B508c609a98Ef2",
      80 * 3600,
    ],
  },
  {
    name: "ausd",
    riskClass: 4,
    file: "UpStableGaugeAdapter.sol",
    args: [
      upConfig(
        "0x29e3F3d9891cAcF213361Bcbcb7728970D53BaA8",
        "0x28E041Aa25b0a11D97E6F159A55F60043d479e52",
        20,
        200,
      ),
      50,
    ],
  },
];

export interface PositionsDeployment {
  spinPositions: Address;
  adapters: Record<string, Address>;
  /** The block each was deployed in. */
  blocks?: Record<string, number>;
}

/**
 * SpinPositions for `collection` (its admin: the deploying wallet; 5% of realised gains to
 * `feeTo`, the fee splitter, or `treasury` without one; gas refunds at most 1 gwei and 0.001 ETH a
 * job), then `venues` (default: all), each listed in its class and withdrawing to `treasury`, and
 * `operator`. Resumable: a contract in `existing` that has code is kept,
 * and a setting already in place is not sent again; `save` is called after each change.
 */
export const deployPositions = async (
  client: PublicClient,
  wallet: WalletClient & { account: Account; chain: Chain },
  o: {
    collection: Address;
    treasury: Address;
    /** The FeeSplitter: SpinPositions' fees (and its withdrawals) go there. */
    feeTo?: Address;
    operator: Address;
    venues?: string[];
    existing?: Partial<PositionsDeployment>;
    save?: (d: PositionsDeployment) => void;
    log?: (line: string) => void;
  },
): Promise<PositionsDeployment> => {
  const log = o.log ?? (() => {});
  const d: PositionsDeployment = {
    spinPositions: o.existing?.spinPositions ?? ("0x" as Address),
    adapters: { ...o.existing?.adapters },
    blocks: { ...o.existing?.blocks },
  };
  const hasCode = async (a?: Address) =>
    Boolean(a && a !== "0x" && (await client.getCode({ address: a })));
  const deploy = async (
    key: string,
    a: { abi: Abi; bytecode: Hex },
    args: unknown[],
  ) => {
    const hash = await wallet.deployContract({
      abi: a.abi,
      bytecode: a.bytecode,
      args,
      account: wallet.account,
      chain: wallet.chain,
    });
    const r = await client.waitForTransactionReceipt({ hash });
    if (r.status !== "success" || !r.contractAddress)
      throw new Error(`${key}: deploy reverted`);
    d.blocks![key] = Number(r.blockNumber);
    log(`${key.padEnd(14)} ${r.contractAddress}`);
    return r.contractAddress;
  };
  const factory = artifact("SpinPositions.sol");
  if (await hasCode(d.spinPositions))
    log(`${"SpinPositions".padEnd(14)} ${d.spinPositions} (kept)`);
  else {
    d.spinPositions = await deploy("SpinPositions", factory, [
      M.registry,
      M.accountV3,
      o.collection,
      M.usdg,
      wallet.account.address,
      o.feeTo ?? o.treasury,
      500,
      10n ** 9n,
      10n ** 15n,
      110_000,
      80_000,
    ]);
    o.save?.(d);
  }
  const read = (functionName: string, args: unknown[]) =>
    client.readContract({
      address: d.spinPositions,
      abi: factory.abi,
      functionName,
      args,
    });
  const call = async (functionName: string, args: unknown[]) => {
    const hash = await wallet.writeContract({
      address: d.spinPositions,
      abi: factory.abi,
      functionName,
      args,
      account: wallet.account,
      chain: wallet.chain,
    });
    if ((await client.waitForTransactionReceipt({ hash })).status !== "success")
      throw new Error(`${functionName} reverted`);
    log(`${functionName}(${args.join(", ")})`);
  };
  for (const v of VENUES.filter(
    (x) => !o.venues || o.venues.includes(x.name),
  )) {
    if (await hasCode(d.adapters[v.name]))
      log(`${v.name.padEnd(14)} ${d.adapters[v.name]} (kept)`);
    else {
      d.adapters[v.name] = await deploy(v.name, artifact(v.file), v.args);
      o.save?.(d);
    }
    if (Number(await read("classOf", [d.adapters[v.name]])) !== v.riskClass)
      await call("setVenue", [d.adapters[v.name], v.riskClass]);
    // Its withdrawals go to the protocol's treasury only, and none until it is set.
    const adapter = { address: d.adapters[v.name]!, abi: artifact(v.file).abi };
    if (
      (
        (await client.readContract({
          ...adapter,
          functionName: "treasury",
        })) as string
      ).toLowerCase() !== o.treasury.toLowerCase()
    ) {
      const hash = await wallet.writeContract({
        ...adapter,
        functionName: "setTreasury",
        args: [o.treasury],
        account: wallet.account,
        chain: wallet.chain,
      });
      if (
        (await client.waitForTransactionReceipt({ hash })).status !== "success"
      )
        throw new Error(`${v.name}.setTreasury reverted`);
      log(`${v.name}.setTreasury(${o.treasury})`);
    }
  }
  const feeTo = o.feeTo ?? o.treasury;
  if (
    ((await read("treasury", [])) as string).toLowerCase() !==
    feeTo.toLowerCase()
  )
    await call("setTreasury", [feeTo]);
  if (!(await read("isOperator", [o.operator])))
    await call("setOperator", [o.operator, true]);
  o.save?.(d);
  return d;
};
