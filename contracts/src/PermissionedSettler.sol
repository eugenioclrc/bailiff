// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPermissionsAdapter} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";

/// @notice Minimal settle helpers for a custom unlock caller (mirrors DeltaResolver._settle + PermissionedV4Router._pay).
library PermissionedSettler {
    using SafeERC20 for IERC20;

    /// @dev Pays `amount` of the adapter currency: sync -> underlying.transfer(adapter) -> wrapToPoolManager -> settle.
    ///      Caller must be in adapter.allowedWrappers and must hold `amount` of the underlying.
    function settleAdapter(IPoolManager pm, IPermissionsAdapter adapter, uint256 amount) internal {
        if (amount == 0) return;
        pm.sync(Currency.wrap(address(adapter)));
        IERC20(address(adapter.PERMISSIONED_TOKEN())).safeTransfer(address(adapter), amount);
        adapter.wrapToPoolManager(amount);
        pm.settle();
    }

    /// @dev Pays `amount` of an ordinary ERC20: sync -> transfer(pm) -> settle.
    function settleErc20(IPoolManager pm, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        pm.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(pm), amount);
        pm.settle();
    }
}
