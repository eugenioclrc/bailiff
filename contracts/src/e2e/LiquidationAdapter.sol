// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";
import {IPermissionsAdapter} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IPermissionsAdapterFactory} from
    "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {BountyMath} from "./BountyMath.sol";

interface IMiniLend {
    function LB_BPS() external view returns (uint256);
    function previewLiquidation(address borrower, uint256 repayAssets) external view returns (uint256 repay, uint256 seize);
    function liquidate(address borrower, uint256 repayAssets, bytes calldata data)
        external
        returns (uint256 repaid, uint256 seized);
}

/// @title LiquidationAdapter
/// @notice The ONE contract the issuer allowlists. Anyone (0 USDC) calls liquidate(); raw RWA only moves
///         Market -> this -> PermissionsAdapter inside a single PoolManager.unlock. Sell-only, fixed pool,
///         never mints ERC-6909 claims, wraps exactly what it transferred, ends every tx with 0 RWA / 0 USDC.
contract LiquidationAdapter is IUnlockCallback, IMsgSender {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IPermissionsAdapter public immutable permissionsAdapter; // pool currency (vRWA)
    IERC20 public immutable rwa;
    IERC20 public immutable usdc;
    IMiniLend public immutable market;
    IHooks public immutable hooks;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    bool public immutable rwaIsCurrency0;
    uint256 public immutable lbBps;
    uint256 public immutable keeperBps;

    error NotPoolManager();
    error AdapterNotVerified();
    error HookNotAllowed();
    error PartialFill(uint256 sold, uint256 seize);
    error MarketMismatch(uint256 repaid, uint256 seized);

    event Liquidated(
        address indexed borrower,
        address indexed keeper,
        uint256 repaid,
        uint256 seized,
        uint256 proceeds,
        uint256 bounty,
        uint256 residual
    );

    constructor(
        IPoolManager pm,
        IPermissionsAdapterFactory factory,
        IPermissionsAdapter pa,
        IERC20 usdc_,
        IMiniLend market_,
        IHooks hooks_,
        uint24 fee_,
        int24 tickSpacing_,
        uint256 keeperBps_
    ) {
        rwa = IERC20(address(pa.PERMISSIONED_TOKEN()));
        if (factory.verifiedPermissionsAdapterOf(address(pa)) != address(rwa)) revert AdapterNotVerified();
        poolManager = pm;
        permissionsAdapter = pa;
        usdc = usdc_;
        market = market_;
        hooks = hooks_;
        fee = fee_;
        tickSpacing = tickSpacing_;
        rwaIsCurrency0 = address(pa) < address(usdc_);
        lbBps = market_.LB_BPS();
        keeperBps = keeperBps_;
        usdc_.forceApprove(address(market_), type(uint256).max);
    }

    /// @inheritdoc IMsgSender
    /// @dev Honest: THIS contract holds and sells the RWA. The keeper never touches it.
    function msgSender() external view returns (address) {
        return address(this);
    }

    function poolKey() public view returns (PoolKey memory k) {
        Currency a = Currency.wrap(address(permissionsAdapter));
        Currency u = Currency.wrap(address(usdc));
        (k.currency0, k.currency1) = rwaIsCurrency0 ? (a, u) : (u, a);
        (k.fee, k.tickSpacing, k.hooks) = (fee, tickSpacing, hooks);
    }

    /// @param repayAssets max USDC debt to repay (type(uint256).max = let the close factor decide)
    /// @param minBounty keeper slippage guard, in USDC units
    function liquidate(address borrower, uint256 repayAssets, uint256 minBounty) external returns (uint256 bounty) {
        // PermissionedHooks does NOT check allowedHooks; routers do (PermissionedV4Router._validatePoolKey).
        if (!permissionsAdapter.allowedHooks(hooks)) revert HookNotAllowed();
        bounty = abi.decode(poolManager.unlock(abi.encode(borrower, repayAssets, minBounty, msg.sender)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address borrower, uint256 repayAssets, uint256 minBounty, address keeper) =
            abi.decode(data, (address, uint256, uint256, address));

        // 1) quote at NAV (reverts Healthy / StaleNav / MustNotLeaveDust)
        (uint256 repay, uint256 seize) = market.previewLiquidation(borrower, repayAssets);

        // 2) sell `seize` vRWA exact-in; the vRWA debt stays open (flash accounting)
        (uint256 sold, uint256 proceeds) = _sell(seize);
        if (sold != seize) revert PartialFill(sold, seize);

        // 3) economics check BEFORE moving anything (reverts InsufficientProceeds / BountyTooLow)
        (uint256 bounty, uint256 residual) = BountyMath.split(proceeds, repay, lbBps, keeperBps, minBounty);

        // 4) take USDC, repay the market, receive the RWA (Market -> this)
        poolManager.take(Currency.wrap(address(usdc)), address(this), proceeds);
        (uint256 repaid, uint256 seized) = market.liquidate(borrower, repayAssets, "");
        if (repaid != repay || seized != seize) revert MarketMismatch(repaid, seized);

        // 5) pay the vRWA debt: sync -> RWA.transfer(PA) -> wrapToPoolManager(exact) -> settle
        poolManager.sync(Currency.wrap(address(permissionsAdapter)));
        rwa.safeTransfer(address(permissionsAdapter), seize);
        permissionsAdapter.wrapToPoolManager(seize);
        poolManager.settle();

        // 6) payouts, USDC only
        usdc.safeTransfer(keeper, bounty);
        if (residual != 0) usdc.safeTransfer(borrower, residual);
        emit Liquidated(borrower, keeper, repaid, seized, proceeds, bounty, residual);
        return abi.encode(bounty);
    }

    function _sell(uint256 amountIn) internal returns (uint256 sold, uint256 proceeds) {
        bool zeroForOne = rwaIsCurrency0; // selling vRWA
        BalanceDelta d = poolManager.swap(
            poolKey(),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn), // exact input
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        sold = uint256(uint128(-(zeroForOne ? d.amount0() : d.amount1())));
        proceeds = uint256(uint128(zeroForOne ? d.amount1() : d.amount0()));
    }
}
