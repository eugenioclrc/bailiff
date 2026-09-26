#!/usr/bin/env bash
# Read-only check of the healthy demo baseline against a manifest. Sends no transactions.
# Usage: scripts/verify-local.sh [manifest.json]   (default: contracts/deployments/anvil.json)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${1:-$REPO/contracts/deployments/anvil.json}"
RPC="${ANVIL_RPC:-http://127.0.0.1:8545}"
FAILS=0

case "$RPC" in http://127.0.0.1:* | http://localhost:*) ;; *) echo "verify: ANVIL_RPC must be loopback" >&2; exit 2 ;; esac
[ "$(cast chain-id --rpc-url "$RPC")" = 31337 ] || { echo "verify: chain is not 31337" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "verify: no manifest at $MANIFEST" >&2; exit 2; }

m() { jq -r "$1" "$MANIFEST"; }
call() { cast call --rpc-url "$RPC" "$@" | awk 'NF {print $1}'; }
check() { # name actual expected
  if [ "$2" = "$3" ]; then printf '  ok    %-34s %s\n' "$1" "$2"; else
    printf '  FAIL  %-34s got %s expected %s\n' "$1" "$2" "$3"; FAILS=$((FAILS + 1)); fi
}
lower() { tr '[:upper:]' '[:lower:]'; }

MARKET=$(m .market); ADAPTER=$(m .adapter); DESK=$(m .desk); PA=$(m .pa); RWA=$(m .rwa); USDC=$(m .usdc)
SV=$(m .stateView); PM=$(m .poolManager); FACTORY=$(m .factory); HOOK=$(m .hook); POOL_ID=$(m .poolId)
ISSUER=$(m .issuer); MM=$(m .mm); KEEPER=$(m .keeper); BORROWER=$(m .borrower); LENDER=$(m .lender)
C0=$(m .poolKey.currency0)

echo "baseline checks against $MANIFEST"
check "chainId" "$(cast chain-id --rpc-url "$RPC")" "$(m .chainId)"
check "market.nav" "$(call "$MARKET" 'nav()(uint256)')" "100000000000000000000"
check "market.MAX_STALENESS" "$(call "$MARKET" 'MAX_STALENESS()(uint256)')" "86400"
NAV_AT=$(call "$MARKET" 'navUpdatedAt()(uint256)')
NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
check "nav fresh (age < 1 day)" "$([ $((NOW - NAV_AT)) -lt 86400 ] && echo yes || echo no)" "yes"

SLOT0=($(call "$SV" 'getSlot0(bytes32)(uint160,int24,uint24,uint24)' "$POOL_ID"))
SQRTP=${SLOT0[0]}
PA_IS0=$([ "$(echo "$C0" | lower)" = "$(echo "$PA" | lower)" ] && echo 1 || echo 0)
SPOT=$(python3 -c "
from decimal import Decimal, getcontext; getcontext().prec = 60
s = Decimal($SQRTP); r = s * s / Decimal(2**192)
p = r * Decimal(10**12) if $PA_IS0 else Decimal(10**12) / r  # raw price * 10^(18-6) = USDC per RWA
print(f'{p:.10f}')")
check "pool spot ~100 (USDC per RWA)" "$(python3 -c "print('yes' if abs($SPOT - 100) < 1e-6 else 'no')")" "yes"
echo "        spot=$SPOT sqrtPriceX96=$SQRTP tick=${SLOT0[1]} lpFee=${SLOT0[3]}"
check "pool liquidity (StateView)" "$(call "$SV" 'getLiquidity(bytes32)(uint128)' "$POOL_ID")" "500000000000000000"

POS=($(call "$MARKET" 'positions(address)(uint256,uint256)' "$BORROWER"))
check "borrower collateral" "${POS[0]}" "1000000000000000000000"
check "borrower debt" "${POS[1]}" "75000000000"
check "healthFactor(borrower)" "$(call "$MARKET" 'healthFactor(address)(uint256)' "$BORROWER")" "1066666666666666666"
check "market totalSupplyAssets" "$(call "$MARKET" 'totalSupplyAssets()(uint256)')" "500000000000"

check "keeper USDC" "$(call "$USDC" 'balanceOf(address)(uint256)' "$KEEPER")" "0"
check "keeper RWA" "$(call "$RWA" 'balanceOf(address)(uint256)' "$KEEPER")" "0"
check "keeper checker flags (NONE)" "$(call "$RWA" 'flags(address)(uint16)' "$KEEPER")" "0"
check "issuer flags (HOLDER only)" "$(call "$RWA" 'flags(address)(uint16)' "$ISSUER")" "32768"
check "mm flags (HOLDER|SWAP|LIQUIDITY)" "$(call "$RWA" 'flags(address)(uint16)' "$MM")" "32771"
check "adapter flags (HOLDER|SWAP)" "$(call "$RWA" 'flags(address)(uint16)' "$ADAPTER")" "32769"
check "borrower flags (HOLDER)" "$(call "$RWA" 'flags(address)(uint16)' "$BORROWER")" "32768"
check "lender USDC (all supplied)" "$(call "$USDC" 'balanceOf(address)(uint256)' "$LENDER")" "0"
check "PoolManager raw RWA" "$(call "$RWA" 'balanceOf(address)(uint256)' "$PM")" "0"

check "PA allowedWrappers(adapter)" "$(call "$PA" 'allowedWrappers(address)(bool)' "$ADAPTER")" "true"
check "PA allowedWrappers(desk)" "$(call "$PA" 'allowedWrappers(address)(bool)' "$DESK")" "true"
check "PA allowedHooks(hook)" "$(call "$PA" 'allowedHooks(address)(bool)' "$HOOK")" "true"
check "PA swappingEnabled" "$(call "$PA" 'swappingEnabled()(bool)')" "true"
check "PA owner == issuer" "$(call "$PA" 'owner()(address)' | lower)" "$(echo "$ISSUER" | lower)"
check "factory.verifiedPAOf(PA) == RWA" "$(call "$FACTORY" 'verifiedPermissionsAdapterOf(address)(address)' "$PA" | lower)" "$(echo "$RWA" | lower)"
check "desk.owner == mm" "$(call "$DESK" 'owner()(address)' | lower)" "$(echo "$MM" | lower)"
check "adapter.keeperBps" "$(call "$ADAPTER" 'keeperBps()(uint256)')" "$(m .keeperBps)"
check "market.oracleAdmin == issuer" "$(call "$MARKET" 'oracleAdmin()(address)' | lower)" "$(echo "$ISSUER" | lower)"
check "usdc.minter == issuer" "$(call "$USDC" 'minter()(address)' | lower)" "$(echo "$ISSUER" | lower)"

if [ "$FAILS" -ne 0 ]; then echo "verify: $FAILS check(s) failed" >&2; exit 1; fi
echo "verify: all baseline checks passed"
