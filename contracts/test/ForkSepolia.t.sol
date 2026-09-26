// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermissionsAdapterFactory} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {IPermissionsAdapter} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {PermissionFlags} from "@uniswap/v4-periphery/src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {MockRWA, RWAAllowlistChecker} from "../src/MockRWA.sol";
import {ToyLiquidityWrapper} from "../src/ToyLiquidityWrapper.sol";
import {ToyLiquidationSeller} from "../src/ToyLiquidationSeller.sol";

/// @notice Same flow as PermissionedSellTest but against the REAL Uniswap Labs deployments on Sepolia.
contract ForkSepoliaTest is Test {
    IPoolManager constant PM = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    IPermissionsAdapterFactory constant FACTORY = IPermissionsAdapterFactory(0xE6B0d96919334C33d06266d1420F97f6f434fA2B);
    IHooks constant HOOK = IHooks(0x51247E2291d290d17C08813A175AC86465EdE8c0);

    function test_fork_anonSellsThroughRealPermissionedHooks() public {
        vm.createSelectFork("https://ethereum-sepolia-rpc.publicnode.com");
        address anon = makeAddr("anonLiquidator");

        MockRWA rwa = new MockRWA();
        RWAAllowlistChecker checker = new RWAAllowlistChecker();
        IPermissionsAdapter pa =
            IPermissionsAdapter(FACTORY.createPermissionsAdapter(IERC20(address(rwa)), address(this), checker));
        rwa.setVerified(address(pa), true);
        rwa.mint(address(this), 1_000_000 ether);
        rwa.approve(address(pa), 1);
        pa.depositForVerification(1);
        FACTORY.verifyPermissionsAdapter(address(pa));

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        bool paIs0 = address(pa) < address(usdc);
        PoolKey memory key = paIs0
            ? PoolKey(Currency.wrap(address(pa)), Currency.wrap(address(usdc)), 3000, 60, HOOK)
            : PoolKey(Currency.wrap(address(usdc)), Currency.wrap(address(pa)), 3000, 60, HOOK);
        PM.initialize(key, paIs0 ? uint160(uint256(2 ** 96) / 1e5) : uint160(2 ** 96 * 1e5));

        pa.updateAllowedHook(HOOK, true);
        pa.updateSwappingEnabled(true);
        ToyLiquidityWrapper lp = new ToyLiquidityWrapper(PM, pa);
        ToyLiquidationSeller seller = new ToyLiquidationSeller(PM, pa, key);
        pa.updateAllowedWrapper(address(lp), true);
        pa.updateAllowedWrapper(address(seller), true);
        checker.setFlags(address(this), PermissionFlags.ALL_ALLOWED);
        checker.setFlags(address(seller), PermissionFlags.SWAP_ALLOWED);
        rwa.setVerified(address(lp), true);
        rwa.setVerified(address(seller), true);

        require(rwa.transfer(address(lp), 20_000 ether));
        usdc.mint(address(lp), 2_000_000e6);
        lp.addLiquidity(key, -887220, 887220, 1e17);
        require(rwa.transfer(address(seller), 10 ether));

        emit log_named_uint("fork block", block.number);
        vm.recordLogs();
        vm.prank(anon);
        uint256 out = seller.sell(10 ether, 990e6, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(HOOK) && logs[i].topics[0] == swapTopic) {
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(seller)))), "hook Swap.sender == seller");
                found = true;
            }
        }
        assertTrue(found, "real hook emitted Swap");
        emit log_named_uint("fork: USDC out for 10 RWA", out);
        assertEq(usdc.balanceOf(anon), out);
        assertEq(rwa.balanceOf(anon), 0);
        assertEq(rwa.balanceOf(address(PM)), 0);
        assertEq(pa.totalSupply(), pa.balanceOf(address(PM)));
    }
}
