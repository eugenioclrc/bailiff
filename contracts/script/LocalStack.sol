// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Shared constants and preflight for the local demo deploy (scripts/deploy-local.sh). Mirrors
// test/finalspec/FinalSpecFixture.sol on a running local Anvil fork of Sepolia.

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    IPermissionsAdapterFactory
} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {ILabsHookView, ILabsStateViewView} from "../test/finalspec/FinalSpecFixture.sol";

abstract contract LocalStack is Script {
    // ------------------------------------------------------------------ pinned stack (OPERATIONS O2)
    uint256 internal constant LOCAL_CHAIN_ID = 31_337;
    IPoolManager internal constant PM = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    IPermissionsAdapterFactory internal constant FACTORY =
        IPermissionsAdapterFactory(0xE6B0d96919334C33d06266d1420F97f6f434fA2B);
    IHooks internal constant HOOK = IHooks(0x51247E2291d290d17C08813A175AC86465EdE8c0);
    address internal constant STATE_VIEW = 0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C;
    bytes32 internal constant PM_CODEHASH = 0x09930125a49f5b95caf8052991cc14d1240dca8b43f42b899115b86867e4bce1;
    bytes32 internal constant FACTORY_CODEHASH = 0x7575a119898cfe9a2163a9b4c467e6d6b5e3cc3af6f9e021a6961ab97b44f102;
    bytes32 internal constant HOOK_CODEHASH = 0xd349895123430f8cbda561f502830de91c16118ad5a348079e66efc1376ef75c;
    bytes32 internal constant STATE_VIEW_CODEHASH = 0xaaed3db8eb8ebde8014ce4c8a3938496687f4c6374e17a7d735288f6c65ceb9e;

    // ------------------------------------------------------------------ fixture constants (O3), same as the fixture
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -887220;
    int24 internal constant TICK_UPPER = 887220;
    int256 internal constant L = 5e17;
    uint128 internal constant L_UNSIGNED = 5e17;
    uint256 internal constant NAV0 = 100e18;
    uint256 internal constant ORACLE_NAV_MIN = 10e18;
    uint256 internal constant ORACLE_NAV_MAX = 1_000e18;
    uint256 internal constant NAV_STALENESS = 1 days;
    uint256 internal constant KEEPER_BPS = 5_000;
    uint256 internal constant PRICE_SCALE = 1e30;
    uint256 internal constant Q192 = 1 << 192;
    uint256 internal constant VERIFICATION_DEPOSIT = 1;
    uint256 internal constant MM_RWA = 100_000e18;
    uint256 internal constant MM_USDC = 6_000_000e6;
    uint256 internal constant LENDER_USDC = 500_000e6;
    uint256 internal constant BORROWER_COLLATERAL = 1_000e18;
    uint256 internal constant BORROWER_DEBT = 75_000e6;
    uint256 internal constant HF_BASELINE = 1066666666666666666;
    uint16 internal constant HOLDER = 0x8000;
    uint16 internal constant SWAP = 0x0001;
    uint16 internal constant LIQUIDITY = 0x0002;

    /// @dev Refuses anything that is not the local Anvil fork carrying the exact Labs deployment.
    function _preflight() internal view {
        require(block.chainid == LOCAL_CHAIN_ID, "LocalStack: not chain 31337 (local Anvil only)");
        require(address(PM).codehash == PM_CODEHASH, "LocalStack: PoolManager code");
        require(address(FACTORY).codehash == FACTORY_CODEHASH, "LocalStack: factory code");
        require(address(HOOK).codehash == HOOK_CODEHASH, "LocalStack: hook code");
        require(STATE_VIEW.codehash == STATE_VIEW_CODEHASH, "LocalStack: StateView code");
        require(FACTORY.POOL_MANAGER() == address(PM), "LocalStack: factory -> PM");
        require(address(ILabsHookView(address(HOOK)).poolManager()) == address(PM), "LocalStack: hook -> PM");
        require(
            address(ILabsHookView(address(HOOK)).PERMISSIONS_ADAPTER_FACTORY()) == address(FACTORY),
            "LocalStack: hook -> factory"
        );
        require(address(ILabsStateViewView(STATE_VIEW).poolManager()) == address(PM), "LocalStack: StateView -> PM");
    }

    /// @notice O3 quote: PA currency0 sqrt(P*2^192/1e30), reverse sqrt(1e30*2^192/P); floor.
    function _sqrtPriceX96ForNav(uint256 navWad, bool paIs0) internal pure returns (uint160) {
        uint256 ratio = paIs0 ? Math.mulDiv(navWad, Q192, PRICE_SCALE) : Math.mulDiv(PRICE_SCALE, Q192, navWad);
        uint256 s = Math.sqrt(ratio);
        require(s > TickMath.MIN_SQRT_PRICE && s < TickMath.MAX_SQRT_PRICE, "LocalStack: sqrtPrice out of range");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(s); // bounded above
    }
}
