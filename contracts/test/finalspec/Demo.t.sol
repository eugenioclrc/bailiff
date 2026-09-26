// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockRWA3643} from "../../src/e2e/MockRWA3643.sol";
import {ISpecMiniLend, ISpecLiquidationAdapter} from "./SpecInterfaces.sol";
import {FinalSpecBase} from "./FinalSpecBase.sol";

/// @notice R4 BountyMath errors, signatures copied from CONTRACTS.md R4 (declared locally, like Uniswap's router
///         tests do, so the test does not depend on where the library lives).
interface ISpecBountyMathErrors {
    error InsufficientProceeds(uint256 proceeds, uint256 repaid);
    error BountyTooLow(uint256 bounty, uint256 minBounty);
}

/// @notice Error of the real Labs PermissionedHooks (v4-hooks-public e4eabe5) raised inside beforeSwap.
interface ILabsPermissionedHooksErrors {
    error Unauthorized();
}

/// @notice O7 demo branches and the TRACEABILITY regressions healthy/stale/minBounty/token pause, against the REAL
///         Labs PoolManager / factory / hook on the pinned Sepolia fork (three-role fixture of FinalSpecFixture).
/// @dev RED on the snapshot: test_thinPool_fullReverts_thenChunkSucceeds (no NAV floor, so the thin-pool full close
///      reverts InsufficientProceeds instead of PartialFill; the residual goes to the borrower instead of the debt) and
///      test_demoResetRestoresBaseline (no R3 claims ledger to prove "claims 0" and its restore).
///      GREEN on the snapshot, to be preserved by the fixes: the four test_revert_* regressions.
///      Exact figures come from reference sales: the MM's LiquidityDesk sells the same amount exact-in with the R5
///      NAV-floor limit on the same real PoolManager inside a rolled-back snapshot, which yields the deltas the R5
///      adapter swap must produce. The demo figures of O7 are pinned below as measured at block 11782723.
contract DemoTest is FinalSpecBase {
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------ demo inputs (O5, O7)
    uint256 internal constant CHUNK_REPAY = 10_000e6; // liquidateChunk nominal repay
    uint128 internal constant MM_REMOVED_L = 4.75e17; // withdraw95
    uint128 internal constant THIN_L = 2.5e16; // 5e17 - 4.75e17
    uint256 internal constant NAV_HF_ONE = 93.75e18; // 1000 RWA * 93.75 * 0.80 == 75000 USDC: HF exactly 1e18
    uint256 internal constant SPOT_BELOW_FLOOR = 80e18; // explicit MM spot fixture, below 0.99*NAV for NAV 85 and 100
    uint256 internal constant BRANCH_DELAY = 1 hours; // each demo branch crashes later than the snapshot

    // ------------------------------------------------------------------ R3/R4 figures (formula in each comment)
    uint256 internal constant CHUNK_SEIZE = 124_705_882_352_941_176_470; // floor(10000e6*10600*1e30/(85e18*1e4))
    uint256 internal constant FULL_CLOSE_BOUNTY = 4_500e6; // LB cap floor(75000e6*600/1e4)
    uint256 internal constant CHUNK_BOUNTY = 600e6; // LB cap floor(10000e6*600/1e4)
    uint256 internal constant HALF_CLOSE_REPAY = 37_500e6; // CLOSE_FACTOR 50% of 75000 (0.95 < HF < 1)
    uint256 internal constant HF_JUST_BELOW_ONE = 999_999_999_986_666_666; // floor(74999999999e18/75000e6)
    uint256 internal constant LT_BPS = 8_000;

    // ------------------------------------------------------------------ measured on the real PM at 11782723
    // Fixture default order (PA = currency0); the PA = currency1 order rounds the thin sold and chunk proceeds 1 wei
    // differently. O7 estimates: 91541.59 / 11844.14; final chunk debt ~63755.86.
    // L 5e17, spot 100: USDC for 935.294117647058823529 RWA
    uint256 internal constant FULL_CLOSE_PROCEEDS = 91_541_594_333;
    // L 2.5e16, spot 100: vRWA sold when the NAV-85 floor (84.15) is reached
    uint256 internal constant THIN_FULL_SOLD = 225_969_325_341_560_425_669;
    // L 2.5e16, spot 100: USDC for 124.705882352941176470 RWA
    uint256 internal constant CHUNK_PROCEEDS = 11_844_135_560;
    uint256 internal constant FULL_CLOSE_RESIDUAL = FULL_CLOSE_PROCEEDS - BORROWER_DEBT - FULL_CLOSE_BOUNTY;
    uint256 internal constant CHUNK_RESIDUAL = CHUNK_PROCEEDS - CHUNK_REPAY - CHUNK_BOUNTY;
    uint256 internal constant CHUNK_FINAL_DEBT = BORROWER_DEBT - CHUNK_REPAY - CHUNK_RESIDUAL; // not 65000

    address internal kycLiquidator = makeAddr("kycLiquidator"); // HOLDER with USDC: the direct MiniLend route

    /// @notice Result of a reference sale on the real PoolManager (rolled back).
    struct Sale {
        uint256 sold; // vRWA the desk paid
        uint256 proceeds; // USDC the desk received
        uint160 endSqrtPriceX96;
    }

    /// @notice Everything an issuer/MM action of the demo can toggle, and the reset must restore.
    struct Permissions {
        bool adapterWrapper;
        bool deskWrapper;
        bool swappingEnabled;
        bool hookAllowed;
        bool tokenPaused;
        bool borrowerFrozen;
        uint16 adapterFlags;
        uint16 deskFlags;
        uint16 marketFlags;
        uint16 paFlags;
        uint16 mmFlags;
        uint16 issuerFlags;
        uint16 keeperFlags;
        uint16 borrowerFlags;
        address paOwner;
    }

    // ================================================================== C3: thin pool (RED)
    /// @notice TRACEABILITY: restored fixture, MM withdraws 4.75e17 of 5e17, full close -> PartialFill with complete
    ///         rollback, nominal 10000e6 chunk passes and its residual repays extra debt. Final debt is
    ///         75000 - repaid - debtRepaid(residual), not a fixed 65000.
    function test_thinPool_fullReverts_thenChunkSucceeds() public {
        _assertHealthyDemoBaseline();
        crashNavAndAssertNavOnly();
        _mmThinPoolAndAssert();
        _assertThinFullCloseRevertsPartialFill();
        _assertThinChunkRepaysDebtWithResidual();
    }

    function _assertThinFullCloseRevertsPartialFill() private {
        (uint256 repay, uint256 seize) = market.previewLiquidation(borrower, type(uint256).max);
        assertEq(repay, BORROWER_DEBT, "HF 0.9067 <= 0.95: full close");
        assertEq(seize, CRASH_FULL_CLOSE_SEIZE, "full close seize at NAV 85");

        // spot 100 is on the allowed side of the 84.15 floor: the refusal cannot be PoolBelowNavFloor
        uint160 limit = navFloorLimitSqrtPriceX96(CRASH_NAV);
        _assertSpotAllowedByFloor(spotSqrtPriceX96(), limit, "thin pool keeps spot above the NAV floor");

        Sale memory ref = _referenceSale(seize, CRASH_NAV);
        assertEq(ref.endSqrtPriceX96, limit, "reference: the thin pool reaches the NAV floor");
        assertLt(ref.sold, seize, "reference: only part of the seize fits above the floor");
        assertEq(ref.sold, THIN_FULL_SOLD, "reference: measured vRWA sold down to the floor");

        // minBounty 0: the refusal cannot be BountyTooLow either
        World memory pre = captureWorld(borrower);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ISpecLiquidationAdapter.PartialFill.selector, ref.sold, seize));
        adapter.liquidate(borrower, type(uint256).max, 0);
        // complete rollback: balances, supplies, debt, collateral, claims, spot, L, MM position
        assertWorldUnchanged(pre);
        assertEq(usdc.balanceOf(keeper), 0, "keeper still 0 USDC after the refused full close");
    }

    function _assertThinChunkRepaysDebtWithResidual() private {
        Liquidation memory r = _liquidateMatchingReference(CHUNK_REPAY, CHUNK_BOUNTY);
        assertEq(r.repaid, CHUNK_REPAY, "nominal chunk 10000 USDC");
        assertEq(r.seized, CHUNK_SEIZE, "chunk seize at NAV 85");
        assertEq(r.seized, expectedSeize(CHUNK_REPAY, CRASH_NAV), "R3 seize formula");
        assertEq(r.proceeds, CHUNK_PROCEEDS, "measured chunk proceeds");
        assertEq(r.bounty, CHUNK_BOUNTY, "bounty == 6% LB cap of the chunk");
        assertGt((r.proceeds - r.repaid) * KEEPER_BPS / BPS, CHUNK_BOUNTY, "cap binds below the keeperBps share");
        assertEq(r.residual, CHUNK_RESIDUAL, "chunk residual");
        assertGt(r.residual, 0, "the chunk leaves a residual to apply");
        assertEq(r.marketBadDebt, 0, "collateral remains: no write-off");
        assertEq(r.post.pool.liquidity, THIN_L, "chunk sale leaves the thin L");
        _assertSpotAllowedByFloor(
            r.post.pool.sqrtPriceX96, navFloorLimitSqrtPriceX96(CRASH_NAV), "chunk sale stays above the floor"
        );
        assertEq(r.post.bal.keeperUsdc, CHUNK_BOUNTY, "keeper: 0 USDC -> bounty");

        // R5 step 8 + R3 priority: the whole residual reaches MiniLend and repays live debt first
        (uint256 debtRepaid, uint256 recovered, uint256 credit) = assertResidualSettledInMarket(r);
        assertEq(debtRepaid, CHUNK_RESIDUAL, "whole residual repays live debt");
        assertEq(recovered, 0, "no bad debt to recover");
        assertEq(credit, 0, "no borrower credit while debt remains");

        (uint256 coll, uint256 debt) = market.positions(borrower);
        assertEq(debt, BORROWER_DEBT - r.repaid - debtRepaid, "debt == 75000 - repaid - residual applied");
        assertEq(debt, CHUNK_FINAL_DEBT, "measured final debt");
        assertLt(debt, BORROWER_DEBT - CHUNK_REPAY, "final debt below the nominal 65000");
        assertEq(coll, BORROWER_COLLATERAL - CHUNK_SEIZE, "collateral -= chunk seize");
        assertEq(specClaimableResidual(borrower), 0, "borrower claim 0");
        assertEq(specTotalResidualClaims(), 0, "totalResidualClaims 0");
        assertEq(specBadDebtOf(borrower), 0, "badDebtOf 0");
        assertAccountingIdentity();
        assertLedgerSums();
        assertBadDebtSum();

        // the route depends on liquidity and may need more chunks: still liquidatable after one
        uint256 hf = market.healthFactor(borrower);
        assertEq(hf, _expectedHealthFactor(coll, debt, CRASH_NAV), "R3 HF after the chunk");
        assertLt(hf, 1e18, "one chunk does not restore health");
    }

    // ================================================================== C3: demo reset (RED)
    /// @notice TRACEABILITY: a local snapshot/revert restores NAV100, P100, L5e17, debt 75000, collateral 1000, keeper
    ///         0 USDC, active wrapper and claims 0. Mirrors reset.mjs: every revert consumes the snapshot id and a new
    ///         one is taken at once. Each branch first proves it moved the fields the reset has to restore.
    function test_demoResetRestoresBaseline() public {
        _assertHealthyDemoBaseline();
        _assertNoResidualLedger();
        World memory baseline = captureWorld(borrower);
        Permissions memory perms = _capturePermissions();
        uint256 t0 = block.timestamp;
        uint256 snap = vm.snapshotState();

        Liquidation memory first = _branchFullClose(); // O7 0:25-1:35
        snap = _resetToBaseline(snap, baseline, perms, t0);

        _branchThinPoolChunk(); // O7 1:35-2:35
        snap = _resetToBaseline(snap, baseline, perms, t0);

        _branchRevokeWrapper(); // O7 2:35-3:10
        snap = _resetToBaseline(snap, baseline, perms, t0);

        // the restored world replays the first branch to the same unit
        Liquidation memory replay = _branchFullClose();
        assertEq(replay.repaid, first.repaid, "replay: repaid");
        assertEq(replay.seized, first.seized, "replay: seized");
        assertEq(replay.proceeds, first.proceeds, "replay: proceeds");
        assertEq(replay.bounty, first.bounty, "replay: bounty");
        assertEq(replay.residual, first.residual, "replay: residual");
        assertEq(replay.post.pool.sqrtPriceX96, first.post.pool.sqrtPriceX96, "replay: post-sale spot");
        _resetToBaseline(snap, baseline, perms, t0);
    }

    /// @dev Crash + keeper full close through the adapter: moves NAV, navUpdatedAt, spot, debt, collateral, keeper
    ///      USDC and the borrower claim.
    function _branchFullClose() private returns (Liquidation memory r) {
        vm.warp(block.timestamp + BRANCH_DELAY);
        crashNavAndAssertNavOnly();
        r = _fullCloseAndAssert(0);
        (uint256 debtRepaid, uint256 recovered, uint256 credit) = assertResidualSettledInMarket(r);
        assertEq(debtRepaid, 0, "full close: no live debt left for the residual");
        assertEq(recovered, 0, "full close: no bad debt to recover");
        assertEq(credit, FULL_CLOSE_RESIDUAL, "full close: residual becomes borrower credit");
        assertEq(specClaimableResidual(borrower), FULL_CLOSE_RESIDUAL, "branch moved the borrower claim");
        assertEq(specTotalResidualClaims(), FULL_CLOSE_RESIDUAL, "branch moved totalResidualClaims");
        assertAccountingIdentity();
        assertBadDebtSum();
        // fields the reset must bring back
        assertEq(market.nav(), CRASH_NAV, "branch moved NAV");
        assertTrue(spotSqrtPriceX96() != sqrtPriceX96ForNav(NAV0), "branch moved spot");
        assertEq(r.post.ledger.debt, 0, "branch moved debt");
        assertEq(r.post.bal.keeperUsdc, FULL_CLOSE_BOUNTY, "branch paid the keeper");
    }

    /// @dev Crash + MM withdraws 95% + nominal chunk: additionally moves L, the MM position and desk balances.
    function _branchThinPoolChunk() private {
        vm.warp(block.timestamp + BRANCH_DELAY);
        crashNavAndAssertNavOnly();
        _mmThinPoolAndAssert();
        Liquidation memory r = _liquidateMatchingReference(CHUNK_REPAY, CHUNK_BOUNTY);
        assertEq(r.proceeds, CHUNK_PROCEEDS, "branch chunk proceeds");
        (uint256 debtRepaid,, uint256 credit) = assertResidualSettledInMarket(r);
        assertEq(debtRepaid, CHUNK_RESIDUAL, "branch chunk residual repays debt");
        assertEq(credit, 0, "branch chunk: no borrower credit");
        assertEq(r.post.ledger.debt, CHUNK_FINAL_DEBT, "branch moved debt");
        assertEq(r.post.pool.liquidity, THIN_L, "branch moved L");
        assertAccountingIdentity();
    }

    /// @dev Crash + issuer revokes only allowedWrapper(adapter): the same keeper call now fails inside the real hook.
    function _branchRevokeWrapper() private {
        vm.warp(block.timestamp + BRANCH_DELAY);
        crashNavAndAssertNavOnly();
        vm.prank(issuer);
        pa.updateAllowedWrapper(address(adapter), false);
        assertFalse(pa.allowedWrappers(address(adapter)), "branch revoked the adapter wrapper");
        assertTrue(pa.allowedWrappers(address(desk)), "revoke touches only the adapter");

        World memory pre = captureWorld(borrower);
        vm.prank(keeper);
        vm.expectRevert(hookWrappedError(abi.encodeWithSelector(ILabsPermissionedHooksErrors.Unauthorized.selector)));
        adapter.liquidate(borrower, type(uint256).max, 0);
        assertWorldUnchanged(pre);
    }

    /// @dev reset.mjs in Solidity: evm_revert must return true, the id is consumed, a fresh snapshot is taken.
    function _resetToBaseline(uint256 snap, World memory baseline, Permissions memory perms, uint256 t0)
        private
        returns (uint256 next)
    {
        assertTrue(vm.revertToStateAndDelete(snap), "revert to the healthy snapshot returns true");
        assertFalse(vm.revertToState(snap), "a consumed snapshot id cannot be reverted to again");
        assertEq(block.timestamp, t0, "reset restores the snapshot time");
        assertWorldUnchanged(baseline);
        _assertPermissionsEqual(perms, _capturePermissions());
        _assertHealthyDemoBaseline();
        _assertNoResidualLedger();
        next = vm.snapshotState();
        assertTrue(next != snap, "a new snapshot id replaces the consumed one");
    }

    // ================================================================== regressions (GREEN)
    /// @notice Healthy position: exact Healthy(hf) on the market view and on the keeper route for any repay size,
    ///         atomic; HF == 1e18 is still healthy; the market verdict precedes the R5 NAV floor. Control: one wei
    ///         of NAV lower, the same keeper call liquidates.
    function test_revert_healthyPosition() public {
        assertEq(market.healthFactor(borrower), HF_BASELINE, "baseline HF 1.0667");
        _assertRefusedHealthy(HF_BASELINE);

        // boundary: HF exactly 1e18 is healthy (liquidation needs HF < 1e18)
        setNavAsIssuer(NAV_HF_ONE);
        assertEq(market.healthFactor(borrower), 1e18, "NAV 93.75: HF == 1e18");
        _assertRefusedHealthy(1e18);
        _assertRefusalPrecedesNavFloor(abi.encodeWithSelector(ISpecMiniLend.Healthy.selector, 1e18));

        // control: one wei of NAV lower the borrower is liquidatable through the same call
        setNavAsIssuer(NAV_HF_ONE - 1);
        uint256 hf = market.healthFactor(borrower);
        assertEq(hf, HF_JUST_BELOW_ONE, "NAV 93.75e18-1: HF just below 1e18");
        assertEq(hf, _expectedHealthFactor(BORROWER_COLLATERAL, BORROWER_DEBT, NAV_HF_ONE - 1), "R3 HF formula");
        Liquidation memory r = _liquidateMatchingReference(type(uint256).max, 0);
        assertEq(r.repaid, HALF_CLOSE_REPAY, "0.95 < HF < 1: close factor 50%");
        assertEq(r.seized, expectedSeize(HALF_CLOSE_REPAY, NAV_HF_ONE - 1), "R3 seize formula");
        assertEq(r.marketBadDebt, 0, "no write-off");
        assertAccountingIdentityAnyVersion();
        assertLedgerSums();
        (uint256 coll, uint256 debt) = market.positions(borrower);
        assertEq(debt, BORROWER_DEBT - HALF_CLOSE_REPAY - residualSplitOf(r).debtRepaid, "debt after half close");
        assertEq(coll, BORROWER_COLLATERAL - r.seized, "collateral after half close");
        uint256 hfAfter = market.healthFactor(borrower);
        assertEq(hfAfter, _expectedHealthFactor(coll, debt, NAV_HF_ONE - 1), "R3 HF after half close");
        assertGt(hfAfter, 1e18, "half close restores health");
    }

    /// @notice Stale NAV: fresh exactly at MAX_STALENESS, StaleNav one second later on the view and the keeper
    ///         route, atomic; healthFactor() keeps answering, so it is not a freshness check; staleness precedes the
    ///         NAV floor. Control: the issuer re-publishes NAV 85 and the same keeper call closes the position.
    function test_revert_staleNav() public {
        crashNavAndAssertNavOnly();
        uint256 publishedAt = market.navUpdatedAt();

        vm.warp(publishedAt + NAV_STALENESS);
        (uint256 repay, uint256 seize) = market.previewLiquidation(borrower, type(uint256).max);
        assertEq(repay, BORROWER_DEBT, "fresh at exactly MAX_STALENESS: full close quoted");
        assertEq(seize, CRASH_FULL_CLOSE_SEIZE, "fresh at exactly MAX_STALENESS: seize quoted");

        vm.warp(publishedAt + NAV_STALENESS + 1);
        assertEq(market.healthFactor(borrower), HF_AFTER_CRASH, "healthFactor() still answers on a stale NAV");
        _assertRefusedStale();
        _assertRefusalPrecedesNavFloor(abi.encodeWithSelector(ISpecMiniLend.StaleNav.selector));

        setNavAsIssuer(CRASH_NAV);
        assertEq(market.navUpdatedAt(), publishedAt + NAV_STALENESS + 1, "NAV re-published now");
        Liquidation memory r = _fullCloseAndAssert(0);
        assertEq(r.pre.ledger.nav, CRASH_NAV, "liquidated at the re-published NAV");
    }

    /// @notice minBounty above the achievable bounty: exact BountyTooLow(bounty, minBounty) after the sale was quoted
    ///         inside unlock, and the swap, take and seize all roll back. minBounty equal to the bounty passes.
    function test_revert_minBountyNotMet() public {
        crashNavAndAssertNavOnly();
        Sale memory ref = _referenceSale(CRASH_FULL_CLOSE_SEIZE, CRASH_NAV);
        assertEq(ref.sold, CRASH_FULL_CLOSE_SEIZE, "reference: the full close sells whole");
        assertEq(ref.proceeds, FULL_CLOSE_PROCEEDS, "reference: measured full-close proceeds");
        (uint256 bounty,) = expectedSplit(ref.proceeds, BORROWER_DEBT);
        assertEq(bounty, FULL_CLOSE_BOUNTY, "full close bounty == 6% LB cap");

        World memory pre = captureWorld(borrower);
        _expectFullCloseBountyTooLow(FULL_CLOSE_BOUNTY + 1);
        _expectFullCloseBountyTooLow(type(uint256).max);
        assertWorldUnchanged(pre);
        assertEq(usdc.balanceOf(keeper), 0, "keeper still 0 USDC");

        // the keeper's own guard at exactly the achievable bounty is met (strict <)
        Liquidation memory r = _fullCloseAndAssert(FULL_CLOSE_BOUNTY);
        assertEq(r.post.bal.keeperUsdc, FULL_CLOSE_BOUNTY, "keeper paid exactly its minBounty");
    }

    /// @notice Token pause: TokenPaused() on the keeper route (after swap and take inside unlock) and on the direct KYC
    ///         route, atomic. Not a MiniLend veto and not a wallet freeze: freezing the borrower changes neither the
    ///         error nor the outcome, and once unpaused the same keeper call liquidates the frozen borrower.
    function test_revert_tokenPaused() public {
        crashNavAndAssertNavOnly();
        _fundKycLiquidator();
        vm.prank(issuer);
        rwa.setPaused(true);
        assertTrue(rwa.paused(), "issuer paused the RWA");

        World memory pre = captureWorld(borrower);
        assertFalse(pre.ledger.liquidationBlocked, "no MiniLend veto on the borrower");
        bytes memory paused = abi.encodeWithSelector(MockRWA3643.TokenPaused.selector);
        vm.prank(keeper);
        vm.expectRevert(paused);
        adapter.liquidate(borrower, type(uint256).max, 0);
        vm.prank(kycLiquidator);
        vm.expectRevert(paused);
        market.liquidate(borrower, type(uint256).max, "");
        assertWorldUnchanged(pre);
        assertEq(usdc.balanceOf(kycLiquidator), BORROWER_DEBT, "direct liquidator keeps its USDC");
        assertEq(rwa.balanceOf(kycLiquidator), 0, "direct liquidator received no RWA");

        // a wallet freeze on the borrower is a different control: while paused the cause stays TokenPaused
        vm.prank(issuer);
        rwa.setFrozen(borrower, true);
        pre = captureWorld(borrower);
        vm.prank(keeper);
        vm.expectRevert(paused);
        adapter.liquidate(borrower, type(uint256).max, 0);
        assertWorldUnchanged(pre);

        // lifting only the pause: the frozen borrower is liquidated by the same call, nothing reaches its wallet in RWA
        vm.prank(issuer);
        rwa.setPaused(false);
        Liquidation memory r = _fullCloseAndAssert(0);
        assertTrue(rwa.frozen(borrower), "borrower still frozen after its liquidation");
        assertEq(r.post.bal.borrowerRwa, 0, "frozen borrower holds no RWA");
        assertFalse(r.post.ledger.liquidationBlocked, "still no MiniLend veto");
    }

    // ================================================================== regression helpers
    function _assertRefusedHealthy(uint256 hf) private {
        bytes memory err = abi.encodeWithSelector(ISpecMiniLend.Healthy.selector, hf);
        World memory pre = captureWorld(borrower);
        vm.expectRevert(err);
        market.previewLiquidation(borrower, type(uint256).max);
        vm.prank(keeper);
        vm.expectRevert(err);
        adapter.liquidate(borrower, type(uint256).max, 0);
        vm.prank(keeper);
        vm.expectRevert(err);
        adapter.liquidate(borrower, CHUNK_REPAY, 0);
        assertWorldUnchanged(pre);
    }

    function _assertRefusedStale() private {
        bytes memory err = abi.encodeWithSelector(ISpecMiniLend.StaleNav.selector);
        World memory pre = captureWorld(borrower);
        vm.expectRevert(err);
        market.previewLiquidation(borrower, type(uint256).max);
        vm.prank(keeper);
        vm.expectRevert(err);
        adapter.liquidate(borrower, type(uint256).max, 0);
        vm.prank(keeper);
        vm.expectRevert(err);
        adapter.liquidate(borrower, CHUNK_REPAY, 0);
        assertWorldUnchanged(pre);
    }

    function _expectFullCloseBountyTooLow(uint256 minBounty) private {
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(ISpecBountyMathErrors.BountyTooLow.selector, FULL_CLOSE_BOUNTY, minBounty)
        );
        adapter.liquidate(borrower, type(uint256).max, minBounty);
    }

    /// @notice R5 order: previewLiquidation (fresh NAV, position) runs before the NAV floor, so a market refusal is
    ///         never masked by PoolBelowNavFloor. The MM's explicit spot fixture lives in a rolled-back snapshot.
    function _assertRefusalPrecedesNavFloor(bytes memory expected) private {
        uint256 snap = vm.snapshotState();
        uint160 target = sqrtPriceX96ForNav(SPOT_BELOW_FLOOR);
        mmSwapToPrice(target, rwa.balanceOf(address(desk)));
        assertEq(spotSqrtPriceX96(), target, "MM moved spot to 80");
        _assertSpotRejectedByFloor(spotSqrtPriceX96(), navFloorLimitSqrtPriceX96(market.nav()));

        World memory pre = captureWorld(borrower);
        vm.prank(keeper);
        vm.expectRevert(expected);
        adapter.liquidate(borrower, type(uint256).max, 0);
        assertWorldUnchanged(pre);
        assertTrue(vm.revertToStateAndDelete(snap), "spot fixture rolled back");
    }

    /// @dev A KYC liquidator: HOLDER set by the issuer, USDC from the minter, approval to MiniLend.
    function _fundKycLiquidator() private {
        vm.startPrank(issuer);
        rwa.setFlags(kycLiquidator, rwa.HOLDER());
        usdc.mint(kycLiquidator, BORROWER_DEBT);
        vm.stopPrank();
        vm.prank(kycLiquidator);
        usdc.approve(address(market), type(uint256).max);
    }

    // ================================================================== liquidation helpers
    /// @notice Full close at NAV 85 in the fixture pool, with the measured O7 figures.
    function _fullCloseAndAssert(uint256 minBounty) private returns (Liquidation memory r) {
        r = _liquidateMatchingReference(type(uint256).max, minBounty);
        assertEq(r.repaid, BORROWER_DEBT, "full close repays 75000");
        assertEq(r.seized, CRASH_FULL_CLOSE_SEIZE, "full close seize at NAV 85");
        assertEq(r.proceeds, FULL_CLOSE_PROCEEDS, "measured full-close proceeds");
        assertEq(r.bounty, FULL_CLOSE_BOUNTY, "bounty == 6% LB cap");
        assertLt(FULL_CLOSE_BOUNTY, (r.proceeds - r.repaid) * KEEPER_BPS / BPS, "cap below the keeperBps share");
        assertEq(r.residual, FULL_CLOSE_RESIDUAL, "full close residual");
        assertEq(r.marketBadDebt, 0, "collateral remains: no write-off");
        assertEq(r.post.ledger.debt, 0, "debt closed");
        assertEq(r.post.ledger.collateral, BORROWER_COLLATERAL - CRASH_FULL_CLOSE_SEIZE, "collateral left");
        assertEq(r.post.ledger.totalSupplyAssets, LENDER_USDC, "lenders keep 500k");
        assertAccountingIdentityAnyVersion();
        assertLedgerSums();
    }

    /// @notice Keeper liquidation checked against a reference sale of the same seize taken just before it: exact
    ///         repaid/seized (preview), proceeds and post-sale spot (reference), bounty/residual (R4 split), plus the
    ///         shared success-path check (inventory, exact wrap, hook Swap, proceeds destinations, ledger deltas).
    function _liquidateMatchingReference(uint256 repayAssets, uint256 minBounty)
        private
        returns (Liquidation memory r)
    {
        (uint256 repay, uint256 seize) = market.previewLiquidation(borrower, repayAssets);
        Sale memory ref = _referenceSale(seize, market.nav());
        assertEq(ref.sold, seize, "reference: the whole seize sells above the NAV floor");
        (uint256 bounty, uint256 residual) = expectedSplit(ref.proceeds, repay);

        r = liquidateViaAdapter(borrower, repayAssets, minBounty);
        assertLiquidationSuccessPath(r);
        assertEq(r.repaid, repay, "repaid == preview");
        assertEq(r.seized, seize, "seized == preview");
        assertEq(r.proceeds, ref.proceeds, "proceeds == reference sale on the real PM");
        assertEq(r.bounty, bounty, "bounty == R4 split of the reference proceeds");
        assertEq(r.residual, residual, "residual == R4 split of the reference proceeds");
        assertEq(r.post.pool.sqrtPriceX96, ref.endSqrtPriceX96, "sale ends at the reference spot");
        assertEq(r.post.pool.liquidity, r.pre.pool.liquidity, "a sale leaves L");
    }

    /// @notice Reference quote: the MM desk (allowed wrapper, MM holds SWAP) sells `amountIn` vRWA exact-in with the
    ///         R5 NAV-floor limit for `navWad`, on the same pool of the real PoolManager, then everything is rolled
    ///         back. The PM computes the same deltas for any sender, so this is what the R5 adapter swap must return.
    function _referenceSale(uint256 amountIn, uint256 navWad) private returns (Sale memory s) {
        uint160 limit = navFloorLimitSqrtPriceX96(navWad);
        World memory pre = captureWorld(borrower);
        // a sale toward the floor only: from the rejected side the desk would buy RWA instead
        _assertSpotAllowedByFloor(pre.pool.sqrtPriceX96, limit, "reference sale starts above the NAV floor");
        uint256 snap = vm.snapshotState();
        mmSwapToPrice(limit, amountIn);
        World memory post = captureWorld(borrower);
        s.sold = pre.bal.deskRwa - post.bal.deskRwa;
        s.proceeds = post.bal.deskUsdc - pre.bal.deskUsdc;
        s.endSqrtPriceX96 = post.pool.sqrtPriceX96;
        assertTrue(vm.revertToStateAndDelete(snap), "reference sale rolled back");
        assertWorldUnchanged(pre);
    }

    // ================================================================== demo state helpers
    /// @notice O4 healthy snapshot, spec literals on purpose (TRACEABILITY row), readable without the R3 ledger.
    function _assertHealthyDemoBaseline() private view {
        assertEq(market.nav(), 100e18, "baseline NAV 100");
        assertEq(spotSqrtPriceX96(), sqrtPriceX96ForNav(100e18), "baseline spot P=100");
        assertEq(PM.getLiquidity(poolId), 5e17, "baseline L 5e17");
        (uint128 deskL,,) = PM.getPositionInfo(poolId, address(desk), TICK_LOWER, TICK_UPPER, bytes32(0));
        assertEq(deskL, 5e17, "baseline MM position 5e17");
        (uint256 coll, uint256 debt) = market.positions(borrower);
        assertEq(coll, 1_000e18, "baseline collateral 1000");
        assertEq(debt, 75_000e6, "baseline debt 75000");
        assertEq(market.healthFactor(borrower), HF_BASELINE, "baseline HF 1.0667");
        assertEq(usdc.balanceOf(keeper), 0, "baseline keeper 0 USDC");
        assertEq(rwa.balanceOf(keeper), 0, "baseline keeper 0 RWA");
        assertTrue(pa.allowedWrappers(address(adapter)), "baseline adapter wrapper active");
        assertTrue(pa.allowedWrappers(address(desk)), "baseline desk wrapper active");
        assertTrue(pa.swappingEnabled(), "baseline swapping enabled");
        assertEq(market.totalBadDebt(), 0, "baseline totalBadDebt 0");
    }

    /// @notice claims 0, read through the R3 getters (named failure while they do not exist).
    function _assertNoResidualLedger() private view {
        assertEq(specClaimableResidual(borrower), 0, "baseline borrower claim 0");
        assertEq(specTotalResidualClaims(), 0, "baseline totalResidualClaims 0");
        assertEq(specBadDebtOf(borrower), 0, "baseline badDebtOf 0");
        assertAccountingIdentity();
    }

    /// @notice withdraw95: L 5e17 -> 2.5e16, spot unchanged, exact principal to the MM desk (no fees: no swap ran in
    ///         the pool yet), nothing else moves.
    function _mmThinPoolAndAssert() private {
        assertEq(MM_REMOVED_L + THIN_L, L_UNSIGNED, "withdraw95: 4.75e17 of 5e17 leaves 2.5e16");
        World memory pre = captureWorld(borrower);
        (uint256 paOut, uint256 usdcOut) = _expectedRemoval(pre.pool.sqrtPriceX96, MM_REMOVED_L);
        mmThinPool();
        World memory post = captureWorld(borrower);

        assertEq(post.pool.liquidity, THIN_L, "L 5e17 -> 2.5e16");
        assertEq(post.pool.deskLiquidity, THIN_L, "MM position 2.5e16");
        assertEq(post.pool.sqrtPriceX96, pre.pool.sqrtPriceX96, "withdrawal leaves spot");
        assertEq(post.pool.tick, pre.pool.tick, "withdrawal leaves tick");
        assertEq(post.bal.deskRwa, pre.bal.deskRwa + paOut, "desk receives the RWA principal");
        assertEq(post.bal.paSupply, pre.bal.paSupply - paOut, "vRWA burned on take");
        assertEq(post.bal.pmPa, pre.bal.pmPa - paOut, "PM vRWA out");
        assertEq(post.bal.paRwa, pre.bal.paRwa - paOut, "PA backing released");
        assertEq(post.bal.deskUsdc, pre.bal.deskUsdc + usdcOut, "desk receives the USDC principal");
        assertEq(post.bal.pmUsdc, pre.bal.pmUsdc - usdcOut, "PM USDC out");
        assertEq(post.bal.pmRwa, 0, "PM holds no raw RWA");
        _assertOnlyDeskAndPoolMoved(pre.bal, post.bal);
        assertEq(abi.encode(post.ledger), abi.encode(pre.ledger), "withdrawal leaves the MiniLend ledger");
    }

    function _assertOnlyDeskAndPoolMoved(Balances memory a, Balances memory b) private pure {
        assertEq(b.keeperUsdc, a.keeperUsdc, "withdrawal: keeper USDC");
        assertEq(b.keeperRwa, a.keeperRwa, "withdrawal: keeper RWA");
        assertEq(b.borrowerUsdc, a.borrowerUsdc, "withdrawal: borrower USDC");
        assertEq(b.borrowerRwa, a.borrowerRwa, "withdrawal: borrower RWA");
        assertEq(b.marketUsdc, a.marketUsdc, "withdrawal: market USDC");
        assertEq(b.marketRwa, a.marketRwa, "withdrawal: market RWA");
        assertEq(b.adapterUsdc, a.adapterUsdc, "withdrawal: adapter USDC");
        assertEq(b.adapterRwa, a.adapterRwa, "withdrawal: adapter RWA");
        assertEq(b.adapterClaimsPa, a.adapterClaimsPa, "withdrawal: adapter vRWA claims");
        assertEq(b.adapterClaimsUsdc, a.adapterClaimsUsdc, "withdrawal: adapter USDC claims");
        assertEq(b.issuerUsdc, a.issuerUsdc, "withdrawal: issuer USDC");
        assertEq(b.issuerRwa, a.issuerRwa, "withdrawal: issuer RWA");
        assertEq(b.mmUsdc, a.mmUsdc, "withdrawal: MM wallet USDC");
        assertEq(b.mmRwa, a.mmRwa, "withdrawal: MM wallet RWA");
        assertEq(b.lenderUsdc, a.lenderUsdc, "withdrawal: lender USDC");
        assertEq(b.rwaSupply, a.rwaSupply, "withdrawal: RWA supply");
        assertEq(b.usdcSupply, a.usdcSupply, "withdrawal: USDC supply");
    }

    /// @dev v4 Pool.modifyLiquidity for an in-range full-range position removal: principal rounded down.
    function _expectedRemoval(uint160 sqrtPriceX96, uint128 liquidity)
        private
        view
        returns (uint256 paOut, uint256 usdcOut)
    {
        uint256 amount0 =
            SqrtPriceMath.getAmount0Delta(sqrtPriceX96, TickMath.getSqrtPriceAtTick(TICK_UPPER), liquidity, false);
        uint256 amount1 =
            SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(TICK_LOWER), sqrtPriceX96, liquidity, false);
        (paOut, usdcOut) = paIsCurrency0 ? (amount0, amount1) : (amount1, amount0);
        assertGt(paOut, 0, "removal returns RWA");
        assertGt(usdcOut, 0, "removal returns USDC");
    }

    function _capturePermissions() private view returns (Permissions memory p) {
        p.adapterWrapper = pa.allowedWrappers(address(adapter));
        p.deskWrapper = pa.allowedWrappers(address(desk));
        p.swappingEnabled = pa.swappingEnabled();
        p.hookAllowed = pa.allowedHooks(HOOK);
        p.tokenPaused = rwa.paused();
        p.borrowerFrozen = rwa.frozen(borrower);
        p.adapterFlags = rwa.flags(address(adapter));
        p.deskFlags = rwa.flags(address(desk));
        p.marketFlags = rwa.flags(address(market));
        p.paFlags = rwa.flags(address(pa));
        p.mmFlags = rwa.flags(mm);
        p.issuerFlags = rwa.flags(issuer);
        p.keeperFlags = rwa.flags(keeper);
        p.borrowerFlags = rwa.flags(borrower);
        p.paOwner = pa.owner();
    }

    function _assertPermissionsEqual(Permissions memory a, Permissions memory b) private pure {
        assertEq(b.adapterWrapper, a.adapterWrapper, "reset: adapter wrapper");
        assertEq(b.deskWrapper, a.deskWrapper, "reset: desk wrapper");
        assertEq(b.swappingEnabled, a.swappingEnabled, "reset: swappingEnabled");
        assertEq(b.hookAllowed, a.hookAllowed, "reset: allowedHooks(hook)");
        assertEq(b.tokenPaused, a.tokenPaused, "reset: token paused");
        assertEq(b.borrowerFrozen, a.borrowerFrozen, "reset: borrower frozen");
        assertEq(b.adapterFlags, a.adapterFlags, "reset: adapter flags");
        assertEq(b.deskFlags, a.deskFlags, "reset: desk flags");
        assertEq(b.marketFlags, a.marketFlags, "reset: market flags");
        assertEq(b.paFlags, a.paFlags, "reset: PA flags");
        assertEq(b.mmFlags, a.mmFlags, "reset: MM flags");
        assertEq(b.issuerFlags, a.issuerFlags, "reset: issuer flags");
        assertEq(b.keeperFlags, a.keeperFlags, "reset: keeper flags");
        assertEq(b.borrowerFlags, a.borrowerFlags, "reset: borrower flags");
        assertEq(b.paOwner, a.paOwner, "reset: PA owner");
    }

    // ================================================================== math
    /// @dev R3: HF = floor(floor(c*n*LT/(S*B))*1e18/d).
    function _expectedHealthFactor(uint256 coll, uint256 debt, uint256 navWad) private pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(coll, navWad * LT_BPS, PRICE_SCALE * BPS), 1e18, debt);
    }

    /// @dev R5 table: PA currency0 rejects current <= limit; PA currency1 rejects current >= limit.
    function _assertSpotAllowedByFloor(uint160 spot, uint160 limit, string memory what) private view {
        if (paIsCurrency0) assertGt(spot, limit, what);
        else assertLt(spot, limit, what);
    }

    function _assertSpotRejectedByFloor(uint160 spot, uint160 limit) private view {
        if (paIsCurrency0) assertLe(spot, limit, "spot fixture sits below the NAV floor");
        else assertGe(spot, limit, "spot fixture sits below the NAV floor");
    }
}
