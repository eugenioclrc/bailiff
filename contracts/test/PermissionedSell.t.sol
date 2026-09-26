// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PermissionsAdapterFactory} from "@uniswap/v4-periphery/src/hooks/permissionedPools/PermissionsAdapterFactory.sol";
import {PermissionsAdapter} from "@uniswap/v4-periphery/src/hooks/permissionedPools/PermissionsAdapter.sol";
import {IPermissionsAdapter} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {PermissionFlags} from "@uniswap/v4-periphery/src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {PermissionedHooks} from "../src/vendor/permissioned-pools/PermissionedHooks.sol";
import {MockRWA, RWAAllowlistChecker} from "../src/MockRWA.sol";
import {ToyLiquidityWrapper} from "../src/ToyLiquidityWrapper.sol";
import {ToyLiquidationSeller} from "../src/ToyLiquidationSeller.sol";

contract PermissionedSellTest is Test {
    uint256 constant VERIFICATION_DEPOSIT = 1 ether;
    uint256 constant SEIZED = 10 ether; // RWA the seller holds (stand-in for seized collateral)

    PoolManager manager;
    PermissionsAdapterFactory factory;
    PermissionedHooks hook;
    MockRWA rwa;
    RWAAllowlistChecker checker;
    PermissionsAdapter pa;
    MockERC20 usdc;
    PoolKey key;
    ToyLiquidityWrapper lp;
    ToyLiquidationSeller seller;
    address anon = makeAddr("anonLiquidator");

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new PermissionsAdapterFactory(address(manager));

        // mine-free hook deploy: put the code at an address whose low 14 bits == permission flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags ^ (uint160(0x4444) << 144));
        deployCodeTo("PermissionedHooks.sol:PermissionedHooks", abi.encode(manager, factory), hookAddr);
        hook = PermissionedHooks(hookAddr);

        // issuer (this test contract) creates the RWA, the checker and the adapter
        rwa = new MockRWA();
        checker = new RWAAllowlistChecker();
        pa = PermissionsAdapter(factory.createPermissionsAdapter(IERC20(address(rwa)), address(this), checker));

        // verification: adapter must be on the RWA allowlist and hold > 0 RWA; verify() is permissionless
        rwa.setVerified(address(pa), true);
        rwa.mint(address(this), 1_000_000 ether);
        rwa.approve(address(pa), VERIFICATION_DEPOSIT);
        pa.depositForVerification(VERIFICATION_DEPOSIT);
        vm.prank(makeAddr("randomVerifier"));
        factory.verifyPermissionsAdapter(address(pa));

        usdc = new MockERC20("USD Coin", "USDC", 6);

        (Currency c0, Currency c1) = address(pa) < address(usdc)
            ? (Currency.wrap(address(pa)), Currency.wrap(address(usdc)))
            : (Currency.wrap(address(usdc)), Currency.wrap(address(pa)));
        key = PoolKey(c0, c1, 3000, 60, IHooks(address(hook)));

        // price: 1 RWA (1e18) = 100 USDC (100e6) -> raw price vRWA->USDC = 1e-10 -> sqrt = 1e-5
        uint160 sqrtPriceX96 = address(pa) < address(usdc) ? uint160(uint256(2 ** 96) / 1e5) : uint160(2 ** 96 * 1e5);
        manager.initialize(key, sqrtPriceX96);

        // adapter config (owner-only)
        pa.updateAllowedHook(IHooks(address(hook)), true);
        pa.updateSwappingEnabled(true);

        lp = new ToyLiquidityWrapper(manager, pa);
        seller = new ToyLiquidationSeller(manager, pa, key);
        pa.updateAllowedWrapper(address(lp), true);
        pa.updateAllowedWrapper(address(seller), true);

        checker.setFlags(address(this), PermissionFlags.ALL_ALLOWED); // lp.msgSender() == this (issuer as LP)
        checker.setFlags(address(seller), PermissionFlags.SWAP_ALLOWED); // seller.msgSender() == seller

        // RWA-level allowlist: only contracts that HOLD the raw RWA. PoolManager is deliberately NOT verified.
        rwa.setVerified(address(lp), true);
        rwa.setVerified(address(seller), true);

        // seed liquidity: 10k RWA + ~1M USDC full range
        rwa.transfer(address(lp), 20_000 ether);
        usdc.mint(address(lp), 2_000_000e6);
        lp.addLiquidity(key, -887220, 887220, 1e17);

        rwa.transfer(address(seller), SEIZED);
    }

    function test_anonWithZeroUsdc_sellsPermissionedTokenViaAllowlistedWrapper() public {
        assertEq(usdc.balanceOf(anon), 0);
        uint256 paRwaBefore = rwa.balanceOf(address(pa));
        uint256 pmAdapterBefore = pa.balanceOf(address(manager));

        vm.prank(anon);
        uint256 out = seller.sell(uint128(SEIZED), 990e6, false); // ~1000 USDC minus fee/impact

        assertEq(usdc.balanceOf(anon), out, "anon got USDC");
        assertGt(out, 990e6);
        emit log_named_uint("USDC out for 10 RWA", out);
        assertEq(rwa.balanceOf(address(seller)), 0, "seller sold all RWA");
        assertEq(rwa.balanceOf(anon), 0, "RWA never reached anon");
        assertEq(rwa.balanceOf(address(manager)), 0, "PoolManager never holds raw RWA");
        assertEq(rwa.balanceOf(address(pa)) - paRwaBefore, SEIZED, "RWA custody moved into the adapter");
        assertEq(pa.balanceOf(address(manager)) - pmAdapterBefore, SEIZED, "PM holds the vRWA claim");
        assertEq(pa.totalSupply(), pa.balanceOf(address(manager)), "PM is sole vRWA holder");
    }

    function test_revert_wrapperNotInAllowedWrappers() public {
        pa.updateAllowedWrapper(address(seller), false);
        vm.expectRevert(_hookRevert(IHooks.beforeSwap.selector, PermissionedHooks.Unauthorized.selector));
        vm.prank(anon);
        seller.sell(uint128(SEIZED), 0, false);
    }

    function test_revert_wrapperNotSwapAllowed() public {
        checker.setFlags(address(seller), PermissionFlags.LIQUIDITY_ALLOWED);
        vm.expectRevert(_hookRevert(IHooks.beforeSwap.selector, PermissionedHooks.Unauthorized.selector));
        vm.prank(anon);
        seller.sell(uint128(SEIZED), 0, false);
    }

    function test_revert_issuerDisablesSwapping() public {
        pa.updateSwappingEnabled(false);
        vm.expectRevert(_hookRevert(IHooks.beforeSwap.selector, PermissionedHooks.SwappingDisabled.selector));
        vm.prank(anon);
        seller.sell(uint128(SEIZED), 0, false);
    }

    function test_revert_rwaNotVerifiedForSeller() public {
        // the seller can swap but cannot move the underlying into the adapter -> settle leg reverts
        rwa.setVerified(address(seller), false);
        vm.expectRevert(abi.encodeWithSelector(MockRWA.NotAllowlisted.selector, address(seller)));
        vm.prank(anon);
        seller.sell(uint128(SEIZED), 0, false);
    }

    function test_naive_horizonStyle_transferToAnonReverts() public {
        vm.prank(address(seller));
        vm.expectRevert(abi.encodeWithSelector(MockRWA.NotAllowlisted.selector, anon));
        rwa.transfer(anon, 1 ether);
    }

    function test_revert_directVRWATransferByNonPoolManager() public {
        // the adapter token cannot be moved by anyone but the PoolManager (no CurrencySettler-style settle)
        vm.expectRevert(abi.encodeWithSelector(IPermissionsAdapter.InvalidTransfer.selector, address(this), address(manager)));
        pa.transfer(address(manager), 0);
    }

    function test_gotcha_verificationDepositIsWrappableSurplus() public {
        // An allowed wrapper that holds ZERO RWA can settle a sale using the adapter's un-minted surplus
        // (balanceOf(adapter) - totalSupply), which initially is exactly the verification deposit.
        ToyLiquidationSeller broke = new ToyLiquidationSeller(manager, pa, key);
        pa.updateAllowedWrapper(address(broke), true);
        checker.setFlags(address(broke), PermissionFlags.SWAP_ALLOWED);
        assertEq(rwa.balanceOf(address(broke)), 0);
        uint256 surplus = rwa.balanceOf(address(pa)) - pa.totalSupply();
        assertEq(surplus, VERIFICATION_DEPOSIT);

        vm.prank(anon);
        uint256 out = broke.sell(uint128(VERIFICATION_DEPOSIT), 0, true);
        assertGt(out, 0, "sold the verification deposit for free");
        assertEq(rwa.balanceOf(address(pa)) - pa.totalSupply(), 0, "surplus consumed");
        emit log_named_uint("USDC extracted from verification deposit", out);
    }

    function _hookRevert(bytes4 hookSelector, bytes4 inner) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hookSelector,
            abi.encodeWithSelector(inner),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}
