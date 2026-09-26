# Bailiff demo console

One page that drives the Bailiff demo on a **local Anvil fork of Sepolia**: the collateral rail
(where the seized RWA goes), issuer, market maker and keeper actions, the borrower's position, and
a timeline of decoded receipts. The server signs with local demo keys and refuses to run against
anything but Anvil (chain 31337) on loopback.

## Run it

```sh
bun install --frozen-lockfile
(cd ../contracts && forge build)   # the ABI script reads contracts/out
bun run abis                        # writes src/lib/abis.generated.ts
bun run dev                         # bound to http://127.0.0.1:5173 by vite.config.ts
```

Anvil must already be running the fork, and `../scripts/deploy-local.sh` must have written the
manifest, the baseline snapshot and this folder's `.env` (see the root README).

## Environment

Create `.env` in this folder (it is git-ignored). Names only; never commit or paste the values.

| Variable          | Meaning                                                        |
| ----------------- | -------------------------------------------------------------- |
| `DEMO_MODE`       | must be `local`; any other value disables the server API       |
| `ANVIL_RPC`       | `http://127.0.0.1:8545` or another loopback URL                |
| `ISSUER_PK`       | issuer key (NAV oracle, pool wrapper owner)                    |
| `MM_PK`           | market maker key (liquidity desk owner)                        |
| `KEEPER_PK`       | keeper key (no flags, no tokens, gas only)                     |
| `DEPLOYMENT_FILE` | absolute path to the O2 manifest, `anvil.json`                 |
| `SNAPSHOT_FILE`   | absolute path to the O4 snapshot record, not the manifest      |
| `EVIDENCE_FILE`   | absolute path to a `.jsonl` evidence log, outside `contracts/` |

Every action, failed ones included, and every local reset is appended to `EVIDENCE_FILE`, so the
receipts of a branch discarded by a reset stay on disk. Keep it outside the repository, for
example next to the dev manifest; it is never committed.

While an action runs, the server holds `SNAPSHOT_FILE.lock` (it carries the server's pid). A
second server or the integration test answers 409 instead of sending between a reset's
`evm_revert` and `evm_snapshot`; a lock left by a crashed process is taken over. Before the new
snapshot is taken, the reverted chain is checked against the O3 baseline (NAV 100, borrower
1,000 RWA / 75,000 USDC, adapter wrapper on, L 5e17). A mismatch answers 409 and takes no new
snapshot, since that would save the stray transaction into every later reset; rerun
`../scripts/deploy-local.sh`.

## Checks

```sh
bun run check   # svelte-check, test files included (src/bun-test.d.ts declares bun:test)
bun test        # unit, server and route tests; no chain, and .env is never loaded
bun run build
BAILIFF_INTEGRATION=1 bun test --env-file=.env src/lib/server/anvil.integration.test.ts   # crash, horizon, reset on Anvil
```

Do not run `check`, `build` or `abis` while recording the demo: they regenerate `.svelte-kit` and
make Vite reload the page. The timeline survives a reload in the same tab (sessionStorage), but a
reload mid-scene still breaks the take. Stop any keeper process before using the page; both would
sign with the keeper key.

Record in a real 1280x720 viewport (Chrome started with `--window-size=1280,720 --kiosk`, or the
DevTools device toolbar), not in a 1280x720 window: the browser's own bars take their height from
the timeline. For the receipt scene, "Show evidence full height" hides the role panels so the
timeline grows while the collateral rail stays on screen.

## After the contract fix

When the contracts change, rerun `../scripts/deploy-local.sh` (it rewrites the manifest, the
snapshot record and `.env`), then `bun run abis` so the spec getters, errors and events decode from
the new artifacts.

## Design

Reading this as: single-screen evidence console for ETHGlobal technical judges, recorded at
1280x720, ledger language (`../DESIGN.md`), dial ENERGY 2 / RHYTHM 2 / MOTION 2.

- **ENERGY 2:** the collateral rail is the focal point, first under the header at every width. The
  one ochre accent marks only the rail segments the seized RWA crossed and the two liquidate
  buttons; ink on warm paper carries every other figure, and steel pushes context back.
- **RHYTHM 2:** a full-width rail, then four role panels that each hold only their role's reads
  and controls, then the receipts. The panels are not copies of each other.
- **MOTION 2:** one motion, with one purpose. When a liquidation is mined, the ochre sweep crosses
  MiniLend, the adapter, the pool wrapper and PoolManager, then the USDC lanes fill back to the
  adapter and split into debt repaid, the keeper's bounty and the residual: to the borrower wallet
  on the deployed snapshot, or a credit withdrawable by the borrower once MiniLend applies it. A
  simulation that would revert runs dashed up to the contract that refuses it and stops at a red
  bar. It plays once per action and never loops; a reloaded page and `prefers-reduced-motion` show
  the final state at once. Apart from a 120 ms grey-out when figures turn stale, nothing else moves.
