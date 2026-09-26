// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MiniLend} from "../../src/e2e/MiniLend.sol";
import {LiquidationAdapter, IMiniLend} from "../../src/e2e/LiquidationAdapter.sol";
import {ISpecMiniLend, ISpecLiquidationAdapter} from "./SpecInterfaces.sol";
import {FinalSpecBase} from "./FinalSpecBase.sol";

/// @title NAV floor acceptance (CONTRACTS R5 "Piso NAV y redondeos", TRACEABILITY C2)
/// @notice Every case runs in both currency orders on the real Labs PoolManager and hook at the pinned block. Spot is
///         moved only by explicit MM fixture swaps (R6 swapToPrice), never by Crash, which stays NAV-only.
///         All three tests are RED on the snapshot: its adapter sells with TickMath.MIN/MAX_SQRT_PRICE -+ 1 and has no
///         NAV floor. Each scenario is built so that nothing but the floor can stop it (minBounty 0 and proceeds that
///         cover the repay), so the snapshot completes a sale under the floor where the spec reverts
///         PoolBelowNavFloor or PartialFill, and the run fails at that revert expectation.
contract NavFloorTest is FinalSpecBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant FULL_CLOSE = type(uint256).max; // the close factor decides
    uint256 internal constant NO_MIN_BOUNTY = 0; // no keeper guard: only the floor may stop a sale
    uint256 internal constant LB_CAP_BOUNTY = BORROWER_DEBT * LB_BPS / BPS; // 4500 USDC, largest bounty possible
    uint256 internal constant SPOT_UNDER_FLOOR = 84e18; // just under 84.15, the floor of NAV 85
    uint256 internal constant SPOT_DEEP_UNDER_FLOOR = 50e18; // a full sale here would not even cover the debt
    uint256 internal constant SPOT_NEAR_NAV = 86e18; // above the floor; a full close pushes spot through it
    uint256 internal constant ODD_NAV = 85e18 + 1; // nav*9900 is not a multiple of 10000: p's rounding shows
    // Wide-oracle variant (same MiniLend code, wider NAV bounds). The concrete market can never hold a liquidatable
    // position at its own NAV_CAP (LT 80% > LTV 75%, 0% APR), so the adapter's floor math at NAV 1000 and at the
    // TickMath edge is reached through this variant. The adapter only ever sees nav().
    uint256 internal constant WIDE_NAV_CAP = 1e69; // above the ~3.4e68 NAV where the currency1 limit hits MIN_SQRT_PRICE
    uint256 internal constant WIDE_COLLATERAL = 1e18;
    uint256 internal constant WIDE_DEBT = 5e56; // borrowable at WIDE_NAV_CAP; HF < 0.95 at every NAV tested
    // Inner rounding of the R5 limit. The two roundings of the quotient under the sqrt differ only where the other
    // rounding lands on a perfect square, so each order gets a NAV (inside the wide variant range) where it does.
    // PA currency0: p*Q/S not exact and floor(p*Q/S) a perfect square, so ceil inside the sqrt moves the limit by one.
    uint256 internal constant INNER_ROUNDING_NAV_PA0 = 75977357431196060579095271338227897209039013244;
    // PA currency1: S*Q/p not exact and ceil(S*Q/p) a perfect square, so floor inside the sqrt moves the limit by one.
    uint256 internal constant INNER_ROUNDING_NAV_PA1 = 101010101010101010100994675253594107580888004;

    /// @notice What the real PoolManager does with an exact-in vRWA sale bounded by a price limit.
    struct Quote {
        uint256 sold; // vRWA the pool absorbed (amountIn + fee)
        uint256 proceeds; // USDC paid out
        uint160 endSqrtPriceX96;
    }

    // ================================================================== tests
    /// @notice TRACEABILITY: an initial price outside the floor reverts PoolBelowNavFloor in both orders; debt,
    ///         collateral and balances do not change. The market's verdict comes first; the floor comes before any sale.
    function test_revert_poolBelowNavFloor() public {
        _revertPoolBelowNavFloor(true);
        _revertPoolBelowNavFloor(false);
    }

    /// @notice TRACEABILITY: equality with the limit is rejected; conservative rounding; TickMath bounds; the maximum
    ///         NAV does not overflow.
    function test_navFloorBoundary_bothCurrencyOrders() public {
        _navFloorBoundary(true);
        _navFloorBoundary(false);
    }

    /// @notice TRACEABILITY: sold < seize produces PartialFill; spot, L, debts, balances and claims roll back.
    function test_navFloorPartialFillRollsBack() public {
        _navFloorPartialFill(true);
        _navFloorPartialFill(false);
    }

    // ================================================================== test_revert_poolBelowNavFloor
    function _revertPoolBelowNavFloor(bool paIs0) private {
        _buildOrder(paIs0);
        _mmMoveSpotTo(sqrtPriceX96ForNav(SPOT_UNDER_FLOOR));
        uint160 spot = spotSqrtPriceX96();

        // NAV 100: the borrower is healthy; the floor must not mask the market's own reason
        _expectKeeperRevert(
            borrower, NO_MIN_BOUNTY, abi.encodeWithSelector(ISpecMiniLend.Healthy.selector, HF_BASELINE)
        );

        crashNavAndAssertNavOnly();
        uint160 limit = navFloorLimitSqrtPriceX96(CRASH_NAV);
        assertTrue(_floorRejects(spot, limit), "spot 84 is outside the NAV-85 floor");
        uint256 seize = _assertFullClose(CRASH_NAV);
        assertEq(seize, CRASH_FULL_CLOSE_SEIZE, "seize at NAV 85");

        // with no floor this sale fills and covers the debt: only the NAV floor can stop it
        Quote memory unbounded = _quoteSale(seize, _unboundedLimit());
        assertEq(unbounded.sold, seize, "unbounded sale at 84 fills");
        assertGt(unbounded.proceeds, BORROWER_DEBT, "unbounded sale at 84 covers the repay");
        _expectKeeperRevert(borrower, NO_MIN_BOUNTY, _belowFloor(spot, limit));

        // deep under the floor with the largest keeper guard: the floor is reported before the sale and the split
        _mmMoveSpotTo(sqrtPriceX96ForNav(SPOT_DEEP_UNDER_FLOOR));
        uint160 deep = spotSqrtPriceX96();
        unbounded = _quoteSale(seize, _unboundedLimit());
        assertLt(unbounded.proceeds, BORROWER_DEBT, "unbounded sale at 50 would not cover the repay");
        _expectKeeperRevert(borrower, LB_CAP_BOUNTY, _belowFloor(deep, limit));

        // same keeper, same call: succeeds once the MM puts spot back at 100
        _mmMoveSpotTo(sqrtPriceX96ForNav(NAV0));
        _liquidateAboveFloor(limit, seize);
    }

    /// @dev Full success-path check, residual destination and R3 identities, plus the sale pinned to the NAV-bounded
    ///      quote of the same pre-state (the limit does not bind at spot 100).
    function _liquidateAboveFloor(uint160 limit, uint256 seize) private {
        Quote memory q = _quoteSale(seize, limit);
        assertEq(q.sold, seize, "NAV-bounded sale at 100 fills");
        assertFalse(_floorRejects(q.endSqrtPriceX96, limit), "and ends above the floor");

        Liquidation memory r = liquidateViaAdapter();
        assertLiquidationSuccessPath(r);
        assertResidualSettledInMarket(r);
        assertEq(r.repaid, BORROWER_DEBT, "full close");
        assertEq(r.seized, seize, "seized == preview seize");
        assertEq(r.proceeds, q.proceeds, "proceeds == NAV-bounded exact-in quote");
        assertEq(r.post.pool.sqrtPriceX96, q.endSqrtPriceX96, "post-sale spot == quote");
        assertEq(r.post.pool.liquidity, L_UNSIGNED, "sale leaves L");
        assertEq(r.eventBounty, LB_CAP_BOUNTY, "bounty == 6% LB cap");
        assertEq(r.marketBadDebt, 0, "collateral remains: no write-off");
        assertEq(r.post.ledger.debt, 0, "debt closed");
        assertAccountingIdentity();
        assertLedgerSums();
        assertBadDebtSum();
    }

    // ================================================================== test_navFloorBoundary_bothCurrencyOrders
    function _navFloorBoundary(bool paIs0) private {
        _buildOrder(paIs0);
        _assertEqualityRejectedAndRounding(paIs0);
        _assertConcreteRangeInsideTickMath(paIs0);

        address wideBorrower = _deployWideNavMarket();
        // the maximum NAV of the concrete configuration: exact limit, no overflow, no clamp
        _expectFloorRejectionAt(wideBorrower, ORACLE_NAV_MAX);
        _assertInnerRoundingPinned(wideBorrower, paIs0);
        if (!paIs0) _assertMinSqrtPriceEdge(wideBorrower);
    }

    function _assertEqualityRejectedAndRounding(bool paIs0) private {
        setNavAsIssuer(ODD_NAV); // explicit oracle update, not Crash
        uint256 seize = _assertFullClose(ODD_NAV);
        uint160 limit = navFloorLimitSqrtPriceX96(ODD_NAV);
        _assertOddNavSeparatesRoundings(paIs0, limit);

        // spot on the limit: rejected (PA currency0 rejects current <= limit, PA currency1 current >= limit)
        _mmMoveSpotTo(limit);
        _expectKeeperRevert(borrower, NO_MIN_BOUNTY, _belowFloor(limit, limit));

        // one unit outside: rejected with the same limit
        uint160 outside = paIs0 ? limit - 1 : limit + 1;
        _mmMoveSpotTo(outside);
        _expectKeeperRevert(borrower, NO_MIN_BOUNTY, _belowFloor(outside, limit));

        // one unit inside: passes the price check; the sale is bounded by the same limit, so it stops at once
        uint160 inside = paIs0 ? limit + 1 : limit - 1;
        _mmMoveSpotTo(inside);
        Quote memory q = _quoteSale(seize, limit);
        assertEq(q.endSqrtPriceX96, limit, "NAV-bounded sale stops on the limit");
        assertGt(q.sold, 0, "the pool absorbs a sliver");
        assertLt(q.sold, seize, "sold < seize");
        _expectKeeperRevert(
            borrower, NO_MIN_BOUNTY, abi.encodeWithSelector(ISpecLiquidationAdapter.PartialFill.selector, q.sold, seize)
        );
    }

    /// @dev At ODD_NAV each less conservative rounding (floor p, sqrt the other way) gives a different limit on the
    ///      accepting side, so a spot on the spec limit is rejected only by the conservative one, and the limit in
    ///      PoolBelowNavFloor pins the exact rounding.
    function _assertOddNavSeparatesRoundings(bool paIs0, uint160 limit) private pure {
        (uint256 pDown, uint256 sqrtOtherWay) = _lessConservativeLimits(ODD_NAV, paIs0);
        if (paIs0) {
            assertLt(pDown, limit, "p rounded up: currency0 limit above the floor(p) limit");
            assertEq(sqrtOtherWay + 1, limit, "currency0 limit is ceil_sqrt, one above floor_sqrt");
        } else {
            assertGt(pDown, limit, "p rounded up: currency1 limit below the floor(p) limit");
            assertEq(sqrtOtherWay, uint256(limit) + 1, "currency1 limit is floor_sqrt, one below ceil_sqrt");
        }
    }

    /// @dev PA currency0: for p >= 1 the limit is above 7.9e13 > MIN_SQRT_PRICE, and it stays below 2^128 < MAX_SQRT_PRICE
    ///      while ceil(p*Q/S) fits in 256 bits, so no NAV reaches a TickMath bound there (only a mulDiv overflow, from
    ///      p ~ 2^64*S, whose revert the spec does not name). PA currency1 reaches MIN_SQRT_PRICE at NAV ~ 3.44e68: that
    ///      edge is tested to the wei.
    function _assertConcreteRangeInsideTickMath(bool paIs0) private view {
        // the concrete oracle range [10, 1000] keeps the limit strictly inside TickMath in this orientation
        assertEq(market.NAV_FLOOR(), ORACLE_NAV_MIN, "concrete NAV floor 10");
        assertEq(market.NAV_CAP(), ORACLE_NAV_MAX, "concrete NAV cap 1000");
        _assertInsideTickMath(navFloorLimitSqrtPriceX96(ORACLE_NAV_MIN, paIs0), "limit at NAV 10");
        _assertInsideTickMath(navFloorLimitSqrtPriceX96(ORACLE_NAV_MAX, paIs0), "limit at NAV 1000");
    }

    /// @dev Pins the rounding of the quotient under the sqrt (ceil(p*Q/S) for PA currency0, floor(S*Q/p) for PA
    ///      currency1). At the chosen NAV the other inner rounding gives a limit exactly one unit away, on the
    ///      accepting side, so the limit reported in PoolBelowNavFloor tells the two apart.
    function _assertInnerRoundingPinned(address wideBorrower, bool paIs0) private {
        uint256 navWad = paIs0 ? INNER_ROUNDING_NAV_PA0 : INNER_ROUNDING_NAV_PA1;
        assertLe(navWad, WIDE_NAV_CAP, "inner-rounding NAV inside the variant oracle range");
        uint256 p = Math.mulDiv(navWad, NAV_FLOOR_BPS, BPS, Math.Rounding.Ceil);
        uint256 limit = navFloorLimitSqrtPriceX96(navWad, paIs0);
        if (paIs0) {
            assertLt(p, (uint256(1) << 64) * PRICE_SCALE, "p*Q/S fits in 256 bits");
            assertGt(mulmod(p, Q192, PRICE_SCALE), 0, "p*Q/S is not exact: ceil != floor");
            uint256 innerDown = Math.mulDiv(p, Q192, PRICE_SCALE);
            uint256 root = Math.sqrt(innerDown);
            assertEq(root * root, innerDown, "floor(p*Q/S) is a perfect square");
            assertEq(limit, root + 1, "currency0 limit is ceil_sqrt(ceil(p*Q/S)), one above ceil_sqrt(floor(p*Q/S))");
        } else {
            assertGt(mulmod(PRICE_SCALE, Q192, p), 0, "S*Q/p is not exact: floor != ceil");
            uint256 innerUp = Math.mulDiv(PRICE_SCALE, Q192, p, Math.Rounding.Ceil);
            uint256 root = Math.sqrt(innerUp);
            assertEq(root * root, innerUp, "ceil(S*Q/p) is a perfect square");
            assertEq(limit + 1, root, "currency1 limit is floor_sqrt(floor(S*Q/p)), one below floor_sqrt(ceil(S*Q/p))");
        }
        _assertInsideTickMath(limit, "inner-rounding limit");
        _expectFloorRejectionAt(wideBorrower, navWad);
    }

    /// @dev PA currency1, TickMath edge to the wei of NAV: the last NAV whose limit is still inside the range reports
    ///      exactly MIN_SQRT_PRICE + 1; one wei of NAV more gives exactly MIN_SQRT_PRICE, which the strict bound must
    ///      turn into BadConfig. A clamp to MIN_SQRT_PRICE + 1, or a non-strict bound, would give PoolBelowNavFloor
    ///      instead, so this pair separates BadConfig from both.
    function _assertMinSqrtPriceEdge(address wideBorrower) private {
        uint256 minInside = uint256(TickMath.MIN_SQRT_PRICE) + 1;
        uint256 pEdge = Math.mulDiv(PRICE_SCALE, Q192, minInside * minInside); // largest p with limit > MIN
        uint256 navEdge = Math.mulDiv(pEdge, BPS, NAV_FLOOR_BPS); // largest NAV whose p is pEdge
        assertEq(Math.mulDiv(navEdge, NAV_FLOOR_BPS, BPS, Math.Rounding.Ceil), pEdge, "p(navEdge) == pEdge");
        assertEq(navFloorLimitSqrtPriceX96(navEdge, false), minInside, "limit at navEdge == MIN_SQRT_PRICE + 1");
        assertEq(
            navFloorLimitSqrtPriceX96(navEdge + 1, false),
            uint256(TickMath.MIN_SQRT_PRICE),
            "limit at navEdge + 1 wei == MIN_SQRT_PRICE, not strictly inside"
        );
        assertLe(navEdge + 1, WIDE_NAV_CAP, "edge inside the variant oracle range");

        _expectFloorRejectionAt(wideBorrower, navEdge);

        setNavAsIssuer(navEdge + 1);
        _assertWideLiquidatable(wideBorrower, navEdge + 1);
        _expectKeeperRevert(
            wideBorrower, NO_MIN_BOUNTY, abi.encodeWithSelector(ISpecLiquidationAdapter.BadConfig.selector)
        );
    }

    /// @dev Oracle moves to `navWad`. Spot (left one unit inside the ODD_NAV limit, ~84.15) lies outside this NAV's
    ///      floor, so the adapter must report exactly this limit.
    function _expectFloorRejectionAt(address wideBorrower, uint256 navWad) private {
        setNavAsIssuer(navWad);
        _assertWideLiquidatable(wideBorrower, navWad);
        uint160 limit = navFloorLimitSqrtPriceX96(navWad);
        uint160 spot = spotSqrtPriceX96();
        assertTrue(_floorRejects(spot, limit), "spot is outside the floor at this NAV");
        _expectKeeperRevert(wideBorrower, NO_MIN_BOUNTY, _belowFloor(spot, limit));
    }

    /// @dev The whole 1-RWA collateral is seized and the repay rounds up (R3 formula), so the adapter gets past the
    ///      preview and reaches the floor.
    function _assertWideLiquidatable(address who, uint256 navWad) private view {
        (uint256 repay, uint256 seize) = market.previewLiquidation(who, FULL_CLOSE);
        assertEq(seize, WIDE_COLLATERAL, "wide borrower: whole collateral seized");
        assertEq(
            repay,
            Math.mulDiv(WIDE_COLLATERAL, navWad * BPS, PRICE_SCALE * (BPS + LB_BPS), Math.Rounding.Ceil),
            "wide borrower: repay = ceil(c*nav*B/(S*(B+LB)))"
        );
    }

    // ================================================================== test_navFloorPartialFillRollsBack
    function _navFloorPartialFill(bool paIs0) private {
        _buildOrder(paIs0);
        crashNavAndAssertNavOnly();
        _mmMoveSpotTo(sqrtPriceX96ForNav(SPOT_NEAR_NAV));
        uint160 limit = navFloorLimitSqrtPriceX96(CRASH_NAV);
        assertFalse(_floorRejects(spotSqrtPriceX96(), limit), "spot 86 passes the initial floor check");
        uint256 seize = _assertFullClose(CRASH_NAV);
        assertEq(seize, CRASH_FULL_CLOSE_SEIZE, "seize at NAV 85");

        // an unbounded sale of the whole seize fills, covers the repay and ends under the floor
        Quote memory unbounded = _quoteSale(seize, _unboundedLimit());
        assertEq(unbounded.sold, seize, "unbounded sale fills");
        assertGt(unbounded.proceeds, BORROWER_DEBT, "unbounded sale covers the repay");
        assertTrue(_floorRejects(unbounded.endSqrtPriceX96, limit), "unbounded sale ends under the floor");

        // bounded by the NAV limit, the pool absorbs only part of it
        Quote memory bounded = _quoteSale(seize, limit);
        assertEq(bounded.endSqrtPriceX96, limit, "NAV-bounded sale stops on the limit");
        assertGt(bounded.sold, 0, "part of the seize sold");
        assertLt(bounded.sold, seize, "sold < seize");

        // PartialFill(sold, seize); spot, L, MM position, debts, collateral, balances and claims all roll back
        _expectKeeperRevert(
            borrower,
            NO_MIN_BOUNTY,
            abi.encodeWithSelector(ISpecLiquidationAdapter.PartialFill.selector, bounded.sold, seize)
        );
    }

    // ================================================================== fixture helpers
    /// @notice Fresh three-role world in the requested order; asserts which adapter branch was built.
    function _buildOrder(bool paIs0) private {
        _deployFixture(paIs0, false);
        assertEq(paIsCurrency0, paIs0, "requested currency order built");
        assertEq(address(pa) < address(usdc), paIs0, "PA/USDC address order");
        assertEq(Currency.unwrap(key.currency0), paIs0 ? address(pa) : address(usdc), "PoolKey currency0");
        assertEq(
            adapter.rwaIsCurrency0(),
            paIs0,
            paIs0 ? "adapter branch: PA is currency0" : "adapter branch: PA is currency1"
        );
        assertEq(keccak256(abi.encode(adapter.poolKey())), keccak256(abi.encode(key)), "adapter pins the fixture pool");
        assertEq(spotSqrtPriceX96(), sqrtPriceX96ForNav(NAV0), "pool starts at P=100");
    }

    /// @notice Explicit MM fixture (R6 swapToPrice), never part of Crash: spot lands exactly on `target`, L unchanged.
    function _mmMoveSpotTo(uint160 target) private {
        uint160 current = spotSqrtPriceX96();
        bool rwaIn = paIsCurrency0 ? target < current : target > current; // RWA cheaper: the MM sells vRWA
        uint256 maxIn = rwaIn ? rwa.balanceOf(address(desk)) : usdc.balanceOf(address(desk));
        mmSwapToPrice(target, maxIn);
        assertEq(spotSqrtPriceX96(), target, "MM moved spot exactly to the target");
        assertEq(PM.getLiquidity(poolId), L_UNSIGNED, "a swap leaves L");
    }

    /// @notice Oracle for R5 step 4: the MM desk runs the same exact-in vRWA sale with the same limit on the real
    ///         PoolManager (the Labs hook adds no delta and no fee override), then the state snapshot is restored.
    function _quoteSale(uint256 amountIn, uint160 limit) private returns (Quote memory q) {
        uint160 spot = spotSqrtPriceX96();
        assertTrue(paIsCurrency0 ? limit < spot : limit > spot, "quote limit on the vRWA-sell side of spot");
        uint256 snap = vm.snapshotState();
        uint256 rwaBefore = rwa.balanceOf(address(desk));
        uint256 usdcBefore = usdc.balanceOf(address(desk));
        mmSwapToPrice(limit, amountIn);
        q.sold = rwaBefore - rwa.balanceOf(address(desk));
        q.proceeds = usdc.balanceOf(address(desk)) - usdcBefore;
        q.endSqrtPriceX96 = spotSqrtPriceX96();
        assertTrue(vm.revertToState(snap), "quote state restored");
        assertEq(spotSqrtPriceX96(), spot, "quote left spot untouched");
    }

    /// @notice The keeper's adapter call reverts with exactly `err`, and every balance, supply, ledger entry (claims
    ///         included) and pool field is unchanged afterwards.
    function _expectKeeperRevert(address who, uint256 minBounty, bytes memory err) private {
        World memory pre = captureWorld(who);
        vm.prank(keeper);
        vm.expectRevert(err);
        adapter.liquidate(who, FULL_CLOSE, minBounty);
        assertWorldUnchanged(pre, who);
    }

    /// @dev HF <= 0.95 at `navWad`: the fixture borrower is closed in full; returns the R3 seize.
    function _assertFullClose(uint256 navWad) private view returns (uint256 seize) {
        uint256 repay;
        (repay, seize) = market.previewLiquidation(borrower, FULL_CLOSE);
        assertEq(repay, BORROWER_DEBT, "HF <= 0.95: full close");
        assertEq(seize, expectedSeize(BORROWER_DEBT, navWad), "R3 seize formula");
    }

    /// @notice Same MiniLend code with a wider oracle range, its own adapter on the SAME PA, pool and hook, and a
    ///         1-RWA borrower at maximum LTV. The fixture's market/adapter now point at it, so the base world
    ///         snapshot covers it. Deployed while NAV is 100, so a constructor-time check of the floor cannot object.
    function _deployWideNavMarket() private returns (address wideBorrower) {
        wideBorrower = makeAddr("wideNavBorrower");
        address wideLender = makeAddr("wideNavLender");
        vm.startPrank(issuer);
        MiniLend m = new MiniLend(
            IERC20(address(rwa)), IERC20(address(usdc)), issuer, NAV0, ORACLE_NAV_MIN, WIDE_NAV_CAP, NAV_STALENESS
        );
        LiquidationAdapter a = new LiquidationAdapter(
            PM, FACTORY, pa, IERC20(address(usdc)), IMiniLend(address(m)), HOOK, FEE, TICK_SPACING, KEEPER_BPS
        );
        uint16 holder = rwa.HOLDER();
        rwa.setFlags(address(m), holder);
        rwa.setFlags(address(a), holder | rwa.SWAP());
        rwa.setFlags(wideBorrower, holder);
        pa.updateAllowedWrapper(address(a), true);
        rwa.mint(wideBorrower, WIDE_COLLATERAL);
        usdc.mint(wideLender, WIDE_DEBT);
        m.setNav(WIDE_NAV_CAP);
        vm.stopPrank();
        vm.startPrank(wideLender);
        usdc.approve(address(m), WIDE_DEBT);
        m.supply(WIDE_DEBT);
        vm.stopPrank();
        vm.startPrank(wideBorrower);
        rwa.approve(address(m), WIDE_COLLATERAL);
        m.depositCollateral(WIDE_COLLATERAL);
        m.borrow(WIDE_DEBT);
        vm.stopPrank();
        (market, adapter) = (m, a);
    }

    // ================================================================== spec math
    /// @notice R5 rejection side: PA currency0 rejects current <= limit, PA currency1 rejects current >= limit.
    function _floorRejects(uint256 current, uint256 limit) private view returns (bool) {
        return paIsCurrency0 ? current <= limit : current >= limit;
    }

    function _belowFloor(uint160 current, uint160 limit) private pure returns (bytes memory) {
        return abi.encodeWithSelector(ISpecLiquidationAdapter.PoolBelowNavFloor.selector, current, limit);
    }

    /// @notice The snapshot's price limit (and what an unbounded seller uses).
    function _unboundedLimit() private view returns (uint160) {
        return paIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @notice The two less conservative variants of the R5 limit: p rounded down, and the square root rounded the
    ///         other way. Both sit on the accepting side of the spec limit.
    function _lessConservativeLimits(uint256 navWad, bool paIs0)
        private
        pure
        returns (uint256 pDown, uint256 sqrtOtherWay)
    {
        uint256 pUpValue = Math.mulDiv(navWad, NAV_FLOOR_BPS, BPS, Math.Rounding.Ceil);
        uint256 pDownValue = Math.mulDiv(navWad, NAV_FLOOR_BPS, BPS);
        assertEq(pUpValue, pDownValue + 1, "nav*9900/B is not exact at this NAV");
        if (paIs0) {
            pDown = Math.sqrt(Math.mulDiv(pDownValue, Q192, PRICE_SCALE, Math.Rounding.Ceil), Math.Rounding.Ceil);
            sqrtOtherWay = Math.sqrt(Math.mulDiv(pUpValue, Q192, PRICE_SCALE, Math.Rounding.Ceil), Math.Rounding.Floor);
        } else {
            pDown = Math.sqrt(Math.mulDiv(PRICE_SCALE, Q192, pDownValue), Math.Rounding.Floor);
            sqrtOtherWay = Math.sqrt(Math.mulDiv(PRICE_SCALE, Q192, pUpValue), Math.Rounding.Ceil);
        }
    }

    function _assertInsideTickMath(uint256 sqrtPriceX96, string memory what) private pure {
        assertGt(sqrtPriceX96, uint256(TickMath.MIN_SQRT_PRICE), string.concat(what, " > MIN_SQRT_PRICE"));
        assertLt(sqrtPriceX96, uint256(TickMath.MAX_SQRT_PRICE), string.concat(what, " < MAX_SQRT_PRICE"));
    }
}
