// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";
import {IPermissionsAdapter} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {PermissionedSettler} from "./PermissionedSettler.sol";

/// @notice Stand-in for LiquidationAdapter: ANY caller triggers a sale of RWA this contract holds,
///         through the permissioned pool, and receives the USDC. msgSender() == address(this), so only
///         THIS contract needs SWAP_ALLOWED + allowedWrappers; the caller needs nothing.
contract ToyLiquidationSeller is IUnlockCallback, IMsgSender {
    IPoolManager public immutable pm;
    IPermissionsAdapter public immutable adapter;
    PoolKey public poolKeyStored;
    bool public immutable adapterIsCurrency0;

    error NotPoolManager();
    error Slippage(uint256 out, uint256 minOut);

    constructor(IPoolManager pm_, IPermissionsAdapter adapter_, PoolKey memory key_) {
        pm = pm_;
        adapter = adapter_;
        poolKeyStored = key_;
        adapterIsCurrency0 = Currency.unwrap(key_.currency0) == address(adapter_);
    }

    function msgSender() external view returns (address) {
        return address(this);
    }

    /// @param skipUnderlyingTransfer spike-only: settle using surplus already sitting in the adapter (gotcha demo)
    function sell(uint128 amountIn, uint256 minOut, bool skipUnderlyingTransfer) external returns (uint256 out) {
        out = abi.decode(pm.unlock(abi.encode(msg.sender, amountIn, minOut, skipUnderlyingTransfer)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(pm)) revert NotPoolManager();
        (address recipient, uint128 amountIn, uint256 minOut, bool skip) =
            abi.decode(data, (address, uint128, uint256, bool));
        PoolKey memory key = poolKeyStored;
        bool zeroForOne = adapterIsCurrency0; // selling the adapter currency

        BalanceDelta delta = pm.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(uint256(amountIn)), // exact input
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 dIn = zeroForOne ? delta.amount0() : delta.amount1(); // < 0 : we owe vRWA
        int128 dOut = zeroForOne ? delta.amount1() : delta.amount0(); // > 0 : we are owed USDC
        uint256 owed = uint256(uint128(-dIn));
        uint256 out = uint256(uint128(dOut));
        if (out < minOut) revert Slippage(out, minOut);

        // 1) take the output first (flash accounting: the debt is still open)
        pm.take(zeroForOne ? key.currency1 : key.currency0, recipient, out);

        // 2) pay the adapter currency: sync -> RWA.transfer(adapter) -> wrapToPoolManager -> settle
        if (skip) {
            pm.sync(Currency.wrap(address(adapter)));
            adapter.wrapToPoolManager(owed); // uses adapter surplus (e.g. the verification deposit)
            pm.settle();
        } else {
            PermissionedSettler.settleAdapter(pm, adapter, owed);
        }
        return abi.encode(out);
    }
}
