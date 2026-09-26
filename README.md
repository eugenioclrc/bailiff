# Bailiff

An additional liquidation route for restricted RWA collateral: the issuer allowlists one sell-only contract, while any keeper can trigger liquidation without supplying USDC.

## Uniswap integration

Bailiff runs on the Uniswap Labs Permissioned Pools deployed on Sepolia, and keeps the canonical hook. Our `LiquidationAdapter` is an `allowedWrapper` of our own PermissionsAdapter, which is created and verified through the real factory.

| Contract | Sepolia address |
| --- | --- |
| PoolManager | [0xE03A1074c86CFeDd5C142C4F04F1a1536e203543](https://sepolia.etherscan.io/address/0xE03A1074c86CFeDd5C142C4F04F1a1536e203543) |
| PermissionsAdapterFactory | [0xE6B0d96919334C33d06266d1420F97f6f434fA2B](https://sepolia.etherscan.io/address/0xE6B0d96919334C33d06266d1420F97f6f434fA2B) |
| PermissionedHooks | [0x51247e2291d290d17c08813a175ac86465ede8c0](https://sepolia.etherscan.io/address/0x51247e2291d290d17c08813a175ac86465ede8c0) |

The addresses come from the [official deployment table](https://github.com/Uniswap/contracts/blob/main/deployments/11155111.md). The fork tests pin Sepolia block 11782723.

| Integration point | Source |
| --- | --- |
| Entry point: check the pool's `allowedHooks`, then open `PoolManager.unlock` | [LiquidationAdapter.sol#L104-L108](contracts/src/e2e/LiquidationAdapter.sol#L104-L108) |
| `unlockCallback`: quote at NAV, sell, repay the market, settle, pay out in USDC | [LiquidationAdapter.sol#L110-L141](contracts/src/e2e/LiquidationAdapter.sol#L110-L141) |
| `msgSender()` returns the adapter, so the adapter, not the keeper, is the permissioned party | [LiquidationAdapter.sol#L91-L93](contracts/src/e2e/LiquidationAdapter.sol#L91-L93) |
| One fixed pool key, and an exact-input sale of exactly the seized amount | [pool key](contracts/src/e2e/LiquidationAdapter.sol#L95-L100), [sale](contracts/src/e2e/LiquidationAdapter.sol#L143-L156), [complete-sale check](contracts/src/e2e/LiquidationAdapter.sol#L119-L120) |
| Paying the permissioned currency: `sync`, transfer the RWA to the PermissionsAdapter, `wrapToPoolManager` of the seized amount, `settle` | [LiquidationAdapter.sol#L130-L134](contracts/src/e2e/LiquidationAdapter.sol#L130-L134) |
| Market-maker liquidity settled through the same wrapping path | [LiquidityDesk.sol#L89-L104](contracts/src/e2e/LiquidityDesk.sol#L89-L104) |
| Tests against the real Sepolia contracts on the pinned fork | [full liquidation by a keeper with 0 USDC](contracts/test/ForkLiquidation.t.sol#L123-L167), [sale through the real PermissionedHooks](contracts/test/ForkSepolia.t.sol#L25-L81), [acceptance tests](contracts/test/finalspec) |

The hook and the PoolManager both emit an event named `Swap`; the demo console tells them apart by the emitting address. Integrator notes for Uniswap are in [FEEDBACK.md](FEEDBACK.md).

## Run the demo locally

The demo runs on a local Anvil fork of Sepolia pinned at block 11782723. It uses the real Uniswap Labs PoolManager, PermissionsAdapterFactory and PermissionedHooks, plus our own mock RWA, USDC and lending market. Nothing is sent to Sepolia. You need two terminals.

### 1. Requirements

- Foundry 1.7.1 (`forge`, `anvil`, `cast`), bun 1.3.10, git, jq and python3.
- A Sepolia RPC that serves archive state at block 11782723. The public Tenderly gateway `https://sepolia.gateway.tenderly.co` works without a key.
- Ports 8545 (Anvil) and 5173 (console) free.

### 2. Clone and build (once)

```bash
git clone --recurse-submodules <REPO_URL> bailiff
cd bailiff/contracts
echo 'SEPOLIA_ARCHIVE_RPC=https://sepolia.gateway.tenderly.co' > .env   # git-ignored
forge build
cd ../frontend
bun install --frozen-lockfile
bun run abis   # generates the console ABIs from contracts/out
```

### 3. Terminal 1: start the fork

```bash
cd bailiff/contracts
source .env
anvil --host 127.0.0.1 --chain-id 31337 --fork-url "$SEPOLIA_ARCHIVE_RPC" --fork-block-number 11782723
```

Leave it running. Restarting Anvil wipes the deployment; run step 4 again afterwards.

### 4. Terminal 2: deploy, seed and snapshot

```bash
cd bailiff
./scripts/deploy-local.sh
```

It takes about 20 seconds and ends with `verify: all baseline checks passed`. The script:

- refuses to run unless the endpoint is a local Anvil forked at block 11782723 with the real Uniswap contracts (chain id, fork block hash and code hashes are checked);
- deploys in two stages: the RWA and our PermissionsAdapter through the real factory, then USDC, the pool at 100 USDC per RWA, MiniLend, LiquidationAdapter and LiquidityDesk, taking every address from the mined receipts;
- seeds the roles with Anvil's default dev accounts: 0 issuer, 1 market maker (the only LP), 2 keeper (no USDC, no RWA), 3 borrower (1,000 RWA of collateral, 75,000 USDC of debt), 4 lender;
- checks the healthy baseline with `scripts/verify-local.sh`, then takes the Anvil snapshot that the console's reset button returns to;
- writes `contracts/deployments/anvil.json` (manifest), `contracts/deployments/anvil-snapshot.json` and `frontend/.env`. All three are git-ignored.

If a step fails, Anvil is rolled back and no file changes; logs are in `contracts/deployments/logs/`. The console appends every action to `$HOME/bailiff-demo/evidence.jsonl`; set `EVIDENCE_FILE` before running the script to use another path.

### 5. Terminal 2: start the console

```bash
cd frontend
bun run dev
```

Open http://127.0.0.1:5173. The server signs only with the Anvil dev keys that step 4 wrote to `frontend/.env`, and only on chain 31337 over loopback.

### 6. Walk the demo

1. **Baseline:** NAV 100, pool spot 100, the borrower holds 1,000 RWA of collateral against 75,000 USDC of debt, and the keeper holds 0 USDC.
2. Issuer, **Cut NAV to 85**: only the oracle moves; the pool price stays at 100.
3. Keeper, **Simulate direct route**: it reverts `NotAllowlisted`, because the keeper may not hold the RWA.
4. Keeper, **Liquidate full position**: in one transaction the RWA goes Market → Adapter → PermissionsAdapter → PoolManager, the debt is repaid and the keeper earns a USDC bounty while holding 0 RWA.
5. **Reset to healthy snapshot**, **Cut NAV to 85**, then market maker, **Withdraw 95% of liquidity**. **Liquidate full position** now reverts and changes nothing; **Liquidate 10,000 USDC** closes a chunk instead.
6. **Reset to healthy snapshot**, **Cut NAV to 85**, then keeper, **Simulate adapter route**: it succeeds. Issuer, **Revoke adapter wrapper**, then **Simulate adapter route** again: it reverts with the hook's `Unauthorized`.
7. **Reset to healthy snapshot**.

The timeline shows every receipt decoded, and simulations are labelled as simulations, never as transactions.

### If something goes wrong

- **Reset says the chain no longer matches the baseline**, or Anvil was restarted: run `./scripts/deploy-local.sh` again and reload the console page. The running console picks up the new deployment without a restart.
- **Liquidations are disabled because the NAV is stale:** the NAV expires one day after it was set. Run `./scripts/deploy-local.sh` again and reload the page.
- **Check the chain without sending anything:** `./scripts/verify-local.sh` compares it with the healthy baseline.
- **While recording**, do not run `bun run check`, `bun run build` or `bun run abis`: they make Vite reload the page.
