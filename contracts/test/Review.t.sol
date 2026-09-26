// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ForkBase} from "./Base.t.sol";
import {LiquidationAdapter} from "../src/e2e/LiquidationAdapter.sol";
import {MiniLend} from "../src/e2e/MiniLend.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract ReviewTest is ForkBase {
    using StateLibrary for IPoolManager;

    // deployed PA (factory 0xE6B0 bytecode): renounceOwnership reverts?
    function test_deployedPA_renounceReverts() public {
        vm.prank(issuer);
        (bool ok, bytes memory ret) = address(pa).call(abi.encodeWithSignature("renounceOwnership()"));
        emit log_named_bytes("ret", ret);
        assertFalse(ok, "renounce should revert");
    }

    // deployed hook 0x5124 does NOT enforce allowedHooks: desk (no check) swaps fine after revocation
    function test_deployedHook_ignoresAllowedHooks() public {
        vm.prank(issuer);
        pa.updateAllowedHook(HOOK, false);
        assertFalse(pa.allowedHooks(HOOK));
        crash(85e18); // desk swap through hook
        (uint160 p,,,) = PM.getSlot0(key.toId());
        assertEq(p, sqrtPriceX96(85e18));
    }

    function test_adapter_hookNotAllowed() public {
        crash(85e18);
        vm.prank(issuer);
        pa.updateAllowedHook(HOOK, false);
        vm.prank(anon);
        vm.expectRevert(LiquidationAdapter.HookNotAllowed.selector);
        adapter.liquidate(borrower, type(uint256).max, 1);
    }

    function test_adapter_staleNav() public {
        crash(85e18);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(anon);
        vm.expectRevert(MiniLend.StaleNav.selector);
        adapter.liquidate(borrower, type(uint256).max, 1);
    }

    // frozen borrower still liquidatable
    function test_frozenBorrowerLiquidatable() public {
        crash(85e18);
        vm.prank(issuer);
        rwa.setFrozen(borrower, true);
        vm.prank(anon);
        adapter.liquidate(borrower, type(uint256).max, 1);
        (, uint256 debt) = market.positions(borrower);
        assertEq(debt, 0);
    }

    // token paused: liquidation blocked (Market->Adapter transfer)
    function test_tokenPaused_blocksLiquidation() public {
        crash(85e18);
        vm.prank(issuer);
        rwa.setPaused(true);
        vm.prank(anon);
        vm.expectRevert();
        adapter.liquidate(borrower, type(uint256).max, 1);
    }

    // Reset: price back up via desk
    function test_reset_swapUp() public {
        crash(85e18);
        vm.prank(anon);
        adapter.liquidate(borrower, type(uint256).max, 1);
        vm.startPrank(issuer);
        market.setNav(100e18);
        desk.swapToPrice(key, sqrtPriceX96(100e18), 50_000e18);
        vm.stopPrank();
        (uint160 p,,,) = PM.getSlot0(key.toId());
        emit log_named_uint("sqrtP after reset", p);
        emit log_named_uint("target", sqrtPriceX96(100e18));
    }

    // keeper-bot style: after full close by bot, second call Healthy? (debt 0 => hf max)
    function test_secondCallAfterFullClose() public {
        crash(85e18);
        vm.prank(anon);
        adapter.liquidate(borrower, type(uint256).max, 1);
        vm.prank(anon);
        vm.expectRevert();
        adapter.liquidate(borrower, type(uint256).max, 0);
    }
}
