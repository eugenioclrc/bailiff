// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ISpecMiniLend, ISpecLiquidationAdapter} from "./SpecInterfaces.sol";
import {FinalSpecFixture} from "./FinalSpecFixture.sol";

/// @notice Base every Bailiff acceptance test inherits: the pinned three-role fixture (FinalSpecFixture) plus the
///         checks TRACEABILITY asks of every success and failure: exact state snapshots, the keeper liquidation
///         helper, the success-path check, the NAV-only crash, residual destination and the R3 accounting identity.
abstract contract FinalSpecBase is FinalSpecFixture {
    using StateLibrary for IPoolManager;

    bytes32 internal constant HOOK_SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant ADAPTER_LIQUIDATED_TOPIC =
        keccak256("Liquidated(address,address,uint256,uint256,uint256,uint256,uint256)");
    bytes32 internal constant MARKET_LIQUIDATED_TOPIC =
        keccak256("Liquidated(address,address,uint256,uint256,uint256)");
    bytes32 internal constant RESIDUAL_APPLIED_TOPIC = keccak256("ResidualApplied(address,uint256,uint256,uint256)");
    bytes32 internal constant NAV_UPDATED_TOPIC = keccak256("NavUpdated(uint256,uint256)");

    struct Balances {
        uint256 keeperUsdc;
        uint256 keeperRwa;
        uint256 borrowerUsdc;
        uint256 borrowerRwa;
        uint256 marketUsdc;
        uint256 marketRwa;
        uint256 adapterUsdc;
        uint256 adapterRwa;
        uint256 adapterClaimsPa; // ERC-6909 claims of the adapter inside PM
        uint256 adapterClaimsUsdc;
        uint256 pmUsdc;
        uint256 pmRwa; // raw RWA held by PM (must stay 0)
        uint256 pmPa; // vRWA held by PM
        uint256 paRwa; // raw RWA backing inside the PA
        uint256 paSupply; // vRWA total supply
        uint256 deskUsdc;
        uint256 deskRwa;
        uint256 issuerUsdc;
        uint256 issuerRwa;
        uint256 mmUsdc;
        uint256 mmRwa;
        uint256 lenderUsdc;
        uint256 rwaSupply; // catches any mint/burn of the RWA
        uint256 usdcSupply; // catches any mint/burn of the USDC
    }

    struct Ledger {
        uint256 collateral;
        uint256 debt;
        uint256 totalCollateral;
        uint256 totalDebt;
        uint256 totalSupplyAssets;
        uint256 totalSupplyShares;
        uint256 totalBadDebt;
        uint256 nav;
        uint256 navUpdatedAt;
        bool specLedger; // true when all R3 residual getters answer
        uint256 badDebtOf;
        uint256 claimableResidual;
        uint256 totalResidualClaims;
        bool liquidationBlocked;
    }

    struct PoolState {
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        uint128 deskLiquidity;
    }

    struct World {
        Balances bal;
        Ledger ledger;
        PoolState pool;
    }

    struct Liquidation {
        address who;
        uint256 bounty; // return value of adapter.liquidate
        uint256 adapterEvents;
        uint256 repaid;
        uint256 seized;
        uint256 proceeds;
        uint256 eventBounty;
        uint256 residual;
        uint256 marketEvents;
        address marketLiquidator;
        uint256 marketRepaid;
        uint256 marketSeized;
        uint256 marketBadDebt;
        uint256 hookSwaps; // Swap events emitted by the HOOK address (PM emits the same signature)
        bytes32 hookPoolId;
        address hookSender;
        int128 hookAmount0;
        int128 hookAmount1;
        World pre;
        World post;
        Vm.Log[] logs;
    }

    /// @notice MiniLend ResidualApplied of one liquidation; all zero when none was emitted (e.g. the snapshot).
    struct ResidualSplit {
        uint256 events;
        uint256 debtRepaid;
        uint256 badDebtRecovered;
        uint256 borrowerCredit;
        uint256 settled; // debtRepaid + badDebtRecovered + borrowerCredit
    }

    // ================================================================== keeper liquidation
    /// @notice The keeper calls the adapter once; everything is snapshotted around the call and the logs decoded.
    /// @dev Consumes vm.recordLogs(); the raw logs are kept in r.logs.
    function liquidateViaAdapter(address who, uint256 repayAssets, uint256 minBounty)
        internal
        returns (Liquidation memory r)
    {
        r.who = who;
        r.pre = captureWorld(who);
        vm.recordLogs();
        vm.prank(keeper);
        r.bounty = adapter.liquidate(who, repayAssets, minBounty);
        r.logs = vm.getRecordedLogs();
        r.post = captureWorld(who);
        _decodeLiquidationLogs(r);
    }

    /// @notice Fixture borrower, close factor decides, no bounty floor.
    function liquidateViaAdapter() internal returns (Liquidation memory) {
        return liquidateViaAdapter(borrower, type(uint256).max, 0);
    }

    function _decodeLiquidationLogs(Liquidation memory r) private view {
        for (uint256 i; i < r.logs.length; i++) {
            Vm.Log memory lg = r.logs[i];
            if (lg.topics.length == 0) continue;
            if (lg.emitter == address(adapter) && lg.topics[0] == ADAPTER_LIQUIDATED_TOPIC) {
                r.adapterEvents++;
                assertEq(lg.topics[1], bytes32(uint256(uint160(r.who))), "adapter event borrower");
                assertEq(lg.topics[2], bytes32(uint256(uint160(keeper))), "adapter event keeper");
                (r.repaid, r.seized, r.proceeds, r.eventBounty, r.residual) =
                    abi.decode(lg.data, (uint256, uint256, uint256, uint256, uint256));
            } else if (lg.emitter == address(market) && lg.topics[0] == MARKET_LIQUIDATED_TOPIC) {
                r.marketEvents++;
                r.marketLiquidator = address(uint160(uint256(lg.topics[1])));
                assertEq(lg.topics[2], bytes32(uint256(uint160(r.who))), "market event borrower");
                (r.marketRepaid, r.marketSeized, r.marketBadDebt) = abi.decode(lg.data, (uint256, uint256, uint256));
            } else if (lg.emitter == address(HOOK) && lg.topics[0] == HOOK_SWAP_TOPIC) {
                r.hookSwaps++;
                r.hookPoolId = lg.topics[1];
                r.hookSender = address(uint160(uint256(lg.topics[2])));
                (r.hookAmount0, r.hookAmount1,,,,) =
                    abi.decode(lg.data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
    }

    // ================================================================== success-path check (TRACEABILITY)
    /// @notice Every successful sale: keeperRWA=0, PM raw RWA=0, adapter flow deltas=0, no adapter 6909 claims,
    ///         PA.balanceOf(PM)=PA.totalSupply, backing>=wrapped supply+deposit, exact wrap of the seize, sold=seize
    ///         on the hook's own Swap, and the exact proceeds distribution and ledger deltas. Holds before and after
    ///         the residual fix: whatever part of the residual MiniLend settles is read from its ResidualApplied and
    ///         everything else must have reached the borrower. Requiring the whole residual in MiniLend is
    ///         assertResidualSettledInMarket's job.
    function assertLiquidationSuccessPath(Liquidation memory r) internal view {
        _assertLiquidationEvents(r);
        _assertInventoryCompliance(r);
        _assertExactWrap(r);
        _assertHookSwap(r);
        _assertProceedsDistribution(r);
    }

    function _assertLiquidationEvents(Liquidation memory r) private view {
        assertEq(r.adapterEvents, 1, "exactly one adapter Liquidated");
        assertEq(r.marketEvents, 1, "exactly one MiniLend Liquidated");
        assertEq(r.bounty, r.eventBounty, "returned bounty == event bounty");
        assertEq(r.marketLiquidator, address(adapter), "market liquidator == adapter");
        assertEq(r.marketRepaid, r.repaid, "market repaid == adapter repaid");
        assertEq(r.marketSeized, r.seized, "market seized == adapter seized");
        assertGt(r.seized, 0, "seized > 0");
    }

    function _assertInventoryCompliance(Liquidation memory r) private pure {
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
    }

    function _assertExactWrap(Liquidation memory r) private pure {
        assertEq(_up(r.pre.bal.paSupply, r.post.bal.paSupply, "vRWA supply"), r.seized, "wrap == seize");
        assertEq(_up(r.pre.bal.paRwa, r.post.bal.paRwa, "PA backing"), r.seized, "PA backing += seize");
        assertEq(_up(r.pre.bal.pmPa, r.post.bal.pmPa, "PM vRWA"), r.seized, "PM vRWA += seize");
        assertEq(_down(r.pre.bal.marketRwa, r.post.bal.marketRwa, "market RWA"), r.seized, "market RWA -= seize");
        assertEq(
            _down(r.pre.ledger.collateral, r.post.ledger.collateral, "collateral"), r.seized, "collateral -= seize"
        );
        assertEq(
            _down(r.pre.ledger.totalCollateral, r.post.ledger.totalCollateral, "totalCollateral"),
            r.seized,
            "totalCollateral -= seize"
        );
    }

    function _assertHookSwap(Liquidation memory r) private view {
        assertEq(r.hookSwaps, 1, "exactly one Swap emitted by the Labs hook");
        assertEq(r.hookPoolId, PoolId.unwrap(poolId), "hook Swap on the fixed pool");
        assertEq(r.hookSender, address(adapter), "hook Swap sender == adapter");
        (int128 paLeg, int128 usdcLeg) = paIsCurrency0 ? (r.hookAmount0, r.hookAmount1) : (r.hookAmount1, r.hookAmount0);
        assertEq(int256(paLeg), -int256(r.seized), "sold == seize (exact-in vRWA)");
        assertEq(int256(usdcLeg), int256(r.proceeds), "hook USDC leg == proceeds");
    }

    function _assertProceedsDistribution(Liquidation memory r) private view {
        _assertProceedsSplit(r);
        ResidualSplit memory s = residualSplitOf(r);
        _assertUsdcDestinations(r, s);
        _assertLedgerDeltas(r, s);
    }

    /// @dev R4 split recomputed independently from the hook's proceeds and the market's repaid.
    function _assertProceedsSplit(Liquidation memory r) private pure {
        Balances memory a = r.pre.bal;
        Balances memory b = r.post.bal;
        assertEq(_down(a.pmUsdc, b.pmUsdc, "PM USDC"), r.proceeds, "PM USDC out == proceeds");
        assertEq(r.proceeds, r.repaid + r.eventBounty + r.residual, "proceeds == repaid + bounty + residual");
        (uint256 bounty, uint256 residual) = expectedSplit(r.proceeds, r.repaid);
        assertEq(r.eventBounty, bounty, "bounty == R4 split");
        assertEq(r.residual, residual, "residual == R4 split");
        assertEq(_up(a.keeperUsdc, b.keeperUsdc, "keeper USDC"), r.eventBounty, "keeper USDC += bounty");
    }

    /// @dev Exact in both versions: MiniLend receives repaid + the residual it settled (0 on the snapshot), the
    ///      borrower receives exactly the rest of the residual (0 once R5 step 8 is implemented).
    function _assertUsdcDestinations(Liquidation memory r, ResidualSplit memory s) private pure {
        assertLe(s.events, 1, "at most one ResidualApplied per liquidation");
        assertLe(s.settled, r.residual, "MiniLend settles at most the residual");
        assertEq(_up(r.pre.bal.marketUsdc, r.post.bal.marketUsdc, "market USDC"), r.repaid + s.settled, "market USDC");
        assertEq(
            _up(r.pre.bal.borrowerUsdc, r.post.bal.borrowerUsdc, "borrower USDC"),
            r.residual - s.settled,
            "borrower USDC == residual not settled in MiniLend"
        );
    }

    /// @dev R3 ledger deltas, exact: debt falls by repaid + gross write-off + residual applied to live debt; the
    ///      write-off leaves lenders and joins totalBadDebt, the recovered part comes back; shares and NAV untouched.
    function _assertLedgerDeltas(Liquidation memory r, ResidualSplit memory s) private pure {
        Ledger memory a = r.pre.ledger;
        Ledger memory b = r.post.ledger;
        uint256 debtDrop = _down(a.debt, b.debt, "debt");
        assertEq(debtDrop, r.repaid + r.marketBadDebt + s.debtRepaid, "debt drop == repaid + write-off + debtRepaid");
        assertEq(_down(a.totalDebt, b.totalDebt, "totalDebt"), debtDrop, "totalDebt tracks debt");
        assertEq(b.totalBadDebt + s.badDebtRecovered, a.totalBadDebt + r.marketBadDebt, "totalBadDebt delta");
        assertEq(b.totalSupplyAssets + r.marketBadDebt, a.totalSupplyAssets + s.badDebtRecovered, "supply delta");
        assertEq(b.totalSupplyShares, a.totalSupplyShares, "liquidation mints/burns no shares");
        assertEq(b.nav, a.nav, "liquidation leaves NAV");
        assertEq(b.navUpdatedAt, a.navUpdatedAt, "liquidation leaves navUpdatedAt");
        assertEq(b.specLedger, a.specLedger, "R3 getters availability stable");
        if (!b.specLedger) {
            // snapshot: no residual ledger exists, so nothing can have been settled into it
            assertEq(s.events, 0, "ResidualApplied without the R3 ledger");
            return;
        }
        assertEq(b.badDebtOf + s.badDebtRecovered, a.badDebtOf + r.marketBadDebt, "badDebtOf delta");
        assertEq(b.claimableResidual, a.claimableResidual + s.borrowerCredit, "claimableResidual += borrowerCredit");
        assertEq(b.totalResidualClaims, a.totalResidualClaims + s.borrowerCredit, "totalResidualClaims += credit");
    }

    /// @notice R5 step 8 / R3: the whole residual goes to MiniLend settlement, never straight to the borrower.
    /// @return debtRepaid badDebtRecovered borrowerCredit from the single ResidualApplied (zeros if residual == 0)
    function assertResidualSettledInMarket(Liquidation memory r)
        internal
        view
        returns (uint256 debtRepaid, uint256 badDebtRecovered, uint256 borrowerCredit)
    {
        assertEq(
            _up(r.pre.bal.marketUsdc, r.post.bal.marketUsdc, "market USDC"),
            r.repaid + r.residual,
            "market USDC += repaid + residual"
        );
        assertEq(r.post.bal.borrowerUsdc, r.pre.bal.borrowerUsdc, "borrower receives no USDC from the liquidation");
        uint256 n;
        (n, debtRepaid, badDebtRecovered, borrowerCredit) = residualAppliedOf(r);
        assertEq(n, r.residual == 0 ? 0 : 1, "one ResidualApplied iff residual > 0");
        assertEq(debtRepaid + badDebtRecovered + borrowerCredit, r.residual, "ResidualApplied splits the residual");
    }

    function residualAppliedOf(Liquidation memory r)
        internal
        view
        returns (uint256 n, uint256 debtRepaid, uint256 badDebtRecovered, uint256 borrowerCredit)
    {
        for (uint256 i; i < r.logs.length; i++) {
            Vm.Log memory lg = r.logs[i];
            if (lg.emitter != address(market) || lg.topics.length == 0 || lg.topics[0] != RESIDUAL_APPLIED_TOPIC) {
                continue;
            }
            n++;
            assertEq(lg.topics[1], bytes32(uint256(uint160(r.who))), "ResidualApplied borrower");
            (debtRepaid, badDebtRecovered, borrowerCredit) = abi.decode(lg.data, (uint256, uint256, uint256));
        }
    }

    function residualSplitOf(Liquidation memory r) internal view returns (ResidualSplit memory s) {
        (s.events, s.debtRepaid, s.badDebtRecovered, s.borrowerCredit) = residualAppliedOf(r);
        s.settled = s.debtRepaid + s.badDebtRecovered + s.borrowerCredit;
    }

    // ================================================================== NAV-only crash (O4, TRACEABILITY)
    /// @notice O4 Crash plus its proof: the only log is MiniLend NavUpdated(85e18, block.timestamp); nav and
    ///         navUpdatedAt are the only state that moves (balances, supplies, ledger, slot0, L, MM position equal).
    /// @dev Warp before calling it if the test needs navUpdatedAt to differ from the fixture's deploy time.
    function crashNavAndAssertNavOnly() internal {
        World memory pre = captureWorld(borrower);
        vm.recordLogs();
        crashNav();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "Crash emits exactly one log");
        assertEq(logs[0].emitter, address(market), "Crash log comes from MiniLend");
        assertEq(logs[0].topics.length, 1, "NavUpdated has no indexed fields");
        assertEq(logs[0].topics[0], NAV_UPDATED_TOPIC, "Crash log is NavUpdated");
        assertEq(logs[0].data, abi.encode(CRASH_NAV, block.timestamp), "NavUpdated(85e18, block.timestamp)");
        assertWorldUnchangedExceptNav(pre, borrower, CRASH_NAV, block.timestamp);
    }

    // ================================================================== accounting identity (R3, TRACEABILITY)
    /// @notice No-donation fixture: USDC.balanceOf(market) + totalDebt == totalSupplyAssets + totalResidualClaims.
    /// @dev Strict: fails with a named message while MiniLend lacks totalResidualClaims (RED on the snapshot).
    function assertAccountingIdentity() internal view {
        uint256 claims = specTotalResidualClaims();
        assertEq(
            usdc.balanceOf(address(market)) + market.totalDebt(),
            market.totalSupplyAssets() + claims,
            "cash + totalDebt == totalSupplyAssets + totalResidualClaims"
        );
    }

    /// @notice Same identity for fixture/GREEN checks: a MiniLend without the R3 claims ledger owes no claims, so its
    ///         totalResidualClaims term is 0; once the getter exists its value is used.
    function assertAccountingIdentityAnyVersion() internal view {
        (bool ok, uint256 claims) = _tryUint(address(market), abi.encodeCall(ISpecMiniLend.totalResidualClaims, ()));
        if (!ok) claims = 0;
        assertEq(
            usdc.balanceOf(address(market)) + market.totalDebt(),
            market.totalSupplyAssets() + claims,
            "cash + totalDebt == totalSupplyAssets + totalResidualClaims (claims 0 without R3 ledger)"
        );
    }

    /// @notice With unsolicited transfers only >= is required.
    function assertAccountingIdentityWithDonations() internal view {
        uint256 claims = specTotalResidualClaims();
        assertGe(
            usdc.balanceOf(address(market)) + market.totalDebt(),
            market.totalSupplyAssets() + claims,
            "cash + totalDebt >= totalSupplyAssets + totalResidualClaims"
        );
    }

    /// @notice RWA side of the R3 reserve identities for the single-borrower fixture.
    function assertCollateralIdentity() internal view {
        (uint256 coll,) = market.positions(borrower);
        assertEq(rwa.balanceOf(address(market)), market.totalCollateral(), "RWA(market) == totalCollateral");
        assertEq(market.totalCollateral(), coll, "totalCollateral == sum of collateral");
    }

    /// @notice R3 ledger sums for the single-borrower fixture: totalDebt == sum of debt, collateral identity.
    function assertLedgerSums() internal view {
        (, uint256 debt) = market.positions(borrower);
        assertEq(market.totalDebt(), debt, "totalDebt == sum of debt");
        assertCollateralIdentity();
    }

    /// @notice R3 totalBadDebt == sum of badDebtOf (strict: needs the R3 getter).
    function assertBadDebtSum() internal view {
        assertEq(market.totalBadDebt(), specBadDebtOf(borrower), "totalBadDebt == sum of badDebtOf");
    }

    function specMarket() internal view returns (ISpecMiniLend) {
        return ISpecMiniLend(address(market));
    }

    function specAdapter() internal view returns (ISpecLiquidationAdapter) {
        return ISpecLiquidationAdapter(address(adapter));
    }

    /// @dev Named assertion instead of an empty revert while the snapshot lacks the R3 getter.
    function specTotalResidualClaims() internal view returns (uint256 v) {
        bool ok;
        (ok, v) = _tryUint(address(market), abi.encodeCall(ISpecMiniLend.totalResidualClaims, ()));
        assertTrue(ok, "R3 MiniLend.totalResidualClaims() not implemented");
    }

    function specBadDebtOf(address who) internal view returns (uint256 v) {
        bool ok;
        (ok, v) = _tryUint(address(market), abi.encodeCall(ISpecMiniLend.badDebtOf, (who)));
        assertTrue(ok, "R3 MiniLend.badDebtOf() not implemented");
    }

    function specClaimableResidual(address who) internal view returns (uint256 v) {
        bool ok;
        (ok, v) = _tryUint(address(market), abi.encodeCall(ISpecMiniLend.claimableResidual, (who)));
        assertTrue(ok, "R3 MiniLend.claimableResidual() not implemented");
    }

    // ================================================================== world snapshot / rollback
    function captureWorld(address who) internal view returns (World memory w) {
        w.bal = _captureBalances(who);
        w.ledger = _captureLedger(who);
        w.pool = _capturePool();
    }

    /// @notice Exact equality of every balance, supply, ledger entry and pool field (state unchanged after a revert).
    function assertWorldUnchanged(World memory a, address who) internal view {
        World memory b = captureWorld(who);
        _assertBalancesUnchanged(a.bal, b.bal);
        _assertLedgerUnchangedExceptNav(a.ledger, b.ledger);
        assertEq(b.ledger.nav, a.ledger.nav, "unchanged: nav");
        assertEq(b.ledger.navUpdatedAt, a.ledger.navUpdatedAt, "unchanged: navUpdatedAt");
        _assertPoolUnchanged(a.pool, b.pool);
    }

    function assertWorldUnchanged(World memory a) internal view {
        assertWorldUnchanged(a, borrower);
    }

    /// @notice Everything in assertWorldUnchanged except nav/navUpdatedAt, which must equal the given values.
    function assertWorldUnchangedExceptNav(World memory a, address who, uint256 newNav, uint256 newNavAt)
        internal
        view
    {
        World memory b = captureWorld(who);
        _assertBalancesUnchanged(a.bal, b.bal);
        _assertLedgerUnchangedExceptNav(a.ledger, b.ledger);
        assertEq(b.ledger.nav, newNav, "nav == new NAV");
        assertEq(b.ledger.navUpdatedAt, newNavAt, "navUpdatedAt == update time");
        _assertPoolUnchanged(a.pool, b.pool);
    }

    function _assertBalancesUnchanged(Balances memory a, Balances memory b) private pure {
        assertEq(b.keeperUsdc, a.keeperUsdc, "unchanged: keeper USDC");
        assertEq(b.keeperRwa, a.keeperRwa, "unchanged: keeper RWA");
        assertEq(b.borrowerUsdc, a.borrowerUsdc, "unchanged: borrower USDC");
        assertEq(b.borrowerRwa, a.borrowerRwa, "unchanged: borrower RWA");
        assertEq(b.marketUsdc, a.marketUsdc, "unchanged: market USDC");
        assertEq(b.marketRwa, a.marketRwa, "unchanged: market RWA");
        assertEq(b.adapterUsdc, a.adapterUsdc, "unchanged: adapter USDC");
        assertEq(b.adapterRwa, a.adapterRwa, "unchanged: adapter RWA");
        assertEq(b.adapterClaimsPa, a.adapterClaimsPa, "unchanged: adapter vRWA 6909 claims");
        assertEq(b.adapterClaimsUsdc, a.adapterClaimsUsdc, "unchanged: adapter USDC 6909 claims");
        assertEq(b.pmUsdc, a.pmUsdc, "unchanged: PM USDC");
        assertEq(b.pmRwa, a.pmRwa, "unchanged: PM raw RWA");
        assertEq(b.pmPa, a.pmPa, "unchanged: PM vRWA");
        assertEq(b.paRwa, a.paRwa, "unchanged: PA RWA backing");
        assertEq(b.paSupply, a.paSupply, "unchanged: vRWA supply");
        assertEq(b.deskUsdc, a.deskUsdc, "unchanged: desk USDC");
        assertEq(b.deskRwa, a.deskRwa, "unchanged: desk RWA");
        assertEq(b.issuerUsdc, a.issuerUsdc, "unchanged: issuer USDC");
        assertEq(b.issuerRwa, a.issuerRwa, "unchanged: issuer RWA");
        assertEq(b.mmUsdc, a.mmUsdc, "unchanged: MM USDC");
        assertEq(b.mmRwa, a.mmRwa, "unchanged: MM RWA");
        assertEq(b.lenderUsdc, a.lenderUsdc, "unchanged: lender USDC");
        assertEq(b.rwaSupply, a.rwaSupply, "unchanged: RWA totalSupply");
        assertEq(b.usdcSupply, a.usdcSupply, "unchanged: USDC totalSupply");
    }

    function _assertLedgerUnchangedExceptNav(Ledger memory a, Ledger memory b) private pure {
        assertEq(b.collateral, a.collateral, "unchanged: collateral");
        assertEq(b.debt, a.debt, "unchanged: debt");
        assertEq(b.totalCollateral, a.totalCollateral, "unchanged: totalCollateral");
        assertEq(b.totalDebt, a.totalDebt, "unchanged: totalDebt");
        assertEq(b.totalSupplyAssets, a.totalSupplyAssets, "unchanged: totalSupplyAssets");
        assertEq(b.totalSupplyShares, a.totalSupplyShares, "unchanged: totalSupplyShares");
        assertEq(b.totalBadDebt, a.totalBadDebt, "unchanged: totalBadDebt");
        assertEq(b.specLedger, a.specLedger, "unchanged: R3 getters availability");
        assertEq(b.badDebtOf, a.badDebtOf, "unchanged: badDebtOf");
        assertEq(b.claimableResidual, a.claimableResidual, "unchanged: claimableResidual");
        assertEq(b.totalResidualClaims, a.totalResidualClaims, "unchanged: totalResidualClaims");
        assertEq(b.liquidationBlocked, a.liquidationBlocked, "unchanged: liquidationBlocked");
    }

    function _assertPoolUnchanged(PoolState memory a, PoolState memory b) private pure {
        assertEq(b.sqrtPriceX96, a.sqrtPriceX96, "unchanged: pool sqrtPriceX96");
        assertEq(b.tick, a.tick, "unchanged: pool tick");
        assertEq(b.liquidity, a.liquidity, "unchanged: pool liquidity");
        assertEq(b.deskLiquidity, a.deskLiquidity, "unchanged: MM position liquidity");
    }

    function _captureBalances(address who) private view returns (Balances memory s) {
        s.keeperUsdc = usdc.balanceOf(keeper);
        s.keeperRwa = rwa.balanceOf(keeper);
        s.borrowerUsdc = usdc.balanceOf(who);
        s.borrowerRwa = rwa.balanceOf(who);
        s.marketUsdc = usdc.balanceOf(address(market));
        s.marketRwa = rwa.balanceOf(address(market));
        s.adapterUsdc = usdc.balanceOf(address(adapter));
        s.adapterRwa = rwa.balanceOf(address(adapter));
        s.adapterClaimsPa = PM.balanceOf(address(adapter), uint256(uint160(address(pa))));
        s.adapterClaimsUsdc = PM.balanceOf(address(adapter), uint256(uint160(address(usdc))));
        s.pmUsdc = usdc.balanceOf(address(PM));
        s.pmRwa = rwa.balanceOf(address(PM));
        s.pmPa = pa.balanceOf(address(PM));
        s.paRwa = rwa.balanceOf(address(pa));
        s.paSupply = pa.totalSupply();
        s.deskUsdc = usdc.balanceOf(address(desk));
        s.deskRwa = rwa.balanceOf(address(desk));
        s.issuerUsdc = usdc.balanceOf(issuer);
        s.issuerRwa = rwa.balanceOf(issuer);
        s.mmUsdc = usdc.balanceOf(mm);
        s.mmRwa = rwa.balanceOf(mm);
        s.lenderUsdc = usdc.balanceOf(lender);
        s.rwaSupply = rwa.totalSupply();
        s.usdcSupply = usdc.totalSupply();
    }

    function _captureLedger(address who) private view returns (Ledger memory s) {
        (s.collateral, s.debt) = market.positions(who);
        s.totalCollateral = market.totalCollateral();
        s.totalDebt = market.totalDebt();
        s.totalSupplyAssets = market.totalSupplyAssets();
        s.totalSupplyShares = market.totalSupplyShares();
        s.totalBadDebt = market.totalBadDebt();
        s.nav = market.nav();
        s.navUpdatedAt = market.navUpdatedAt();
        _captureSpecLedger(s, who);
    }

    /// @dev R3 getters read with staticcall so a snapshot without them still yields a comparable Ledger.
    function _captureSpecLedger(Ledger memory s, address who) private view {
        address m = address(market);
        bool ok1;
        bool ok2;
        bool ok3;
        bool ok4;
        uint256 blocked;
        (ok1, s.badDebtOf) = _tryUint(m, abi.encodeCall(ISpecMiniLend.badDebtOf, (who)));
        (ok2, s.claimableResidual) = _tryUint(m, abi.encodeCall(ISpecMiniLend.claimableResidual, (who)));
        (ok3, s.totalResidualClaims) = _tryUint(m, abi.encodeCall(ISpecMiniLend.totalResidualClaims, ()));
        (ok4, blocked) = _tryUint(m, abi.encodeCall(ISpecMiniLend.liquidationBlocked, (who)));
        s.liquidationBlocked = blocked != 0;
        s.specLedger = ok1 && ok2 && ok3 && ok4;
    }

    function _capturePool() private view returns (PoolState memory s) {
        (s.sqrtPriceX96, s.tick,,) = PM.getSlot0(poolId);
        s.liquidity = PM.getLiquidity(poolId);
        (s.deskLiquidity,,) = PM.getPositionInfo(poolId, address(desk), TICK_LOWER, TICK_UPPER, bytes32(0));
    }

    // ================================================================== internals
    function _tryUint(address target, bytes memory callData) private view returns (bool ok, uint256 v) {
        (bool success, bytes memory ret) = target.staticcall(callData);
        if (success && ret.length == 32) {
            ok = true;
            v = abi.decode(ret, (uint256));
        }
    }

    function _up(uint256 pre, uint256 post, string memory what) private pure returns (uint256) {
        assertGe(post, pre, string.concat(what, " must not decrease"));
        return post - pre;
    }

    function _down(uint256 pre, uint256 post, string memory what) private pure returns (uint256) {
        assertLe(post, pre, string.concat(what, " must not increase"));
        return pre - post;
    }
}
