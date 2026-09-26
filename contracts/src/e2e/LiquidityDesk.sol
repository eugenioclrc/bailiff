// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";
import {IPermissionsAdapter} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";

/// @title LiquidityDesk - issuer / market-maker desk for the permissioned pool (LP + reprice)
/// @notice msgSender() reports the desk owner (the issuer/MM), who must hold SWAP|LIQUIDITY in the checker.
///         The desk itself must be HOLDER on the RWA (it receives raw RWA on remove / reprice).
contract LiquidityDesk is IUnlockCallback, IMsgSender {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    enum Op {
        Modify,
        SwapToPrice
    }

    IPoolManager public immutable pm;
    IPermissionsAdapter public immutable pa;
    address public immutable owner;

    error NotPoolManager();
    error NotOwner();

    constructor(IPoolManager pm_, IPermissionsAdapter pa_, address owner_) {
        (pm, pa, owner) = (pm_, pa_, owner_);
    }

    function msgSender() external view returns (address) {
        return owner;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function modifyLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        external
        onlyOwner
    {
        pm.unlock(abi.encode(Op.Modify, abi.encode(key, tickLower, tickUpper, liquidityDelta)));
    }

    /// @notice Push the pool to `targetSqrtPriceX96` (e.g. after a NAV update). Exact-in up to `maxIn`, partial fill ok.
    function swapToPrice(PoolKey calldata key, uint160 targetSqrtPriceX96, uint256 maxIn) external onlyOwner {
        pm.unlock(abi.encode(Op.SwapToPrice, abi.encode(key, targetSqrtPriceX96, maxIn)));
    }

    function withdraw(IERC20 token, uint256 amount) external onlyOwner {
        token.safeTransfer(owner, amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(pm)) revert NotPoolManager();
        (Op op, bytes memory args) = abi.decode(data, (Op, bytes));
        PoolKey memory key;
        BalanceDelta d;
        if (op == Op.Modify) {
            int24 tl;
            int24 tu;
            int256 liq;
            (key, tl, tu, liq) = abi.decode(args, (PoolKey, int24, int24, int256));
            (d,) = pm.modifyLiquidity(key, ModifyLiquidityParams(tl, tu, liq, 0), "");
        } else {
            uint160 target;
            uint256 maxIn;
            (key, target, maxIn) = abi.decode(args, (PoolKey, uint160, uint256));
            (uint160 current,,,) = pm.getSlot0(key.toId());
            if (current == target) return "";
            d = pm.swap(key, SwapParams(target < current, -int256(maxIn), target), "");
        }
        _resolve(key.currency0, d.amount0());
        _resolve(key.currency1, d.amount1());
        return "";
    }

    function _resolve(Currency c, int128 delta) private {
        if (delta > 0) {
            // take: for vRWA the adapter auto-unwraps raw RWA to this desk (desk must be HOLDER)
            pm.take(c, address(this), uint256(uint128(delta)));
        } else if (delta < 0) {
            uint256 owed = uint256(uint128(-delta));
            pm.sync(c);
            if (Currency.unwrap(c) == address(pa)) {
                IERC20(address(pa.PERMISSIONED_TOKEN())).safeTransfer(address(pa), owed);
                pa.wrapToPoolManager(owed); // exactly what was sent
            } else {
                IERC20(Currency.unwrap(c)).safeTransfer(address(pm), owed);
            }
            pm.settle();
        }
    }
}
