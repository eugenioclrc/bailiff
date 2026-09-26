// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {
    IPermissionsAdapter
} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {PermissionFlags} from "@uniswap/v4-periphery/src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {MockRWA3643} from "../../src/e2e/MockRWA3643.sol";
import {ISpecMiniLend, ISpecLiquidationAdapter} from "./SpecInterfaces.sol";
import {FinalSpecBase} from "./FinalSpecBase.sol";

/// @notice Errors of the deployed Labs PermissionedHooks (i14n-import/bar/PermissionedHooks.sol:55-58), declared here
///         the way PermissionedV4Router.t.sol does, so the tests do not depend on the vendored copy.
interface ILabsPermissionedHooksErrors {
    error Unauthorized();
}

/// @notice Permission and route acceptance (TRACEABILITY "Acceptance contractual contra el fork real"; R3, R5).
///         Real Labs PoolManager / factory / hook on Sepolia 11782723, own mocks for RWA, USDC, lending and NAV.
///
///         Against the imported snapshot (src/):
///         - test_adapterPreflightRevocations      RED: only allowedHooks is checked before unlock; swapping-off and
///           SWAP-withdrawn come back as the hook's WrappedError, not R5's direct SwappingDisabled() / Unauthorized().
///         - test_wrapperRevocationChangesSameCall GREEN: same call passes, fails on revoke (hook), passes on restore.
///         - test_liquidationBlocked_allRoutes     RED: MiniLend has no setLiquidationBlocked / LiquidationBlocked.
///         - test_sellOnlyFixedPool                GREEN: fixed PoolKey, sale direction, exact-in seize, no 6909; the
///           deployed dispatcher routes only R5 selectors (no fallback/receive), and route/recipient/raw-swap calls,
///           probed in the state where the fixed call succeeds, hit no entry point.
contract PermissionsTest is FinalSpecBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant ERC20_TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant ERC6909_TRANSFER_TOPIC = keccak256("Transfer(address,address,address,uint256,uint256)");
    bytes32 internal constant LIQUIDATION_BLOCKED_SET_TOPIC = keccak256("LiquidationBlockedSet(address,bool)");
    bytes32 internal constant FROZEN_SET_TOPIC = keccak256("FrozenSet(address,bool)");
    // second borrower (R3: the veto is per borrower): the fixture borrower's HF profile at 1/10 of its size
    uint256 internal constant B2_COLLATERAL = 100e18;
    uint256 internal constant B2_DEBT = 7_500e6;
    uint256 internal constant MIN_BOUNTY_PCT = 97; // O5/O6: minBounty = floor(quote * 97 / 100)
    uint256 internal constant PCT = 100;
    uint256 internal constant FULL_CLOSE_BOUNTY = BORROWER_DEBT * LB_BPS / BPS; // 4500e6: the 6% cap binds at spot 100
    uint256 internal constant KYC_CHUNK = 10_000e6; // nominal repay of the direct KYC liquidation (O7 chunk size)
    uint256 internal constant DECOY_NAV = 50e18; // decoy pools priced far away from the fixed pool
    uint24 internal constant DECOY_FEE = 500;
    int24 internal constant DECOY_TICK_SPACING = 10;
    // entry points a caller-chosen route or recipient would need (R5: none may exist)
    string internal constant LIQUIDATE_WITH_KEY =
        "liquidate(address,uint256,uint256,(address,address,uint24,int24,address))";
    string internal constant LIQUIDATE_WITH_KEY_TO =
        "liquidate(address,uint256,uint256,(address,address,uint24,int24,address),address)";
    string internal constant LIQUIDATE_WITH_SIDE = "liquidate(address,uint256,uint256,bool)";
    string internal constant LIQUIDATE_TO = "liquidate(address,uint256,uint256,address)";
    string internal constant LIQUIDATE_WITH_DATA = "liquidate(address,uint256,uint256,bytes)";
    string internal constant RAW_SWAP = "swap((address,address,uint24,int24,address),(bool,int256,uint160),bytes)";
    // R5 "Firmas y estado": the whole external interface; NAV_FLOOR_BPS() is new in the spec (index 15)
    uint256 internal constant R5_ABI_SIZE = 16;
    uint256 internal constant R5_NAV_FLOOR_BPS_INDEX = 15;
    // opcodes read by the dispatcher scan (legacy codegen: foundry.toml pins via_ir = false, solc 0.8.26)
    uint8 internal constant OP_LT = 0x10;
    uint8 internal constant OP_EQ = 0x14;
    uint8 internal constant OP_CALLDATASIZE = 0x36;
    uint8 internal constant OP_JUMPI = 0x57;
    uint8 internal constant OP_PUSH0 = 0x5f;
    uint8 internal constant OP_PUSH1 = 0x60;
    uint8 internal constant OP_PUSH4 = 0x63;
    uint8 internal constant OP_PUSH32 = 0x7f;
    uint8 internal constant OP_DUP1 = 0x80;
    uint8 internal constant SELECTOR_BYTES = 4;
    bytes internal constant BARE_REVERT = hex"5b5f80fd"; // JUMPDEST PUSH0 DUP1 REVERT: revert with empty data
    uint8 internal constant CBOR_MAP_MIN = 0xa1; // solc metadata is a CBOR map of 1..3 entries
    uint8 internal constant CBOR_MAP_MAX = 0xa3;

    /// @dev Direct MiniLend liquidator that passed KYC: HOLDER on the RWA so it may receive seized collateral.
    address internal kycLiquidator = makeAddr("kycLiquidator");
    /// @dev Second unhealthy borrower, never vetoed; its wallet gets frozen (a freeze is not a veto).
    address internal borrower2 = makeAddr("borrower2");

    /// @notice One call observed through vm state-diff recording: outcome, exact revert data and what it reached.
    struct Attempt {
        bool ok;
        bytes ret;
        uint256 pmUnlocks;
        uint256 pmSwaps;
        uint256 hookBeforeSwaps;
        address hookSender; // `sender` the PoolManager handed to the hook's beforeSwap
        PoolKey hookKey; // pool the hook evaluated
    }

    /// @notice Every state-changing call a successful liquidation made on the PoolManager and the PA.
    struct FlowCalls {
        uint256 unlocks;
        uint256 swaps;
        uint256 takes;
        uint256 syncs;
        uint256 settles;
        uint256 otherPm; // mint, burn, settleFor, clear, modifyLiquidity, donate, transfer, initialize, ...
        uint256 revertedPm;
        uint256 wraps;
        uint256 otherPa;
        address unlockCaller;
        address swapCaller;
        address wrapCaller;
        bytes swapArgs;
        bytes takeArgs;
        bytes syncArgs;
        bytes wrapArgs;
    }

    struct Decoys {
        PoolKey hookless; // same currencies, fee and spacing, no hook
        PoolKey otherTier; // same currencies and canonical hook, another fee tier
        uint160 sqrtPriceX96;
    }

    // ================================================================== tests
    /// @notice R5 preflight, in order, before PoolManager.unlock: allowedHooks -> HookNotAllowed, swappingEnabled ->
    ///         SwappingDisabled, isAllowed(adapter, SWAP) -> Unauthorized. A revoked allowedWrapper is not a preflight
    ///         step: the real hook still rejects it, wrapped by the PoolManager. Every rejection rolls back exactly and
    ///         restoring the permissions restores the same liquidation.
    function test_adapterPreflightRevocations() public {
        crashNavAndAssertNavOnly();
        uint256 quote = _quoteFullClose(); // control: every permission active, the call succeeds

        // step 1: the deployed Labs hook never reads allowedHooks, so only the adapter can refuse a revoked hook
        _setHookAllowed(false);
        _assertPermissionState(false, true, true, true);
        _assertPreflightRejects(
            ISpecLiquidationAdapter.HookNotAllowed.selector, "R5 preflight 1: HookNotAllowed() raised by the adapter"
        );
        _setHookAllowed(true);

        // step 2: swapping disabled must be refused directly, not discovered inside the swap
        _setSwapping(false);
        _assertPermissionState(true, false, true, true);
        _assertPreflightRejects(
            ISpecLiquidationAdapter.SwappingDisabled.selector,
            "R5 preflight 2: SwappingDisabled() raised by the adapter, not the hook's WrappedError"
        );
        _setSwapping(true);

        _assertAdapterIsTheSwapSubject(); // step 3
        _assertPreflightOrder();
        _assertRevokedWrapperRejectedByHook();

        // every permission restored: the very same liquidation goes through
        _assertPermissionState(true, true, true, true);
        Liquidation memory r = liquidateViaAdapter();
        assertEq(r.bounty, quote, "restored permissions: bounty == control quote");
        assertEq(r.repaid, BORROWER_DEBT, "full close");
        assertEq(r.seized, CRASH_FULL_CLOSE_SEIZE, "seize at NAV 85");
        assertLiquidationSuccessPath(r);
        assertResidualSettledInMarket(r);
        assertAccountingIdentity();
        assertLedgerSums();
        assertBadDebtSum();
    }

    /// @notice O7 2:35-3:10: the same keeper call (borrower, maxUint256, minBounty 97% of the quote) simulates fine
    ///         with the wrapper active, fails after the issuer revokes only allowedWrapper(adapter) with the hook's
    ///         Unauthorized decoded from the PoolManager WrappedError, and succeeds again once the wrapper is restored.
    ///         The direct route fails identically before and after, so it is not the effect of the revocation.
    function test_wrapperRevocationChangesSameCall() public {
        crashNavAndAssertNavOnly();
        uint256 quote = _quoteFullClose();
        uint256 minBounty = quote * MIN_BOUNTY_PCT / PCT;
        bytes memory sameCall =
            abi.encodeCall(ISpecLiquidationAdapter.liquidate, (borrower, type(uint256).max, minBounty));

        assertEq(_simulate(sameCall), quote, "wrapper active: the fixed call re-simulates to the quote");
        _assertDirectRouteNotAllowlisted();

        _updateWrapperAndAssertOnlyChange(false);

        _assertHookRejectsRevokedWrapper(sameCall);
        _assertDirectRouteNotAllowlisted();

        _updateWrapperAndAssertOnlyChange(true);

        // the same call (liquidateViaAdapter sends liquidate(borrower, maxUint256, minBounty) from the keeper)
        Liquidation memory r = liquidateViaAdapter(borrower, type(uint256).max, minBounty);
        assertEq(r.bounty, quote, "wrapper restored: bounty == quote");
        assertGe(r.bounty, minBounty, "bounty meets the 97% floor");
        assertEq(r.repaid, BORROWER_DEBT, "full close");
        assertEq(r.seized, CRASH_FULL_CLOSE_SEIZE, "seize at NAV 85");
        assertEq(r.marketBadDebt, 0, "no write-off");
        assertEq(r.post.ledger.debt, 0, "debt closed");
        assertLiquidationSuccessPath(r);
        assertAccountingIdentityAnyVersion();
        assertLedgerSums();
    }

    /// @notice R3: only oracleAdmin sets or lifts the per-borrower veto; the guard opens previewLiquidation, so it
    ///         answers before Healthy/StaleNav and stops the adapter, a KYC liquidator calling MiniLend directly and
    ///         the non-KYC keeper alike. It binds only the vetoed borrower: a second unhealthy borrower whose wallet
    ///         the issuer froze is neither vetoed nor blocked, and the keeper closes it through the adapter while the
    ///         first stays vetoed. The veto is not a token freeze. Lifting it restores both liquidation routes.
    function test_liquidationBlocked_allRoutes() public {
        _setUpKycLiquidator();
        _setUpSecondBorrower();
        vm.expectRevert(abi.encodeWithSelector(ISpecMiniLend.Healthy.selector, HF_BASELINE));
        market.previewLiquidation(borrower, type(uint256).max); // control: no veto, a healthy position says Healthy

        _assertOnlyOracleAdminCanSetVeto(true);
        _oracleSetsVeto(true);
        _assertPreviewVetoed(); // healthy borrower: the veto answers first

        crashNavAndAssertNavOnly();
        _assertAllRoutesVetoed();
        _assertFreezeIsNotVeto(borrower2);
        _secondBorrowerClosedWhileFirstVetoed();

        vm.warp(market.navUpdatedAt() + NAV_STALENESS + 1);
        _assertPreviewVetoed(); // stale NAV: the veto still answers first
        _assertOnlyOracleAdminCanSetVeto(false);
        _assertVetoIsNotTokenFreeze();

        _oracleSetsVeto(false);
        vm.expectRevert(ISpecMiniLend.StaleNav.selector);
        market.previewLiquidation(borrower, type(uint256).max); // control: staleness was only masked by the veto
        setNavAsIssuer(CRASH_NAV);

        _kycLiquidatorRepaysChunkDirectly();
        _adapterClosesTheRest();
    }

    /// @notice R5 sell-only wrapper, in both currency orders: the deployed dispatcher routes only the R5 ABI, so no
    ///         entry point of any shape takes a PoolKey, direction, raw swap or recipient; the only PoolManager work is one unlock, one exact-in sale of the seize on the fixed pool,
    ///         one take of USDC, one sync of vRWA and one settle; the hook's Swap (told apart from the PoolManager's
    ///         Swap by emitter) carries the fixed poolId and sale deltas; no ERC-6909 claim exists at any point.
    function test_sellOnlyFixedPool() public {
        assertTrue(paIsCurrency0, "setUp builds the PA-is-currency0 order");
        _assertSellOnlyInFixedPool(true);
        _deployFixture(false, false);
        _assertSellOnlyInFixedPool(false);
    }

    // ================================================================== preflight (test_adapterPreflightRevocations)
    function _assertPreflightRejects(bytes4 expected, string memory why) private {
        World memory pre = captureWorld(borrower);
        Attempt memory a = _attemptAs(keeper, address(adapter), _fullCloseCall());
        assertFalse(a.ok, string.concat(why, ": call must revert"));
        assertEq(a.ret, abi.encodePacked(expected), why);
        assertEq(a.pmUnlocks, 0, string.concat(why, ": rejected before PoolManager.unlock"));
        assertEq(a.hookBeforeSwaps, 0, string.concat(why, ": the hook is never consulted"));
        assertWorldUnchanged(pre);
    }

    /// @dev Step 3: the subject is the adapter itself (msgSender() == this), whatever the keeper holds.
    function _assertAdapterIsTheSwapSubject() private {
        _setAdapterSwapFlag(false);
        _assertPermissionState(true, true, false, true);
        _assertPreflightRejects(
            ISpecLiquidationAdapter.Unauthorized.selector,
            "R5 preflight 3: Unauthorized() raised by the adapter, not the hook's WrappedError"
        );
        _setKeeperFlags(rwa.SWAP());
        assertTrue(pa.isAllowed(keeper, PermissionFlags.SWAP_ALLOWED), "keeper temporarily SWAP-allowed");
        _assertPreflightRejects(
            ISpecLiquidationAdapter.Unauthorized.selector, "R5 preflight 3: the keeper's SWAP flag does not stand in"
        );
        _setKeeperFlags(0);
        _setAdapterSwapFlag(true);
    }

    /// @dev All three revoked at once, then restored one by one: the first failing check in R5 order answers.
    function _assertPreflightOrder() private {
        _setHookAllowed(false);
        _setSwapping(false);
        _setAdapterSwapFlag(false);
        _assertPermissionState(false, false, false, true);
        _assertPreflightRejects(ISpecLiquidationAdapter.HookNotAllowed.selector, "R5 order: allowedHooks first");
        _setHookAllowed(true);
        _assertPreflightRejects(
            ISpecLiquidationAdapter.SwappingDisabled.selector, "R5 order: swappingEnabled checked second"
        );
        _setSwapping(true);
        _assertPreflightRejects(ISpecLiquidationAdapter.Unauthorized.selector, "R5 order: adapter SWAP checked third");
        _setAdapterSwapFlag(true);
    }

    /// @dev allowedWrapper is enforced by the real hook, not by the preflight: the revert is the hook's Unauthorized.
    function _assertRevokedWrapperRejectedByHook() private {
        _updateWrapperAndAssertOnlyChange(false);
        _assertHookRejectsRevokedWrapper(_fullCloseCall());
        _updateWrapperAndAssertOnlyChange(true);
    }

    /// @dev Preflight passes, the sale reaches the real hook, which rejects the adapter as wrapper; exact rollback.
    function _assertHookRejectsRevokedWrapper(bytes memory callData) private {
        World memory pre = captureWorld(borrower);
        Attempt memory a = _attemptAs(keeper, address(adapter), callData);
        assertFalse(a.ok, "wrapper revoked: the call fails");
        _assertWrappedHookError(a.ret, ILabsPermissionedHooksErrors.Unauthorized.selector);
        assertEq(a.pmUnlocks, 1, "adapter preflight passes: the call reaches PoolManager.unlock");
        assertEq(a.pmSwaps, 1, "the sale is attempted once");
        assertEq(a.hookBeforeSwaps, 1, "the real Labs hook evaluated the sale in beforeSwap");
        assertEq(a.hookSender, address(adapter), "hook evaluated the adapter as wrapper");
        assertEq(keccak256(abi.encode(a.hookKey)), keccak256(abi.encode(key)), "hook evaluated the fixed pool");
        assertWorldUnchanged(pre);
    }

    // ================================================================== wrapper revocation
    /// @dev O5 "revoke": the issuer changes only allowedWrapper(adapter); one AllowedWrapperUpdated and nothing else.
    function _updateWrapperAndAssertOnlyChange(bool allowed) private {
        World memory pre = captureWorld(borrower);
        vm.recordLogs();
        vm.prank(issuer);
        pa.updateAllowedWrapper(address(adapter), allowed);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "wrapper update emits exactly one log");
        assertEq(logs[0].emitter, address(pa), "AllowedWrapperUpdated comes from the PA");
        assertEq(logs[0].topics.length, 2, "AllowedWrapperUpdated has one indexed field");
        assertEq(logs[0].topics[0], PA_WRAPPER_TOPIC, "AllowedWrapperUpdated topic");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(adapter)))), "wrapper == adapter");
        assertEq(logs[0].data, abi.encode(allowed), "allowed flag");
        assertWorldUnchanged(pre);
        _assertPermissionState(true, true, true, allowed);
    }

    /// @dev Horizon-style direct call by the keeper: NotAllowlisted(keeper) from the RWA transfer rule, no effect.
    function _assertDirectRouteNotAllowlisted() private {
        World memory pre = captureWorld(borrower);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(MockRWA3643.NotAllowlisted.selector, keeper));
        market.liquidate(borrower, type(uint256).max, "");
        assertWorldUnchanged(pre);
    }

    /// @dev Full equality with the PoolManager's WrappedError, then the recursive decode the UI performs (O5).
    function _assertWrappedHookError(bytes memory ret, bytes4 hookError) private pure {
        bytes memory cause = abi.encodeWithSelector(hookError);
        assertEq(ret, hookWrappedError(cause), "revert == WrappedError(hook, beforeSwap, cause, HookCallFailed)");
        assertEq(bytes32(_selectorOf(ret)), bytes32(CustomRevert.WrappedError.selector), "outer: WrappedError");
        (address target, bytes4 callSel, bytes memory reason, bytes memory details) =
            abi.decode(_argsOf(ret), (address, bytes4, bytes, bytes));
        assertEq(target, address(HOOK), "decoded target: the canonical Labs hook");
        assertEq(bytes32(callSel), bytes32(IHooks.beforeSwap.selector), "decoded call: beforeSwap");
        assertEq(reason, cause, "decoded cause");
        assertEq(details, abi.encodeWithSelector(Hooks.HookCallFailed.selector), "decoded details: HookCallFailed");
    }

    // ================================================================== veto (test_liquidationBlocked_allRoutes)
    function _setUpKycLiquidator() private {
        uint16 holder = rwa.HOLDER(); // read before the prank
        vm.startPrank(issuer);
        rwa.setFlags(kycLiquidator, holder);
        usdc.mint(kycLiquidator, KYC_CHUNK);
        vm.stopPrank();
        vm.prank(kycLiquidator);
        usdc.approve(address(market), KYC_CHUNK);
        assertEq(rwa.flags(kycLiquidator), holder, "KYC liquidator: HOLDER");
        assertFalse(pa.isAllowed(kycLiquidator, PermissionFlags.SWAP_ALLOWED), "KYC liquidator: no pool access");
    }

    /// @dev Same path as the fixture borrower (HOLDER, deposit, borrow at LTV 75%), a tenth of the size.
    function _setUpSecondBorrower() private {
        uint16 holder = rwa.HOLDER(); // read before the prank
        vm.startPrank(issuer);
        rwa.setFlags(borrower2, holder);
        rwa.mint(borrower2, B2_COLLATERAL);
        vm.stopPrank();
        vm.startPrank(borrower2);
        rwa.approve(address(market), B2_COLLATERAL);
        market.depositCollateral(B2_COLLATERAL);
        market.borrow(B2_DEBT);
        vm.stopPrank();
        (uint256 coll, uint256 debt) = market.positions(borrower2);
        assertEq(coll, B2_COLLATERAL, "borrower2 collateral");
        assertEq(debt, B2_DEBT, "borrower2 debt");
        assertEq(market.healthFactor(borrower2), HF_BASELINE, "borrower2: same HF as the fixture borrower");
        assertEq(usdc.balanceOf(borrower2), B2_DEBT, "borrower2 holds the borrowed USDC");
        _assertTwoBorrowerSums();
    }

    function _assertOnlyOracleAdminCanSetVeto(bool blocked) private {
        address[7] memory others = [keeper, mm, borrower, borrower2, lender, kycLiquidator, address(adapter)];
        World memory pre = captureWorld(borrower);
        bytes memory callData = abi.encodeCall(ISpecMiniLend.setLiquidationBlocked, (borrower, blocked));
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            (bool ok, bytes memory ret) = address(market).call(callData);
            assertFalse(ok, "R3 setLiquidationBlocked: a non-oracleAdmin call must revert");
            assertEq(
                ret,
                abi.encodeWithSelector(ISpecMiniLend.NotOracle.selector),
                "R3 setLiquidationBlocked(address,bool) exists and rejects non-oracleAdmin with NotOracle()"
            );
        }
        assertWorldUnchanged(pre);
    }

    /// @dev Only the veto flag of the fixture borrower moves (borrower2's world, flag included, stays equal);
    ///      exactly one LiquidationBlockedSet(borrower, blocked) from MiniLend.
    function _oracleSetsVeto(bool blocked) private {
        World memory expected = captureWorld(borrower);
        World memory other = captureWorld(borrower2);
        expected.ledger.liquidationBlocked = blocked;
        vm.recordLogs();
        vm.prank(issuer);
        ISpecMiniLend(address(market)).setLiquidationBlocked(borrower, blocked);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "veto update emits exactly one log");
        assertEq(logs[0].emitter, address(market), "LiquidationBlockedSet comes from MiniLend");
        assertEq(logs[0].topics.length, 2, "LiquidationBlockedSet has one indexed field");
        assertEq(logs[0].topics[0], LIQUIDATION_BLOCKED_SET_TOPIC, "LiquidationBlockedSet topic");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(borrower))), "veto borrower");
        assertEq(logs[0].data, abi.encode(blocked), "veto flag");
        assertEq(specMarket().liquidationBlocked(borrower), blocked, "liquidationBlocked(borrower)");
        assertFalse(specMarket().liquidationBlocked(borrower2), "the veto is per borrower: borrower2 not blocked");
        assertWorldUnchanged(expected);
        assertWorldUnchanged(other, borrower2);
    }

    function _vetoedError() private view returns (bytes memory) {
        return abi.encodeWithSelector(ISpecMiniLend.LiquidationBlocked.selector, borrower);
    }

    function _assertPreviewVetoed() private {
        vm.expectRevert(_vetoedError());
        market.previewLiquidation(borrower, type(uint256).max);
    }

    /// @dev Unhealthy borrower, fresh NAV: preview, adapter, KYC direct and keeper direct all get the veto, unwrapped.
    function _assertAllRoutesVetoed() private {
        World memory pre = captureWorld(borrower);
        World memory other = captureWorld(borrower2);
        _assertPreviewVetoed();

        Attempt memory a = _attemptAs(keeper, address(adapter), _fullCloseCall());
        assertFalse(a.ok, "adapter route: call must revert");
        assertEq(a.ret, _vetoedError(), "adapter route: LiquidationBlocked(borrower), not wrapped");
        assertEq(a.pmSwaps, 0, "adapter route: vetoed before any sale");
        assertEq(a.hookBeforeSwaps, 0, "adapter route: the hook is never consulted");

        vm.prank(kycLiquidator);
        vm.expectRevert(_vetoedError());
        market.liquidate(borrower, KYC_CHUNK, "");

        vm.prank(keeper); // the veto answers before the RWA transfer rule could say NotAllowlisted(keeper)
        vm.expectRevert(_vetoedError());
        market.liquidate(borrower, type(uint256).max, "");

        assertWorldUnchanged(pre);
        assertWorldUnchanged(other, borrower2);
        assertEq(usdc.balanceOf(kycLiquidator), KYC_CHUNK, "KYC liquidator keeps its USDC");
        assertEq(rwa.balanceOf(kycLiquidator), 0, "KYC liquidator received no RWA");
    }

    /// @dev R3 per borrower: with the fixture borrower vetoed, `who` previews exactly. R3 vs R1: the issuer then
    ///      freezes that wallet and nothing else happens; one FrozenSet from the RWA, no LiquidationBlockedSet,
    ///      liquidationBlocked(who) stays false and the position still previews exactly.
    function _assertFreezeIsNotVeto(address who) private {
        _assertPreviewsExactly(who, "the veto is per borrower: an unvetoed unhealthy borrower previews");
        World memory pre = captureWorld(borrower);
        World memory preWho = captureWorld(who);
        vm.recordLogs();
        vm.prank(issuer);
        rwa.setFrozen(who, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "freeze emits exactly one log");
        assertEq(logs[0].emitter, address(rwa), "FrozenSet comes from the RWA, MiniLend emits nothing");
        assertEq(logs[0].topics[0], FROZEN_SET_TOPIC, "FrozenSet topic");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(who))), "frozen wallet");
        assertEq(logs[0].data, abi.encode(true), "frozen flag");
        assertTrue(rwa.frozen(who), "wallet frozen");
        assertFalse(specMarket().liquidationBlocked(who), "a frozen wallet does not set liquidationBlocked");
        assertTrue(specMarket().liquidationBlocked(borrower), "the fixture borrower stays vetoed");
        assertWorldUnchanged(pre);
        assertWorldUnchanged(preWho, who);
        _assertPreviewsExactly(who, "a freeze is not a veto: the frozen, unvetoed borrower still previews");
    }

    /// @dev Named assertion instead of a raw revert: full close (HF <= 0.95) and seize at NAV 85.
    function _assertPreviewsExactly(address who, string memory why) private view {
        (, uint256 debt) = market.positions(who);
        (bool ok, bytes memory ret) =
            address(market).staticcall(abi.encodeCall(ISpecMiniLend.previewLiquidation, (who, type(uint256).max)));
        assertTrue(ok, string.concat(why, " (previewLiquidation must not revert)"));
        (uint256 repay, uint256 seize) = abi.decode(ret, (uint256, uint256));
        assertEq(repay, debt, string.concat(why, ": repay == full debt"));
        assertEq(seize, expectedSeize(debt, CRASH_NAV), string.concat(why, ": seize at NAV 85"));
    }

    /// @dev Per-borrower veto: with the fixture borrower vetoed, the keeper's adapter call closes frozen borrower2
    ///      in full; the vetoed position does not move and stays vetoed.
    function _secondBorrowerClosedWhileFirstVetoed() private {
        (uint256 coll1, uint256 debt1) = market.positions(borrower);
        uint256 seize = expectedSeize(B2_DEBT, CRASH_NAV);
        Liquidation memory r = liquidateViaAdapter(borrower2, type(uint256).max, 0);
        assertEq(r.repaid, B2_DEBT, "borrower2: full close");
        assertEq(r.seized, seize, "borrower2: seize at NAV 85");
        assertEq(r.bounty, B2_DEBT * LB_BPS / BPS, "borrower2: bounty capped at 6% of the repaid 7500");
        assertEq(r.marketBadDebt, 0, "borrower2: collateral remains, no write-off");
        assertEq(r.post.ledger.debt, 0, "borrower2: debt closed");
        assertEq(r.post.ledger.collateral, B2_COLLATERAL - seize, "borrower2: collateral -= seize");
        assertLiquidationSuccessPath(r);
        assertResidualSettledInMarket(r);
        assertTrue(rwa.frozen(borrower2), "borrower2 wallet frozen throughout");
        (uint256 coll1After, uint256 debt1After) = market.positions(borrower);
        assertEq(coll1After, coll1, "vetoed borrower: collateral untouched");
        assertEq(debt1After, debt1, "vetoed borrower: debt untouched");
        assertTrue(specMarket().liquidationBlocked(borrower), "fixture borrower still vetoed");
        _assertPreviewVetoed();
        assertAccountingIdentity();
        _assertTwoBorrowerSums();
        _assertTwoBorrowerBadDebtSum();
    }

    /// @dev R3 ledger sums with both borrowers (the base helpers assume the single fixture borrower).
    function _assertTwoBorrowerSums() private view {
        (uint256 c1, uint256 d1) = market.positions(borrower);
        (uint256 c2, uint256 d2) = market.positions(borrower2);
        assertEq(market.totalDebt(), d1 + d2, "totalDebt == sum of debt");
        assertEq(market.totalCollateral(), c1 + c2, "totalCollateral == sum of collateral");
        assertEq(rwa.balanceOf(address(market)), market.totalCollateral(), "RWA(market) == totalCollateral");
    }

    function _assertTwoBorrowerBadDebtSum() private view {
        assertEq(
            market.totalBadDebt(), specBadDebtOf(borrower) + specBadDebtOf(borrower2), "totalBadDebt == sum badDebtOf"
        );
    }

    /// @dev R1/R3: the veto is a MiniLend flag, not a wallet freeze, pause or flag change on the token.
    function _assertVetoIsNotTokenFreeze() private view {
        assertTrue(specMarket().liquidationBlocked(borrower), "veto still active");
        assertFalse(rwa.frozen(borrower), "veto does not freeze the borrower wallet");
        assertFalse(rwa.paused(), "veto does not pause the token");
        assertEq(rwa.flags(borrower), rwa.HOLDER(), "borrower flags untouched");
    }

    /// @dev Veto lifted: the KYC liquidator's direct route works again, exactly as R3 prices it.
    function _kycLiquidatorRepaysChunkDirectly() private {
        World memory pre = captureWorld(borrower);
        uint256 seize = expectedSeize(KYC_CHUNK, CRASH_NAV);
        vm.recordLogs();
        vm.prank(kycLiquidator);
        (uint256 repaid, uint256 seized) = market.liquidate(borrower, KYC_CHUNK, "");
        _assertOnlyMarketLiquidated(vm.getRecordedLogs(), kycLiquidator, KYC_CHUNK, seize);
        World memory post = captureWorld(borrower);
        assertEq(repaid, KYC_CHUNK, "direct route restored: repaid");
        assertEq(seized, seize, "direct route restored: seized");
        assertEq(rwa.balanceOf(kycLiquidator), seize, "KYC liquidator receives the seize");
        assertEq(usdc.balanceOf(kycLiquidator), 0, "KYC liquidator paid the chunk");
        assertEq(post.bal.marketUsdc, pre.bal.marketUsdc + KYC_CHUNK, "market USDC += chunk");
        assertEq(post.bal.marketRwa, pre.bal.marketRwa - seize, "market RWA -= seize");
        assertEq(post.ledger.debt, pre.ledger.debt - KYC_CHUNK, "debt -= chunk");
        assertEq(post.ledger.collateral, pre.ledger.collateral - seize, "collateral -= seize");
        assertEq(post.ledger.totalSupplyAssets, pre.ledger.totalSupplyAssets, "lenders untouched");
        assertEq(post.ledger.totalBadDebt, pre.ledger.totalBadDebt, "no write-off");
        assertEq(post.bal.keeperUsdc, pre.bal.keeperUsdc, "keeper untouched");
        assertAccountingIdentity();
        _assertTwoBorrowerSums();
    }

    /// @dev Veto lifted: the adapter route closes the remaining 65000 USDC in one keeper call.
    function _adapterClosesTheRest() private {
        uint256 rest = BORROWER_DEBT - KYC_CHUNK;
        Liquidation memory r = liquidateViaAdapter();
        assertEq(r.repaid, rest, "adapter route restored: full close of the rest");
        assertEq(r.seized, expectedSeize(rest, CRASH_NAV), "adapter route restored: seize at NAV 85");
        assertEq(r.marketBadDebt, 0, "collateral remains: no write-off");
        assertEq(r.post.ledger.debt, 0, "debt closed");
        assertLiquidationSuccessPath(r);
        assertResidualSettledInMarket(r);
        assertAccountingIdentity();
        _assertTwoBorrowerSums();
        _assertTwoBorrowerBadDebtSum();
    }

    function _assertOnlyMarketLiquidated(Vm.Log[] memory logs, address liquidator, uint256 repaid, uint256 seized)
        private
        view
    {
        uint256 n;
        Vm.Log memory only;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(market)) continue;
            n++;
            only = logs[i];
        }
        assertEq(n, 1, "direct liquidation: MiniLend emits exactly one event");
        assertEq(only.topics[0], MARKET_LIQUIDATED_TOPIC, "MiniLend Liquidated");
        assertEq(only.topics[1], bytes32(uint256(uint160(liquidator))), "Liquidated.liquidator");
        assertEq(only.topics[2], bytes32(uint256(uint160(borrower))), "Liquidated.borrower");
        assertEq(only.data, abi.encode(repaid, seized, uint256(0)), "Liquidated(repaid, seized, badDebt 0)");
    }

    // ================================================================== sell-only fixed pool (test_sellOnlyFixedPool)
    function _assertSellOnlyInFixedPool(bool paIs0) private {
        assertEq(paIsCurrency0, paIs0, "requested currency order built");
        _assertPinnedPoolKey();
        Decoys memory d = _initializeDecoyPools();
        crashNavAndAssertNavOnly();
        uint256 quote = _quoteFullClose(); // the fixed call succeeds in exactly this state (simulated, rolled back),
        _assertNoCallerChosenRoute(d); // so a route/recipient entry point would succeed here too if it existed
        PoolState memory before = captureWorld(borrower).pool;

        vm.startStateDiffRecording();
        Liquidation memory r = liquidateViaAdapter();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        assertEq(r.bounty, quote, "the fixed call pays the quote simulated before the probes");
        assertLiquidationSuccessPath(r);
        assertEq(r.repaid, BORROWER_DEBT, "full close");
        assertEq(r.seized, CRASH_FULL_CLOSE_SEIZE, "seize at NAV 85");
        _assertFlowCalls(_tallyFlowCalls(accesses), r);
        _assertSaleOnFixedPool(r, before);
        _assertTokenPaths(r);
        _assertDecoysUntouched(d);
        assertAccountingIdentityAnyVersion();
        assertLedgerSums();
    }

    function _assertPinnedPoolKey() private view {
        PoolKey memory k = specAdapter().poolKey();
        (address c0, address c1) = paIsCurrency0 ? (address(pa), address(usdc)) : (address(usdc), address(pa));
        assertEq(Currency.unwrap(k.currency0), c0, "poolKey currency0: sorted PA/USDC");
        assertEq(Currency.unwrap(k.currency1), c1, "poolKey currency1: sorted PA/USDC");
        assertEq(uint256(k.fee), 3_000, "poolKey fee 3000");
        assertEq(int256(k.tickSpacing), 60, "poolKey tickSpacing 60");
        assertEq(address(k.hooks), address(HOOK), "poolKey hook: canonical Labs hook");
        assertEq(PoolId.unwrap(k.toId()), PoolId.unwrap(poolId), "adapter pool == fixture pool");
        assertEq(specAdapter().rwaIsCurrency0(), paIsCurrency0, "adapter orientation");
        assertEq(specAdapter().msgSender(), address(adapter), "the adapter itself is the seller the hook checks");
    }

    /// @dev Pools anyone can open next to the fixed one; a caller-chosen route would need one of them.
    function _initializeDecoyPools() private returns (Decoys memory d) {
        d.hookless = PoolKey(key.currency0, key.currency1, FEE, TICK_SPACING, IHooks(address(0)));
        d.otherTier = PoolKey(key.currency0, key.currency1, DECOY_FEE, DECOY_TICK_SPACING, HOOK);
        d.sqrtPriceX96 = sqrtPriceX96ForNav(DECOY_NAV);
        vm.startPrank(keeper);
        PM.initialize(d.hookless, d.sqrtPriceX96);
        PM.initialize(d.otherTier, d.sqrtPriceX96);
        vm.stopPrank();
        _assertDecoysUntouched(d);
    }

    function _assertDecoysUntouched(Decoys memory d) private view {
        PoolKey[2] memory decoys = [d.hookless, d.otherTier];
        for (uint256 i; i < decoys.length; i++) {
            PoolId id = decoys[i].toId();
            assertTrue(PoolId.unwrap(id) != PoolId.unwrap(poolId), "decoy is another pool");
            (uint160 p,,,) = PM.getSlot0(id);
            assertEq(p, d.sqrtPriceX96, "decoy pool price untouched");
            assertEq(PM.getLiquidity(id), 0, "decoy pool liquidity untouched");
        }
    }

    /// @dev R5 "sin parámetros de ruta ni receptor elegidos por el keeper", probed on the unhealthy borrower with every
    ///      permission active, where liquidate(borrower, max, 0) succeeds: each variant, including ones naming the
    ///      fixed pool and the sale side, must hit no selector (empty revert data), reach no PoolManager and move
    ///      nothing. The callback answers NotPoolManager() to anyone else.
    function _assertNoCallerChosenRoute(Decoys memory d) private {
        _assertAdapterInterfaceIsR5(); // every entry point, whatever its shape
        uint256 max = type(uint256).max;
        bool sell = paIsCurrency0;
        uint160 farLimit = sell ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        // forge-lint: disable-next-line(unsafe-typecast) -- CRASH_FULL_CLOSE_SEIZE < 2^255
        SwapParams memory sale = SwapParams(sell, -int256(CRASH_FULL_CLOSE_SEIZE), farLimit);
        bytes memory route = abi.encode(key, sell, mm);
        _assertNoEntryPoint(0, abi.encodeWithSignature(LIQUIDATE_WITH_KEY, borrower, max, 0, key), "PoolKey = fixed");
        _assertNoEntryPoint(0, abi.encodeWithSignature(LIQUIDATE_WITH_KEY, borrower, max, 0, d.otherTier), "decoy key");
        _assertNoEntryPoint(
            0, abi.encodeWithSignature(LIQUIDATE_WITH_KEY_TO, borrower, max, 0, key, mm), "fixed PoolKey + recipient"
        );
        _assertNoEntryPoint(0, abi.encodeWithSignature(LIQUIDATE_WITH_SIDE, borrower, max, 0, sell), "side = sale");
        _assertNoEntryPoint(0, abi.encodeWithSignature(LIQUIDATE_WITH_SIDE, borrower, max, 0, !sell), "side = buy");
        _assertNoEntryPoint(0, abi.encodeWithSignature(LIQUIDATE_TO, borrower, max, 0, mm), "recipient");
        _assertNoEntryPoint(0, abi.encodeWithSignature(LIQUIDATE_WITH_DATA, borrower, max, 0, route), "route bytes");
        _assertNoEntryPoint(0, abi.encodeWithSignature(RAW_SWAP, key, sale, ""), "raw swap on the fixed pool");
        _assertNoEntryPoint(0, "", "empty calldata (fallback/receive)");
        _assertNoEntryPoint(1, "", "empty calldata with 1 wei (payable receive)");
        _assertForgedCallbackRejected(abi.encode(borrower, max, uint256(0), keeper));
        _assertForgedCallbackRejected(abi.encode(borrower, max, uint256(0), mm));
    }

    function _assertNoEntryPoint(uint256 value, bytes memory callData, string memory why) private {
        World memory pre = captureWorld(borrower);
        uint256 keeperEth = keeper.balance;
        Attempt memory a = _attemptAs(keeper, address(adapter), value, callData);
        assertFalse(a.ok, string.concat("R5: no caller-chosen route/recipient entry point: ", why));
        assertEq(a.ret.length, 0, string.concat(why, ": no matching selector, no fallback (empty revert data)"));
        assertEq(a.pmUnlocks, 0, string.concat(why, ": never reaches PoolManager.unlock"));
        assertEq(keeper.balance, keeperEth, string.concat(why, ": keeper ETH unchanged"));
        assertEq(address(adapter).balance, 0, string.concat(why, ": adapter holds no ETH"));
        assertWorldUnchanged(pre);
    }

    function _assertForgedCallbackRejected(bytes memory payload) private {
        World memory pre = captureWorld(borrower);
        Attempt memory a =
            _attemptAs(keeper, address(adapter), 0, abi.encodeCall(ISpecLiquidationAdapter.unlockCallback, (payload)));
        assertFalse(a.ok, "forged unlockCallback must revert");
        assertEq(a.ret, abi.encodePacked(ISpecLiquidationAdapter.NotPoolManager.selector), "NotPoolManager()");
        assertEq(a.pmUnlocks + a.pmSwaps + a.hookBeforeSwaps, 0, "forged callback reaches no PoolManager or hook");
        assertWorldUnchanged(pre);
    }

    /// @dev R5 flow on the PoolManager and PA, nothing else: unlock, exact-in sale, take(USDC), sync(vRWA), settle,
    ///      one wrapToPoolManager(seize); never mint/burn/settleFor/clear/modifyLiquidity/donate.
    function _assertFlowCalls(FlowCalls memory c, Liquidation memory r) private view {
        assertEq(c.unlocks, 1, "one PoolManager.unlock");
        assertEq(c.unlockCaller, address(adapter), "unlock by the adapter");
        assertEq(c.swaps, 1, "one PoolManager.swap");
        assertEq(c.swapCaller, address(adapter), "swap by the adapter");
        assertEq(c.takes, 1, "one PoolManager.take");
        assertEq(c.syncs, 1, "one PoolManager.sync");
        assertEq(c.settles, 1, "one PoolManager.settle");
        assertEq(c.otherPm, 0, "no other PoolManager call: no 6909 mint/burn, settleFor, clear, liquidity or donate");
        assertEq(c.revertedPm, 0, "no reverted PoolManager call inside a successful liquidation");
        assertEq(c.wraps, 1, "one wrapToPoolManager");
        assertEq(c.wrapCaller, address(adapter), "wrap by the adapter");
        assertEq(c.otherPa, 0, "no other state-changing PA call");

        (PoolKey memory k, SwapParams memory p, bytes memory hookData) =
            abi.decode(c.swapArgs, (PoolKey, SwapParams, bytes));
        assertEq(keccak256(abi.encode(k)), keccak256(abi.encode(key)), "swap on the fixed PoolKey");
        assertEq(p.zeroForOne, paIsCurrency0, "swap direction: vRWA in, USDC out");
        assertEq(p.amountSpecified, -int256(r.seized), "exact input == seize");
        assertEq(hookData.length, 0, "no hookData");

        (Currency takeCurrency, address takeTo, uint256 takeAmount) =
            abi.decode(c.takeArgs, (Currency, address, uint256));
        assertEq(Currency.unwrap(takeCurrency), address(usdc), "take USDC only, never vRWA");
        assertEq(takeTo, address(adapter), "take to the adapter");
        assertEq(takeAmount, r.proceeds, "take == proceeds");
        assertEq(Currency.unwrap(abi.decode(c.syncArgs, (Currency))), address(pa), "sync vRWA");
        assertEq(abi.decode(c.wrapArgs, (uint256)), r.seized, "wrap exactly the seize");
    }

    /// @dev Both Swap events share one signature: exactly one from the PoolManager and one from the hook, same pool,
    ///      same sender and deltas; the pool moved in the sale direction and kept its liquidity.
    function _assertSaleOnFixedPool(Liquidation memory r, PoolState memory before) private view {
        (Vm.Log memory pmSwap, Vm.Log memory hookSwap) = _poolManagerAndHookSwaps(r.logs);
        assertEq(pmSwap.topics[1], PoolId.unwrap(poolId), "PoolManager Swap on the fixed pool");
        assertEq(pmSwap.topics[2], bytes32(uint256(uint160(address(adapter)))), "PoolManager Swap sender == adapter");
        assertEq(hookSwap.topics[1], pmSwap.topics[1], "hook and PoolManager Swap: same poolId");
        assertEq(hookSwap.topics[2], pmSwap.topics[2], "hook and PoolManager Swap: same sender");
        (int128 pm0, int128 pm1,,,,) = abi.decode(pmSwap.data, (int128, int128, uint160, uint128, int24, uint24));
        assertEq(int256(pm0), int256(r.hookAmount0), "hook amount0 == PoolManager amount0");
        assertEq(int256(pm1), int256(r.hookAmount1), "hook amount1 == PoolManager amount1");

        (,, uint160 sqrtP, uint128 liq, int24 tick, uint24 fee) =
            abi.decode(hookSwap.data, (int128, int128, uint160, uint128, int24, uint24));
        assertEq(sqrtP, r.post.pool.sqrtPriceX96, "hook Swap price == post-sale slot0");
        assertEq(int256(tick), int256(r.post.pool.tick), "hook Swap tick == post-sale slot0");
        assertEq(uint256(liq), uint256(L_UNSIGNED), "hook Swap liquidity == L");
        assertEq(uint256(fee), uint256(FEE), "hook Swap fee == 3000");
        if (paIsCurrency0) assertLt(sqrtP, before.sqrtPriceX96, "vRWA sold: price of currency0 falls");
        else assertGt(sqrtP, before.sqrtPriceX96, "vRWA sold: price of currency1 falls");
        assertEq(uint256(r.post.pool.liquidity), uint256(before.liquidity), "a sale leaves L");
        assertEq(uint256(r.post.pool.deskLiquidity), uint256(before.deskLiquidity), "MM position untouched");
    }

    /// @dev Filters by emitter, not only topic0: the PoolManager and the hook emit the same Swap signature.
    function _poolManagerAndHookSwaps(Vm.Log[] memory logs)
        private
        pure
        returns (Vm.Log memory pmSwap, Vm.Log memory hookSwap)
    {
        uint256 sameTopic;
        uint256 pmLogs;
        uint256 claimLogs;
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory lg = logs[i];
            if (lg.emitter == address(PM)) pmLogs++;
            if (lg.topics.length == 0) continue;
            if (lg.emitter == address(PM) && lg.topics[0] == ERC6909_TRANSFER_TOPIC) claimLogs++;
            if (lg.topics[0] != HOOK_SWAP_TOPIC) continue;
            sameTopic++;
            if (lg.emitter == address(PM)) pmSwap = lg;
            if (lg.emitter == address(HOOK)) hookSwap = lg;
        }
        assertEq(sameTopic, 2, "Swap topic: one PoolManager log and one hook log");
        assertEq(pmLogs, 1, "the PoolManager emits only its Swap");
        assertEq(claimLogs, 0, "no ERC-6909 Transfer (claim mint/burn)");
        assertEq(pmSwap.emitter, address(PM), "PoolManager Swap found");
        assertEq(hookSwap.emitter, address(HOOK), "hook Swap found");
    }

    /// @dev Exact, ordered ERC-20 movements of the flow: raw RWA only market -> adapter -> PA; vRWA only minted to
    ///      the PoolManager; USDC taken once, repaid, bounty to the keeper, then the residual leaves the adapter to
    ///      MiniLend (R5 step 8) or, on the snapshot, to the borrower. Nothing else moves.
    function _assertTokenPaths(Liquidation memory r) private view {
        assertEq(
            _moves(r.logs, address(rwa)),
            abi.encodePacked(address(market), address(adapter), r.seized, address(adapter), address(pa), r.seized),
            "raw RWA moves exactly market -> adapter -> PA, seize each"
        );
        assertEq(
            _moves(r.logs, address(pa)),
            abi.encodePacked(address(0), address(PM), r.seized),
            "vRWA: one mint of exactly the seize to the PoolManager"
        );
        assertGt(r.residual, 0, "the fixture sale leaves a residual");
        bytes memory usdcHead =
            abi.encodePacked(address(PM), address(adapter), r.proceeds, address(adapter), address(market), r.repaid);
        usdcHead = abi.encodePacked(usdcHead, address(adapter), keeper, r.bounty);
        bytes32 got = keccak256(_moves(r.logs, address(usdc)));
        bool toMarket = got == keccak256(abi.encodePacked(usdcHead, address(adapter), address(market), r.residual));
        bool toBorrower = got == keccak256(abi.encodePacked(usdcHead, address(adapter), borrower, r.residual));
        assertTrue(toMarket || toBorrower, "USDC: take, repay, bounty, then only the residual leaves the adapter");
    }

    /// @dev Packed (from, to, amount) of every ERC-20 Transfer the token emitted, in log order.
    function _moves(Vm.Log[] memory logs, address token) private pure returns (bytes memory seq) {
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory lg = logs[i];
            if (lg.emitter != token || lg.topics.length != 3 || lg.topics[0] != ERC20_TRANSFER_TOPIC) continue;
            seq = abi.encodePacked(seq, uint160(uint256(lg.topics[1])), uint160(uint256(lg.topics[2])), lg.data);
        }
    }

    // ================================================================== adapter interface (bytecode)
    /// @dev R5 "sin parámetros de ruta ni receptor elegidos por el keeper" / "No acepta PoolKey del caller" over the
    ///      WHOLE interface, not a sample of shapes. Reads the deployed runtime code: every selector solc's dispatcher
    ///      compares calldata against must be an R5 function (none of which takes a PoolKey, direction, recipient or
    ///      route), each R5 function the spec keeps must be routed exactly once (so the scan provably reads the
    ///      dispatcher), NAV_FLOOR_BPS() may be absent (snapshot) or routed once (spec), and calldata shorter than a
    ///      selector must hit a bare revert, i.e. there is no fallback() and no receive() either.
    function _assertAdapterInterfaceIsR5() private view {
        bytes memory code = address(adapter).code;
        uint256 end = _codeEndBeforeMetadata(code);
        bytes4[] memory routed = _dispatcherSelectors(code, end);
        string[R5_ABI_SIZE] memory abiR5 = _r5Abi();
        uint256 inR5;
        for (uint256 j; j < R5_ABI_SIZE; j++) {
            uint256 hits = _countSelector(routed, bytes4(keccak256(bytes(abiR5[j]))));
            if (j == R5_NAV_FLOOR_BPS_INDEX) assertLe(hits, 1, "dispatcher routes NAV_FLOOR_BPS() at most once");
            else assertEq(hits, 1, string.concat("dispatcher routes the kept R5 function ", abiR5[j], " once"));
            inR5 += hits;
        }
        for (uint256 i; i < routed.length; i++) {
            assertTrue(
                _isR5Selector(abiR5, routed[i]),
                string.concat(
                    "R5: adapter entry point outside the R5 ABI (caller-chosen route/recipient/setter?): ",
                    vm.toString(abi.encodePacked(routed[i]))
                )
            );
        }
        assertEq(routed.length, inR5, "every dispatcher selector is an R5 function");
        _assertShortCalldataBareRevert(code, end);
    }

    /// @dev CONTRACTS.md R5 "Firmas y estado", verbatim; poolKey() returns a PoolKey but no function accepts one.
    function _r5Abi() private pure returns (string[R5_ABI_SIZE] memory) {
        return [
            "liquidate(address,uint256,uint256)",
            "unlockCallback(bytes)",
            "msgSender()",
            "poolKey()",
            "poolManager()",
            "permissionsAdapter()",
            "rwa()",
            "usdc()",
            "market()",
            "hooks()",
            "fee()",
            "tickSpacing()",
            "rwaIsCurrency0()",
            "lbBps()",
            "keeperBps()",
            "NAV_FLOOR_BPS()"
        ];
    }

    function _isR5Selector(string[R5_ABI_SIZE] memory abiR5, bytes4 sel) private pure returns (bool) {
        for (uint256 j; j < R5_ABI_SIZE; j++) {
            if (bytes4(keccak256(bytes(abiR5[j]))) == sel) return true;
        }
        return false;
    }

    function _countSelector(bytes4[] memory list, bytes4 sel) private pure returns (uint256 n) {
        for (uint256 i; i < list.length; i++) {
            if (list[i] == sel) n++;
        }
    }

    /// @dev solc appends CBOR metadata and its 2-byte length; the scan stops before it so hash bytes never parse
    ///      as opcodes (the hash changes with every source edit).
    function _codeEndBeforeMetadata(bytes memory code) private pure returns (uint256 end) {
        assertGt(code.length, 2, "adapter has runtime code");
        uint256 metaLen = (uint256(uint8(code[code.length - 2])) << 8) | uint8(code[code.length - 1]);
        assertLt(metaLen + 2, code.length, "CBOR metadata length fits inside the runtime code");
        end = code.length - metaLen - 2;
        uint8 map = uint8(code[end]);
        assertTrue(map >= CBOR_MAP_MIN && map <= CBOR_MAP_MAX, "solc CBOR metadata map located");
    }

    function _dispatcherSelectors(bytes memory code, uint256 end) private pure returns (bytes4[] memory routed) {
        routed = new bytes4[](_scanDispatcher(code, end, new bytes4[](0)));
        _scanDispatcher(code, end, routed);
    }

    /// @dev Walks opcodes up to `end` (PUSH immediates skipped); counts the selector compares and writes their
    ///      selectors into `out` while it has room.
    function _scanDispatcher(bytes memory code, uint256 end, bytes4[] memory out) private pure returns (uint256 n) {
        for (uint256 p; p < end; p = _nextOp(code, p)) {
            (bool hit, bytes4 sel) = _selectorCompareAt(code, p, end);
            if (!hit) continue;
            if (n < out.length) out[n] = sel;
            n++;
        }
    }

    function _nextOp(bytes memory code, uint256 p) private pure returns (uint256) {
        uint8 op = uint8(code[p]);
        return op >= OP_PUSH1 && op <= OP_PUSH32 ? p + 1 + (op - OP_PUSH0) : p + 1;
    }

    /// @dev solc's per-function compare: DUP1, PUSH0..PUSH4 selector (a leading-zero selector is pushed shorter),
    ///      EQ, PUSH1..PUSH4 jump tag, JUMPI.
    function _selectorCompareAt(bytes memory code, uint256 p, uint256 end) private pure returns (bool, bytes4) {
        if (p + 1 >= end || uint8(code[p]) != OP_DUP1) return (false, bytes4(0));
        uint8 push = uint8(code[p + 1]);
        if (push < OP_PUSH0 || push > OP_PUSH4) return (false, bytes4(0));
        uint256 width = push - OP_PUSH0;
        uint256 eq = p + 2 + width;
        if (eq + 1 >= end || uint8(code[eq]) != OP_EQ) return (false, bytes4(0));
        uint8 tagPush = uint8(code[eq + 1]);
        if (tagPush < OP_PUSH1 || tagPush > OP_PUSH4) return (false, bytes4(0));
        uint256 jumpi = eq + 2 + (tagPush - OP_PUSH0);
        if (jumpi >= end || uint8(code[jumpi]) != OP_JUMPI) return (false, bytes4(0));
        // forge-lint: disable-next-line(unsafe-typecast) -- width <= 4, the immediate fits in 32 bits
        return (true, bytes4(uint32(_immediate(code, p + 2, width))));
    }

    /// @dev `PUSH1 4 CALLDATASIZE LT PUSHn tag JUMPI` sends calldata shorter than a selector to `tag`; without
    ///      fallback() and receive() solc places a bare `JUMPDEST PUSH0 DUP1 REVERT` there.
    function _assertShortCalldataBareRevert(bytes memory code, uint256 end) private pure {
        for (uint256 p; p + 4 < end; p = _nextOp(code, p)) {
            bool guard = uint8(code[p]) == OP_PUSH1 && uint8(code[p + 1]) == SELECTOR_BYTES
                && uint8(code[p + 2]) == OP_CALLDATASIZE && uint8(code[p + 3]) == OP_LT;
            if (!guard) continue;
            uint8 tagPush = uint8(code[p + 4]);
            assertTrue(tagPush >= OP_PUSH1 && tagPush <= OP_PUSH4, "short-calldata guard pushes a jump tag");
            uint256 width = tagPush - OP_PUSH0;
            assertLt(p + 5 + width, end, "short-calldata guard inside the code");
            assertEq(uint8(code[p + 5 + width]), OP_JUMPI, "short-calldata guard ends in JUMPI");
            uint256 tag = _immediate(code, p + 5, width);
            assertLe(tag + BARE_REVERT.length, end, "short-calldata target inside the code");
            bytes memory target = new bytes(BARE_REVERT.length);
            for (uint256 k; k < target.length; k++) {
                target[k] = code[tag + k];
            }
            assertEq(target, BARE_REVERT, "R5: no fallback()/receive(): short calldata reverts with empty data");
            return;
        }
        assertTrue(false, "solc short-calldata guard (PUSH1 4 CALLDATASIZE LT) found in the adapter");
    }

    function _immediate(bytes memory code, uint256 from, uint256 width) private pure returns (uint256 v) {
        for (uint256 k; k < width; k++) {
            v = (v << 8) | uint8(code[from + k]);
        }
    }

    // ================================================================== call observation
    /// @notice The keeper's full-close call with every permission active, run and rolled back (O5 simulation).
    function _quoteFullClose() private returns (uint256 quote) {
        quote = _simulate(_fullCloseCall());
        assertEq(quote, FULL_CLOSE_BOUNTY, "control quote: bounty capped at 6% of the repaid 75000");
    }

    function _fullCloseCall() private view returns (bytes memory) {
        return abi.encodeCall(ISpecLiquidationAdapter.liquidate, (borrower, type(uint256).max, uint256(0)));
    }

    function _simulate(bytes memory callData) private returns (uint256 bounty) {
        World memory pre = captureWorld(borrower);
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        (bool ok, bytes memory ret) = address(adapter).call(callData);
        assertTrue(ok, "simulation with every permission active succeeds");
        bounty = abi.decode(ret, (uint256));
        assertTrue(vm.revertToState(snap), "simulation rolled back");
        assertWorldUnchanged(pre);
    }

    function _attemptAs(address caller, address target, bytes memory callData) private returns (Attempt memory) {
        return _attemptAs(caller, target, 0, callData);
    }

    function _attemptAs(address caller, address target, uint256 value, bytes memory callData)
        private
        returns (Attempt memory a)
    {
        vm.startStateDiffRecording();
        vm.prank(caller);
        (a.ok, a.ret) = target.call{value: value}(callData);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        for (uint256 i; i < accesses.length; i++) {
            if (accesses[i].kind != VmSafe.AccountAccessKind.Call) continue;
            bytes4 sel = _selectorOf(accesses[i].data);
            if (accesses[i].account == address(PM)) {
                if (sel == IPoolManager.unlock.selector) a.pmUnlocks++;
                if (sel == IPoolManager.swap.selector) a.pmSwaps++;
            } else if (accesses[i].account == address(HOOK) && sel == IHooks.beforeSwap.selector) {
                a.hookBeforeSwaps++;
                (a.hookSender, a.hookKey,,) =
                    abi.decode(_argsOf(accesses[i].data), (address, PoolKey, SwapParams, bytes));
            }
        }
    }

    function _tallyFlowCalls(Vm.AccountAccess[] memory accesses) private view returns (FlowCalls memory c) {
        for (uint256 i; i < accesses.length; i++) {
            Vm.AccountAccess memory x = accesses[i];
            if (x.kind != VmSafe.AccountAccessKind.Call) continue;
            if (x.account == address(PM)) _tallyPmCall(c, x);
            else if (x.account == address(pa)) _tallyPaCall(c, x);
        }
    }

    function _tallyPmCall(FlowCalls memory c, Vm.AccountAccess memory x) private pure {
        bytes4 sel = _selectorOf(x.data);
        if (x.reverted) c.revertedPm++;
        if (sel == IPoolManager.unlock.selector) {
            (c.unlocks, c.unlockCaller) = (c.unlocks + 1, x.accessor);
        } else if (sel == IPoolManager.swap.selector) {
            (c.swaps, c.swapCaller, c.swapArgs) = (c.swaps + 1, x.accessor, _argsOf(x.data));
        } else if (sel == IPoolManager.take.selector) {
            (c.takes, c.takeArgs) = (c.takes + 1, _argsOf(x.data));
        } else if (sel == IPoolManager.sync.selector) {
            (c.syncs, c.syncArgs) = (c.syncs + 1, _argsOf(x.data));
        } else if (sel == IPoolManager.settle.selector) {
            c.settles++;
        } else {
            c.otherPm++;
        }
    }

    function _tallyPaCall(FlowCalls memory c, Vm.AccountAccess memory x) private pure {
        if (_selectorOf(x.data) != IPermissionsAdapter.wrapToPoolManager.selector) c.otherPa++;
        else (c.wraps, c.wrapCaller, c.wrapArgs) = (c.wraps + 1, x.accessor, _argsOf(x.data));
    }

    // ================================================================== permission switches (issuer)
    function _setHookAllowed(bool allowed) private {
        vm.prank(issuer);
        pa.updateAllowedHook(HOOK, allowed);
        assertEq(pa.allowedHooks(HOOK), allowed, "PA allowedHooks(HOOK) updated");
    }

    function _setSwapping(bool enabled) private {
        vm.prank(issuer);
        pa.updateSwappingEnabled(enabled);
        assertEq(pa.swappingEnabled(), enabled, "PA swappingEnabled updated");
    }

    function _setAdapterSwapFlag(bool allowed) private {
        uint16 flags = allowed ? rwa.HOLDER() | rwa.SWAP() : rwa.HOLDER(); // read before the prank
        vm.prank(issuer);
        rwa.setFlags(address(adapter), flags);
        assertEq(rwa.flags(address(adapter)), flags, "adapter flags updated");
    }

    function _setKeeperFlags(uint16 flags) private {
        vm.prank(issuer);
        rwa.setFlags(keeper, flags);
        assertEq(rwa.flags(keeper), flags, "keeper flags updated");
    }

    function _assertPermissionState(bool hookAllowed, bool swapping, bool adapterSwap, bool wrapper) private view {
        assertEq(pa.allowedHooks(HOOK), hookAllowed, "state: allowedHooks(HOOK)");
        assertEq(pa.swappingEnabled(), swapping, "state: swappingEnabled");
        assertEq(pa.isAllowed(address(adapter), PermissionFlags.SWAP_ALLOWED), adapterSwap, "state: adapter SWAP");
        assertEq(pa.allowedWrappers(address(adapter)), wrapper, "state: allowedWrappers(adapter)");
        assertTrue(pa.allowedWrappers(address(desk)), "state: desk wrapper untouched");
        assertEq(rwa.flags(address(adapter)) & rwa.HOLDER(), rwa.HOLDER(), "state: adapter stays HOLDER");
    }

    // ================================================================== bytes helpers
    function _selectorOf(bytes memory data) private pure returns (bytes4) {
        if (data.length < 4) return bytes4(0);
        // forge-lint: disable-next-line(unsafe-typecast) -- keeping only the first 4 bytes is the point
        return bytes4(data);
    }

    function _argsOf(bytes memory data) private pure returns (bytes memory args) {
        assertGe(data.length, 4, "calldata carries a selector");
        args = new bytes(data.length - 4);
        for (uint256 i; i < args.length; i++) {
            args[i] = data[i + 4];
        }
    }
}
