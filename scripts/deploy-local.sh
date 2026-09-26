#!/usr/bin/env bash
# Local demo deploy. Puts the Bailiff fixture on a local Anvil fork of Sepolia (block 11782723) in two phases,
# checks the healthy baseline, takes the baseline evm_snapshot, writes the manifest and the snapshot record to
# contracts/deployments/ and writes frontend/.env. Local Anvil (chain 31337) only, with Anvil's default dev accounts 0..4.
#
# Usage: scripts/deploy-local.sh
# Env:    ANVIL_RPC (default http://127.0.0.1:8545; must be loopback)
#         EVIDENCE_FILE (default: the value already in frontend/.env, else $HOME/bailiff-demo/evidence.jsonl)
# On any failure after the first transaction, Anvil is reverted to a pre-deploy snapshot and no output file changes.
set -euo pipefail
umask 077

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONTRACTS="$REPO/contracts"
OUT="$CONTRACTS/deployments"
LOGS="$OUT/logs"
RPC="${ANVIL_RPC:-http://127.0.0.1:8545}"
MANIFEST="$OUT/anvil.json"
SNAPSHOT="$OUT/anvil-snapshot.json"
FRONTEND_ENV="$REPO/frontend/.env"

CHAIN_ID=31337
FORK_BLOCK=11782723
FORK_BLOCK_HASH=0x408c76d91eb65f4b2469b6399c2e07dee5a5a2640fb50565cf487c8e8bbe214e
PM=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
FACTORY=0xE6B0d96919334C33d06266d1420F97f6f434fA2B
HOOK=0x51247E2291d290d17C08813A175AC86465EdE8c0
STATE_VIEW=0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C
# Anvil's public default dev mnemonic; accounts 0..4 = issuer, mm, keeper, borrower, lender.
MNEMONIC="test test test test test test test test test test test junk"
PA_CREATED_TOPIC=$(cast keccak "PermissionsAdapterCreated(address,address)")
INITIALIZE_TOPIC=$(cast keccak "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)")

die() { echo "deploy-local: $*" >&2; exit 1; }
log() { echo "deploy-local: $*"; }
lower() { tr '[:upper:]' '[:lower:]'; }
checksum() { cast to-check-sum-address "$1"; }
rpc() { cast rpc --rpc-url "$RPC" "$@"; }

# ------------------------------------------------------------------ 0. guards: local Anvil fork only
preflight() {
  case "$RPC" in http://127.0.0.1:* | http://localhost:*) ;; *) die "ANVIL_RPC must be a loopback URL" ;; esac
  [ "$(cast chain-id --rpc-url "$RPC")" = "$CHAIN_ID" ] || die "chain id is not $CHAIN_ID"
  local info; info=$(rpc anvil_nodeInfo) || die "endpoint is not an Anvil node"
  [ "$(jq -r '.forkConfig.forkBlockNumber' <<<"$info")" = "$FORK_BLOCK" ] || die "Anvil is not forked at $FORK_BLOCK"
  [ "$(cast block "$FORK_BLOCK" --field hash --rpc-url "$RPC")" = "$FORK_BLOCK_HASH" ] || die "fork block hash mismatch"
  local accounts; accounts=$(rpc eth_accounts)
  for i in 0 1 2 3 4; do
    [ "$(jq -r ".[$i]" <<<"$accounts")" = "$(addr_of "$i" | lower)" ] || die "Anvil account $i is not the default dev account"
  done
}

addr_of() { cast wallet address --mnemonic "$MNEMONIC" --mnemonic-index "$1"; }
pk_of() { cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index "$1"; }

# ------------------------------------------------------------------ receipt helpers (read mined state, not predictions)
receipt_ok() { # hash -> receipt json, dies unless status 1
  local r; r=$(cast receipt "$1" --json --rpc-url "$RPC") || die "no receipt for tx $1"
  [ "$(jq -r .status <<<"$r")" = "0x1" ] || die "tx $1 not successful"
  printf '%s' "$r"
}
tx_hash_where() { # broadcast.json jq-filter -> single hash
  local hs; hs=$(jq -r "[.transactions[] | select($2) | .hash] | .[]" "$1") || die "cannot read $1"
  [ "$(wc -w <<<"$hs" | tr -d ' ')" = 1 ] || die "expected exactly one tx matching $2 in $1"
  printf '%s' "$hs"
}
created_address() { # broadcast.json contractName -> contractAddress from the mined receipt (CREATE)
  local h a r
  h=$(tx_hash_where "$1" ".transactionType == \"CREATE\" and .contractName == \"$2\"") || exit 1
  r=$(receipt_ok "$h") || exit 1
  a=$(jq -r .contractAddress <<<"$r") || exit 1
  [ -n "$a" ] && [ "$a" != null ] || die "no contractAddress in receipt of $2"
  checksum "$a"
}
create2_address() { # broadcast.json contractName -> address created by the mined CREATE2 (call trace)
  local h a t
  h=$(tx_hash_where "$1" ".transactionType == \"CREATE2\" and .contractName == \"$2\"") || exit 1
  receipt_ok "$h" >/dev/null || exit 1
  t=$(rpc debug_traceTransaction "$h" '{"tracer":"callTracer"}') || die "cannot trace $h"
  a=$(jq -r '[.. | objects | select(.type? == "CREATE2") | .to] | if length == 1 then .[0] else "none" end' <<<"$t") || exit 1
  [ -n "$a" ] && [ "$a" != none ] || die "no single CREATE2 in trace of $h"
  checksum "$a"
}
topic_addr() { echo "0x${1: -40}"; }

# ------------------------------------------------------------------ phase 1: RWA + PA through the real factory
phase1() {
  log "phase 1: MockRWA3643 + factory.createPermissionsAdapter"
  (cd "$CONTRACTS" && ISSUER_PK="$ISSUER_PK" forge script script/LocalDeployPA.s.sol:LocalDeployPA \
    --rpc-url "$RPC" --broadcast --slow) >"$LOGS/phase1.log" 2>&1 || die "phase 1 failed, see $LOGS/phase1.log"
  BC1="$CONTRACTS/broadcast/LocalDeployPA.s.sol/$CHAIN_ID/run-latest.json"
  RWA=$(created_address "$BC1" MockRWA3643)
  local h; h=$(tx_hash_where "$BC1" "(.function // \"\") | startswith(\"createPermissionsAdapter\")")
  local logs; logs=$(receipt_ok "$h" | jq -c --arg f "$(echo "$FACTORY" | lower)" --arg t "$PA_CREATED_TOPIC" \
    '[.logs[] | select((.address | ascii_downcase) == $f and .topics[0] == $t)]')
  [ "$(jq length <<<"$logs")" = 1 ] || die "expected exactly one PermissionsAdapterCreated from the real factory"
  [ "$(topic_addr "$(jq -r '.[0].topics[2]' <<<"$logs")" | lower)" = "$(echo "$RWA" | lower)" ] || die "event token != RWA"
  PA=$(checksum "$(topic_addr "$(jq -r '.[0].topics[1]' <<<"$logs")")")
  [ "$(cast call "$FACTORY" 'permissionsAdapterOf(address)(address)' "$PA" --rpc-url "$RPC" | lower)" = "$(echo "$RWA" | lower)" ] \
    || die "factory.permissionsAdapterOf(PA) != RWA"
  local first; first=$(receipt_ok "$(jq -r '.transactions[0].hash' "$BC1")")
  DEPLOY_BLOCK=$(cast to-dec "$(jq -r .blockNumber <<<"$first")")
  log "  RWA=$RWA PA=$PA (from PermissionsAdapterCreated in $h) deployBlock=$DEPLOY_BLOCK"
}

# ------------------------------------------------------------------ phase 2: verify PA, USDC, pool, protocol, seed
phase2() {
  log "phase 2: verify PA, USDC, pool, MiniLend/adapter/desk, seed roles"
  (cd "$CONTRACTS" && ISSUER_PK="$ISSUER_PK" MM_PK="$MM_PK" BORROWER_PK="$BORROWER_PK" LENDER_PK="$LENDER_PK" \
    KEEPER="$KEEPER" RWA="$RWA" PA="$PA" PA_IS_CURRENCY0=true \
    forge script script/LocalDeploy.s.sol:LocalDeploy --rpc-url "$RPC" --broadcast --slow) \
    >"$LOGS/phase2.log" 2>&1 || die "phase 2 failed, see $LOGS/phase2.log"
  BC2="$CONTRACTS/broadcast/LocalDeploy.s.sol/$CHAIN_ID/run-latest.json"
  USDC=$(create2_address "$BC2" SpecMockUSDC)
  MARKET=$(created_address "$BC2" MiniLend)
  ADAPTER=$(created_address "$BC2" LiquidationAdapter)
  DESK=$(created_address "$BC2" LiquidityDesk)
  local h; h=$(tx_hash_where "$BC2" "(.function // \"\") | startswith(\"initialize(\")")
  local ev; ev=$(receipt_ok "$h" | jq -c --arg p "$(echo "$PM" | lower)" --arg t "$INITIALIZE_TOPIC" \
    '[.logs[] | select((.address | ascii_downcase) == $p and .topics[0] == $t)]')
  [ "$(jq length <<<"$ev")" = 1 ] || die "expected exactly one PoolManager Initialize"
  POOL_ID=$(jq -r '.[0].topics[1]' <<<"$ev")
  CURRENCY0=$(checksum "$(topic_addr "$(jq -r '.[0].topics[2]' <<<"$ev")")")
  CURRENCY1=$(checksum "$(topic_addr "$(jq -r '.[0].topics[3]' <<<"$ev")")")
  local want; want=$(cast keccak "$(cast abi-encode 'k(address,address,uint24,int24,address)' "$CURRENCY0" "$CURRENCY1" 3000 60 "$HOOK")")
  [ "$want" = "$POOL_ID" ] || die "poolId from Initialize != keccak(poolKey)"
  [ "$(echo "$CURRENCY0" | lower)" = "$(echo "$PA" | lower)" ] && [ "$(echo "$CURRENCY1" | lower)" = "$(echo "$USDC" | lower)" ] \
    || die "pool currencies are not (PA, USDC)"
  # simulated addresses printed by the script must equal what the receipts say
  for pair in "USDC:$USDC" "MARKET:$MARKET" "ADAPTER:$ADAPTER" "DESK:$DESK"; do
    grep -qi "simulated ${pair%%:*} ${pair#*:}" "$LOGS/phase2.log" || die "simulated ${pair%%:*} != mined ${pair#*:}"
  done
  log "  USDC=$USDC MARKET=$MARKET ADAPTER=$ADAPTER DESK=$DESK poolId=$POOL_ID"
}

write_manifest() { # -> $1
  local txs; txs=$(jq -c -s '[.[].transactions[].hash]' "$BC1" "$BC2")
  for h in $(jq -r '.[]' <<<"$txs"); do receipt_ok "$h" >/dev/null; done
  jq -n --arg forkBlockHash "$FORK_BLOCK_HASH" \
    --arg poolManager "$(checksum "$PM")" --arg factory "$(checksum "$FACTORY")" --arg hook "$(checksum "$HOOK")" \
    --arg stateView "$(checksum "$STATE_VIEW")" --arg rwa "$RWA" --arg usdc "$USDC" --arg pa "$PA" \
    --arg market "$MARKET" --arg adapter "$ADAPTER" --arg desk "$DESK" \
    --arg issuer "$ISSUER" --arg mm "$MM" --arg keeper "$KEEPER" --arg borrower "$BORROWER" --arg lender "$LENDER" \
    --arg c0 "$CURRENCY0" --arg c1 "$CURRENCY1" --arg poolId "$POOL_ID" --arg deployBlock "$DEPLOY_BLOCK" \
    --arg sourceCommit "$SOURCE_COMMIT" --argjson txs "$txs" '{
      schemaVersion: 1, network: "anvil-fork", chainId: 31337, forkBlock: "11782723", forkBlockHash: $forkBlockHash,
      poolManager: $poolManager, factory: $factory, hook: $hook, stateView: $stateView,
      rwa: $rwa, usdc: $usdc, pa: $pa, market: $market, adapter: $adapter, desk: $desk,
      issuer: $issuer, mm: $mm, keeper: $keeper, borrower: $borrower, lender: $lender,
      poolKey: {currency0: $c0, currency1: $c1, fee: 3000, tickSpacing: 60, hooks: $hook},
      poolId: $poolId, deployBlock: $deployBlock, initialLiquidity: "500000000000000000",
      tickLower: -887220, tickUpper: 887220, navFloorBps: 9900, keeperBps: 5000,
      sourceCommit: $sourceCommit, deployTransactions: $txs, liquidationTransaction: null }' >"$1"
}

write_env() { # -> $1 (keys never echoed)
  {
    echo "DEMO_MODE=local"
    echo "ANVIL_RPC=$RPC"
    echo "ISSUER_PK=$ISSUER_PK"
    echo "MM_PK=$MM_PK"
    echo "KEEPER_PK=$KEEPER_PK"
    echo "DEPLOYMENT_FILE=$MANIFEST"
    echo "SNAPSHOT_FILE=$SNAPSHOT"
    echo "EVIDENCE_FILE=$EVIDENCE_FILE"
  } >"$1"
  chmod 600 "$1"
}

# ------------------------------------------------------------------ main
PRE_SNAP=""
TMP_MANIFEST="$OUT/anvil.json.tmp"
TMP_SNAPSHOT="$OUT/anvil-snapshot.json.tmp"
TMP_ENV="$FRONTEND_ENV.tmp" # matches the frontend .gitignore (.env.*)
on_exit() {
  local rc=$?
  rm -f "$TMP_MANIFEST" "$TMP_SNAPSHOT" "$TMP_ENV"
  if [ "$rc" -ne 0 ] && [ -n "$PRE_SNAP" ]; then
    echo "deploy-local: failed; reverting Anvil to pre-deploy snapshot $PRE_SNAP" >&2
    [ "$(rpc evm_revert "$PRE_SNAP")" = true ] || echo "deploy-local: evm_revert($PRE_SNAP) did not return true" >&2
  fi
}
trap on_exit EXIT

SOURCE_COMMIT=$(git -C "$REPO" rev-parse HEAD)
[ -z "$(git -C "$REPO" status --porcelain -- contracts)" ] \
  || log "warning: contracts/ has uncommitted changes; the manifest still records $SOURCE_COMMIT"
if [ -z "${EVIDENCE_FILE:-}" ] && [ -f "$FRONTEND_ENV" ]; then
  EVIDENCE_FILE=$(sed -n 's/^EVIDENCE_FILE=//p' "$FRONTEND_ENV" | tail -1)
fi
EVIDENCE_FILE="${EVIDENCE_FILE:-$HOME/bailiff-demo/evidence.jsonl}"
mkdir -p "$LOGS" "$(dirname "$EVIDENCE_FILE")"

ISSUER=$(addr_of 0); MM=$(addr_of 1); KEEPER=$(addr_of 2); BORROWER=$(addr_of 3); LENDER=$(addr_of 4)
preflight
ISSUER_PK=$(pk_of 0); MM_PK=$(pk_of 1); KEEPER_PK=$(pk_of 2); BORROWER_PK=$(pk_of 3); LENDER_PK=$(pk_of 4)

(cd "$CONTRACTS" && forge build script/LocalDeployPA.s.sol script/LocalDeploy.s.sol >"$LOGS/build.log" 2>&1) \
  || die "forge build failed, see $LOGS/build.log"
PRE_SNAP=$(rpc evm_snapshot | jq -r .)
log "pre-deploy rollback snapshot $PRE_SNAP"

phase1
phase2
write_manifest "$TMP_MANIFEST"
ANVIL_RPC="$RPC" "$REPO/scripts/verify-local.sh" "$TMP_MANIFEST" | tee "$LOGS/verify.log"

BASE_SNAP=$(rpc evm_snapshot | jq -r .)
[ -n "$BASE_SNAP" ] && [ "$BASE_SNAP" != null ] || die "evm_snapshot returned nothing"
jq -n --arg id "$BASE_SNAP" --arg c "$SOURCE_COMMIT" --arg p "$MANIFEST" \
  '{snapshotId: $id, chainId: 31337, sourceCommit: $c, manifestPath: $p}' >"$TMP_SNAPSHOT"
write_env "$TMP_ENV"
chmod 644 "$TMP_MANIFEST" "$TMP_SNAPSHOT"
mv "$TMP_MANIFEST" "$MANIFEST"
mv "$TMP_SNAPSHOT" "$SNAPSHOT"
mv "$TMP_ENV" "$FRONTEND_ENV"
PRE_SNAP="" # success: keep the deployment
log "baseline snapshot $BASE_SNAP -> $SNAPSHOT"
log "manifest -> $MANIFEST"
log "frontend env -> $FRONTEND_ENV (keys not printed)"
