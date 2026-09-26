# Bailiff demo console

One page that drives the Bailiff demo on a **local Anvil fork of Sepolia**: issuer, market maker
and keeper actions, the borrower's position, and a timeline of decoded receipts. The server signs
with local demo keys and refuses to run against anything but Anvil (chain 31337) on loopback.

## Run it

```sh
bun install --frozen-lockfile
(cd ../contracts && forge build)   # the ABI script reads contracts/out
bun run abis                        # writes src/lib/abis.generated.ts
bun run dev                         # bound to http://127.0.0.1:5173 by vite.config.ts
```

Anvil must already be running the fork and the local deploy and seed must have written the
manifest and the baseline snapshot (OPERATIONS.md O4).

## Environment

Create `.env` in this folder (it is git-ignored). Names only; never commit or paste the values.

| Variable          | Meaning                                                   |
| ----------------- | --------------------------------------------------------- |
| `DEMO_MODE`       | must be `local`; any other value disables the server API  |
| `ANVIL_RPC`       | `http://127.0.0.1:8545` or another loopback URL           |
| `ISSUER_PK`       | issuer key (NAV oracle, pool wrapper owner)               |
| `MM_PK`           | market maker key (liquidity desk owner)                   |
| `KEEPER_PK`       | keeper key (no flags, no tokens, gas only)                |
| `DEPLOYMENT_FILE` | absolute path to the O2 manifest, `anvil.json`            |
| `SNAPSHOT_FILE`   | absolute path to the O4 snapshot record, not the manifest |

Every action and every local reset is appended to `evidence.jsonl` next to `SNAPSHOT_FILE`, so
the receipts of a branch discarded by a reset stay on disk.

## Checks

```sh
bun run check   # svelte-check
bun test        # unit, server and route tests; no chain needed
bun run build
BAILIFF_INTEGRATION=1 bun test src/lib/server/anvil.integration.test.ts   # crash, horizon, reset on Anvil
```

Do not run `check`, `build` or `abis` while recording the demo: they regenerate `.svelte-kit` and
make Vite reload the page. The timeline survives a reload in the same tab (sessionStorage), but a
reload mid-scene still breaks the take. Stop any keeper process before using the page; both would
sign with the keeper key.

## After the contract fix

When the fixed contracts are redeployed, rerun the local deploy and seed (it rewrites the manifest
and the snapshot record), then `bun run abis` so the spec getters, errors and events decode from
the new artifacts.
