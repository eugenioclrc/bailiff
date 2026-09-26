// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockRWA3643 as MockRWA} from "../../src/e2e/MockRWA3643.sol";
import {MiniLend} from "../../src/e2e/MiniLend.sol";
import {BountyMath} from "../../src/e2e/BountyMath.sol";
import {IAllowlistChecker} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {PermissionFlag, PermissionFlags} from "@uniswap/v4-periphery/src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {MockUSDC, SimVenue, SimAdapter} from "./sim/Sim.sol";

contract Base is Test {
    address issuer = makeAddr("issuer");
    address oracle = makeAddr("oracle");
    address lender = makeAddr("lender");
    address alice = makeAddr("alice"); // KYC borrower
    address kycLiq = makeAddr("kycLiquidator"); // Horizon-style whitelisted liquidator
    address anon = makeAddr("anon"); // 0 USDC, not allowlisted

    MockRWA rwa;
    MockUSDC usdc;
    MiniLend lend;
    SimVenue venue;
    SimAdapter adapter;

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        rwa = new MockRWA(issuer);
        usdc = new MockUSDC();
        lend = new MiniLend(rwa, usdc, oracle, 100e18, 1e18, 10_000e18, 1 days);
        venue = new SimVenue(rwa, usdc);
        adapter = new SimAdapter(lend, venue, 10_000);

        vm.startPrank(issuer);
        uint16 H = rwa.HOLDER();
        rwa.setFlags(alice, H | rwa.SWAP() | rwa.LIQUIDITY());
        rwa.setFlags(kycLiq, H);
        rwa.setFlags(address(lend), H);
        rwa.setFlags(address(venue), H);
        rwa.setFlags(address(adapter), H | rwa.SWAP());
        rwa.mint(alice, 1_000e18);
        rwa.mint(address(venue), 100_000e18);
        vm.stopPrank();
        usdc.mint(address(venue), 10_000_000e6);

        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(lend), type(uint256).max);
        lend.supply(1_000_000e6);
        vm.stopPrank();

        vm.startPrank(alice);
        rwa.approve(address(lend), type(uint256).max);
        lend.depositCollateral(1_000e18);
        lend.borrow(75_000e6); // max LTV 75%
        vm.stopPrank();
    }

    function _crash(uint256 newNav) internal {
        vm.prank(oracle);
        lend.setNav(newNav);
        // arbs re-centre the pool on NAV: rebuild y so that y/x == nav
        uint256 x = rwa.balanceOf(address(venue));
        uint256 targetY = x * newNav / 1e30;
        uint256 y = usdc.balanceOf(address(venue));
        if (y > targetY) { vm.prank(address(venue)); usdc.transfer(address(0xdead), y - targetY); }
        else usdc.mint(address(venue), targetY - y);
    }
}

contract MiniLendTest is Base {
    function test_healthFactor_demoNumbers() public {
        assertEq(lend.healthFactor(alice), 1_066_666_666_666_666_666); // 100k*0.80/75k
        vm.prank(oracle); lend.setNav(90e18);
        assertEq(lend.healthFactor(alice), 0.96e18);
        vm.prank(oracle); lend.setNav(85e18);
        assertEq(lend.healthFactor(alice), 906_666_666_666_666_666);
    }

    function test_borrow_aboveLtv_reverts() public {
        vm.prank(alice);
        vm.expectRevert(MiniLend.Unhealthy.selector);
        lend.borrow(1);
    }

    function test_staleNav_blocksBorrowAndLiquidation() public {
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        vm.expectRevert(MiniLend.StaleNav.selector);
        lend.borrow(1);
        vm.expectRevert(MiniLend.StaleNav.selector);
        lend.previewLiquidation(alice, type(uint256).max);
        // repay is always allowed
        usdc.mint(alice, 1e6);
        vm.startPrank(alice); usdc.approve(address(lend), 1e6); lend.repay(alice, 1e6); vm.stopPrank();
    }

    function test_navBounds() public {
        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(MiniLend.NavOutOfBounds.selector, 0.5e18));
        lend.setNav(0.5e18);
        vm.expectRevert(MiniLend.NotOracle.selector);
        lend.setNav(90e18);
    }

    function test_liquidate_healthy_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(MiniLend.Healthy.selector, 1_066_666_666_666_666_666));
        adapter.liquidate(alice, type(uint256).max, 0);
    }

    function test_closeFactor50_at_minus10() public {
        vm.prank(oracle); lend.setNav(90e18);
        (uint256 repay, uint256 seize) = lend.previewLiquidation(alice, type(uint256).max);
        assertEq(repay, 37_500e6);
        assertEq(seize, 441_666_666_666_666_666_666); // 37.5k*1.06/90, rounded down
    }

    function test_fullClose_at_minus15() public {
        vm.prank(oracle); lend.setNav(85e18);
        (uint256 repay, uint256 seize) = lend.previewLiquidation(alice, type(uint256).max);
        assertEq(repay, 75_000e6);
        assertEq(seize, 935_294_117_647_058_823_529);
    }

    function test_badDebt_at_minus30() public {
        _crash(70e18);
        (uint256 repay, uint256 seize) = lend.previewLiquidation(alice, type(uint256).max);
        assertEq(seize, 1_000e18);
        assertEq(repay, 66_037_735_850); // ceil(70_000 / 1.06)
        vm.prank(anon);
        adapter.liquidate(alice, type(uint256).max, 0);
        assertEq(lend.totalBadDebt(), 75_000e6 - 66_037_735_850); // 8,962.264150 USDC socialised
        (uint256 c, uint256 d) = lend.positions(alice);
        assertEq(c + d, 0);
    }

    function test_horizonStyle_anonDirectLiquidation_reverts() public {
        vm.prank(oracle); lend.setNav(85e18);
        usdc.mint(anon, 75_000e6); // even WITH capital
        vm.startPrank(anon);
        usdc.approve(address(lend), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(MockRWA.NotAllowlisted.selector, anon));
        lend.liquidate(alice, type(uint256).max, "");
        vm.stopPrank();
    }

    function test_horizonStyle_kycLiquidator_succeeds() public {
        vm.prank(oracle); lend.setNav(85e18);
        usdc.mint(kycLiq, 75_000e6);
        vm.startPrank(kycLiq);
        usdc.approve(address(lend), type(uint256).max);
        lend.liquidate(alice, type(uint256).max, "");
        vm.stopPrank();
        assertEq(rwa.balanceOf(kycLiq), 935_294_117_647_058_823_529); // now warehouses RWA, must redeem T+N
    }

    function test_adapter_anonZeroUsdc_getsOnlyUsdc() public {
        _crash(85e18);
        assertEq(usdc.balanceOf(anon), 0);
        vm.prank(anon);
        (uint256 bounty, uint256 residual) = adapter.liquidate(alice, type(uint256).max, 1);
        emit log_named_decimal_uint("bounty USDC", bounty, 6);
        emit log_named_decimal_uint("residual USDC", residual, 6);
        assertGt(bounty, 0);
        assertEq(usdc.balanceOf(anon), bounty);
        assertEq(rwa.balanceOf(anon), 0);
        assertEq(rwa.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertLe(bounty, 75_000e6 * 600 / 10_000);
        (, uint256 d) = lend.positions(alice);
        assertEq(d, 0);
    }

    function test_adapter_thinPool_reverts_thenChunkSucceeds() public {
        _crash(85e18);
        // drain pool to 1,000 RWA / 85,000 USDC
        vm.startPrank(address(venue));
        rwa.transfer(issuer, 99_000e18);
        usdc.transfer(address(0xdead), usdc.balanceOf(address(venue)) - 85_000e6);
        vm.stopPrank();
        vm.prank(anon);
        vm.expectRevert(); // InsufficientProceeds: selling 935 RWA into a 1,000 RWA pool
        adapter.liquidate(alice, type(uint256).max, 0);
        // constant-product capacity per chunk ~= LB * x = 6% * 1,000 RWA = ~59 RWA = ~4.7k USDC repay
        vm.prank(anon);
        vm.expectRevert(); // 5k repay -> 62.4 RWA -> 6.2% impact > 5.66% budget
        adapter.liquidate(alice, 5_000e6, 0);
        vm.prank(anon);
        (uint256 bounty,) = adapter.liquidate(alice, 2_000e6, 1);
        emit log_named_decimal_uint("chunk bounty USDC", bounty, 6);
        assertGt(bounty, 0);
    }

    function test_adapter_minBounty_enforced() public {
        _crash(85e18);
        vm.prank(anon);
        vm.expectRevert();
        adapter.liquidate(alice, type(uint256).max, 4_500e6 + 1);
    }

    function test_poolPremium_residualToBorrower() public {
        vm.prank(oracle); lend.setNav(85e18); // pool left at 100 (premium over NAV)
        uint256 before = usdc.balanceOf(alice);
        vm.prank(anon);
        (uint256 bounty, uint256 residual) = adapter.liquidate(alice, type(uint256).max, 0);
        assertEq(bounty, 4_500e6); // capped at repay * 6%
        assertGt(residual, 0);
        assertEq(usdc.balanceOf(alice) - before, residual);
    }

    function test_partialLiquidation_restoresHealth() public {
        _crash(90e18);
        vm.prank(anon);
        adapter.liquidate(alice, type(uint256).max, 0);
        assertGt(lend.healthFactor(alice), 1e18);
        emit log_named_decimal_uint("HF after", lend.healthFactor(alice), 18);
    }

    function test_mockRwa_checker_interface() public view {
        assertTrue(rwa.supportsInterface(type(IAllowlistChecker).interfaceId));
        PermissionFlag f = rwa.checkAllowlist(address(adapter), address(rwa));
        assertTrue((f & PermissionFlags.SWAP_ALLOWED) == PermissionFlags.SWAP_ALLOWED);
        assertFalse((f & PermissionFlags.LIQUIDITY_ALLOWED) == PermissionFlags.LIQUIDITY_ALLOWED);
        assertTrue(rwa.checkAllowlist(anon, address(rwa)) == PermissionFlags.NONE);
        assertTrue(rwa.checkAllowlist(address(adapter), address(usdc)) == PermissionFlags.NONE);
    }

    function testFuzz_seizeNeverExceedsBonus(uint256 navDrop, uint256 repayAssets) public {
        navDrop = bound(navDrop, 7, 60); // HF < 1 needs > 6.25% drop
        _crash(100e18 * (100 - navDrop) / 100);
        repayAssets = bound(repayAssets, 1_000e6, 75_000e6);
        try lend.previewLiquidation(alice, repayAssets) returns (uint256 repay, uint256 seize) {
            // borrower never loses more than repay * 1.06 worth of RWA at NAV
            assertLe(lend.collateralValue(seize), repay * 10_600 / 10_000 + 1);
        } catch {}
    }

    function testFuzz_split(uint256 proceeds, uint256 repaid, uint256 keeperBps) public pure {
        repaid = bound(repaid, 1, 1e15);
        proceeds = bound(proceeds, repaid, repaid * 2);
        keeperBps = bound(keeperBps, 0, 10_000);
        (uint256 b, uint256 r) = BountyMath.split(proceeds, repaid, 600, keeperBps, 0);
        assertEq(b + r + repaid, proceeds);
        assertLe(b, repaid * 600 / 10_000);
    }
}
