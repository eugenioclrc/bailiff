// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ForkBase} from "./Base.t.sol";
import {LiquidationAdapter} from "../src/e2e/LiquidationAdapter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract PartialTest is ForkBase {
    using StateLibrary for IPoolManager;

    function test_partialFill() public {
        crash(85e18);
        (, int24 tick,,) = PM.getSlot0(key.toId());
        int24 t = (tick / 60) * 60;
        vm.startPrank(issuer);
        desk.modifyLiquidity(key, -887220, 887220, -L);
        desk.modifyLiquidity(key, t - 600, t + 600, 1e15);
        vm.stopPrank();
        vm.prank(anon);
        vm.expectPartialRevert(LiquidationAdapter.PartialFill.selector);
        adapter.liquidate(borrower, type(uint256).max, 1);
    }
}
