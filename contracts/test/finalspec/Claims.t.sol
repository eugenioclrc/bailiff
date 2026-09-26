// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MockRWA3643} from "../../src/e2e/MockRWA3643.sol";
import {MiniLend} from "../../src/e2e/MiniLend.sol";
import {ISpecMiniLend, ISpecLiquidationAdapter} from "./SpecInterfaces.sol";
import {FinalSpecBase} from "./FinalSpecBase.sol";
import {SpecBlockableUSDC, SpecMockUSDC} from "./FinalSpecFixture.sol";

interface IUsdcReceiveHook {
    function onUsdcReceived(address from, uint256 amount) external;
}

/// @notice Test-only USDC with the R2 ABI that calls a minter-registered recipient right after crediting it, like an
///         ERC-777 hook. It only gives claimResidual's outgoing transfer a re-entry point; never a product token.
contract CallbackUSDC is SpecMockUSDC {
    mapping(address => bool) public hooked;

    constructor(address minter_) SpecMockUSDC(minter_) {}

    function setHooked(address account, bool isHooked) external {
        if (msg.sender != minter) revert OnlyMinter();
        hooked[account] = isHooked;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hooked[to]) IUsdcReceiveHook(to).onUsdcReceived(from, value);
    }
}

/// @notice Credit holder that, from the USDC receive hook, first records what the market exposes while its outgoing
///         transfer is still in flight (R3 CEI) and then re-enters claimResidual once, recording what the market answered.
contract ReentrantClaimer is IUsdcReceiveHook {
    uint256 private constant UNSEEN = type(uint256).max; // sentinel: the hook never overwrote the field

    ISpecMiniLend public immutable market;
    IERC20 public immutable usdc;
    uint256 public reentries;
    uint256 public reentryPaid;
    bytes public reentryRevert;
    // observed inside the market's safeTransfer, after the token moved the funds and before it returns to MiniLend
    address public hookFrom;
    uint256 public hookAmount;
    uint256 public creditDuringTransfer;
    uint256 public claimsDuringTransfer;
    uint256 public marketUsdcDuringTransfer;
    uint256 public ownUsdcDuringTransfer;
    bool private armed;

    constructor(ISpecMiniLend market_, IERC20 usdc_) {
        market = market_;
        usdc = usdc_;
    }

    function claim() external returns (uint256) {
        creditDuringTransfer = UNSEEN;
        claimsDuringTransfer = UNSEEN;
        marketUsdcDuringTransfer = UNSEEN;
        ownUsdcDuringTransfer = UNSEEN;
        armed = true;
        return market.claimResidual();
    }

    function onUsdcReceived(address from, uint256 amount) external {
        if (!armed || msg.sender != address(usdc)) return;
        armed = false;
        reentries++;
        hookFrom = from;
        hookAmount = amount;
        creditDuringTransfer = market.claimableResidual(address(this));
        claimsDuringTransfer = market.totalResidualClaims();
        marketUsdcDuringTransfer = usdc.balanceOf(address(market));
        ownUsdcDuringTransfer = usdc.balanceOf(address(this));
        try market.claimResidual() returns (uint256 paid) {
            reentryPaid = paid;
        } catch (bytes memory reason) {
            reentryRevert = reason;
        }
    }
}

/// @notice Acceptance for the borrower residual claim (CONTRACTS R1 freeze, R3 settlement/claim/reserve identities, R5
///         step 8; TRACEABILITY C1 rows) on the REAL Labs PoolManager/factory/hook pinned at Sepolia 11782723.
/// @dev Snapshot verdicts: test_frozenBorrowerLiquidatable is GREEN (the freeze already never touches the route).
///      The other four are RED: the snapshot adapter pays the residual straight to the borrower and MiniLend has no
///      claims ledger, so each fails at the named assertion for that missing behaviour.
contract ClaimsTest is FinalSpecBase {
    // ------------------------------------------------------------------ full close at NAV 85 on the pinned fixture
    /// @dev Measured through the real PoolManager (PA currency0, P=100, L=5e17, fee 3000) selling
    ///      CRASH_FULL_CLOSE_SEIZE exact-in; O7 estimated 91541.59. The NAV floor (84.15) is not reached by this sale.
    uint256 internal constant FULL_CLOSE_PROCEEDS = 91_541_594_333;
    /// @dev min(floor(16541.594333e6 * 5000 / 1e4), floor(75000e6 * 600 / 1e4)): the 6% LB cap binds.
    uint256 internal constant FULL_CLOSE_BOUNTY = 4_500e6;
    /// @dev proceeds - repaid - bounty = 91541.594333 - 75000 - 4500.
    uint256 internal constant FULL_CLOSE_RESIDUAL = 12_041_594_333;
    uint256 internal constant COLLATERAL_AFTER_FULL_CLOSE = 64_705_882_352_941_176_471; // 1000e18 - seize

    // ------------------------------------------------------------------ lender shares (R3 virtual shares 1e6, assets 1)
    uint256 internal constant LENDER_SHARES = 5e17; // 500000e6 * (0 + 1e6) / (0 + 1)
    /// @dev While no loss is realised totalSupplyShares + 1e6 == 1e6 * (totalSupplyAssets + 1), so 1e6 shares == 1 unit.
    uint256 internal constant SHARES_PER_UNIT = 1e6;
    /// @dev Capacity of the leftover collateral at NAV 85: floor(64705882352941176471 * 85e18 * 7500 / 1e34) = 4125e6.
    uint256 internal constant REBORROW = 4_000e6;
    uint256 internal constant HF_AFTER_REBORROW = 1.1e18; // floor(4400e6 * 1e18 / 4000e6)

    // ------------------------------------------------------------------ donations and re-entry probe
    uint256 internal constant ADAPTER_USDC_DONATION = 1_234_567;
    uint256 internal constant ADAPTER_RWA_DONATION = 3e18;
    uint256 internal constant MARKET_USDC_DONATION = 2_500e6;
    uint256 internal constant MARKET_RWA_DONATION = 5e18;
    uint256 internal constant REENTRY_CREDIT = 777e6;
    uint256 internal constant OTHER_CREDIT = 313e6;

    // ------------------------------------------------------------------ second lender and collateral top-up
    uint256 internal constant SUPPLIER_USDC = 20_000e6;
    /// @dev 20000e6 * (5e17 + 1e6) / (500000e6 + 1) = 20000e6 * 1e6: the no-donation share price, exactly.
    uint256 internal constant SUPPLIER_SHARES = 2e16;
    uint256 internal constant SUPPLY_WITH_SUPPLIER = 520_000e6; // LENDER_USDC + SUPPLIER_USDC
    uint256 internal constant SHARES_WITH_SUPPLIER = 5.2e17; // LENDER_SHARES + SUPPLIER_SHARES
    uint256 internal constant COLLATERAL_TOPUP = 10e18;

    address internal donor = makeAddr("donor"); // unsolicited third party, HOLDER only
    address internal supplier = makeAddr("supplier"); // second lender, supplies while a donation sits in the market
    address internal claimRecipient = makeAddr("claimRecipient"); // alternative recipient a claim must never pay

    // ================================================================== tests
    /// @notice GREEN. R1: an RWA freeze on the borrower does not stop the liquidation, because the collateral already
    ///         sits in MiniLend and travels Market -> Adapter -> PA, never to the borrower. Controls: the freeze is live
    ///         on the token, freezing a contract ON that route does stop the very same call, and afterwards the market
    ///         still cannot hand the leftover collateral to the frozen borrower.
    function test_frozenBorrowerLiquidatable() public {
        crashNavAndAssertNavOnly();
        _setFrozenAsIssuer(borrower, true);
        assertEq(rwa.flags(borrower), rwa.HOLDER(), "freeze is not delisting: borrower keeps HOLDER only");
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(MockRWA3643.WalletFrozen.selector, borrower));
        rwa.mint(borrower, 1);

        _assertFrozenMarketBlocksSameCall();

        Liquidation memory r = liquidateViaAdapter();
        assertLiquidationSuccessPath(r);
        _assertFullCloseAmounts(r);
        assertTrue(rwa.frozen(borrower), "borrower stayed frozen through the liquidation");
        assertEq(r.post.bal.borrowerRwa, 0, "no RWA reached the frozen borrower");
        assertAccountingIdentityAnyVersion();
        assertLedgerSums();

        // the leftover collateral cannot be paid out to the frozen borrower either
        World memory pre = captureWorld(borrower);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(MockRWA3643.WalletFrozen.selector, borrower), address(rwa));
        market.withdrawCollateral(COLLATERAL_AFTER_FULL_CLOSE);
        assertWorldUnchanged(pre);
    }

    /// @notice RED on the snapshot. C1, R3, R5 step 8: with the test-only USDC rejecting the borrower, the liquidation
    ///         still finishes and credits the whole residual inside MiniLend; the borrower's claim then reverts on its
    ///         own with the token's error, keeping the credit, and pays exactly that credit once the token accepts the
    ///         borrower again. PM, factory and hook stay the real Labs contracts.
    function test_rejectedResidualClaimDoesNotBlockLiquidation() public {
        _deployFixture(DEFAULT_PA_IS_CURRENCY0, true);
        assertTrue(usdcIsBlockable, "fixture USDC is the blockable test variant");
        crashNavAndAssertNavOnly();
        setUsdcRecipientBlocked(borrower, true);
        vm.prank(issuer);
        vm.expectRevert(_rejected(borrower));
        usdc.mint(borrower, 1);

        _assertKeeperLiquidationDoesNotRevert(
            "USDC rejecting the borrower blocked the liquidation: the residual must be settled in MiniLend (R5 step 8)"
        );
        Liquidation memory r = liquidateViaAdapter();
        assertLiquidationSuccessPath(r);
        _assertFullCloseAmounts(r);
        uint256 credit = _assertResidualCredited(r);
        assertAccountingIdentity();

        // the rejected claim reverts alone: credit, claims, cash and the finished liquidation stay exactly as they are
        World memory pre = captureWorld(borrower);
        vm.prank(borrower);
        vm.expectRevert(_rejected(borrower), address(usdc)); // raised by the token, bubbled by MiniLend
        specMarket().claimResidual();
        assertWorldUnchanged(pre);
        assertEq(pre.ledger.debt, 0, "liquidation stays finished: debt 0");
        assertEq(pre.ledger.collateral, COLLATERAL_AFTER_FULL_CLOSE, "liquidation stays finished: collateral left");
        assertEq(pre.ledger.claimableResidual, credit, "credit kept after the rejected claim");
        assertAccountingIdentity();

        // restore control: the very same claim pays exactly the preserved credit
        setUsdcRecipientBlocked(borrower, false);
        _claimAndAssert(credit);
        assertAccountingIdentity();
        assertLedgerSums();
    }

    /// @notice RED on the snapshot. R3 claimResidual pays the caller's own credit to the caller only (not tx.origin, not
    ///         the keeper, not the adapter that paid the settlement, and there is no entry point naming another
    ///         recipient), zeroes it and lowers totalResidualClaims by exactly that amount; a second call reverts
    ///         ZeroAmount; the credit is zeroed and totalResidualClaims reduced before the transfer (observed from the
    ///         recipient's hook) and nonReentrant pays a re-entering recipient once.
    function test_claimResidualOnce() public {
        Liquidation memory r = _crashAndFullClose();
        uint256 credit = _assertResidualCredited(r);
        assertAccountingIdentity();

        _assertClaimRevertsZeroAmount(keeper); // triggered the sale; the residual is not the keeper's
        _assertClaimRevertsZeroAmount(address(adapter)); // paid the settlement; keeps no custody and no credit
        _assertNoClaimToOtherRecipient(credit); // the credit holder cannot direct its credit elsewhere
        _claimAndAssert(credit);
        assertAccountingIdentity();

        _assertClaimRevertsZeroAmount(borrower); // claimed once, nothing left
        assertEq(usdc.balanceOf(address(market)), LENDER_USDC, "market cash is lender assets only again");
        assertAccountingIdentity();
        assertLedgerSums();

        _assertReentrantClaimPaidOnce();
    }

    /// @notice RED on the snapshot. R3 reserve: totalSupplyAssets counts lender assets only and the credit is a separate
    ///         obligation. After a permitted borrow and the lender's maximum withdrawal cash equals the claims exactly;
    ///         one more unit of either reverts InsufficientLiquidity although the cash is there; the claim is paid in
    ///         full and the lender exits with exactly its supply.
    function test_lenderWithdrawalPreservesResidualClaims() public {
        Liquidation memory r = _crashAndFullClose();
        uint256 credit = _assertResidualCredited(r);
        assertEq(usdc.balanceOf(address(market)), LENDER_USDC + credit, "cash == lender assets + credit");
        assertAccountingIdentity();

        // a permitted borrow at NAV 85 draws on lender assets; the credit reserve is untouched
        _borrowAndAssert(REBORROW);
        assertEq(market.healthFactor(borrower), HF_AFTER_REBORROW, "re-borrow is within LTV and healthy");
        assertAccountingIdentity();

        // lenders can neither pull what is lent out nor reach into the credit
        _assertWithdrawRevertsInsufficientLiquidity(LENDER_SHARES);
        _withdrawAndAssert((LENDER_USDC - REBORROW) * SHARES_PER_UNIT, LENDER_USDC - REBORROW);
        assertEq(usdc.balanceOf(address(market)), credit, "remaining cash covers the claims exactly");
        assertEq(specTotalResidualClaims(), credit, "same reserve after the borrow and the withdrawal");
        _assertWithdrawRevertsInsufficientLiquidity(SHARES_PER_UNIT);
        _assertBorrowRevertsInsufficientLiquidity(1);
        assertAccountingIdentity();

        // the reserved cash pays the claim in full; then the loan closes and the lender takes the rest
        _claimAndAssert(credit);
        assertAccountingIdentity();
        _repayAndAssert(REBORROW);
        _withdrawAndAssert(REBORROW * SHARES_PER_UNIT, REBORROW);
        assertEq(usdc.balanceOf(lender), LENDER_USDC, "lender got back exactly its supply, none of the credit");
        assertEq(usdc.balanceOf(address(market)), 0, "market drained, each unit to its owner");
        assertEq(market.totalSupplyShares(), 0, "all shares burned");
        assertAccountingIdentity();
        assertLedgerSums();
        assertBadDebtSum();
    }

    /// @notice RED on the snapshot. R3 identities hold with equality in the no-donation fixture. Then unsolicited
    ///         USDC/RWA lands in the adapter and in MiniLend BEFORE anything else runs, and every later market action
    ///         runs with it in place: a supply, the liquidation with its residual settlement, a collateral deposit, the
    ///         withdrawals and the claim. Each returns exactly its no-donation amounts (same shares, same proceeds,
    ///         bounty and ResidualApplied split, same credit, same totalSupplyAssets, same collateral), the adapter's
    ///         donation neither subsidises nor blocks the sale (R5), and the balance identities are only >= with the
    ///         excess exactly the donation at every step, which nobody can withdraw.
    function test_residualDonationAccounting() public {
        assertAccountingIdentity();
        assertLedgerSums();
        assertBadDebtSum();
        _fundDonor();

        _donateToAdapterAndAssert();
        assertAccountingIdentity(); // nothing reached the market yet: still strict
        _donateToMarketAndAssert();
        _assertDonatedExcess();
        _assertDonorOwnsNothing();

        // a supply priced while the donation sits in the market mints the no-donation shares
        _supplyAndAssert(SUPPLIER_USDC, SUPPLIER_SHARES);
        _assertDonatedExcess();

        // the settlement runs with the donation in the market: the ResidualApplied split, the credit, the claims and
        // the lender assets and shares are exactly the no-donation values
        Liquidation memory r = _crashAndFullClose(); // same proceeds, bounty and residual as without either donation
        assertEq(r.post.bal.adapterUsdc, ADAPTER_USDC_DONATION, "adapter keeps exactly the donated USDC");
        assertEq(r.post.bal.adapterRwa, ADAPTER_RWA_DONATION, "adapter keeps exactly the donated RWA");
        assertEq(r.post.bal.marketRwa, COLLATERAL_AFTER_FULL_CLOSE + MARKET_RWA_DONATION, "market RWA: leftover + gift");
        uint256 credit = _assertResidualCredited(r, SUPPLY_WITH_SUPPLIER, SHARES_WITH_SUPPLIER);
        _assertDonatedExcess();
        _assertDonorOwnsNothing();

        // a collateral deposit with donated RWA in the market credits exactly the deposit
        _depositCollateralAndAssert(COLLATERAL_TOPUP);
        _assertDonatedExcess();

        // every owner exits with exactly its own amount; only the donation is left behind
        _withdrawAndAssert(LENDER_SHARES, LENDER_USDC);
        _withdrawAsAndAssert(supplier, SUPPLIER_SHARES, SUPPLIER_USDC);
        _claimAndAssert(credit);
        assertEq(usdc.balanceOf(address(market)), MARKET_USDC_DONATION, "only the donated USDC is left");
        assertEq(market.totalSupplyAssets(), 0, "no lender assets left");
        assertEq(market.totalSupplyShares(), 0, "all shares burned");
        assertEq(specTotalResidualClaims(), 0, "no claim left");
        _assertDonatedExcess();
        _assertDonorOwnsNothing();
    }

    // ================================================================== liquidation and residual
    /// @dev O4 NAV-only crash, one keeper call through the adapter with the close factor deciding, then every
    ///      TRACEABILITY success check and the exact amounts of the pinned fixture.
    function _crashAndFullClose() private returns (Liquidation memory r) {
        crashNavAndAssertNavOnly();
        r = liquidateViaAdapter();
        assertLiquidationSuccessPath(r);
        _assertFullCloseAmounts(r);
    }

    function _assertFullCloseAmounts(Liquidation memory r) private pure {
        assertEq(r.repaid, BORROWER_DEBT, "HF <= 0.95: full close repays 75000");
        assertEq(r.seized, CRASH_FULL_CLOSE_SEIZE, "seize at NAV 85");
        assertEq(r.proceeds, FULL_CLOSE_PROCEEDS, "pool proceeds on the pinned fixture");
        assertEq(r.eventBounty, FULL_CLOSE_BOUNTY, "bounty == 6% LB cap");
        assertEq(r.residual, FULL_CLOSE_RESIDUAL, "residual == proceeds - repaid - bounty");
        assertEq(r.marketBadDebt, 0, "collateral remains: no write-off");
        assertEq(r.post.ledger.debt, 0, "debt closed");
        assertEq(r.post.ledger.collateral, COLLATERAL_AFTER_FULL_CLOSE, "collateral left");
    }

    /// @dev R3 priority with no live debt and no write-off: the whole residual becomes borrower credit, owed by the market
    ///      apart from lender assets and shares.
    function _assertResidualCredited(Liquidation memory r) private view returns (uint256) {
        return _assertResidualCredited(r, LENDER_USDC, LENDER_SHARES);
    }

    /// @param supplyAssets totalSupplyAssets before and after the settlement (lender assets only)
    /// @param supplyShares totalSupplyShares before and after the settlement
    function _assertResidualCredited(Liquidation memory r, uint256 supplyAssets, uint256 supplyShares)
        private
        view
        returns (uint256 credit)
    {
        credit = specClaimableResidual(borrower);
        assertEq(credit, FULL_CLOSE_RESIDUAL, "debt 0 and no write-off: the whole residual is borrower credit");
        assertEq(specTotalResidualClaims(), FULL_CLOSE_RESIDUAL, "totalResidualClaims == the single credit");
        assertEq(specBadDebtOf(borrower), 0, "no write-off recorded");
        (uint256 debtRepaid, uint256 recovered, uint256 borrowerCredit) = assertResidualSettledInMarket(r);
        assertEq(debtRepaid, 0, "ResidualApplied: no live debt left to repay");
        assertEq(recovered, 0, "ResidualApplied: no write-off to recover");
        assertEq(borrowerCredit, FULL_CLOSE_RESIDUAL, "ResidualApplied credits the whole residual");
        assertEq(r.pre.ledger.totalSupplyAssets, supplyAssets, "lender assets before the settlement");
        assertEq(market.totalSupplyAssets(), supplyAssets, "credit is not lender assets");
        assertEq(r.pre.ledger.totalSupplyShares, supplyShares, "lender shares before the settlement");
        assertEq(market.totalSupplyShares(), supplyShares, "credit mints no shares");
    }

    /// @dev Probe inside a state snapshot so a revert fails this named assertion with its revert data instead of
    ///      aborting the test; liquidateViaAdapter then makes the real call on the untouched state.
    function _assertKeeperLiquidationDoesNotRevert(string memory why) private {
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        (bool ok, bytes memory ret) =
            address(adapter).call(abi.encodeCall(ISpecLiquidationAdapter.liquidate, (borrower, type(uint256).max, 0)));
        assertTrue(vm.revertToStateAndDelete(snap), "probe state restored");
        vm.getRecordedLogs(); // drop the probe's logs
        assertTrue(ok, string.concat(why, "; revert data: ", vm.toString(ret)));
    }

    // ================================================================== claims
    /// @dev The borrower claims with tx.origin = keeper: only msg.sender is paid. Every other balance, supply, ledger and
    ///      pool field must stay exactly as before (assertWorldUnchanged against the expected world).
    function _claimAndAssert(uint256 credit) private {
        World memory expected = _copy(captureWorld(borrower));
        expected.bal.borrowerUsdc += credit;
        expected.bal.marketUsdc -= credit;
        expected.ledger.claimableResidual = 0;
        expected.ledger.totalResidualClaims -= credit;
        vm.expectEmit(true, false, false, true, address(market));
        emit ISpecMiniLend.ResidualClaimed(borrower, credit);
        vm.prank(borrower, keeper);
        uint256 paid = specMarket().claimResidual();
        assertEq(paid, credit, "claimResidual returns the credit it paid");
        assertWorldUnchanged(expected);
    }

    /// @dev R3: "claimResidual solo paga el credito de msg.sender a msg.sender, sin parametro de destinatario
    ///      alternativo". The credit holder calls the recipient-taking shapes such an entry point would have; MiniLend
    ///      must not dispatch any of them (revert with empty data, no fallback) and nothing may move.
    function _assertNoClaimToOtherRecipient(uint256 credit) private {
        bytes[4] memory calls = [
            abi.encodeWithSignature("claimResidual(address)", claimRecipient),
            abi.encodeWithSignature("claimResidual(address,uint256)", claimRecipient, credit),
            abi.encodeWithSignature("claimResidualTo(address)", claimRecipient),
            abi.encodeWithSignature("claimResidualTo(address,uint256)", claimRecipient, credit)
        ];
        for (uint256 i; i < calls.length; i++) {
            World memory pre = captureWorld(borrower);
            vm.prank(borrower);
            (bool ok, bytes memory ret) = address(market).call(calls[i]);
            assertFalse(ok, "MiniLend has no claim entry point that takes a recipient");
            assertEq(ret, bytes(""), "recipient-taking claim selector is not dispatched (empty revert data)");
            assertWorldUnchanged(pre);
            assertEq(usdc.balanceOf(claimRecipient), 0, "alternative recipient received nothing");
            assertEq(specClaimableResidual(borrower), credit, "credit kept for its holder");
            assertEq(specTotalResidualClaims(), credit, "totalResidualClaims unchanged");
        }
    }

    function _assertClaimRevertsZeroAmount(address caller) private {
        World memory pre = captureWorld(borrower);
        uint256 callerUsdc = usdc.balanceOf(caller);
        vm.prank(caller);
        vm.expectRevert(ISpecMiniLend.ZeroAmount.selector);
        specMarket().claimResidual();
        assertWorldUnchanged(pre);
        assertEq(usdc.balanceOf(caller), callerUsdc, "rejected claim pays the caller nothing");
    }

    /// @dev CEI + nonReentrant (R3). The fixture USDC has no receive hook, so this runs on a separate MiniLend over the
    ///      test-only CallbackUSDC. Credits come from the permissionless settlement on accounts with no debt and no
    ///      write-off, which R3 turns entirely into borrower credit. A second holder keeps totalResidualClaims non-zero,
    ///      so "reduced by exactly the credit" is distinguishable from "reset". The recipient reads the ledger from
    ///      inside the transfer: R3 requires the credit zeroed and totalResidualClaims reduced BEFORE safeTransfer.
    function _assertReentrantClaimPaidOnce() private {
        CallbackUSDC cusdc = new CallbackUSDC(issuer);
        ISpecMiniLend m = ISpecMiniLend(
            address(
                new MiniLend(
                    IERC20(address(rwa)),
                    IERC20(address(cusdc)),
                    issuer,
                    NAV0,
                    ORACLE_NAV_MIN,
                    ORACLE_NAV_MAX,
                    NAV_STALENESS
                )
            )
        );
        ReentrantClaimer claimer = new ReentrantClaimer(m, IERC20(address(cusdc)));
        address other = makeAddr("otherCreditHolder");
        _settleCreditFor(cusdc, m, other, OTHER_CREDIT);
        _settleCreditFor(cusdc, m, address(claimer), REENTRY_CREDIT);
        assertEq(m.totalResidualClaims(), OTHER_CREDIT + REENTRY_CREDIT, "two credits outstanding");
        vm.prank(issuer);
        cusdc.setHooked(address(claimer), true);

        assertEq(claimer.claim(), REENTRY_CREDIT, "outer claim pays the credit");
        assertEq(claimer.reentries(), 1, "recipient hook ran once, inside the market's transfer");
        assertEq(claimer.hookFrom(), address(m), "hooked transfer is the market paying the claimer");
        assertEq(claimer.hookAmount(), REENTRY_CREDIT, "hooked transfer carries exactly the credit");

        // effects before the interaction: observed while safeTransfer is still on the stack
        assertEq(claimer.creditDuringTransfer(), 0, "CEI: claimableResidual(caller) already 0 during the transfer");
        assertEq(
            claimer.claimsDuringTransfer(),
            OTHER_CREDIT,
            "CEI: totalResidualClaims already reduced by exactly the credit during the transfer"
        );
        assertEq(claimer.marketUsdcDuringTransfer(), OTHER_CREDIT, "market cash during the transfer == other claims");
        assertEq(claimer.ownUsdcDuringTransfer(), REENTRY_CREDIT, "hook ran after the claimer was credited");

        assertEq(
            claimer.reentryRevert(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "re-entry stopped by nonReentrant"
        );
        assertEq(claimer.reentryPaid(), 0, "re-entry paid nothing");
        assertEq(cusdc.balanceOf(address(claimer)), REENTRY_CREDIT, "credit paid exactly once");
        assertEq(cusdc.balanceOf(address(m)), OTHER_CREDIT, "market paid out exactly the claimer's credit");
        assertEq(m.claimableResidual(address(claimer)), 0, "credit zeroed");
        assertEq(m.claimableResidual(other), OTHER_CREDIT, "other holder's credit untouched");
        assertEq(m.totalResidualClaims(), OTHER_CREDIT, "totalResidualClaims reduced by exactly the credit");
        assertEq(cusdc.balanceOf(other), 0, "other holder paid nothing by someone else's claim");
    }

    function _settleCreditFor(CallbackUSDC cusdc, ISpecMiniLend m, address account, uint256 amount) private {
        address payer = makeAddr("settlementPayer");
        uint256 claimsBefore = m.totalResidualClaims();
        uint256 cashBefore = cusdc.balanceOf(address(m));
        vm.prank(issuer);
        cusdc.mint(payer, amount);
        vm.startPrank(payer);
        cusdc.approve(address(m), amount);
        (uint256 debtRepaid, uint256 recovered, uint256 credit) = m.settleLiquidationResidual(account, amount);
        vm.stopPrank();
        assertEq(debtRepaid, 0, "no debt to repay");
        assertEq(recovered, 0, "no write-off to recover");
        assertEq(credit, amount, "whole settlement is credit");
        assertEq(cusdc.balanceOf(payer), 0, "settlement pulled exactly the assets from the payer");
        assertEq(cusdc.balanceOf(address(m)), cashBefore + amount, "market holds the settled assets");
        assertEq(m.claimableResidual(account), amount, "credit recorded");
        assertEq(m.totalResidualClaims(), claimsBefore + amount, "claims grew by exactly the credit");
    }

    // ================================================================== lender / borrower actions (expected worlds)
    function _borrowAndAssert(uint256 assets) private {
        World memory expected = _copy(captureWorld(borrower));
        expected.bal.borrowerUsdc += assets;
        expected.bal.marketUsdc -= assets;
        expected.ledger.debt += assets;
        expected.ledger.totalDebt += assets;
        vm.prank(borrower);
        market.borrow(assets);
        assertWorldUnchanged(expected); // claimableResidual and totalResidualClaims untouched by the borrow
    }

    function _repayAndAssert(uint256 assets) private {
        World memory expected = _copy(captureWorld(borrower));
        expected.bal.borrowerUsdc -= assets;
        expected.bal.marketUsdc += assets;
        expected.ledger.debt -= assets;
        expected.ledger.totalDebt -= assets;
        vm.startPrank(borrower);
        usdc.approve(address(market), assets);
        assertEq(market.repay(borrower, assets), assets, "repaid");
        vm.stopPrank();
        assertWorldUnchanged(expected);
    }

    function _withdrawAndAssert(uint256 shares, uint256 assets) private {
        _withdrawAsAndAssert(lender, shares, assets);
    }

    /// @dev Pays exactly `assets` to `who` and to nobody else; claims, collateral and debt untouched.
    function _withdrawAsAndAssert(address who, uint256 shares, uint256 assets) private {
        World memory expected = _copy(captureWorld(borrower));
        if (who == lender) expected.bal.lenderUsdc += assets;
        expected.bal.marketUsdc -= assets;
        expected.ledger.totalSupplyAssets -= assets;
        expected.ledger.totalSupplyShares -= shares;
        uint256 whoShares = market.supplyShares(who);
        uint256 whoUsdc = usdc.balanceOf(who);
        vm.prank(who);
        assertEq(market.withdraw(shares), assets, "withdraw pays exactly the assets attributable to the shares");
        assertEq(market.supplyShares(who), whoShares - shares, "withdrawer shares burned");
        assertEq(usdc.balanceOf(who), whoUsdc + assets, "withdrawer received exactly the assets");
        assertWorldUnchanged(expected); // claims untouched by the withdrawal
    }

    /// @dev A second lender supplies; shares are priced on lender assets only (R3 virtual shares 1e6, assets 1).
    function _supplyAndAssert(uint256 assets, uint256 expectedShares) private {
        vm.prank(issuer);
        usdc.mint(supplier, assets);
        World memory expected = _copy(captureWorld(borrower));
        expected.bal.marketUsdc += assets;
        expected.ledger.totalSupplyAssets += assets;
        expected.ledger.totalSupplyShares += expectedShares;
        vm.startPrank(supplier);
        usdc.approve(address(market), assets);
        assertEq(market.supply(assets), expectedShares, "supply mints the shares of lender assets only");
        vm.stopPrank();
        assertEq(market.supplyShares(supplier), expectedShares, "supplier shares");
        assertEq(usdc.balanceOf(supplier), 0, "supply pulled exactly the assets");
        assertWorldUnchanged(expected); // claims, collateral and debt untouched by the supply
    }

    /// @dev The borrower tops up collateral; its position grows by exactly the deposited amount.
    function _depositCollateralAndAssert(uint256 amount) private {
        vm.prank(issuer);
        rwa.mint(borrower, amount);
        World memory expected = _copy(captureWorld(borrower));
        expected.bal.borrowerRwa -= amount;
        expected.bal.marketRwa += amount;
        expected.ledger.collateral += amount;
        expected.ledger.totalCollateral += amount;
        vm.prank(borrower);
        market.depositCollateral(amount);
        assertWorldUnchanged(expected);
    }

    function _assertWithdrawRevertsInsufficientLiquidity(uint256 shares) private {
        World memory pre = captureWorld(borrower);
        vm.prank(lender);
        vm.expectRevert(MiniLend.InsufficientLiquidity.selector);
        market.withdraw(shares);
        assertWorldUnchanged(pre);
    }

    function _assertBorrowRevertsInsufficientLiquidity(uint256 assets) private {
        World memory pre = captureWorld(borrower);
        vm.prank(borrower);
        vm.expectRevert(MiniLend.InsufficientLiquidity.selector);
        market.borrow(assets);
        assertWorldUnchanged(pre);
    }

    // ================================================================== freeze
    function _setFrozenAsIssuer(address account, bool isFrozen) private {
        vm.expectEmit(true, false, false, true, address(rwa));
        emit MockRWA3643.FrozenSet(account, isFrozen);
        vm.prank(issuer);
        rwa.setFrozen(account, isFrozen);
        assertEq(rwa.frozen(account), isFrozen, "frozen flag set");
    }

    /// @dev R1 contrast: freezing a contract ON the route (MiniLend, the RWA sender) stops the very same keeper call,
    ///      atomically; unfreezing it restores the route while the borrower stays frozen.
    function _assertFrozenMarketBlocksSameCall() private {
        _setFrozenAsIssuer(address(market), true);
        World memory pre = captureWorld(borrower);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(MockRWA3643.WalletFrozen.selector, address(market)), address(rwa));
        adapter.liquidate(borrower, type(uint256).max, 0);
        assertWorldUnchanged(pre);
        _setFrozenAsIssuer(address(market), false);
    }

    // ================================================================== donations
    function _fundDonor() private {
        vm.startPrank(issuer);
        rwa.setFlags(donor, rwa.HOLDER());
        rwa.mint(donor, ADAPTER_RWA_DONATION + MARKET_RWA_DONATION);
        usdc.mint(donor, ADAPTER_USDC_DONATION + MARKET_USDC_DONATION);
        vm.stopPrank();
    }

    function _donateToAdapterAndAssert() private {
        World memory expected = _copy(captureWorld(borrower));
        expected.bal.adapterUsdc += ADAPTER_USDC_DONATION;
        expected.bal.adapterRwa += ADAPTER_RWA_DONATION;
        _donorSends(address(adapter), ADAPTER_USDC_DONATION, ADAPTER_RWA_DONATION);
        assertWorldUnchanged(expected);
    }

    /// @dev Only the market's balances move: no shares, collateral, debt or claim is created by the transfer.
    function _donateToMarketAndAssert() private {
        World memory expected = _copy(captureWorld(borrower));
        expected.bal.marketUsdc += MARKET_USDC_DONATION;
        expected.bal.marketRwa += MARKET_RWA_DONATION;
        _donorSends(address(market), MARKET_USDC_DONATION, MARKET_RWA_DONATION);
        assertWorldUnchanged(expected);
    }

    function _donorSends(address to, uint256 usdcAmount, uint256 rwaAmount) private {
        vm.startPrank(donor);
        assertTrue(usdc.transfer(to, usdcAmount), "donor USDC transfer");
        assertTrue(rwa.transfer(to, rwaAmount), "donor RWA transfer");
        vm.stopPrank();
    }

    /// @dev With donations the balance identities become >=, and the excess is exactly what was donated; the ledger sums
    ///      stay equalities.
    function _assertDonatedExcess() private view {
        assertAccountingIdentityWithDonations();
        assertEq(
            usdc.balanceOf(address(market)) + market.totalDebt(),
            market.totalSupplyAssets() + specTotalResidualClaims() + MARKET_USDC_DONATION,
            "cash + totalDebt - (totalSupplyAssets + totalResidualClaims) == USDC donation"
        );
        assertEq(
            rwa.balanceOf(address(market)),
            market.totalCollateral() + MARKET_RWA_DONATION,
            "RWA(market) - totalCollateral == RWA donation"
        );
        (uint256 coll, uint256 debt) = market.positions(borrower);
        assertEq(market.totalCollateral(), coll, "totalCollateral == sum of collateral");
        assertEq(market.totalDebt(), debt, "totalDebt == sum of debt");
        assertEq(specClaimableResidual(borrower), specTotalResidualClaims(), "totalResidualClaims == sum of credits");
        assertBadDebtSum();
    }

    /// @dev The donor gave value away: it holds no shares, collateral, debt, write-off or credit, and cannot claim.
    function _assertDonorOwnsNothing() private {
        assertEq(market.supplyShares(donor), 0, "donation mints no shares");
        (uint256 coll, uint256 debt) = market.positions(donor);
        assertEq(coll, 0, "donation creates no collateral");
        assertEq(debt, 0, "donation creates no debt");
        assertEq(specBadDebtOf(donor), 0, "donation creates no write-off");
        assertEq(specClaimableResidual(donor), 0, "donation creates no claim");
        _assertClaimRevertsZeroAmount(donor);
    }

    // ================================================================== utils
    function _rejected(address who) private pure returns (bytes memory) {
        return abi.encodeWithSelector(SpecBlockableUSDC.RecipientBlocked.selector, who);
    }

    /// @dev Deep copy; memory struct assignment would alias.
    function _copy(World memory w) private pure returns (World memory) {
        return abi.decode(abi.encode(w), (World));
    }
}
