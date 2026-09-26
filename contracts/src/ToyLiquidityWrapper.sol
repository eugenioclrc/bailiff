// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";
import {IPermissionsAdapter} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {PermissionedSettler} from "./PermissionedSettler.sol";

/// @notice Custom LP wrapper. msgSender() reports the real caller (like PositionManager's _getLocker()).
/// @dev Holds pre-funded underlying RWA + USDC. Position is owned by this contract (spike only).
contract ToyLiquidityWrapper is IUnlockCallback, IMsgSender {
    IPoolManager public immutable pm;
    IPermissionsAdapter public immutable adapter;
    address private locker;

    error NotPoolManager();

    constructor(IPoolManager pm_, IPermissionsAdapter adapter_) {
        pm = pm_;
        adapter = adapter_;
    }

    function msgSender() external view returns (address) {
        return locker;
    }

    function addLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint256 liquidity) external {
        locker = msg.sender;
        pm.unlock(abi.encode(key, tickLower, tickUpper, liquidity));
        locker = address(0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(pm)) revert NotPoolManager();
        (PoolKey memory key, int24 tl, int24 tu, uint256 liq) = abi.decode(data, (PoolKey, int24, int24, uint256));
        (BalanceDelta delta,) = pm.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: int256(liq), salt: 0}), ""
        );
        _pay(key.currency0, delta.amount0());
        _pay(key.currency1, delta.amount1());
        return "";
    }

    function _pay(Currency currency, int128 d) private {
        if (d >= 0) return;
        uint256 owed = uint256(uint128(-d));
        if (Currency.unwrap(currency) == address(adapter)) {
            PermissionedSettler.settleAdapter(pm, adapter, owed);
        } else {
            PermissionedSettler.settleErc20(pm, currency, owed);
        }
    }
}
