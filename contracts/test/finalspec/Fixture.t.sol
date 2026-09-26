// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {MiniLend} from "../../src/e2e/MiniLend.sol";
import {FinalSpecBase} from "./FinalSpecBase.sol";
import {SpecBlockableUSDC, SpecMockUSDC} from "./FinalSpecFixture.sol";

/// @notice GREEN smoke tests of the shared acceptance fixture itself: pinned fork and real Labs stack, the three
///         O3 roles and their configuration, the NAV-only crash, both currency orders, both branches of the R4
///         split, and the test-only blockable USDC.
contract FixtureTest is FinalSpecBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant CRASH_DELAY = 1 hours; // crash later than deploy so navUpdatedAt must move
    uint256 internal constant SPOT_NEAR_NAV = 90e18; // explicit MM fixture: spot close to the crashed NAV
    uint256 internal constant LENDER_TOP_UP = 10e6;
    uint256 internal constant PAYDOWN = 1_000e6;

    // ================================================================== tests
    function test_fixture_threeRolesAndPinnedFork() public {
        _assertPinnedStack();
        _assertDistinctRoles();
        _assertRoleAuthority();
        _assertRoleFlags();
        _assertWrapperSetIsAdapterAndDesk();
        _assertMarketConfiguration();
        _assertAdapterAndDeskConfiguration();
        _assertKeeperStartsEmpty();
        _assertMarketMakerIsSoleLp();
        _assertHealthyBaseline();

        // O4 Crash, one hour after deploy: only NavUpdated, only nav/navUpdatedAt move
        uint256 deployedAt = market.navUpdatedAt();
        assertEq(deployedAt, block.timestamp, "NAV set at deploy");
        vm.warp(block.timestamp + CRASH_DELAY);
        assertEq(market.healthFactor(borrower), HF_BASELINE, "time alone does not make the borrower unhealthy");
        crashNavAndAssertNavOnly();
        assertEq(market.navUpdatedAt(), deployedAt + CRASH_DELAY, "navUpdatedAt moved to the crash time");
        assertEq(market.nav(), CRASH_NAV, "NAV 85");

        // only now is the borrower liquidatable
        assertEq(market.healthFactor(borrower), HF_AFTER_CRASH, "HF after crash");
        (uint256 repay, uint256 seize) = market.previewLiquidation(borrower, type(uint256).max);
        assertEq(repay, BORROWER_DEBT, "HF <= 0.95: full close");
        assertEq(seize, CRASH_FULL_CLOSE_SEIZE, "seize at NAV 85");
        assertEq(seize, expectedSeize(BORROWER_DEBT, CRASH_NAV), "R3 seize formula");
    }

    function test_fixture_bothCurrencyOrders() public {
        // setUp built the default order; rebuild explicitly so both branches are exercised in this test
        _deployFixture(true, false);
        address paLow = address(pa);
        bytes32 poolLow = PoolId.unwrap(poolId);
        _assertOrderAndLiquidate(true);

        _deployFixture(false, false);
        assertTrue(address(pa) != paLow, "second fixture has its own PA");
        assertTrue(PoolId.unwrap(poolId) != poolLow, "second fixture has its own pool");
        _assertOrderAndLiquidate(false);
    }

    /// @notice The fixture exercises the keeperBps branch of the R4 split too, not only the 6% LB cap.
    function test_fixture_keeperBpsBindsBelowLbCap() public {
        // explicit R6 test fixture, done by the MM and separate from Crash: spot 100 -> 90
        uint160 target = sqrtPriceX96ForNav(SPOT_NEAR_NAV);
        World memory beforeSwap = captureWorld(borrower);
        mmSwapToPrice(target, beforeSwap.bal.deskRwa);
        assertEq(spotSqrtPriceX96(), target, "MM moved spot to 90");
        assertEq(PM.getLiquidity(poolId), L_UNSIGNED, "a swap leaves L");

        crashNavAndAssertNavOnly();
        uint256 limit = navFloorLimitSqrtPriceX96(CRASH_NAV, paIsCurrency0);
        _assertSpotOnAllowedSide(spotSqrtPriceX96(), limit, paIsCurrency0, "pre-sale spot vs NAV floor");

        Liquidation memory r = liquidateViaAdapter();
        assertLiquidationSuccessPath(r);
        assertEq(r.repaid, BORROWER_DEBT, "full close");
        assertEq(r.seized, CRASH_FULL_CLOSE_SEIZE, "seize");
        uint256 surplus = r.proceeds - r.repaid;
        assertEq(r.eventBounty, surplus * 5_000 / 10_000, "bounty == floor(surplus * keeperBps 5000 / B)");
        assertLt(r.eventBounty, BORROWER_DEBT * 600 / 10_000, "bounty below the 6% LB cap");
        assertEq(r.marketBadDebt, 0, "no write-off");
        assertAccountingIdentityAnyVersion();
        assertLedgerSums();
        // the spec's NAV-floor limit would not cut this sale short
        _assertSpotOnAllowedSide(spotSqrtPriceX96(), limit, paIsCurrency0, "post-sale spot vs NAV floor");
    }

    function test_fixture_blockableUsdcVariant() public {
        _deployFixture(DEFAULT_PA_IS_CURRENCY0, true);
        _assertBlockableIsSameFixture();

        // only the minter controls the block list
        vm.prank(keeper);
        vm.expectRevert(SpecMockUSDC.OnlyMinter.selector);
        _blockable().setBlocked(borrower, true);
        assertFalse(_blockable().blocked(borrower), "rejected setBlocked leaves the borrower unblocked");

        setUsdcRecipientBlocked(borrower, true);
        assertTrue(_blockable().blocked(borrower), "minter blocked the borrower");
        _assertEveryInboundRouteRejected();
        _assertBlockedBorrowerStillSends();
        _assertMarketPayoutToBlockedReverts();
    }

    // ================================================================== three roles / pinned stack
    function _assertPinnedStack() private {
        assertEq(block.number, FORK_BLOCK, "block 11782723");
        assertEq(block.chainid, SEPOLIA_CHAIN_ID, "Sepolia");
        assertEq(blockhash(FORK_BLOCK - 1), FORK_PARENT_HASH, "Sepolia history at the pinned block");
        assertGt(address(PM).code.length, 0, "PoolManager has code");
        assertGt(address(FACTORY).code.length, 0, "factory has code");
        assertGt(address(HOOK).code.length, 0, "hook has code");
        assertGt(STATE_VIEW.code.length, 0, "StateView has code");
        assertEq(address(PM).codehash, PM_CODEHASH, "PoolManager codehash");
        assertEq(address(FACTORY).codehash, FACTORY_CODEHASH, "factory codehash");
        assertEq(address(HOOK).codehash, HOOK_CODEHASH, "hook codehash");
        assertEq(STATE_VIEW.codehash, STATE_VIEW_CODEHASH, "StateView codehash");
        assertEq(pa.POOL_MANAGER(), address(PM), "PA -> PM");
        assertEq(FACTORY.permissionsAdapterOf(address(pa)), address(rwa), "factory created PA for RWA");
        assertEq(FACTORY.verifiedPermissionsAdapterOf(address(pa)), address(rwa), "PA verified for RWA");
        emit log_named_string("fixture USDC", usdcIsProductMock ? PRODUCT_MOCK_USDC : "SpecMockUSDC stand-in (R2 ABI)");
    }

    function _assertDistinctRoles() private view {
        assertTrue(issuer != mm, "issuer != MM");
        assertTrue(mm != keeper, "MM != keeper");
        assertTrue(issuer != keeper, "issuer != keeper");
        assertTrue(borrower != keeper && borrower != mm && borrower != issuer, "borrower is a setup account");
        assertTrue(lender != keeper && lender != mm && lender != issuer, "lender is a setup account");
    }

    function _assertRoleAuthority() private view {
        assertEq(pa.owner(), issuer, "issuer owns PA");
        assertEq(market.oracleAdmin(), issuer, "issuer is oracleAdmin");
        assertEq(rwa.issuer(), issuer, "issuer is RWA agent");
        assertEq(usdc.minter(), issuer, "issuer is USDC minter");
        assertEq(usdc.decimals(), 6, "USDC 6 decimals");
        assertEq(usdc.name(), "USD Coin (mock)", "R2 name");
        assertEq(usdc.symbol(), "mUSDC", "R2 symbol");
        assertEq(desk.owner(), mm, "MM owns the desk, not the issuer");
        assertEq(desk.msgSender(), mm, "desk reports the MM to the hook");
        assertEq(adapter.msgSender(), address(adapter), "adapter reports itself");
    }

    function _assertRoleFlags() private view {
        uint16 h = rwa.HOLDER();
        uint16 s = rwa.SWAP();
        uint16 q = rwa.LIQUIDITY();
        assertEq(rwa.flags(issuer), h, "issuer HOLDER only");
        assertEq(rwa.flags(mm), h | s | q, "MM HOLDER|SWAP|LIQUIDITY");
        assertEq(rwa.flags(keeper), 0, "keeper NONE");
        assertEq(rwa.flags(borrower), h, "borrower HOLDER");
        assertEq(rwa.flags(lender), 0, "lender needs no HOLDER");
        assertEq(rwa.flags(address(market)), h, "market HOLDER");
        assertEq(rwa.flags(address(pa)), h, "PA HOLDER");
        assertEq(rwa.flags(address(desk)), h, "desk HOLDER");
        assertEq(rwa.flags(address(adapter)), h | s, "adapter HOLDER|SWAP");
        assertEq(rwa.flags(address(PM)), 0, "PoolManager not HOLDER");
        assertTrue(pa.allowedHooks(HOOK), "canonical hook allowed");
        assertTrue(pa.swappingEnabled(), "swapping enabled");
    }

    /// @dev The mapping cannot be enumerated: the fresh PA's full AllowedWrapperUpdated history is exactly two grants,
    ///      and every other fixture address reads false.
    function _assertWrapperSetIsAdapterAndDesk() private view {
        assertEq(paWrapperUpdates.length, 2, "PA wrapper history: exactly two updates");
        assertEq(paWrapperUpdates[0].wrapper, address(adapter), "first wrapper grant: adapter");
        assertTrue(paWrapperUpdates[0].allowed, "adapter granted");
        assertEq(paWrapperUpdates[1].wrapper, address(desk), "second wrapper grant: desk");
        assertTrue(paWrapperUpdates[1].allowed, "desk granted");
        assertTrue(pa.allowedWrappers(address(adapter)), "adapter allowedWrapper");
        assertTrue(pa.allowedWrappers(address(desk)), "desk allowedWrapper");
        address[13] memory others = [
            issuer,
            mm,
            keeper,
            borrower,
            lender,
            address(market),
            address(PM),
            address(HOOK),
            address(FACTORY),
            address(pa),
            address(rwa),
            address(usdc),
            STATE_VIEW
        ];
        for (uint256 i; i < others.length; i++) {
            assertFalse(pa.allowedWrappers(others[i]), "only adapter and desk are wrappers");
        }
    }

    /// @dev Spec literals on purpose (R3 concrete configuration), not the fixture's own constants.
    function _assertMarketConfiguration() private view {
        assertEq(address(market.RWA()), address(rwa), "market RWA");
        assertEq(address(market.USDC()), address(usdc), "market USDC");
        assertEq(market.PRICE_SCALE(), 1e30, "PRICE_SCALE 1e30");
        assertEq(market.NAV_FLOOR(), 10e18, "NAV floor 10");
        assertEq(market.NAV_CAP(), 1_000e18, "NAV cap 1000");
        assertEq(market.MAX_STALENESS(), 1 days, "staleness 1 day");
        assertEq(market.LTV_BPS(), 7_500, "LTV 75%");
        assertEq(market.LT_BPS(), 8_000, "LT 80%");
        assertEq(market.LB_BPS(), 600, "LB 6%");
        assertEq(market.CLOSE_FACTOR_BPS(), 5_000, "close factor 50%");
        assertEq(market.FULL_CLOSE_HF(), 0.95e18, "full close HF 0.95");
        assertEq(market.MIN_FULL_CLOSE_DEBT(), 2_000e6, "min full close debt 2000");
        assertEq(market.MIN_LEFTOVER_DEBT(), 1_000e6, "min leftover debt 1000");
    }

    /// @dev R5/R6/O2/O3 literals: fee 3000, tickSpacing 60, keeperBps 5000, lbBps 600 from the market.
    function _assertAdapterAndDeskConfiguration() private view {
        assertEq(address(adapter.poolManager()), address(PM), "adapter PM");
        assertEq(address(adapter.permissionsAdapter()), address(pa), "adapter PA");
        assertEq(address(adapter.rwa()), address(rwa), "adapter RWA == PA.PERMISSIONED_TOKEN");
        assertEq(address(pa.PERMISSIONED_TOKEN()), address(rwa), "PA wraps the RWA");
        assertEq(address(pa.allowListChecker()), address(rwa), "RWA is the allowlist checker");
        assertEq(address(adapter.usdc()), address(usdc), "adapter USDC");
        assertEq(address(adapter.market()), address(market), "adapter market");
        assertEq(address(adapter.hooks()), address(HOOK), "adapter hook");
        assertEq(adapter.fee(), 3_000, "adapter fee 3000");
        assertEq(adapter.tickSpacing(), 60, "adapter tickSpacing 60");
        assertEq(adapter.keeperBps(), 5_000, "keeperBps 5000");
        assertEq(adapter.lbBps(), 600, "lbBps 600");
        assertEq(adapter.rwaIsCurrency0(), paIsCurrency0, "adapter orientation");
        assertEq(keccak256(abi.encode(adapter.poolKey())), keccak256(abi.encode(key)), "adapter pins the pool");
        assertEq(key.fee, 3_000, "pool fee 3000");
        assertEq(key.tickSpacing, 60, "pool tickSpacing 60");
        assertEq(address(key.hooks), address(HOOK), "pool uses the canonical hook");
        assertEq(address(desk.pm()), address(PM), "desk PM");
        assertEq(address(desk.pa()), address(pa), "desk PA");
    }

    function _assertKeeperStartsEmpty() private view {
        assertEq(usdc.balanceOf(keeper), 0, "keeper 0 USDC");
        assertEq(rwa.balanceOf(keeper), 0, "keeper 0 RWA");
        assertEq(keeper.balance, 1 ether, "keeper holds only gas ETH");
        assertEq(rwa.balanceOf(address(PM)), 0, "PM 0 raw RWA");
        assertEq(rwa.balanceOf(address(adapter)), 0, "adapter 0 RWA");
        assertEq(usdc.balanceOf(address(adapter)), 0, "adapter 0 USDC");
    }

    function _assertMarketMakerIsSoleLp() private view {
        World memory w = captureWorld(borrower);
        assertEq(w.pool.liquidity, 5e17, "pool L == 5e17");
        assertEq(w.pool.deskLiquidity, 5e17, "all of L is the MM desk position [-887220, 887220]");
        assertEq(w.pool.sqrtPriceX96, sqrtPriceX96ForNav(NAV0), "pool initialised at P=100");
        assertEq(w.pool.tick, TickMath.getTickAtSqrtPrice(w.pool.sqrtPriceX96), "tick consistent with price");
        // the real StateView (what the UI reads) sees the same pool
        IStateView sv = IStateView(STATE_VIEW);
        (uint160 svPrice, int24 svTick,,) = sv.getSlot0(poolId);
        assertEq(svPrice, w.pool.sqrtPriceX96, "StateView slot0 price");
        assertEq(svTick, w.pool.tick, "StateView slot0 tick");
        assertEq(sv.getLiquidity(poolId), 5e17, "StateView L");
        (uint128 svPos,,) = sv.getPositionInfo(poolId, address(desk), -887220, 887220, bytes32(0));
        assertEq(svPos, 5e17, "StateView MM position");
        // every unit the MM received is either in the pool or still on its desk
        assertEq(w.bal.deskRwa + w.bal.paSupply, 100_000e18, "MM RWA: desk + pool");
        assertEq(w.bal.deskUsdc + w.bal.pmUsdc, 6_000_000e6, "MM USDC: desk + pool");
        assertEq(w.bal.pmPa, w.bal.paSupply, "vRWA only in PM");
        assertEq(w.bal.paRwa, w.bal.paSupply + VERIFICATION_DEPOSIT, "PA backing == supply + 1 wei deposit");
        assertEq(w.bal.mmRwa, 0, "MM funded its desk");
        assertEq(w.bal.mmUsdc, 0, "MM funded its desk");
    }

    function _assertHealthyBaseline() private {
        assertEq(market.nav(), NAV0, "NAV 100");
        (uint256 coll, uint256 debt) = market.positions(borrower);
        assertEq(coll, 1_000e18, "collateral 1000");
        assertEq(debt, 75_000e6, "debt 75000");
        assertEq(market.totalSupplyAssets(), 500_000e6, "lender supplied 500k");
        assertEq(usdc.balanceOf(address(market)), 500_000e6 - 75_000e6, "market cash");
        assertEq(usdc.balanceOf(borrower), 75_000e6, "borrower holds the loan");
        assertEq(market.totalBadDebt(), 0, "no bad debt");
        assertAccountingIdentityAnyVersion();
        assertLedgerSums();
        assertEq(market.healthFactor(borrower), HF_BASELINE, "HF baseline");
        vm.expectRevert(abi.encodeWithSelector(MiniLend.Healthy.selector, HF_BASELINE));
        market.previewLiquidation(borrower, type(uint256).max);
    }

    // ================================================================== both currency orders
    function _assertOrderAndLiquidate(bool paIs0) private {
        assertEq(paIsCurrency0, paIs0, "requested order built");
        assertEq(address(pa) < address(usdc), paIs0, "address order");
        (address c0, address c1) = paIs0 ? (address(pa), address(usdc)) : (address(usdc), address(pa));
        assertEq(Currency.unwrap(key.currency0), c0, "currency0");
        assertEq(Currency.unwrap(key.currency1), c1, "currency1");
        PoolKey memory k = adapter.poolKey();
        assertEq(keccak256(abi.encode(k)), keccak256(abi.encode(key)), "adapter pins the fixture PoolKey");
        assertEq(adapter.rwaIsCurrency0(), paIs0, "adapter orientation");
        uint160 spot = spotSqrtPriceX96();
        assertEq(spot, sqrtPriceX96ForNav(NAV0, paIs0), "P=100 in this orientation");
        (, int24 tick,,) = PM.getSlot0(poolId);
        assertTrue(paIs0 ? tick < 0 : tick > 0, "USDC(6d) per RWA(18d) tick sign");
        assertAccountingIdentityAnyVersion();
        assertLedgerSums();

        // spot 100 sits on the allowed side of the 84.15 floor in both orientations
        crashNavAndAssertNavOnly();
        uint256 limit = navFloorLimitSqrtPriceX96(CRASH_NAV, paIs0);
        _assertSpotOnAllowedSide(spot, limit, paIs0, "pre-sale spot vs NAV floor");

        Liquidation memory r = liquidateViaAdapter();
        assertLiquidationSuccessPath(r);
        assertEq(r.repaid, BORROWER_DEBT, "full close");
        assertEq(r.seized, CRASH_FULL_CLOSE_SEIZE, "seize");
        assertEq(r.eventBounty, BORROWER_DEBT * 600 / 10_000, "bounty == 6% LB cap");
        assertLt(r.eventBounty, (r.proceeds - r.repaid) * 5_000 / 10_000, "cap below the keeperBps share");
        assertEq(r.marketBadDebt, 0, "collateral remains: no write-off");
        (uint256 coll, uint256 debt) = market.positions(borrower);
        assertEq(debt, 0, "debt closed");
        assertEq(coll, BORROWER_COLLATERAL - CRASH_FULL_CLOSE_SEIZE, "collateral left");
        assertEq(market.totalBadDebt(), 0, "totalBadDebt stays 0");
        assertEq(market.totalSupplyAssets(), LENDER_USDC, "lenders keep 500k");
        assertAccountingIdentityAnyVersion();
        assertLedgerSums();
        // the spec's NAV-floor limit would not cut this sale short
        _assertSpotOnAllowedSide(spotSqrtPriceX96(), limit, paIs0, "post-sale spot vs NAV floor");
    }

    /// @dev R5 table: PA currency0 rejects current <= limit; PA currency1 rejects current >= limit.
    function _assertSpotOnAllowedSide(uint160 spot, uint256 limit, bool paIs0, string memory what) private pure {
        if (paIs0) assertGt(uint256(spot), limit, what);
        else assertLt(uint256(spot), limit, what);
    }

    // ================================================================== blockable USDC variant
    function _blockable() private view returns (SpecBlockableUSDC) {
        return SpecBlockableUSDC(address(usdc));
    }

    function _blockedError() private view returns (bytes memory) {
        return abi.encodeWithSelector(SpecBlockableUSDC.RecipientBlocked.selector, borrower);
    }

    function _assertBlockableIsSameFixture() private view {
        assertTrue(usdcIsBlockable, "blockable variant built");
        assertFalse(usdcIsProductMock, "blockable variant is test-only");
        assertEq(usdc.minter(), issuer, "same R2 minter");
        assertEq(usdc.decimals(), 6, "same R2 decimals");
        (uint256 coll, uint256 debt) = market.positions(borrower);
        assertEq(coll, BORROWER_COLLATERAL, "same seeded collateral");
        assertEq(debt, BORROWER_DEBT, "same seeded debt");
        assertFalse(_blockable().blocked(borrower), "nobody blocked by default");
    }

    /// @dev mint, transfer and transferFrom to the blocked borrower all revert RecipientBlocked(borrower); no state moves.
    function _assertEveryInboundRouteRejected() private {
        vm.prank(issuer);
        usdc.mint(lender, LENDER_TOP_UP);
        vm.prank(lender);
        usdc.approve(mm, 1);
        World memory pre = captureWorld(borrower);

        vm.prank(issuer);
        vm.expectRevert(_blockedError());
        usdc.mint(borrower, 1);

        vm.prank(lender);
        vm.expectRevert(_blockedError());
        // forge-lint: disable-next-line(erc20-unchecked-transfer) -- expected to revert, no return value
        usdc.transfer(borrower, 1);

        vm.prank(mm);
        vm.expectRevert(_blockedError());
        // forge-lint: disable-next-line(erc20-unchecked-transfer) -- expected to revert, no return value
        usdc.transferFrom(lender, borrower, 1);

        assertWorldUnchanged(pre);
        assertEq(usdc.allowance(lender, mm), 1, "rejected transferFrom keeps the allowance");
    }

    /// @dev Blocking is receive-only: the blocked borrower repays MiniLend and pays another account.
    function _assertBlockedBorrowerStillSends() private {
        World memory pre = captureWorld(borrower);
        vm.startPrank(borrower);
        usdc.approve(address(market), PAYDOWN);
        uint256 repaid = market.repay(borrower, PAYDOWN);
        assertTrue(usdc.transfer(lender, 1), "blocked borrower pays out");
        vm.stopPrank();
        World memory post = captureWorld(borrower);
        assertEq(repaid, PAYDOWN, "repaid");
        assertEq(post.bal.borrowerUsdc, pre.bal.borrowerUsdc - PAYDOWN - 1, "borrower USDC out");
        assertEq(post.bal.marketUsdc, pre.bal.marketUsdc + PAYDOWN, "market USDC in");
        assertEq(post.bal.lenderUsdc, pre.bal.lenderUsdc + 1, "lender USDC in");
        assertEq(post.ledger.debt, pre.ledger.debt - PAYDOWN, "debt paid down");
        assertEq(post.ledger.totalDebt, pre.ledger.totalDebt - PAYDOWN, "totalDebt paid down");
        assertAccountingIdentityAnyVersion();
        assertLedgerSums();
    }

    /// @dev MiniLend's own safeTransfer to the borrower (the claimResidual mechanism; borrow() here) bubbles
    ///      RecipientBlocked(borrower) and rolls back; after unblocking the same call pays out.
    function _assertMarketPayoutToBlockedReverts() private {
        World memory pre = captureWorld(borrower);
        vm.prank(borrower);
        vm.expectRevert(_blockedError());
        market.borrow(PAYDOWN);
        assertWorldUnchanged(pre);

        setUsdcRecipientBlocked(borrower, false);
        assertFalse(_blockable().blocked(borrower), "minter unblocked the borrower");
        vm.prank(borrower);
        market.borrow(PAYDOWN);
        World memory post = captureWorld(borrower);
        assertEq(post.bal.borrowerUsdc, pre.bal.borrowerUsdc + PAYDOWN, "unblocked borrower receives");
        assertEq(post.bal.marketUsdc, pre.bal.marketUsdc - PAYDOWN, "market pays out");
        assertEq(post.ledger.debt, BORROWER_DEBT, "debt back to 75000");
        assertAccountingIdentityAnyVersion();
        assertLedgerSums();
    }
}
