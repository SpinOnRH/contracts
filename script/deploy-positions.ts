/**
 * Deploys the USDG positions to Robinhood Chain mainnet (or a local fork of it): SpinPositions and
 * the venues' adapters with their mainnet settings (script/positions.ts), each adapter listed in
 * its risk class, and the positions' operator. The deploying address is SpinPositions' admin.
 * Writes deployments/positions-4663.json, and prints the worker's and the app's settings.
 *
 *   forge build                                   # once
 *   npm run deploy:positions         # a dry run: what it would do
 *   npm run deploy:positions -- --send
 *
 * Safe to run again: whatever the file lists and has code is kept, and a setting already in place
 * is not sent again (a run that stopped half-way picks up where it stopped).
 *
 * Settings, from the environment or the repo's .env:
 *   RPC_URL           the mainnet RPC (or a fork of it)
 *   DEPLOYER_KEY      the deploying key: SpinPositions' admin
 *   SPINNERS_ADDRESS  the Spinners collection
 *   TREASURY_ADDRESS  where our 5% of realised gains goes (the team's)
 *   the operator: POSITIONS_OPERATOR_ADDRESS, else OPERATOR_MNEMONIC at POSITIONS_OPERATOR_INDEX
 *                 (default 100, as the worker derives it)
 *   POSITION_VENUES   optional, comma-separated venue names (default: all nine)
 *   DEPLOYMENT_FILE   optional (default: deployments/positions-<chainId>.json)
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import {
  createPublicClient,
  createWalletClient,
  defineChain,
  formatEther,
  http,
  isAddress,
  type Address,
  type Hex,
} from "viem";
import { mnemonicToAccount, privateKeyToAccount } from "viem/accounts";

import { deployPositions, VENUES, type PositionsDeployment } from "./positions";

import { ROOT, setting } from "./env";

const address = (name: string, value: string) => {
  if (!isAddress(value)) throw new Error(`${name} is not an address`);
  return value as Address;
};

const send = process.argv.includes("--send");
const rpc = setting("RPC_URL");
const rawKey = setting("DEPLOYER_KEY");
const deployer = privateKeyToAccount(
  (rawKey.startsWith("0x") ? rawKey : `0x${rawKey}`) as Hex,
);
const chainId = await createPublicClient({ transport: http(rpc) }).getChainId();
if (chainId !== 4663)
  throw new Error(
    `chain ${chainId}: the USDG positions' venues are Robinhood Chain mainnet's (4663), or a fork of it`,
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

const collection = address("SPINNERS_ADDRESS", setting("SPINNERS_ADDRESS"));
const treasury = address("TREASURY_ADDRESS", setting("TREASURY_ADDRESS"));
/** The FeeSplitter: the 5% fee goes there (70% to the burn wallet, 30% to the treasury). Without it, all to the treasury. */
const feeTo = setting("FEE_SPLITTER", "")
  ? address("FEE_SPLITTER", setting("FEE_SPLITTER"))
  : undefined;
const mnemonic = setting("OPERATOR_MNEMONIC", "");
const operator = address(
  "POSITIONS_OPERATOR_ADDRESS",
  setting("POSITIONS_OPERATOR_ADDRESS", "") ||
    (mnemonic
      ? mnemonicToAccount(mnemonic, {
          addressIndex: Number(setting("POSITIONS_OPERATOR_INDEX", "100")),
        }).address
      : ""),
);
const venues = setting("POSITION_VENUES", "")
  .split(",")
  .map((v) => v.trim())
  .filter(Boolean);
for (const v of venues)
  if (!VENUES.some((x) => x.name === v))
    throw new Error(
      `POSITION_VENUES: no venue "${v}" (${VENUES.map((x) => x.name).join(", ")})`,
    );

const outFile = setting(
  "DEPLOYMENT_FILE",
  join(ROOT, "deployments", `positions-${chainId}.json`),
);
const existing: Partial<PositionsDeployment> = existsSync(outFile)
  ? JSON.parse(readFileSync(outFile, "utf8"))
  : {};
const save = (d: PositionsDeployment) => {
  mkdirSync(dirname(outFile), { recursive: true });
  writeFileSync(
    outFile,
    `${JSON.stringify({ chainId, admin: deployer.address, collection, treasury, operator, ...d }, null, 2)}\n`,
  );
};

const balance = await client.getBalance({ address: deployer.address });
console.log(`chain ${chainId} via ${new URL(rpc).host}`);
console.log(
  `deployer (admin) ${deployer.address}, ${formatEther(balance)} ETH`,
);
console.log(
  `collection ${collection}\ntreasury   ${treasury}\nfees to    ${feeTo ?? `${treasury} (no FEE_SPLITTER)`}\noperator   ${operator}`,
);
console.log(
  `venues     ${(venues.length ? venues : VENUES.map((v) => v.name)).join(", ")}`,
);
console.log(`file       ${outFile}${existsSync(outFile) ? " (resuming)" : ""}`);
if (!send) {
  console.log("\nA dry run: nothing sent. Add --send to deploy.");
  process.exit(0);
}

const d = await deployPositions(client, wallet, {
  collection,
  treasury,
  feeTo,
  operator,
  venues: venues.length ? venues : undefined,
  existing,
  save,
  log: (l) => console.log(l),
});
console.log(`\nwrote ${outFile}\n`);
console.log("The worker:");
console.log(`  POSITIONS_ADDRESS=${d.spinPositions}`);
console.log(
  `  POSITION_ADAPTERS=${Object.entries(d.adapters)
    .map(([n, a]) => `${n}=${a}`)
    .join(",")}`,
);
console.log("The app's bots config, mainnet `positions`:");
console.log(`  positions: "${d.spinPositions}",`);
