// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPermissionsAdapterFactory} from
    "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {IPermissionsAdapter} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {MockRWA3643} from "../src/e2e/MockRWA3643.sol";
import {MiniLend} from "../src/e2e/MiniLend.sol";
import {LiquidationAdapter, IMiniLend} from "../src/e2e/LiquidationAdapter.sol";
import {LiquidityDesk} from "../src/e2e/LiquidityDesk.sol";

/// @notice Full E2E on a Sepolia fork: MiniLend + LiquidationAdapter + REAL Uniswap Labs PermissionedHooks.
contract ForkLiquidationTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    IPermissionsAdapterFactory constant FACTORY =
        IPermissionsAdapterFactory(0xE6B0d96919334C33d06266d1420F97f6f434fA2B);
    IHooks constant HOOK = IHooks(0x51247E2291d290d17C08813A175AC86465EdE8c0);
    bytes32 constant SWAP_TOPIC = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    address issuer = makeAddr("issuer");
    address borrower = makeAddr("borrower");
    address lender = makeAddr("lender");
    address anon = makeAddr("anonKeeper");

    MockRWA3643 rwa;
    MockERC20 usdc;
    IPermissionsAdapter pa;
    PoolKey key;
    MiniLend market;
    LiquidationAdapter adapter;
    LiquidityDesk desk;
    bool rwaIs0;
    int256 constant L = 1e18;

    function setUp() public {
        vm.createSelectFork("https://ethereum-sepolia-rpc.publicnode.com");
        vm.startPrank(issuer);
        // token + adapter + verification
        rwa = new MockRWA3643(issuer);
        usdc = new MockERC20("USD Coin (mock)", "USDC", 6);
        pa = IPermissionsAdapter(
            FACTORY.createPermissionsAdapter(IERC20(address(rwa)), issuer, IAllowlistChecker(address(rwa)))
        );
        rwa.setFlags(address(pa), rwa.HOLDER());
        rwa.mint(issuer, 1_000_000e18);
        rwa.approve(address(pa), 1);
        pa.depositForVerification(1);
        FACTORY.verifyPermissionsAdapter(address(pa));
        pa.updateAllowedHook(HOOK, true);
        pa.updateSwappingEnabled(true);
        // pool
        rwaIs0 = address(pa) < address(usdc);
        key = rwaIs0
            ? PoolKey(Currency.wrap(address(pa)), Currency.wrap(address(usdc)), 3000, 60, HOOK)
            : PoolKey(Currency.wrap(address(usdc)), Currency.wrap(address(pa)), 3000, 60, HOOK);
        PM.initialize(key, sqrtPriceX96(100e18));
        // market + adapter + desk
        market = new MiniLend(IERC20(address(rwa)), IERC20(address(usdc)), issuer, 100e18, 10e18, 1_000e18, 1 days);
        adapter = new LiquidationAdapter(
            PM, FACTORY, pa, IERC20(address(usdc)), IMiniLend(address(market)), HOOK, 3000, 60, 5_000
        );
        desk = new LiquidityDesk(PM, pa, issuer);
        rwa.setFlags(address(market), rwa.HOLDER());
        rwa.setFlags(address(adapter), rwa.HOLDER() | rwa.SWAP());
        rwa.setFlags(address(desk), rwa.HOLDER());
        rwa.setFlags(borrower, rwa.HOLDER());
        pa.updateAllowedWrapper(address(adapter), true);
        pa.updateAllowedWrapper(address(desk), true);
        // liquidity: 100k RWA + 10M USDC full range at $100 (L = 1e18)
        rwa.transfer(address(desk), 200_000e18);
        usdc.mint(address(desk), 12_000_000e6);
        desk.modifyLiquidity(key, -887220, 887220, L);
        rwa.transfer(borrower, 1_000e18);
        vm.stopPrank();

        usdc.mint(lender, 500_000e6);
        vm.startPrank(lender);
        usdc.approve(address(market), type(uint256).max);
        market.supply(500_000e6);
        vm.stopPrank();

        vm.startPrank(borrower);
        rwa.approve(address(market), type(uint256).max);
        market.depositCollateral(1_000e18);
        market.borrow(75_000e6);
        vm.stopPrank();
    }

    function sqrtPriceX96(uint256 navWad) internal view returns (uint160) {
        uint256 q192 = 1 << 192;
        return uint160(Math.sqrt(rwaIs0 ? Math.mulDiv(navWad, q192, 1e30) : Math.mulDiv(1e30, q192, navWad)));
    }

    function crash(uint256 navWad) internal {
        vm.startPrank(issuer);
        market.setNav(navWad);
        desk.swapToPrice(key, sqrtPriceX96(navWad), 50_000e18);
        vm.stopPrank();
    }

    function _assertCompliance() internal view {
        assertEq(rwa.balanceOf(anon), 0, "anon never holds RWA");
        assertEq(rwa.balanceOf(address(PM)), 0, "PoolManager never holds raw RWA");
        assertEq(rwa.balanceOf(address(adapter)), 0, "adapter stateless RWA");
        assertEq(usdc.balanceOf(address(adapter)), 0, "adapter stateless USDC");
        assertEq(pa.balanceOf(address(PM)), pa.totalSupply(), "vRWA only in PM");
        assertEq(rwa.balanceOf(address(pa)), pa.totalSupply() + 1, "I8: PA backing == supply + verification deposit");
    }

    function test_e2e_crash15_fullClose_anonZeroUsdc() public {
        assertEq(market.healthFactor(borrower), 1066666666666666666);
        crash(85e18);
        emit log_named_decimal_uint("HF after crash", market.healthFactor(borrower), 18);

        // Horizon-style: anon calls the market directly -> the RWA transfer rule stops it
        vm.prank(anon);
        vm.expectRevert(abi.encodeWithSelector(MockRWA3643.NotAllowlisted.selector, anon));
        market.liquidate(borrower, type(uint256).max, "");

        assertEq(usdc.balanceOf(anon), 0);
        uint256 borrowerUsdcBefore = usdc.balanceOf(borrower);
        vm.recordLogs();
        vm.prank(anon);
        uint256 g = gasleft();
        uint256 bounty = adapter.liquidate(borrower, type(uint256).max, 1);
        g -= gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 coll, uint256 debt) = market.positions(borrower);
        emit log_named_decimal_uint("bounty to anon (USDC)", bounty, 6);
        emit log_named_decimal_uint("residual to borrower (USDC)", usdc.balanceOf(borrower) - borrowerUsdcBefore, 6);
        emit log_named_decimal_uint("collateral left (RWA)", coll, 18);
        emit log_named_uint("gas adapter.liquidate", g);
        assertEq(debt, 0);
        assertEq(usdc.balanceOf(anon), bounty);
        assertGt(bounty, 0);
        _assertCompliance();

        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(HOOK) && logs[i].topics[0] == SWAP_TOPIC) {
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(adapter)))), "Swap.sender == adapter");
                found = true;
            }
            if (logs[i].emitter == address(adapter)) {
                (uint256 repaid, uint256 seized, uint256 proceeds,,) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                emit log_named_decimal_uint("repaid (USDC)", repaid, 6);
                emit log_named_decimal_uint("seized (RWA)", seized, 18);
                emit log_named_decimal_uint("proceeds (USDC)", proceeds, 6);
            }
        }
        assertTrue(found, "real Labs hook emitted Swap");
    }

    function test_e2e_crash10_partial_restoresHealth() public {
        crash(90e18);
        vm.prank(anon);
        uint256 bounty = adapter.liquidate(borrower, type(uint256).max, 1);
        (, uint256 debt) = market.positions(borrower);
        emit log_named_decimal_uint("bounty (USDC)", bounty, 6);
        emit log_named_decimal_uint("debt left (USDC)", debt, 6);
        emit log_named_decimal_uint("HF after", market.healthFactor(borrower), 18);
        assertEq(debt, 37_500e6);
        assertGt(market.healthFactor(borrower), 1e18);
        _assertCompliance();
    }

    function test_e2e_crash30_badDebtRealized() public {
        crash(70e18);
        vm.prank(anon);
        uint256 bounty = adapter.liquidate(borrower, type(uint256).max, 0);
        emit log_named_decimal_uint("bounty (USDC)", bounty, 6);
        emit log_named_decimal_uint("bad debt (USDC)", market.totalBadDebt(), 6);
        assertGt(market.totalBadDebt(), 0);
        _assertCompliance();
    }

    function test_revert_issuerPausesSwapping() public {
        crash(85e18);
        vm.prank(issuer);
        pa.updateSwappingEnabled(false);
        vm.prank(anon);
        vm.expectRevert(); // WrappedError(hook, beforeSwap, SwappingDisabled(), HookCallFailed())
        adapter.liquidate(borrower, type(uint256).max, 1);
    }

    function test_revert_issuerRevokesAdapterSwapFlag() public {
        crash(85e18);
        uint16 holderOnly = rwa.HOLDER(); // read BEFORE prank (external call would consume it)
        vm.prank(issuer);
        rwa.setFlags(address(adapter), holderOnly);
        vm.prank(anon);
        vm.expectRevert(); // WrappedError(hook, beforeSwap, Unauthorized(), HookCallFailed())
        adapter.liquidate(borrower, type(uint256).max, 1);
    }

    function test_revert_adapterNotAllowedWrapper() public {
        crash(85e18);
        vm.prank(issuer);
        pa.updateAllowedWrapper(address(adapter), false);
        vm.prank(anon);
        vm.expectRevert();
        adapter.liquidate(borrower, type(uint256).max, 1);
    }

    function test_revert_healthy() public {
        vm.prank(anon);
        vm.expectRevert(abi.encodeWithSelector(MiniLend.Healthy.selector, 1066666666666666666));
        adapter.liquidate(borrower, type(uint256).max, 1);
    }

    function test_revert_minBountyTooHigh() public {
        crash(85e18);
        vm.prank(anon);
        vm.expectRevert(); // BountyMath.BountyTooLow
        adapter.liquidate(borrower, type(uint256).max, 1_000_000e6);
    }

    function test_thinPool_fullReverts_thenChunkSucceeds() public {
        crash(85e18);
        vm.prank(issuer);
        desk.modifyLiquidity(key, -887220, 887220, -(L * 95 / 100)); // LPs flee: 95% of liquidity removed
        vm.prank(anon);
        vm.expectRevert(); // BountyMath.InsufficientProceeds: selling 935 RWA into a 5k-RWA pool
        adapter.liquidate(borrower, type(uint256).max, 1);
        vm.prank(anon);
        uint256 bounty = adapter.liquidate(borrower, 10_000e6, 1);
        (, uint256 debt) = market.positions(borrower);
        emit log_named_decimal_uint("thin pool chunk bounty (USDC)", bounty, 6);
        emit log_named_decimal_uint("thin pool debt left (USDC)", debt, 6);
        assertEq(debt, 65_000e6);
        _assertCompliance();
    }

    function test_revert_unlockCallbackOnlyPM() public {
        vm.expectRevert(LiquidationAdapter.NotPoolManager.selector);
        adapter.unlockCallback("");
    }
}
