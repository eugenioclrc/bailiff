# Uniswap permissioned-pool integration feedback

Environment: Foundry 1.7.1, Solidity 0.8.26, Cancun; v4-periphery at 9969eec; v4-hooks-public at e4eabe5; Sepolia fork pinned at block 11782723. Real Sepolia contracts from the [deployment table](https://github.com/Uniswap/contracts/blob/main/deployments/11155111.md): PoolManager `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`, PermissionsAdapterFactory `0xE6B0d96919334C33d06266d1420F97f6f434fA2B`, PermissionedHooks `0x51247e2291d290d17c08813a175ac86465ede8c0`.

We built a narrowly scoped, sell-only liquidation wrapper (`LiquidationAdapter`). It sells exactly the seized RWA collateral in one fixed permissioned pool inside `PoolManager.unlock`. These are integrator experience notes and known or by-design behaviors, not newly disclosed vulnerabilities.

Developer Feedback Form: not submitted yet.

## A custom-wrapper guide would reduce settlement mistakes

The relevant behavior is split across DeltaResolver, PermissionedV4Router, PermissionsAdapter and PermissionedHooks. The ordinary currency payment path is not enough for a wrapped permissioned currency: the [canonical router overrides `_pay`](https://github.com/Uniswap/v4-periphery/blob/9969eec/src/hooks/permissionedPools/PermissionedV4Router.sol#L59-L80) so it can wrap through `wrapToPoolManager`. We learned the sequence by reading that source.

Our settlement is `unlockCallback` in [LiquidationAdapter.sol](contracts/src/e2e/LiquidationAdapter.sol): `sync` on the PermissionsAdapter currency, transfer the seized RWA to the PermissionsAdapter, `wrapToPoolManager` of exactly that amount, then `settle`. `test_e2e_crash15_fullClose_anonZeroUsdc` in [ForkLiquidation.t.sol](contracts/test/ForkLiquidation.t.sol) runs it against the real Sepolia contracts.

Request: one documented custom-wrapper example showing permissions, `msgSender` semantics and the sync, pay, wrap, settle sequence.

## Wrapper approval is a trust decision

An approved wrapper takes part in wrapping and reports the identity that the permissioned hook trusts through `msgSender()`. An allowlist entry alone does not establish that every possible wrapper is safe.

Our wrapper only sells seized collateral, in one fixed pool, and the issuer can revoke it. It is not a general user-controlled swap router. Request: document the powers and review obligations attached to `allowedWrappers`. This is a trust-model clarification.

## Explain verification-deposit accounting

[`wrapToPoolManager`](https://github.com/Uniswap/v4-periphery/blob/9969eec/src/hooks/permissionedPools/PermissionsAdapter.sol#L48-L51) treats `balanceOf(adapter) - totalSupply()` of the underlying as available backing. The verification deposit and any unsolicited transfer of the underlying therefore count as backing that any approved wrapper can wrap.

Our setup uses the minimum positive verification deposit. Request: explain this accounting in the verification guide. It is a low-severity, by-design integration consideration, not a new vulnerability.

## Make caller-side allowedHooks policy explicit

PermissionedV4Router checks `allowedHooks` in [`_validateHook`](https://github.com/Uniswap/v4-periphery/blob/9969eec/src/hooks/permissionedPools/PermissionedV4Router.sol#L39-L42). Custom callers must apply the same policy themselves, because the deployed hook does not replace that caller-side check. This behavior is already covered by prior OpenZeppelin audit discussion, and we are not claiming a new finding.

Our adapter checks the configured hook against `allowedHooks` before every liquidation. The regression is `test_adapter_hookNotAllowed` in [Review.t.sol](contracts/test/Review.t.sol).

Request: include this requirement in the custom-wrapper documentation.

## Publish one versioned deployment compatibility table

The [Sepolia deployment summary](https://github.com/Uniswap/contracts/blob/main/deployments/11155111.md) identifies the factory and the hook, but an integrator has to follow deployment history and source repositories to establish which periphery and hooks revisions match them.

Request: record the source commits, plus the compatible router and quoter versions, next to each deployment. The set we selected is listed at the top of this file.

## Explain permissioned quoting for a keeper without SWAP permission

A quote path can involve `msgSender` and account permissions. A generic quoter address is not enough to infer compatibility with a permissioned pool.

Our keeper has no SWAP permission, so we quote by simulating the actual adapter call with `eth_call`. Request: document the supported quoter versions, the caller permissions they need and the `eth_call` simulation path for an approved wrapper.

## Infrastructure note

For the pinned block, `ethereum-sepolia-rpc.publicnode.com` answered historical-state requests with error -32000, while the public Tenderly gateway (`sepolia.gateway.tenderly.co`) served them. The reproducible setup therefore asks for an archive-capable RPC. This is infrastructure feedback, not a Uniswap issue, and we do not claim a permanent retention limit for either provider.

## What worked

The canonical router and the test deployers made the required permissions and the settlement sequence inspectable. Creating and verifying our own PermissionsAdapter through the real factory is permissionless, so the whole integration runs against the real Sepolia contracts on a fork. Filtering `Swap` logs by the emitting contract separates the hook's event from the PoolManager's and gives direct integration evidence. Atomic reverts give the liquidation a clear failure boundary: a failed liquidation changes nothing.
