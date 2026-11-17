/**
 * The scripts' settings: from the environment, else from .env at the repo root.
 * The environment wins, so `RPC_URL=… npm run deploy:testnet` overrides the file.
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** The repo root: deployments/, out/ and .env are here. */
export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
export const ENV_FILE = join(ROOT, ".env");

const env = existsSync(ENV_FILE) ? readFileSync(ENV_FILE, "utf8") : "";

/** NAME from the environment, else .env, else `fallback`; with none of them, an error. */
export const setting = (name: string, fallback?: string): string => {
  if (process.env[name]) return process.env[name]!;
  const m = env.match(new RegExp(`^${name}=(.*)$`, "m"));
  const v = m && m[1]!.replace(/"/g, "").trim();
  if (v) return v;
  if (fallback !== undefined) return fallback;
  throw new Error(`set ${name} (in the environment or ${ENV_FILE})`);
};

/** The mainnet deploying key: DEPLOYER_KEY, else DEPLOYER_PRIVATE_KEY. */
export const deployerKey = () =>
  setting("DEPLOYER_KEY", "") || setting("DEPLOYER_PRIVATE_KEY");
