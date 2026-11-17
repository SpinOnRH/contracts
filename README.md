# spin-contracts

The Solidity contracts of Spin, with their tests and deploy scripts. They are deployed on Robinhood
Chain mainnet (chain 4663) and testnet (chain 46630).

## Contents

| Path              | What it holds                                                                                                                                                                                  |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/collection/` | `Spinners`, the ERC721-C collection. Each token has its own token-bound account (ERC-6551).                                                                                                    |
| `src/bots/`       | `SpinBotGuard`, which trades for a Spinner's account through approved venue adapters (`adapters/`); `Routes`, the route ids; `HookList`, the allowed Uniswap V4 hooks; `SpinnerCreatorVaults`. |
| `src/positions/`  | `SpinPositions` and `SpinPosition`, a Spinner's USDG position, and the venue adapters it can hold (`adapters/`).                                                                               |
| `src/fees/`       | `FeeSplitter`, which splits the protocol's fees between the burn wallet and the treasury.                                                                                                      |
| `src/testnet/`    | `TestPons`, a small bonding curve for the test network.                                                                                                                                        |
| `test/`           | Unit tests. `test/integration/` holds the fork tests, which run against mainnet.                                                                                                               |
| `script/`         | Deploy and admin scripts (TypeScript, run with `tsx`).                                                                                                                                         |
| `deployments/`    | The deployed addresses, one file per chain. The deploy scripts read and update them.                                                                                                           |

## Requirements

- [Foundry](https://getfoundry.sh) 1.8 or later (`forge`)
- Node.js 24 or later

## Setup

```sh
npm ci           # tsx, viem and TypeScript, for the scripts
npm run setup    # clones the pinned Solidity libraries into lib/ (see foundry.toml)
forge build
```

`lib/` is not committed. `npm run setup` clones each library at a fixed version. Run it again after
a version changes in `package.json`.

The testnet deploy also needs Tokenbound's contracts:

```sh
npm run setup:tokenbound
```

## Tests

```sh
npm run test:unit    # unit tests only: no RPC needed
npm test             # unit tests and fork tests
```

The fork tests in `test/integration/` run only when `RPC_URL` is set, and are skipped when it is
not. `RPC_URL` must be a Robinhood Chain mainnet **archive** node.

**Forge loads `.env` by itself.** If `.env` sets `RPC_URL`, `npm test` runs the fork tests. A fork
test reads chain state one storage slot at a time, so one run can make thousands of paid RPC calls.
Use `npm run test:unit` for usual work.

If your RPC provider refuses forge's `anvil_nodeInfo` probe (Alchemy returns HTTP 400),
`npm run rpc-shim` starts a local proxy that answers it. The proxy forwards everything else to
`RPC_URL_UPSTREAM`, else to `RPC_URL` from `.env`.

TypeScript check for the scripts:

```sh
npm run typecheck
```

## Settings (`.env`)

The scripts read each setting from the environment first, then from `.env` at the repo root
(`script/env.ts`). A value in the environment overrides the file:

```sh
RPC_URL=https://rpc.testnet.chain.robinhood.com DEPLOYER_KEY=0x… npm run deploy:testnet
```

`.env` is in `.gitignore`. **Do not commit it**: it holds private keys.

| Setting                                                                   | Used by                                | What it is                                                                                                               |
| ------------------------------------------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `RPC_URL`                                                                 | all scripts, fork tests                | The chain's RPC. Mainnet scripts and fork tests need mainnet. Testnet scripts default to Robinhood's public testnet RPC. |
| `DEPLOYER_KEY`                                                            | all deploy scripts                     | The deploying key. It becomes the admin of what it deploys.                                                              |
| `DEPLOYER_PRIVATE_KEY`                                                    | `deploy:mainnet`, `deploy:fobo`        | Used when `DEPLOYER_KEY` is not set.                                                                                     |
| `ETHERSCAN_API_KEY`                                                       | `forge verify-contract`                | Etherscan V2 key. The scripts do not read it and do not verify contracts.                                                |
| `WHITELIST_SIGNER_KEY`                                                    | `deploy:mainnet`, `sign:whitelist`     | The whitelist signer. Its address is set on the collection.                                                              |
| `WHITELIST_SUPPLY`, `DEV_MINT`                                            | `deploy:mainnet`                       | Optional: whitelist mints in all (default 100), dev mint (default 50).                                                   |
| `OPERATOR_MNEMONIC`, `SEND_LANES`                                         | deploy scripts (`script/operators.ts`) | The senders' keys. Index 0 and up are the guard's operators.                                                             |
| `OPERATOR_ADDRESSES`, `OPERATOR_ADDRESS`, `OPERATOR_PRIVATE_KEY`          | deploy scripts (`script/operators.ts`) | Other ways to name the operators when there is no mnemonic.                                                              |
| `OPERATOR_FLOAT_ETH`                                                      | deploy scripts                         | ETH each operator is topped up to (default 0.01).                                                                        |
| `POSITIONS_OPERATOR_INDEX`, `POSITIONS_OPERATOR_ADDRESS`                  | `deploy:mainnet`, `deploy:positions`   | The positions' operator: the mnemonic at this index (default 100), or an address.                                        |
| `SPINNERS_ADDRESS`, `TREASURY_ADDRESS`, `FEE_SPLITTER`, `POSITION_VENUES` | `deploy:positions`                     | The collection, the treasury, the optional fee receiver and the venues to deploy.                                        |
| `SIGN_RPC_URL`                                                            | `sign:whitelist`                       | Optional: an RPC for signing only (default `RPC_URL`).                                                                   |
| `BASE_URI`                                                                | `deploy:testnet`                       | Optional: the test collection's metadata base URI (default empty; the owner can set it later).                           |
| `DEPLOYMENT_FILE`                                                         | testnet scripts                        | Optional: the deployment file (default `deployments/<chainId>.json`).                                                    |

Mainnet and testnet use the same names. The testnet scripts stop on mainnet (chain 4663), and the
positions and FOBO scripts stop on all other chains.

## Deploying

The mainnet scripts (`deploy:mainnet`, `deploy:positions`, `deploy:fobo`) print their plan and send
nothing unless you add `-- --send`. **The testnet scripts send at once.** Each script is safe to run
again: it keeps what `deployments/` lists and what has code, and it does not send a setting that is
already in place.

```sh
forge build                                  # first: the scripts read out/

npm run deploy:mainnet                       # dry run
npm run deploy:mainnet -- --send
npm run deploy:positions -- --send           # the USDG positions only
npm run deploy:fobo -- --send                # the FoboAdapter only

npm run deploy:testnet                       # testnet, sends: also deploys Tokenbound and TestPons
npm run setup:testnet-spin                   # testnet, sends: a test $SPIN and mint prices
npm run sign:whitelist -- <spinners address> <list.csv> [out.json]
```

After a deploy, the scripts print the addresses to copy into the app's and the worker's settings.
