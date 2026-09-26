# Bailiff

An additional liquidation route for restricted RWA collateral: the issuer allowlists one sell-only contract, while any keeper can trigger liquidation without supplying USDC.

## Run the demo locally

The demo runs on a local Anvil fork of Sepolia pinned at block 11782723. It uses the real Uniswap Labs PoolManager, PermissionsAdapterFactory and PermissionedHooks, and our own mock RWA, USDC and lending market. Nothing is sent to Sepolia.

### 1. Requirements

- Foundry 1.7.1 (`forge`, `anvil`, `cast`), bun 1.3.10, git and jq.
- A Sepolia RPC that serves archive state at block 11782723. The public Tenderly gateway `https://sepolia.gateway.tenderly.co` served it during development without a key.

### 2. Build the contracts

```bash
git clone --recurse-submodules <REPO_URL> bailiff
cd bailiff/contracts
echo 'SEPOLIA_ARCHIVE_RPC=https://sepolia.gateway.tenderly.co' > .env   # git-ignored
forge build
```

### 3. Start the fork (terminal 1)

```bash
cd bailiff/contracts
source .env
anvil --host 127.0.0.1 --chain-id 31337 --fork-url "$SEPOLIA_ARCHIVE_RPC" --fork-block-number 11782723
```

Leave it running. Anvil prints ten funded dev accounts with their private keys. The demo uses accounts 0 to 4 as issuer, market maker, keeper, borrower and lender.

### 4. Deploy, seed and snapshot (terminal 2)

```bash
cd bailiff/contracts
export RPC_URL=http://127.0.0.1:8545
export ISSUER_PK=<key 0> MM_PK=<key 1> KEEPER_PK=<key 2> BORROWER_PK=<key 3> LENDER_PK=<key 4>
forge script script/DeployPA.s.sol:DeployPA --rpc-url "$RPC_URL" --broadcast --slow
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast --slow
forge script script/Seed.s.sol:Seed --rpc-url "$RPC_URL" --broadcast --slow
```

Deployment runs in two stages because the PermissionsAdapter address is only known from DeployPA's mined receipt: DeployPA creates the RWA, USDC and PermissionsAdapter, and Deploy takes those three addresses from that receipt. Seed funds the market maker, lender and borrower. The scripts write the manifest to `deployments/anvil.json`.

Then record the healthy baseline, which the console's reset button returns to:

```bash
SNAP=$(cast rpc evm_snapshot --rpc-url "$RPC_URL" | tr -d '"')
jq -n --arg id "$SNAP" \
      --arg commit "$(jq -r .sourceCommit deployments/anvil.json)" \
      --arg manifest "$PWD/deployments/anvil.json" \
      '{snapshotId: $id, chainId: 31337, sourceCommit: $commit, manifestPath: $manifest}' \
  > deployments/anvil-snapshot.json
```

If Anvil restarts, repeat steps 3 and 4.

### 5. Start the console (terminal 2)

```bash
cd ../frontend
bun install --frozen-lockfile
bun run abis
ROOT=$(git rev-parse --show-toplevel)
mkdir -p "$HOME/bailiff-demo"
cat > .env <<EOF
DEMO_MODE=local
ANVIL_RPC=http://127.0.0.1:8545
ISSUER_PK=<key 0>
MM_PK=<key 1>
KEEPER_PK=<key 2>
DEPLOYMENT_FILE=$ROOT/contracts/deployments/anvil.json
SNAPSHOT_FILE=$ROOT/contracts/deployments/anvil-snapshot.json
EVIDENCE_FILE=$HOME/bailiff-demo/evidence.jsonl
EOF
bun run dev
```

Open http://127.0.0.1:5173. `frontend/.env` is git-ignored. The server signs only on chain 31337 over loopback, and every action and reset is appended to `EVIDENCE_FILE`. [frontend/README.md](frontend/README.md) explains each variable.

### 6. Walk the demo

1. **Baseline:** NAV 100, pool spot 100, the borrower holds 1,000 RWA of collateral against 75,000 USDC of debt, and the keeper holds 0 USDC.
2. Issuer, **Cut NAV to 85**: only the oracle moves; the pool price stays at 100.
3. Keeper, **Simulate direct route**: it reverts `NotAllowlisted`, because the keeper may not hold the RWA.
4. Keeper, **Liquidate full position**: in one transaction the RWA goes Market → Adapter → PermissionsAdapter → PoolManager, the debt is repaid and the keeper earns a USDC bounty while holding 0 RWA.
5. **Reset to healthy snapshot**, **Cut NAV to 85**, then market maker, **Withdraw 95% of liquidity**. **Liquidate full position** now reverts and changes nothing; **Liquidate 10,000 USDC** closes a chunk instead.
6. **Reset to healthy snapshot**, **Cut NAV to 85**, then keeper, **Simulate adapter route**: it succeeds. Issuer, **Revoke adapter wrapper**, then **Simulate adapter route** again: it reverts with the hook's `Unauthorized`.
7. **Reset to healthy snapshot**.

The timeline shows every receipt decoded, and simulations are labelled as simulations, never as transactions. Do not run `bun run check`, `bun run build` or `bun run abis` while recording: they make Vite reload the page. If a reset reports that the chain no longer matches the baseline, rerun step 4.
