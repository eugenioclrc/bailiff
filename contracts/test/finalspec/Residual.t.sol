// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidationAdapter, IMiniLend} from "../../src/e2e/LiquidationAdapter.sol";
import {ISpecMiniLend} from "./SpecInterfaces.sol";
import {FinalSpecBase} from "./FinalSpecBase.sol";

/// @notice CONTRACTS R3 "Prioridad exacta del residual" (C1) on the pinned Sepolia fork: every liquidation is the keeper
///         (0 USDC) calling the real LiquidationAdapter, which sells through the REAL Labs PoolManager + PermissionedHooks.
///         R3 settlement order for `a` USDC with live debt `d` and pending write-off `w`:
///             debtRepaid = min(a, d); badDebtRecovered = min(a - debtRepaid, w); borrowerCredit = the rest.
///         Zero is never settled: settleLiquidationResidual(borrower, 0) reverts ZeroAmount at every ledger stage and
///         a liquidation whose residual is 0 makes no settlement call at all (R3, R5 step 8 "Si residual>0").
/// @dev All five tests are RED on the snapshot: its adapter pushes the residual straight to the borrower (R5 step 8
///      missing) and its MiniLend has no badDebtOf / settleLiquidationResidual / claim ledger (R3). Each test first
///      checks the parts the snapshot already gets right (success path, pool math, R4 split, write-off, and the
///      residual-0 liquidation, which the snapshot already leaves in MiniLend), then fails at the first assertion
///      naming its own missing behavior:
///        partialRepaysDebt           -> "debt == 75000e6 - repaid - residual"
///        badDebtZeroingDoesNotPay... -> "written-off debt outstanding: no residual USDC to the borrower"
///        recoveryThenBorrowerCredit  -> "stage 1 before stage 2: ..." (first, partial settlement)
///        recoveryUsesCurrentShares   -> "in-flow recovery accrues to the shares outstanding at recovery time"
///        badDebtPersistsAfterReborrow-> "R3 MiniLend.badDebtOf() not implemented" (the loss ledger itself)
///      Sale amounts are pinned from the real v4 exact-in math on this fixture (spot, L=5e17, fee 3000); the NAV-floor
///      limit of R5 is never reached in these sales (checked), so the same amounts hold once R5 is implemented.
contract ResidualTest is FinalSpecBase {
    // ------------------------------------------------------------------ R3 lending literals (spec, not read from src)
    uint256 internal constant LT_BPS = 8_000;
    uint256 internal constant FULL_CLOSE_HF = 0.95e18;
    uint256 internal constant MIN_LEFTOVER_DEBT = 1_000e6; // binds the nominal repay only, never the residual
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    uint256 internal constant LENDER_SHARES = 5e17; // 500000e6 * (0 + 1e6) / (0 + 1)

    bytes32 internal constant REPAID_TOPIC = keccak256("Repaid(address,address,uint256)");
    bytes32 internal constant RESIDUAL_CLAIMED_TOPIC = keccak256("ResidualClaimed(address,uint256)");

    // ------------------------------------------------------------------ partial close (NAV-only 100 -> 90, spot 100)
    uint256 internal constant NAV_PARTIAL = 90e18;
    uint256 internal constant HF_PARTIAL = 0.96e18; // floor(1000*90*0.8/75000 * 1e18): 0.95 < HF < 1
    uint256 internal constant PARTIAL_REPAY = 37_500e6; // close factor 50%
    uint256 internal constant PARTIAL_SEIZE = 441_666_666_666_666_666_666; // floor(37500e6*10600*1e30/(90e18*1e4))
    uint256 internal constant PARTIAL_PROCEEDS = 43_649_750_587;
    uint256 internal constant PARTIAL_BOUNTY = 2_250_000_000; // 6% LB cap binds (surplus/2 = 3074.875293)
    uint256 internal constant PARTIAL_RESIDUAL = 3_899_750_587;
    uint256 internal constant PARTIAL_DEBT_LEFT = 33_600_249_413; // 75000e6 - 37500e6 - residual
    uint256 internal constant PARTIAL_HF_AFTER = 1_196_419_690_398_088_057; // (1000e18-seize, 33600.249413, NAV 90)

    // ------------------------------------------------------------------ second partial, full-close regime (NAV-only -> 70)
    // Nominal repay leaves 10200.249413 (>= MIN_LEFTOVER_DEBT); the residual then takes live debt to 531.839002.
    uint256 internal constant NAV_DUST = 70e18;
    uint256 internal constant HF_DUST = 930_548_648_067_560_700; // (558.33e18, 33600.249413, NAV 70) <= 0.95
    uint256 internal constant DUST_CHUNK = 23_400e6;
    uint256 internal constant DUST_SEIZE = 354_342_857_142_857_142_857; // floor(23400e6*10600*1e30/(70e18*1e4))
    uint256 internal constant DUST_PROCEEDS = 34_472_410_411;
    uint256 internal constant DUST_BOUNTY = 1_404_000_000; // 6% LB cap binds (surplus/2 = 5536.205205)
    uint256 internal constant DUST_RESIDUAL = 9_668_410_411;
    uint256 internal constant DUST_NOMINAL_LEFT = 10_200_249_413; // 33600.249413 - 23400
    uint256 internal constant DUST_DEBT_LEFT = 531_839_002; // nominal leftover - residual, in (0, 1000e6)
    uint256 internal constant DUST_COLLATERAL_LEFT = 203_990_476_190_476_190_477;
    uint256 internal constant DUST_HF_AFTER = 21_479_181_900_991_909_577; // (collateral left, 531.839002, NAV 70)

    // ------------------------------------------------------------------ residual 0 (O4 crash 100 -> 85, MM spot 85)
    // With the default keeperBps 5000 a sale above the NAV floor always leaves residual >= ceil(surplus/2) > 0, so the
    // zero branch needs keeperBps 10000 (the R4 constructor bound): a surplus within the LB cap is all bounty.
    uint256 internal constant FULL_BOUNTY_KEEPER_BPS = 10_000;
    uint256 internal constant ZERO_RES_CHUNK = 8_500e6; // leaves 66500e6 of live debt (>= 1000e6: no dust)
    uint256 internal constant ZERO_RES_SEIZE = 106e18; // 8500e6*10600*1e30/(85e18*1e4), exact
    uint256 internal constant ZERO_RES_PROCEEDS = 8_965_499_113; // one exact-in step from sqrtPriceX96ForNav(85e18)
    uint256 internal constant ZERO_RES_BOUNTY = 465_499_113; // the whole surplus, below the 510e6 LB cap
    uint256 internal constant ZERO_RES_RESIDUAL_AT_DEFAULT = 232_749_557; // what the 5000 adapter would have left
    uint160 internal constant ZERO_RES_SQRT_AFTER = 729_026_926_528_388_724_694_294; // > NAV-85 floor limit
    uint256 internal constant ZERO_RES_DEBT_LEFT = 66_500e6; // 75000e6 - nominal repay, nothing else

    // ------------------------------------------------------------------ write-off (MM spot 75, NAV-only -> 70)
    uint256 internal constant SPOT_WRITEOFF = 75e18; // explicit MM fixture (R6), not part of the crash
    uint256 internal constant NAV_WRITEOFF = 70e18;
    uint256 internal constant HF_WRITEOFF = 746_666_666_666_666_666; // floor(1000*70*0.8/75000 * 1e18) <= 0.95
    uint256 internal constant WRITEOFF_REPAY = 66_037_735_850; // ceil(1000e18*70e18*1e4/(1e30*10600))
    uint256 internal constant WRITEOFF_BAD_DEBT = 8_962_264_150; // 75000e6 - repay, gross write-off
    uint256 internal constant WRITEOFF_PROCEEDS = 73_505_664_019;
    uint256 internal constant WRITEOFF_BOUNTY = 3_733_964_084; // floor(surplus/2), below the 3962.264151 cap
    uint256 internal constant WRITEOFF_RESIDUAL = 3_733_964_085; // < gross write-off: all of it recovers lenders
    uint256 internal constant WRITEOFF_PENDING = 5_228_300_065; // write-off still unrecovered

    // ------------------------------------------------------------------ reopened position (NAV 70), then NAV-only -> 50
    uint256 internal constant NAV_REOPEN_CRASH = 50e18;
    uint256 internal constant REOPEN_LEFTOVER = 2_000e6; // live debt the keeper's chunk leaves (>= 1000e6: no dust)
    // badDebtPersistsAfterReborrow: residual < leftover + pending, so no credit
    uint256 internal constant REOPEN_COLLATERAL = 200e18;
    uint256 internal constant REOPEN_CAPACITY = 10_500e6; // floor(200e18*70e18*7500/(1e30*1e4))
    uint256 internal constant REOPEN_DEBT = 10_000e6;
    uint256 internal constant HF_REOPENED = 1.12e18; // floor(200*70*0.8/10000 * 1e18)
    uint256 internal constant REOPEN_CHUNK = 8_000e6;
    uint256 internal constant REOPEN_SEIZE = 169.6e18; // floor(8000e6*10600*1e30/(50e18*1e4))
    uint256 internal constant REOPEN_PROCEEDS = 12_219_754_663;
    uint256 internal constant REOPEN_BOUNTY = 480_000_000; // 6% cap
    uint256 internal constant REOPEN_RESIDUAL = 3_739_754_663;
    uint256 internal constant REOPEN_RECOVERED = 1_739_754_663; // residual - leftover, < pending
    uint256 internal constant REOPEN_PENDING_AFTER = 3_488_545_402; // 5228300065 - 1739754663
    // recoveryThenBorrowerCredit, first sale: 0 < residual < live debt, write-off pending -> all of it is stage 1
    uint256 internal constant RECOVERY_COLLATERAL = 400e18;
    uint256 internal constant RECOVERY_DEBT = 20_000e6;
    uint256 internal constant HF_RECOVERY_CRASH = 0.8e18; // floor(400*50*0.8/20000 * 1e18)
    uint256 internal constant PROBE_CHUNK = 1_000e6;
    uint256 internal constant PROBE_SEIZE = 21.2e18; // floor(1000e6*10600*1e30/(50e18*1e4)), exact
    uint256 internal constant PROBE_PROCEEDS = 1_531_315_873;
    uint256 internal constant PROBE_BOUNTY = 60_000_000; // 6% cap (surplus/2 = 265.657936)
    uint256 internal constant PROBE_RESIDUAL = 471_315_873;
    uint256 internal constant PROBE_DEBT_LEFT = 18_528_684_127; // 20000e6 - 1000e6 - residual
    uint256 internal constant PROBE_HF_AFTER = 817_759_096_984_146_023; // (378.8e18, 18528.684127, NAV 50) <= 0.95
    // second sale: residual > leftover + pending, so only the excess is credit
    uint256 internal constant RECOVERY_CHUNK = 16_528_684_127; // leaves exactly REOPEN_LEFTOVER of live debt
    uint256 internal constant RECOVERY_SEIZE = 350_408_103_492_400_000_000; // floor(chunk*10600*1e30/(50e18*1e4))
    uint256 internal constant RECOVERY_PROCEEDS = 25_151_972_736;
    uint256 internal constant RECOVERY_BOUNTY = 991_721_047; // 6% cap (surplus/2 = 4311.644304)
    uint256 internal constant RECOVERY_RESIDUAL = 7_631_567_562;
    uint256 internal constant RECOVERY_CREDIT = 403_267_497; // 7631567562 - 2000e6 - 5228300065
    uint256 internal constant RECOVERY_COLLATERAL_LEFT = 28_391_896_507_600_000_000; // 400e18 - 21.2e18 - seize

    // ------------------------------------------------------------------ lenders around the loss (current shares)
    uint256 internal constant STAYS_SUPPLY = 100_000e6;
    uint256 internal constant STAYS_SHARES = 1e17; // 100000e6*(5e17+1e6)/(500000e6+1), exact
    uint256 internal constant EXIT_ASSETS = 495_643_083_279; // 5e17 shares at (6e17, 594771.699935)
    uint256 internal constant LATE_SUPPLY = 50_000e6;
    uint256 internal constant LATE_SHARES = 50_439_521_589_923_481; // bought at the depressed share price
    uint256 internal constant STAYS_OUT = 102_603_966_756;
    uint256 internal constant LATE_OUT = 51_752_949_964;

    address internal recoveryPayer = makeAddr("recoveryPayer"); // any third party settling a residual (permissionless)
    address internal zeroPayer = makeAddr("zeroPayer"); // funded and approved, tries to settle 0
    address internal lenderStays = makeAddr("lenderStays");
    address internal lenderLate = makeAddr("lenderLate");

    // ================================================================== tests
    /// @notice CONTRACTS R7: debt falls by the nominal repay PLUS the residual applied to principal; while debt remains
    ///         the borrower is paid nothing (no USDC, no claimable credit). Boundary first: with residual 0 the part
    ///         applied is 0 and no settlement happens at all. Then two partial liquidations of the same position: one
    ///         under the 50% close factor, and one in the full-close regime whose residual takes live debt below
    ///         MIN_LEFTOVER_DEBT without clearing it (R3: the threshold binds the nominal repay, never the residual;
    ///         no money is held back to keep a minimum debt).
    function test_residual_partialRepaysDebt() public {
        _zeroResidualSkipsSettlement(); // isolated: the fixture is restored before the partial case

        _moveNavOnly(NAV_PARTIAL);
        assertEq(market.healthFactor(borrower), HF_PARTIAL, "0.95 < HF < 1: close factor 50%");

        Liquidation memory r = liquidateViaAdapter();
        assertLiquidationSuccessPath(r);
        _assertSale(r, PARTIAL_REPAY, PARTIAL_SEIZE, PARTIAL_PROCEEDS, PARTIAL_BOUNTY, PARTIAL_RESIDUAL, 0);
        assertEq(r.seized, expectedSeize(r.repaid, NAV_PARTIAL), "R3 seize formula");
        _assertSpotAboveNavFloor("post-sale spot above the NAV floor");

        // RED on the snapshot: debt falls by the nominal repay only and the residual goes to the borrower
        assertEq(r.post.ledger.debt, BORROWER_DEBT - r.repaid - r.residual, "debt == 75000e6 - repaid - residual");
        assertEq(r.post.ledger.debt, PARTIAL_DEBT_LEFT, "debt left 33600.249413");
        _assertLiquidationSplit(r, PARTIAL_RESIDUAL, 0, 0);
        _assertResidualLedger(0, 0, LENDER_USDC);
        assertEq(r.post.ledger.collateral, BORROWER_COLLATERAL - PARTIAL_SEIZE, "collateral -= seize");
        assertEq(market.healthFactor(borrower), PARTIAL_HF_AFTER, "HF from the reduced debt");
        assertEq(
            PARTIAL_HF_AFTER,
            _healthFactor(r.post.ledger.collateral, r.post.ledger.debt, NAV_PARTIAL),
            "R3 HF formula on the post state"
        );
        _assertBorrowerCannotClaim();

        _residualTakesDebtBelowMinLeftover();
        _assertBorrowerCannotClaim();
        _assertZeroSettleRejected(); // stage 1: live debt outstanding
    }

    /// @notice CONTRACTS R7 case 1: the write-off sets live debt to 0 while badDebtOf > 0; the residual recovers lenders
    ///         (totalSupplyAssets up, totalBadDebt down) and the borrower is credited only after the last unit of loss.
    function test_residual_badDebtZeroingDoesNotPayBorrower() public {
        Liquidation memory r = _writeOffWithPartialRecovery();

        // RED on the snapshot: the adapter pays the whole residual to a borrower whose loss is still unrecovered
        assertEq(
            r.post.bal.borrowerUsdc,
            r.pre.bal.borrowerUsdc,
            "written-off debt outstanding: no residual USDC to the borrower"
        );
        _assertLiquidationSplit(r, 0, WRITEOFF_RESIDUAL, 0);
        assertEq(r.marketBadDebt, WRITEOFF_BAD_DEBT, "Liquidated.badDebt keeps the gross write-off");
        _assertResidualLedger(WRITEOFF_PENDING, 0, LENDER_USDC - WRITEOFF_PENDING);
        assertEq(market.healthFactor(borrower), type(uint256).max, "debt 0 reads as max HF although a loss is pending");
        _assertBorrowerCannotClaim();
        _assertZeroSettleRejected(); // stage 2: live debt 0, write-off pending

        // permissionless recovery up to one unit short of the loss: still no credit
        _thirdPartySettle(WRITEOFF_PENDING - 1, 0, WRITEOFF_PENDING - 1, 0);
        _assertResidualLedger(1, 0, LENDER_USDC - 1);
        _assertBorrowerCannotClaim();
        // the last unit of loss, then the first unit of credit
        _thirdPartySettle(2, 0, 1, 1);
        _assertResidualLedger(0, 1, LENDER_USDC);
    }

    /// @notice TRACEABILITY: min(assets, liveDebt), then min(rest, badDebt), then credit; destinations sum to assets.
    ///         Two real liquidations of a position reopened while a write-off is pending. The first residual is
    ///         smaller than the live debt, with both live debt and the write-off outstanding: all of it is stage 1 and
    ///         the loss is untouched (a loss-first order would split it differently). The second residual exceeds
    ///         live debt + pending loss: all three stages non-zero, and only the excess over live and written-off
    ///         debt becomes credit; lenders end exactly whole.
    function test_residual_recoveryThenBorrowerCredit() public {
        _writeOffWithPartialRecovery();
        _reopen(RECOVERY_COLLATERAL, RECOVERY_DEBT);
        _moveNavOnly(NAV_REOPEN_CRASH);
        assertEq(market.healthFactor(borrower), HF_RECOVERY_CRASH, "HF <= 0.95: full close regime");

        _residualBelowLiveDebtIsStageOneOnly();

        Liquidation memory r = liquidateViaAdapter(borrower, RECOVERY_CHUNK, 0);
        assertLiquidationSuccessPath(r);
        _assertSale(r, RECOVERY_CHUNK, RECOVERY_SEIZE, RECOVERY_PROCEEDS, RECOVERY_BOUNTY, RECOVERY_RESIDUAL, 0);
        assertEq(r.seized, expectedSeize(r.repaid, NAV_REOPEN_CRASH), "R3 seize formula");
        assertEq(r.pre.ledger.debt, PROBE_DEBT_LEFT, "second sale starts from the debt the first residual left");
        assertEq(r.pre.ledger.debt - r.repaid, REOPEN_LEFTOVER, "chunk leaves 2000e6 of live debt");
        assertEq(r.pre.ledger.badDebtOf, WRITEOFF_PENDING, "write-off still fully pending before the second sale");
        assertGt(r.residual, REOPEN_LEFTOVER + WRITEOFF_PENDING, "residual exceeds live debt + pending loss");
        _assertSpotAboveNavFloor("post-sale spot above the NAV floor");

        assertEq(r.post.ledger.debt, 0, "stage 1 min(assets, liveDebt): residual clears the 2000e6 left by the chunk");
        _assertLiquidationSplit(r, REOPEN_LEFTOVER, WRITEOFF_PENDING, RECOVERY_CREDIT);
        assertEq(
            RECOVERY_CREDIT, RECOVERY_RESIDUAL - REOPEN_LEFTOVER - WRITEOFF_PENDING, "credit == residual - live - loss"
        );
        _assertResidualLedger(0, RECOVERY_CREDIT, LENDER_USDC);
        assertEq(r.post.ledger.collateral, RECOVERY_COLLATERAL_LEFT, "collateral -= both seizes");
        _assertZeroSettleRejected(); // stage 3: nothing owed, credit outstanding
    }

    /// @notice CONTRACTS R3: recovery accrues to whoever holds shares when it happens (no cohort history). A lender who
    ///         left after the loss is not compensated; a lender who entered after the loss shares in the recovery.
    function test_residual_recoveryUsesCurrentShares() public {
        assertEq(market.supplyShares(lender), LENDER_SHARES, "fixture lender shares");
        uint256 ts = LENDER_SHARES;
        uint256 ta = LENDER_USDC;
        uint256 stayShares = _supplyAs(lenderStays, STAYS_SUPPLY, ts, ta);
        assertEq(stayShares, STAYS_SHARES, "second lender joins before the loss at 1e6 shares per unit");
        (ts, ta) = (ts + stayShares, ta + STAYS_SUPPLY);

        Liquidation memory r = _writeOffWithPartialRecovery();
        // RED on the snapshot: the residual leaves MiniLend, lenders bear the whole gross write-off
        ta = ta - WRITEOFF_BAD_DEBT + WRITEOFF_RESIDUAL;
        assertEq(market.totalSupplyAssets(), ta, "in-flow recovery accrues to the shares outstanding at recovery time");
        assertEq(market.totalSupplyShares(), ts, "recovery mints no shares");
        _assertLiquidationSplit(r, 0, WRITEOFF_RESIDUAL, 0);
        _assertResidualLedger(WRITEOFF_PENDING, 0, ta);

        // the fixture lender leaves after the loss, before the rest is recovered, bearing its share of it
        uint256 exitAssets = _withdrawAllAs(lender, ts, ta);
        assertEq(exitAssets, EXIT_ASSETS, "exit at the depressed share price");
        assertLt(exitAssets, LENDER_USDC, "exiting lender keeps its share of the still unrecovered loss");
        (ts, ta) = (ts - LENDER_SHARES, ta - exitAssets);
        // a new lender enters at the depressed share price
        uint256 lateShares = _supplyAs(lenderLate, LATE_SUPPLY, ts, ta);
        assertEq(lateShares, LATE_SHARES, "late lender buys at the depressed share price");
        (ts, ta) = (ts + lateShares, ta + LATE_SUPPLY);
        uint256 stayBefore = _assetsFor(stayShares, ts, ta);
        uint256 lateBefore = _assetsFor(lateShares, ts, ta);

        // the rest of the loss is recovered later by a permissionless settlement
        _thirdPartySettle(WRITEOFF_PENDING, 0, WRITEOFF_PENDING, 0);
        ta += WRITEOFF_PENDING;
        _assertResidualLedger(0, 0, ta);
        assertEq(market.totalSupplyShares(), ts, "recovery mints no shares");
        assertEq(market.supplyShares(lender), 0, "exited lender holds no shares");
        assertEq(usdc.balanceOf(lender), exitAssets, "exited lender is not compensated by the later recovery");

        _assertCurrentSharesTookRecovery(stayShares, lateShares, stayBefore, lateBefore, ts, ta);
    }

    /// @notice CONTRACTS R3: reopening through the existing guards keeps badDebtOf; the next residual pays live debt
    ///         first, then the pending loss, and creates no credit while any of that loss remains.
    function test_residual_badDebtPersistsAfterReborrow() public {
        _writeOffWithPartialRecovery();
        vm.prank(issuer);
        rwa.mint(borrower, REOPEN_COLLATERAL);
        vm.prank(borrower);
        market.depositCollateral(REOPEN_COLLATERAL);
        // RED on the snapshot: MiniLend keeps no per-borrower write-off ledger at all
        assertEq(specBadDebtOf(borrower), WRITEOFF_PENDING, "a new deposit keeps the prior write-off");

        _assertReopenGuards();
        vm.prank(borrower);
        market.borrow(REOPEN_DEBT);
        (uint256 coll, uint256 debt) = market.positions(borrower);
        assertEq(coll, REOPEN_COLLATERAL, "reopened collateral");
        assertEq(debt, REOPEN_DEBT, "reopened debt");
        assertEq(market.healthFactor(borrower), HF_REOPENED, "new position healthy at NAV 70");
        _assertResidualLedger(WRITEOFF_PENDING, 0, LENDER_USDC - WRITEOFF_PENDING);

        _moveNavOnly(NAV_REOPEN_CRASH);
        Liquidation memory r = liquidateViaAdapter(borrower, REOPEN_CHUNK, 0);
        assertLiquidationSuccessPath(r);
        _assertSale(r, REOPEN_CHUNK, REOPEN_SEIZE, REOPEN_PROCEEDS, REOPEN_BOUNTY, REOPEN_RESIDUAL, 0);
        assertEq(r.seized, expectedSeize(r.repaid, NAV_REOPEN_CRASH), "R3 seize formula");
        assertEq(r.pre.ledger.debt - r.repaid, REOPEN_LEFTOVER, "chunk leaves 2000e6 of live debt");
        _assertSpotAboveNavFloor("post-sale spot above the NAV floor");
        assertEq(r.post.ledger.debt, 0, "residual pays the live debt first");
        _assertLiquidationSplit(r, REOPEN_LEFTOVER, REOPEN_RECOVERED, 0);
        _assertResidualLedger(REOPEN_PENDING_AFTER, 0, LENDER_USDC - REOPEN_PENDING_AFTER);
        _assertBorrowerCannotClaim();

        // closing the new position does not clear the old loss either
        uint256 left = r.post.ledger.collateral;
        assertEq(left, REOPEN_COLLATERAL - REOPEN_SEIZE, "collateral -= seize");
        vm.prank(borrower);
        market.withdrawCollateral(left);
        assertEq(rwa.balanceOf(borrower), left, "borrower withdrew the rest of its collateral");
        _assertResidualLedger(REOPEN_PENDING_AFTER, 0, LENDER_USDC - REOPEN_PENDING_AFTER);
    }

    // ================================================================== scenario steps
    /// @dev Explicit MM fixture (spot 75) + NAV-only move to 70: the whole collateral is sold above the NAV floor and
    ///      the proceeds do not cover the obligation. Checks only what holds on the snapshot too.
    function _writeOffWithPartialRecovery() private returns (Liquidation memory r) {
        _mmMoveSpot(SPOT_WRITEOFF);
        _moveNavOnly(NAV_WRITEOFF);
        assertEq(market.healthFactor(borrower), HF_WRITEOFF, "HF <= 0.95: full close");
        _assertSpotAboveNavFloor("pre-sale spot above the NAV floor");

        r = liquidateViaAdapter();
        assertLiquidationSuccessPath(r);
        _assertSale(
            r,
            WRITEOFF_REPAY,
            BORROWER_COLLATERAL,
            WRITEOFF_PROCEEDS,
            WRITEOFF_BOUNTY,
            WRITEOFF_RESIDUAL,
            WRITEOFF_BAD_DEBT
        );
        assertEq(
            r.repaid,
            Math.mulDiv(BORROWER_COLLATERAL, NAV_WRITEOFF * BPS, PRICE_SCALE * (BPS + LB_BPS), Math.Rounding.Ceil),
            "seize capped at collateral: repay = ceil(c*n*B/(S*(B+LB)))"
        );
        assertEq(r.marketBadDebt, BORROWER_DEBT - r.repaid, "gross write-off = debt - repay");
        assertLt(r.residual, r.marketBadDebt, "proceeds do not cover the whole obligation");
        _assertSpotAboveNavFloor("post-sale spot above the NAV floor");
        assertEq(r.post.ledger.collateral, 0, "all collateral seized");
        assertEq(r.post.ledger.debt, 0, "write-off zeroes the live debt");
        assertAccountingIdentityAnyVersion();
        assertLedgerSums();
    }

    /// @dev First sale of recoveryThenBorrowerCredit (reopened position, NAV 50, full-close regime): the residual `a` is
    ///      below the live debt `d` the chunk leaves while the write-off `w` is pending (0 < a < d, w > 0). R3 order:
    ///      debtRepaid = min(a, d) = a, badDebtRecovered = 0, borrowerCredit = 0. Since a < w as well, a loss-first
    ///      order would have put all of it into the loss instead, so this sale pins stage 1 before stage 2.
    function _residualBelowLiveDebtIsStageOneOnly() private {
        Liquidation memory r = liquidateViaAdapter(borrower, PROBE_CHUNK, 0);
        assertLiquidationSuccessPath(r);
        _assertSale(r, PROBE_CHUNK, PROBE_SEIZE, PROBE_PROCEEDS, PROBE_BOUNTY, PROBE_RESIDUAL, 0);
        assertEq(r.seized, expectedSeize(r.repaid, NAV_REOPEN_CRASH), "R3 seize formula");
        assertEq(r.pre.ledger.debt, RECOVERY_DEBT, "first sale starts from the reopened debt");
        uint256 liveLeft = r.pre.ledger.debt - r.repaid;
        assertGe(liveLeft, MIN_LEFTOVER_DEBT, "nominal repay leaves no dust");
        assertGt(r.residual, 0, "residual > 0");
        assertLt(r.residual, liveLeft, "residual < live debt left by the chunk");
        assertLt(r.residual, WRITEOFF_PENDING, "residual < pending write-off: the order alone decides the split");
        _assertSpotAboveNavFloor("post-sale spot above the NAV floor");

        // RED on the snapshot: the live debt keeps the nominal leftover and the residual is pushed to the borrower
        assertEq(
            r.post.ledger.debt,
            liveLeft - r.residual,
            "stage 1 before stage 2: with a write-off pending, a residual below live debt all repays live debt"
        );
        assertEq(r.post.ledger.debt, PROBE_DEBT_LEFT, "debt left 18528.684127");
        assertEq(r.pre.ledger.badDebtOf, WRITEOFF_PENDING, "write-off pending when the residual is settled");
        _assertLiquidationSplit(r, PROBE_RESIDUAL, 0, 0);
        _assertResidualLedger(WRITEOFF_PENDING, 0, LENDER_USDC - WRITEOFF_PENDING);
        assertEq(r.post.ledger.collateral, RECOVERY_COLLATERAL - PROBE_SEIZE, "collateral -= seize");
        assertEq(market.healthFactor(borrower), PROBE_HF_AFTER, "HF from the reduced debt");
        assertEq(
            PROBE_HF_AFTER,
            _healthFactor(r.post.ledger.collateral, r.post.ledger.debt, NAV_REOPEN_CRASH),
            "R3 HF formula on the post state"
        );
        assertLe(PROBE_HF_AFTER, FULL_CLOSE_HF, "still in the full-close regime");
        _assertBorrowerCannotClaim();
    }

    /// @dev Second partial of partialRepaysDebt, same position: NAV-only 90 -> 70 puts it in the full-close regime.
    ///      The nominal repay must leave >= MIN_LEFTOVER_DEBT (preview boundary checked); the residual is then applied
    ///      to principal in full and takes live debt into (0, MIN_LEFTOVER_DEBT): nothing is held back or credited.
    function _residualTakesDebtBelowMinLeftover() private {
        _moveNavOnly(NAV_DUST);
        assertEq(market.healthFactor(borrower), HF_DUST, "HF <= 0.95: full close regime");
        assertLe(HF_DUST, FULL_CLOSE_HF, "HF_DUST in the full-close regime");
        _assertNominalLeftoverBoundary(PARTIAL_DEBT_LEFT);

        Liquidation memory r = liquidateViaAdapter(borrower, DUST_CHUNK, 0);
        assertLiquidationSuccessPath(r);
        _assertSale(r, DUST_CHUNK, DUST_SEIZE, DUST_PROCEEDS, DUST_BOUNTY, DUST_RESIDUAL, 0);
        assertEq(r.seized, expectedSeize(r.repaid, NAV_DUST), "R3 seize formula");
        assertEq(r.pre.ledger.debt, PARTIAL_DEBT_LEFT, "second sale starts from the debt the first residual left");
        assertEq(r.pre.ledger.debt - r.repaid, DUST_NOMINAL_LEFT, "nominal repay leaves 10200.249413");
        assertGe(DUST_NOMINAL_LEFT, MIN_LEFTOVER_DEBT, "nominal leftover respects MIN_LEFTOVER_DEBT");
        assertGt(r.residual, DUST_NOMINAL_LEFT - MIN_LEFTOVER_DEBT, "residual reaches below MIN_LEFTOVER_DEBT");
        assertLt(r.residual, DUST_NOMINAL_LEFT, "residual does not clear the debt");
        _assertSpotAboveNavFloor("post-sale spot above the NAV floor");

        assertEq(
            r.post.ledger.debt,
            DUST_NOMINAL_LEFT - DUST_RESIDUAL,
            "whole residual repays principal: nothing held back to keep MIN_LEFTOVER_DEBT"
        );
        assertEq(r.post.ledger.debt, DUST_DEBT_LEFT, "debt left 531.839002");
        assertGt(DUST_DEBT_LEFT, 0, "debt not cleared");
        assertLt(DUST_DEBT_LEFT, MIN_LEFTOVER_DEBT, "debt below MIN_LEFTOVER_DEBT");
        _assertLiquidationSplit(r, DUST_RESIDUAL, 0, 0);
        _assertResidualLedger(0, 0, LENDER_USDC);
        assertEq(r.post.ledger.collateral, DUST_COLLATERAL_LEFT, "collateral -= both seizes");
        assertEq(DUST_COLLATERAL_LEFT, BORROWER_COLLATERAL - PARTIAL_SEIZE - DUST_SEIZE, "collateral left derivation");
        assertEq(market.healthFactor(borrower), DUST_HF_AFTER, "HF from the reduced debt");
        assertEq(
            DUST_HF_AFTER,
            _healthFactor(r.post.ledger.collateral, r.post.ledger.debt, NAV_DUST),
            "R3 HF formula on the post state"
        );
    }

    /// @dev R3 previewLiquidation: a nominal repay leaving exactly MIN_LEFTOVER_DEBT is quoted, one unit more reverts
    ///      MustNotLeaveDust (collateral remains in both), and the chosen chunk is quoted at the R3 seize.
    function _assertNominalLeftoverBoundary(uint256 debt) private {
        (, uint256 d) = market.positions(borrower);
        assertEq(d, debt, "live debt before the boundary check");
        (uint256 repay, uint256 seize) = market.previewLiquidation(borrower, debt - MIN_LEFTOVER_DEBT);
        assertEq(repay, debt - MIN_LEFTOVER_DEBT, "nominal leftover == MIN_LEFTOVER_DEBT is quoted");
        assertEq(seize, expectedSeize(repay, NAV_DUST), "boundary seize");
        (uint256 coll,) = market.positions(borrower);
        assertLt(seize, coll, "boundary quote leaves collateral");
        vm.expectRevert(ISpecMiniLend.MustNotLeaveDust.selector);
        market.previewLiquidation(borrower, debt - MIN_LEFTOVER_DEBT + 1);
        (repay, seize) = market.previewLiquidation(borrower, DUST_CHUNK);
        assertEq(repay, DUST_CHUNK, "chunk quoted in full");
        assertEq(seize, DUST_SEIZE, "chunk seize quoted");
    }

    /// @dev R3 "Adapter y simulador omiten el settlement cuando el residual es cero" / R5 step 8, isolated by a state
    ///      snapshot: O4 crash to 85, explicit MM fixture spot 85, keeper liquidates 8500e6 through a second adapter
    ///      with keeperBps 10000. The whole surplus is bounty, residual 0: no settleLiquidationResidual call, no
    ///      ResidualApplied, MiniLend cash += nominal repay, borrower ledger moves only by repay and seize.
    function _zeroResidualSkipsSettlement() private {
        uint256 snap = vm.snapshotState();
        World memory baseline = captureWorld(borrower);
        LiquidationAdapter defaultAdapter = adapter;

        crashNavAndAssertNavOnly();
        _mmMoveSpot(CRASH_NAV);
        assertEq(market.healthFactor(borrower), HF_AFTER_CRASH, "HF <= 0.95: full close allowed");
        adapter = _deployFullBountyAdapter(); // base helpers now drive and decode the 10000 adapter
        _assertSpotAboveNavFloor("pre-sale spot above the NAV floor");

        vm.startStateDiffRecording();
        Liquidation memory r = liquidateViaAdapter(borrower, ZERO_RES_CHUNK, 0);
        Vm.AccountAccess[] memory calls = vm.stopAndReturnStateDiff();

        _assertSuccessPathAt(r, FULL_BOUNTY_KEEPER_BPS);
        _assertSale(r, ZERO_RES_CHUNK, ZERO_RES_SEIZE, ZERO_RES_PROCEEDS, ZERO_RES_BOUNTY, 0, 0);
        assertEq(r.seized, expectedSeize(r.repaid, CRASH_NAV), "R3 seize formula");
        assertEq(r.pre.bal.keeperUsdc, 0, "keeper liquidates from 0 USDC");
        assertEq(r.eventBounty, r.proceeds - r.repaid, "keeperBps 10000 within the LB cap: bounty == whole surplus");
        (, uint256 residualAtDefault) = expectedSplit(r.proceeds, r.repaid);
        assertEq(residualAtDefault, ZERO_RES_RESIDUAL_AT_DEFAULT, "the same sale at keeperBps 5000 leaves a residual");
        assertEq(r.post.pool.sqrtPriceX96, ZERO_RES_SQRT_AFTER, "post-sale sqrtPriceX96 (one exact-in step)");
        assertEq(r.post.pool.liquidity, L_UNSIGNED, "sale leaves L");
        _assertSpotAboveNavFloor("post-sale spot above the NAV floor");
        _assertNoSettlement(r, calls);
        assertAccountingIdentityAnyVersion();
        assertLedgerSums();

        assertTrue(vm.revertToState(snap), "fixture snapshot restored");
        assertEq(address(adapter), address(defaultAdapter), "fixture adapter restored");
        assertWorldUnchanged(baseline);
    }

    /// @dev Second LiquidationAdapter on the same PA, market and pool, identical to the fixture's except keeperBps
    ///      10000; the issuer grants it HOLDER|SWAP and allowedWrapper exactly like the fixture adapter.
    function _deployFullBountyAdapter() private returns (LiquidationAdapter a) {
        vm.startPrank(issuer);
        a = new LiquidationAdapter(
            PM,
            FACTORY,
            pa,
            IERC20(address(usdc)),
            IMiniLend(address(market)),
            HOOK,
            FEE,
            TICK_SPACING,
            FULL_BOUNTY_KEEPER_BPS
        );
        rwa.setFlags(address(a), rwa.HOLDER() | rwa.SWAP());
        pa.updateAllowedWrapper(address(a), true);
        vm.stopPrank();
        assertEq(a.keeperBps(), FULL_BOUNTY_KEEPER_BPS, "second adapter keeperBps == 10000");
        assertEq(a.lbBps(), LB_BPS, "second adapter lbBps");
        assertEq(address(a.market()), address(market), "second adapter market");
        assertEq(a.rwaIsCurrency0(), paIsCurrency0, "second adapter currency order");
        assertTrue(pa.allowedWrappers(address(a)), "second adapter is an allowed wrapper");
        assertEq(usdc.balanceOf(address(a)), 0, "second adapter starts with 0 USDC");
        assertEq(rwa.balanceOf(address(a)), 0, "second adapter starts with 0 RWA");
    }

    function _reopen(uint256 collateral, uint256 debt) private {
        vm.prank(issuer);
        rwa.mint(borrower, collateral);
        vm.startPrank(borrower);
        market.depositCollateral(collateral);
        market.borrow(debt);
        vm.stopPrank();
        (uint256 coll, uint256 d) = market.positions(borrower);
        assertEq(coll, collateral, "reopened collateral");
        assertEq(d, debt, "reopened debt");
    }

    /// @dev The existing guards still gate the reopened position: LTV (Unhealthy) and NAV freshness (StaleNav).
    function _assertReopenGuards() private {
        World memory pre = captureWorld(borrower);
        vm.prank(borrower);
        vm.expectRevert(ISpecMiniLend.Unhealthy.selector);
        market.borrow(REOPEN_CAPACITY + 1);
        assertWorldUnchanged(pre);

        vm.warp(market.navUpdatedAt() + NAV_STALENESS + 1);
        pre = captureWorld(borrower);
        vm.prank(borrower);
        vm.expectRevert(ISpecMiniLend.StaleNav.selector);
        market.borrow(REOPEN_DEBT);
        assertWorldUnchanged(pre);
        assertEq(specBadDebtOf(borrower), WRITEOFF_PENDING, "rejected borrows keep the prior write-off");

        _moveNavOnly(NAV_WRITEOFF); // oracle refresh at the same NAV
    }

    /// @dev Explicit R6 test fixture done by the MM (sole LP): spot moves, L and the lending market do not.
    function _mmMoveSpot(uint256 spotNav) private {
        World memory pre = captureWorld(borrower);
        uint160 target = sqrtPriceX96ForNav(spotNav);
        mmSwapToPrice(target, pre.bal.deskRwa);
        World memory post = captureWorld(borrower);
        assertEq(post.pool.sqrtPriceX96, target, "MM fixture: spot at target");
        assertEq(post.pool.liquidity, L_UNSIGNED, "MM fixture: L unchanged");
        assertEq(post.pool.deskLiquidity, L_UNSIGNED, "MM fixture: MM position unchanged");
        assertEq(post.ledger.nav, pre.ledger.nav, "MM fixture: NAV untouched");
        assertEq(post.ledger.debt, pre.ledger.debt, "MM fixture: debt untouched");
        assertEq(post.ledger.collateral, pre.ledger.collateral, "MM fixture: collateral untouched");
        assertEq(post.bal.marketUsdc, pre.bal.marketUsdc, "MM fixture: market cash untouched");
        assertEq(post.bal.keeperUsdc, 0, "keeper still holds no USDC");
    }

    /// @dev NAV-only oracle move by the issuer: exactly one NavUpdated(newNav, now); nothing else in the world moves.
    function _moveNavOnly(uint256 newNav) private {
        World memory pre = captureWorld(borrower);
        vm.recordLogs();
        setNavAsIssuer(newNav);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "NAV move emits exactly one log");
        assertEq(logs[0].emitter, address(market), "NAV log comes from MiniLend");
        assertEq(logs[0].topics[0], NAV_UPDATED_TOPIC, "NAV log is NavUpdated");
        assertEq(logs[0].data, abi.encode(newNav, block.timestamp), "NavUpdated(newNav, block.timestamp)");
        assertWorldUnchangedExceptNav(pre, borrower, newNav, block.timestamp);
    }

    /// @dev Anyone may pay a residual into MiniLend (R3 settleLiquidationResidual is permissionless and pulls from the
    ///      caller). Exact return values, event, pull and ledger deltas, re-derived from the R3 formula.
    function _thirdPartySettle(uint256 assets, uint256 expDebtRepaid, uint256 expRecovered, uint256 expCredit) private {
        vm.prank(issuer);
        usdc.mint(recoveryPayer, assets);
        vm.prank(recoveryPayer);
        usdc.approve(address(market), assets);
        World memory pre = captureWorld(borrower);
        (uint256 fd, uint256 fw, uint256 fc) = _r3Split(assets, pre.ledger.debt, pre.ledger.badDebtOf);
        assertEq(fd, expDebtRepaid, "R3 formula: debtRepaid");
        assertEq(fw, expRecovered, "R3 formula: badDebtRecovered");
        assertEq(fc, expCredit, "R3 formula: borrowerCredit");

        vm.expectEmit(true, false, false, true, address(market));
        emit ISpecMiniLend.ResidualApplied(borrower, expDebtRepaid, expRecovered, expCredit);
        vm.prank(recoveryPayer);
        (uint256 d, uint256 w, uint256 c) = specMarket().settleLiquidationResidual(borrower, assets);
        assertEq(d, expDebtRepaid, "settle returns debtRepaid");
        assertEq(w, expRecovered, "settle returns badDebtRecovered");
        assertEq(c, expCredit, "settle returns borrowerCredit");
        _assertSettleDeltas(pre, assets, expDebtRepaid, expRecovered, expCredit);
    }

    function _assertSettleDeltas(World memory pre, uint256 assets, uint256 dRepaid, uint256 recovered, uint256 credit)
        private
        view
    {
        World memory post = captureWorld(borrower);
        assertEq(usdc.balanceOf(recoveryPayer), 0, "settle pulls exactly assets from the caller");
        assertEq(usdc.allowance(recoveryPayer, address(market)), 0, "settle consumes exactly the approved assets");
        assertEq(post.bal.marketUsdc, pre.bal.marketUsdc + assets, "market USDC += assets");
        assertEq(post.bal.borrowerUsdc, pre.bal.borrowerUsdc, "settlement pushes nothing to the borrower");
        assertEq(post.ledger.debt, pre.ledger.debt - dRepaid, "debt -= debtRepaid");
        assertEq(post.ledger.totalDebt, pre.ledger.totalDebt - dRepaid, "totalDebt -= debtRepaid");
        assertEq(post.ledger.badDebtOf, pre.ledger.badDebtOf - recovered, "badDebtOf -= badDebtRecovered");
        assertEq(post.ledger.totalBadDebt, pre.ledger.totalBadDebt - recovered, "totalBadDebt -= badDebtRecovered");
        assertEq(
            post.ledger.totalSupplyAssets, pre.ledger.totalSupplyAssets + recovered, "totalSupplyAssets += recovered"
        );
        assertEq(post.ledger.totalSupplyShares, pre.ledger.totalSupplyShares, "settlement mints no shares");
        assertEq(post.ledger.claimableResidual, pre.ledger.claimableResidual + credit, "claimableResidual += credit");
        assertEq(
            post.ledger.totalResidualClaims, pre.ledger.totalResidualClaims + credit, "totalResidualClaims += credit"
        );
        assertEq(post.ledger.collateral, pre.ledger.collateral, "settlement leaves collateral");
        assertEq(post.ledger.nav, pre.ledger.nav, "settlement leaves NAV");
    }

    // ================================================================== lenders
    function _supplyAs(address who, uint256 assets, uint256 ts, uint256 ta) private returns (uint256 shares) {
        assertEq(market.totalSupplyShares(), ts, "tracked totalSupplyShares");
        assertEq(market.totalSupplyAssets(), ta, "tracked totalSupplyAssets");
        vm.prank(issuer);
        usdc.mint(who, assets);
        vm.startPrank(who);
        usdc.approve(address(market), assets);
        shares = market.supply(assets);
        vm.stopPrank();
        assertEq(shares, Math.mulDiv(assets, ts + VIRTUAL_SHARES, ta + VIRTUAL_ASSETS), "R3 supply shares (round down)");
        assertEq(market.supplyShares(who), shares, "lender shares recorded");
        assertEq(usdc.balanceOf(who), 0, "supply pulls exactly assets");
        assertAccountingIdentityAnyVersion(); // strict once R3 exists: the getter's value is used
    }

    function _withdrawAllAs(address who, uint256 ts, uint256 ta) private returns (uint256 assets) {
        assertEq(market.totalSupplyShares(), ts, "tracked totalSupplyShares");
        assertEq(market.totalSupplyAssets(), ta, "tracked totalSupplyAssets");
        uint256 shares = market.supplyShares(who);
        uint256 cashBefore = usdc.balanceOf(who);
        vm.prank(who);
        assets = market.withdraw(shares);
        assertEq(assets, _assetsFor(shares, ts, ta), "R3 withdraw assets (round down)");
        assertEq(usdc.balanceOf(who), cashBefore + assets, "lender receives exactly assets");
        assertEq(market.supplyShares(who), 0, "all shares burned");
        assertAccountingIdentityAnyVersion(); // strict once R3 exists: the getter's value is used
    }

    /// @dev Everything the later recovery added went to the shares outstanding at that moment (the lender who stayed
    ///      and the one who entered after the loss), to the unit; the market ends with only the virtual-asset dust.
    function _assertCurrentSharesTookRecovery(
        uint256 stayShares,
        uint256 lateShares,
        uint256 stayBefore,
        uint256 lateBefore,
        uint256 ts,
        uint256 ta
    ) private {
        uint256 stayOut = _withdrawAllAs(lenderStays, ts, ta);
        assertEq(stayOut, STAYS_OUT, "lender who stayed");
        (ts, ta) = (ts - stayShares, ta - stayOut);
        uint256 lateOut = _withdrawAllAs(lenderLate, ts, ta);
        assertEq(lateOut, LATE_OUT, "lender who entered after the loss");
        (ts, ta) = (ts - lateShares, ta - lateOut);

        assertGt(stayOut, stayBefore, "recovery raised the value of the shares that stayed");
        assertGt(lateOut, lateBefore, "recovery raised the value of the shares bought after the loss");
        assertEq((stayOut - stayBefore) + (lateOut - lateBefore), WRITEOFF_PENDING, "current shares took all of it");
        assertGt(lateOut, LATE_SUPPLY, "no cohort history: the late lender profits from the recovery");
        assertEq(market.totalSupplyShares(), 0, "every share redeemed");
        assertEq(market.totalSupplyAssets(), ta, "tracked leftover");
        assertEq(ta, VIRTUAL_ASSETS, "only the virtual-asset rounding dust remains");
        assertEq(usdc.balanceOf(address(market)), ta, "cash == leftover assets");
        assertAccountingIdentity();
    }

    // ================================================================== residual checks
    /// @dev The residual reached MiniLend (never the borrower) and ResidualApplied splits it exactly as the R3 formula
    ///      on the post-`market.liquidate` state; the repayment is not reported a second time as Repaid.
    function _assertLiquidationSplit(
        Liquidation memory r,
        uint256 expDebtRepaid,
        uint256 expRecovered,
        uint256 expCredit
    ) private view {
        (uint256 d, uint256 w, uint256 c) = assertResidualSettledInMarket(r);
        assertEq(d, expDebtRepaid, "ResidualApplied.debtRepaid");
        assertEq(w, expRecovered, "ResidualApplied.badDebtRecovered");
        assertEq(c, expCredit, "ResidualApplied.borrowerCredit");
        uint256 liveAfterLiquidate = r.pre.ledger.debt - r.repaid - r.marketBadDebt;
        uint256 pendingAfterLiquidate = r.pre.ledger.badDebtOf + r.marketBadDebt;
        (uint256 fd, uint256 fw, uint256 fc) = _r3Split(r.residual, liveAfterLiquidate, pendingAfterLiquidate);
        assertEq(fd, d, "R3 formula: debtRepaid = min(residual, live debt)");
        assertEq(fw, w, "R3 formula: badDebtRecovered = min(rest, pending write-off)");
        assertEq(fc, c, "R3 formula: borrowerCredit = what is left");
        assertEq(
            _countMarketLogs(r.logs, REPAID_TOPIC), 0, "residual repayment is ResidualApplied, not a second Repaid"
        );
        assertEq(_countMarketLogs(r.logs, RESIDUAL_CLAIMED_TOPIC), 0, "a liquidation pays no claim");
    }

    /// @dev R3 ledger for the single-borrower fixture, plus the no-donation identities.
    function _assertResidualLedger(uint256 pending, uint256 credit, uint256 supplyAssets) private view {
        assertEq(specBadDebtOf(borrower), pending, "badDebtOf == write-off not yet recovered");
        assertEq(market.totalBadDebt(), pending, "totalBadDebt == net unrecovered loss");
        assertEq(specClaimableResidual(borrower), credit, "claimableResidual(borrower)");
        assertEq(specTotalResidualClaims(), credit, "totalResidualClaims");
        assertEq(market.totalSupplyAssets(), supplyAssets, "totalSupplyAssets");
        assertAccountingIdentity();
        assertLedgerSums();
        assertBadDebtSum();
    }

    /// @dev Nothing is claimable: claimResidual reverts ZeroAmount and moves nothing.
    function _assertBorrowerCannotClaim() private {
        World memory pre = captureWorld(borrower);
        vm.prank(borrower);
        vm.expectRevert(ISpecMiniLend.ZeroAmount.selector);
        specMarket().claimResidual();
        assertWorldUnchanged(pre);
    }

    /// @dev R3: settleLiquidationResidual rejects 0 with ZeroAmount at every ledger stage, from a payer that could pay
    ///      (funded, approved), and moves nothing.
    function _assertZeroSettleRejected() private {
        vm.prank(issuer);
        usdc.mint(zeroPayer, 1);
        vm.prank(zeroPayer);
        usdc.approve(address(market), 1);
        World memory pre = captureWorld(borrower);
        uint256 payerBefore = usdc.balanceOf(zeroPayer);

        vm.prank(zeroPayer);
        vm.expectRevert(ISpecMiniLend.ZeroAmount.selector);
        specMarket().settleLiquidationResidual(borrower, 0);

        assertWorldUnchanged(pre);
        assertEq(usdc.balanceOf(zeroPayer), payerBefore, "rejected settle pulls nothing");
        assertEq(usdc.allowance(zeroPayer, address(market)), 1, "rejected settle spends no allowance");
    }

    /// @dev residual == 0: MiniLend receives exactly the nominal repay, nothing reaches or is credited to the borrower,
    ///      and the ledger moves only by repay and seize (no write-off, recovery, claim; NAV and shares untouched).
    ///      The call trace proves the adapter made no settlement call (not even a zero or reverted one).
    function _assertNoSettlement(Liquidation memory r, Vm.AccountAccess[] memory calls) private view {
        assertResidualSettledInMarket(r); // market USDC += repaid + 0, borrower USDC unchanged, no ResidualApplied
        assertEq(_countMarketCalls(calls, ISpecMiniLend.liquidate.selector), 1, "trace holds the adapter's liquidate");
        assertEq(
            _countMarketCalls(calls, ISpecMiniLend.settleLiquidationResidual.selector),
            0,
            "residual 0: the adapter never calls settleLiquidationResidual"
        );
        assertEq(_countMarketLogs(r.logs, RESIDUAL_APPLIED_TOPIC), 0, "residual 0: no ResidualApplied");
        assertEq(_countMarketLogs(r.logs, REPAID_TOPIC), 0, "liquidation emits no Repaid");
        Ledger memory a = r.pre.ledger;
        Ledger memory b = r.post.ledger;
        assertEq(r.marketBadDebt, 0, "no write-off");
        assertEq(b.debt + r.repaid, a.debt, "debt -= nominal repay only");
        assertEq(b.debt, ZERO_RES_DEBT_LEFT, "debt left 66500e6");
        assertEq(b.totalDebt + r.repaid, a.totalDebt, "totalDebt -= nominal repay only");
        assertEq(b.totalBadDebt, a.totalBadDebt, "totalBadDebt unchanged");
        assertEq(b.totalSupplyAssets, a.totalSupplyAssets, "totalSupplyAssets unchanged");
        assertEq(b.totalSupplyShares, a.totalSupplyShares, "totalSupplyShares unchanged");
        assertEq(b.nav, a.nav, "liquidation leaves NAV");
        assertEq(b.navUpdatedAt, a.navUpdatedAt, "liquidation leaves navUpdatedAt");
        assertEq(b.specLedger, a.specLedger, "R3 getters availability stable");
        assertEq(b.badDebtOf, a.badDebtOf, "badDebtOf unchanged");
        assertEq(b.claimableResidual, a.claimableResidual, "no borrower credit");
        assertEq(b.totalResidualClaims, a.totalResidualClaims, "totalResidualClaims unchanged");
        assertEq(b.liquidationBlocked, a.liquidationBlocked, "liquidationBlocked unchanged");
    }

    /// @dev assertLiquidationSuccessPath for an adapter whose keeperBps is not the fixture's (the base recomputes R4 at
    ///      KEEPER_BPS 5000): same event, inventory, exact-wrap and hook-swap checks, R4 split at `keeperBps`.
    function _assertSuccessPathAt(Liquidation memory r, uint256 keeperBps) private view {
        assertEq(r.adapterEvents, 1, "exactly one adapter Liquidated");
        assertEq(r.marketEvents, 1, "exactly one MiniLend Liquidated");
        assertEq(r.bounty, r.eventBounty, "returned bounty == event bounty");
        assertEq(r.marketLiquidator, address(adapter), "market liquidator == adapter");
        assertEq(r.marketRepaid, r.repaid, "market repaid == adapter repaid");
        assertEq(r.marketSeized, r.seized, "market seized == adapter seized");
        assertGt(r.seized, 0, "seized > 0");
        _assertInventoryAndWrap(r);
        _assertHookSale(r);
        _assertSplitAt(r, keeperBps);
    }

    function _assertInventoryAndWrap(Liquidation memory r) private pure {
        Balances memory a = r.pre.bal;
        Balances memory b = r.post.bal;
        assertEq(b.keeperRwa, 0, "keeper never holds RWA");
        assertEq(b.pmRwa, 0, "PoolManager never holds raw RWA");
        assertEq(b.adapterRwa, a.adapterRwa, "adapter RWA flow delta == 0");
        assertEq(b.adapterUsdc, a.adapterUsdc, "adapter USDC flow delta == 0");
        assertEq(b.adapterClaimsPa, 0, "adapter holds no vRWA 6909 claim");
        assertEq(b.adapterClaimsUsdc, 0, "adapter holds no USDC 6909 claim");
        assertEq(b.pmPa, b.paSupply, "PA.balanceOf(PM) == PA.totalSupply");
        assertGe(b.paRwa, b.paSupply + VERIFICATION_DEPOSIT, "RWA backing >= wrapped supply + verification deposit");
        assertEq(b.borrowerRwa, a.borrowerRwa, "no RWA sent to the borrower");
        assertEq(b.rwaSupply, a.rwaSupply, "no RWA minted or burned");
        assertEq(b.usdcSupply, a.usdcSupply, "no USDC minted or burned");
        assertEq(b.paSupply, a.paSupply + r.seized, "wrap == seize");
        assertEq(b.paRwa, a.paRwa + r.seized, "PA backing += seize");
        assertEq(b.pmPa, a.pmPa + r.seized, "PM vRWA += seize");
        assertEq(b.marketRwa + r.seized, a.marketRwa, "market RWA -= seize");
        assertEq(r.post.ledger.collateral + r.seized, r.pre.ledger.collateral, "collateral -= seize");
        assertEq(r.post.ledger.totalCollateral + r.seized, r.pre.ledger.totalCollateral, "totalCollateral -= seize");
    }

    function _assertHookSale(Liquidation memory r) private view {
        assertEq(r.hookSwaps, 1, "exactly one Swap emitted by the Labs hook");
        assertEq(r.hookPoolId, PoolId.unwrap(poolId), "hook Swap on the fixed pool");
        assertEq(r.hookSender, address(adapter), "hook Swap sender == adapter");
        (int128 paLeg, int128 usdcLeg) = paIsCurrency0 ? (r.hookAmount0, r.hookAmount1) : (r.hookAmount1, r.hookAmount0);
        assertEq(int256(paLeg), -int256(r.seized), "sold == seize (exact-in vRWA)");
        assertEq(int256(usdcLeg), int256(r.proceeds), "hook USDC leg == proceeds");
        assertEq(r.post.bal.pmUsdc + r.proceeds, r.pre.bal.pmUsdc, "PM USDC out == proceeds");
    }

    /// @dev R4 recomputed independently: bounty = min(floor(surplus*keeperBps/B), floor(repaid*lb/B)).
    function _assertSplitAt(Liquidation memory r, uint256 keeperBps) private pure {
        assertGe(r.proceeds, r.repaid, "proceeds cover the repay");
        uint256 surplus = r.proceeds - r.repaid;
        uint256 bounty = Math.min(surplus * keeperBps / BPS, r.repaid * LB_BPS / BPS);
        assertEq(r.eventBounty, bounty, "bounty == R4 split at the adapter's keeperBps");
        assertEq(r.residual, surplus - bounty, "residual == R4 split at the adapter's keeperBps");
        assertEq(r.proceeds, r.repaid + r.eventBounty + r.residual, "proceeds == repaid + bounty + residual");
        assertEq(r.post.bal.keeperUsdc, r.pre.bal.keeperUsdc + r.eventBounty, "keeper USDC += bounty");
    }

    /// @dev Pool math and R4 split pinned for this fixture; identical before and after the residual fix.
    function _assertSale(
        Liquidation memory r,
        uint256 repaid,
        uint256 seized,
        uint256 proceeds,
        uint256 bounty,
        uint256 residual,
        uint256 badDebt
    ) private pure {
        assertEq(r.repaid, repaid, "repaid");
        assertEq(r.seized, seized, "seized");
        assertEq(r.proceeds, proceeds, "proceeds (real v4 exact-in)");
        assertEq(r.eventBounty, bounty, "bounty");
        assertEq(r.residual, residual, "residual");
        assertEq(r.marketBadDebt, badDebt, "gross write-off in MiniLend Liquidated");
    }

    /// @dev R5 table, PA currency0 rejects current <= limit, PA currency1 rejects current >= limit.
    function _assertSpotAboveNavFloor(string memory what) private view {
        uint256 limit = navFloorLimitSqrtPriceX96(market.nav(), paIsCurrency0);
        uint256 spot = uint256(spotSqrtPriceX96());
        if (paIsCurrency0) assertGt(spot, limit, what);
        else assertLt(spot, limit, what);
    }

    // ================================================================== independent spec math
    function _r3Split(uint256 assets, uint256 liveDebt, uint256 pending)
        private
        pure
        returns (uint256 debtRepaid, uint256 badDebtRecovered, uint256 borrowerCredit)
    {
        debtRepaid = Math.min(assets, liveDebt);
        badDebtRecovered = Math.min(assets - debtRepaid, pending);
        borrowerCredit = assets - debtRepaid - badDebtRecovered;
    }

    function _assetsFor(uint256 shares, uint256 ts, uint256 ta) private pure returns (uint256) {
        return Math.mulDiv(shares, ta + VIRTUAL_ASSETS, ts + VIRTUAL_SHARES);
    }

    function _healthFactor(uint256 collateral, uint256 debt, uint256 navWad) private pure returns (uint256) {
        uint256 adjusted = Math.mulDiv(collateral, navWad * LT_BPS, PRICE_SCALE * BPS);
        return Math.mulDiv(adjusted, 1e18, debt);
    }

    function _countMarketLogs(Vm.Log[] memory logs, bytes32 topic) private view returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(market) && logs[i].topics.length != 0 && logs[i].topics[0] == topic) n++;
        }
    }

    /// @dev CALLs into MiniLend with `selector`, reverted or not (a caught zero settlement still counts).
    function _countMarketCalls(Vm.AccountAccess[] memory calls, bytes4 selector) private view returns (uint256 n) {
        for (uint256 i; i < calls.length; i++) {
            Vm.AccountAccess memory c = calls[i];
            if (c.kind != VmSafe.AccountAccessKind.Call || c.account != address(market) || c.data.length < 4) continue;
            if (bytes4(c.data) == selector) n++;
        }
    }
}
