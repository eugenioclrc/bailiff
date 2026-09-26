// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    IPermissionsAdapterFactory
} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {
    IPermissionsAdapter
} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {MockRWA3643} from "../../src/e2e/MockRWA3643.sol";
import {MiniLend} from "../../src/e2e/MiniLend.sol";
import {LiquidationAdapter, IMiniLend} from "../../src/e2e/LiquidationAdapter.sol";
import {LiquidityDesk} from "../../src/e2e/LiquidityDesk.sol";
import {ISpecMockUSDC} from "./SpecInterfaces.sol";

/// @notice Labs getters the stack-identity preflight reads (OPERATIONS O2). Not part of CONTRACTS.md.
interface ILabsHookView {
    function poolManager() external view returns (IPoolManager);
    function PERMISSIONS_ADAPTER_FACTORY() external view returns (IPermissionsAdapterFactory);
}

interface ILabsStateViewView {
    function poolManager() external view returns (IPoolManager);
}

/// @notice Test-only stand-in with the exact R2 MockUSDC ABI. Used only while src/e2e/MockUSDC.sol does not exist;
///         once it does, the fixture deploys the product artifact instead (FinalSpecFixture._usdcInitCode).
contract SpecMockUSDC is ERC20 {
    address public immutable minter;

    error OnlyMinter();

    constructor(address minter_) ERC20("USD Coin (mock)", "mUSDC") {
        minter = minter_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert OnlyMinter();
        _mint(to, amount);
    }
}

/// @notice Test-only USDC that can refuse a recipient (R2: "variante solo de test que rechaza USDC al borrower").
///         Never a product token; MockRWA3643 policy is untouched.
contract SpecBlockableUSDC is SpecMockUSDC {
    mapping(address => bool) public blocked;

    error RecipientBlocked(address to);

    constructor(address minter_) SpecMockUSDC(minter_) {}

    function setBlocked(address account, bool isBlocked) external {
        if (msg.sender != minter) revert OnlyMinter();
        blocked[account] = isBlocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0) && blocked[to]) revert RecipientBlocked(to);
        super._update(from, to, value);
    }
}

/// @notice Deploys the Bailiff acceptance world: REAL Uniswap Labs PoolManager / PermissionsAdapterFactory /
///         PermissionedHooks on a Sepolia fork pinned at 11782723, own mocks for RWA, USDC, lending and NAV, and the
///         three-role setup of OPERATIONS O3 (issuer, independent KYC market maker as sole LP, keeper with 0 USDC).
/// @dev Mirrors test/Base.t.sol:ForkBase instead of inheriting it: ForkBase.setUp is not virtual and forks latest
///      through a public endpoint, so it cannot be pinned without editing it.
abstract contract FinalSpecFixture is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------------------------ pinned stack (OPERATIONS O2)
    uint256 internal constant FORK_BLOCK = 11_782_723;
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    // hash of block 11782722, read through SEPOLIA_ARCHIVE_RPC; pins the chain history behind the fork
    bytes32 internal constant FORK_PARENT_HASH = 0x67647167c34667a6da237c1217f7ddeca82a793346e580f6fbe75d1f6b4ccc77;
    IPoolManager internal constant PM = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    IPermissionsAdapterFactory internal constant FACTORY =
        IPermissionsAdapterFactory(0xE6B0d96919334C33d06266d1420F97f6f434fA2B);
    IHooks internal constant HOOK = IHooks(0x51247E2291d290d17C08813A175AC86465EdE8c0);
    address internal constant STATE_VIEW = 0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C;
    // runtime code hashes read at FORK_BLOCK; pins the exact Labs deployment under test
    bytes32 internal constant PM_CODEHASH = 0x09930125a49f5b95caf8052991cc14d1240dca8b43f42b899115b86867e4bce1;
    bytes32 internal constant FACTORY_CODEHASH = 0x7575a119898cfe9a2163a9b4c467e6d6b5e3cc3af6f9e021a6961ab97b44f102;
    bytes32 internal constant HOOK_CODEHASH = 0xd349895123430f8cbda561f502830de91c16118ad5a348079e66efc1376ef75c;
    bytes32 internal constant STATE_VIEW_CODEHASH = 0xaaed3db8eb8ebde8014ce4c8a3938496687f4c6374e17a7d735288f6c65ceb9e;

    // ------------------------------------------------------------------ fixture constants (O3, R3, R5, R6)
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -887220;
    int24 internal constant TICK_UPPER = 887220;
    int256 internal constant L = 5e17;
    uint128 internal constant L_UNSIGNED = 5e17;
    int256 internal constant THIN_POOL_REMOVE = 4.75e17; // MM withdraws 95% of L
    uint256 internal constant NAV0 = 100e18;
    uint256 internal constant CRASH_NAV = 85e18;
    uint256 internal constant ORACLE_NAV_MIN = 10e18;
    uint256 internal constant ORACLE_NAV_MAX = 1_000e18;
    uint256 internal constant NAV_STALENESS = 1 days;
    uint256 internal constant KEEPER_BPS = 5_000;
    uint256 internal constant LB_BPS = 600;
    uint256 internal constant NAV_FLOOR_BPS = 9_900;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PRICE_SCALE = 1e30;
    uint256 internal constant Q192 = 1 << 192;
    uint256 internal constant VERIFICATION_DEPOSIT = 1;
    uint256 internal constant MM_RWA = 100_000e18;
    uint256 internal constant MM_USDC = 6_000_000e6;
    uint256 internal constant LENDER_USDC = 500_000e6;
    uint256 internal constant BORROWER_COLLATERAL = 1_000e18;
    uint256 internal constant BORROWER_DEBT = 75_000e6;
    uint256 internal constant HF_BASELINE = 1066666666666666666; // floor(1000*100*0.8/75000 * 1e18)
    uint256 internal constant HF_AFTER_CRASH = 906666666666666666; // floor(1000*85*0.8/75000 * 1e18)
    uint256 internal constant CRASH_FULL_CLOSE_SEIZE = 935294117647058823529; // floor(75000e6*10600*1e30/(85e18*1e4))
    bool internal constant DEFAULT_PA_IS_CURRENCY0 = true;
    string internal constant PRODUCT_MOCK_USDC = "src/e2e/MockUSDC.sol:MockUSDC";
    uint256 internal constant MAX_SALT_TRIES = 64;
    bytes32 internal constant PA_CREATED_TOPIC = keccak256("PermissionsAdapterCreated(address,address)");
    bytes32 internal constant PA_WRAPPER_TOPIC = keccak256("AllowedWrapperUpdated(address,bool)");

    // ------------------------------------------------------------------ roles (O3)
    address internal issuer = makeAddr("issuer"); // PA owner, oracleAdmin, minter; HOLDER only
    address internal mm = makeAddr("marketMakerKyc"); // sole LP, LiquidityDesk owner
    address internal keeper = makeAddr("keeper"); // NONE in checker, 0 USDC, 0 RWA
    address internal borrower = makeAddr("borrower"); // setup account
    address internal lender = makeAddr("lender"); // setup account

    // ------------------------------------------------------------------ fixture state
    MockRWA3643 internal rwa;
    ISpecMockUSDC internal usdc;
    IPermissionsAdapter internal pa;
    MiniLend internal market;
    LiquidationAdapter internal adapter;
    LiquidityDesk internal desk;
    PoolKey internal key;
    PoolId internal poolId;
    bool internal paIsCurrency0;
    bool internal usdcIsProductMock; // true once src/e2e/MockUSDC.sol exists and is the fixture USDC
    bool internal usdcIsBlockable; // SpecBlockableUSDC fixture
    uint256 internal fixtureCount;

    struct WrapperUpdate {
        address wrapper;
        bool allowed;
    }

    /// @notice Every AllowedWrapperUpdated the fixture PA emitted from its creation to the end of the fixture, in
    ///         order. The PA is fresh, so this is its whole wrapper history (the mapping cannot be enumerated).
    WrapperUpdate[] internal paWrapperUpdates;

    // ================================================================== setUp
    function setUp() public virtual {
        _setUpPinnedFixture(DEFAULT_PA_IS_CURRENCY0, false);
    }

    /// @notice One-liner for suites that need another default: fork, stack identity, fixture.
    function _setUpPinnedFixture(bool paIs0, bool blockableUsdc) internal {
        _selectPinnedFork();
        _assertStackIdentity();
        _deployFixture(paIs0, blockableUsdc);
    }

    function _selectPinnedFork() internal {
        vm.createSelectFork(vm.envString("SEPOLIA_ARCHIVE_RPC"), FORK_BLOCK);
        assertEq(block.number, FORK_BLOCK, "fork not pinned to 11782723");
        assertEq(block.chainid, SEPOLIA_CHAIN_ID, "fork is not Sepolia");
    }

    /// @dev Code and cross relations of the real Labs stack, checked before anything is deployed on it.
    function _assertStackIdentity() internal view {
        assertEq(address(PM).codehash, PM_CODEHASH, "PoolManager code");
        assertEq(address(FACTORY).codehash, FACTORY_CODEHASH, "PermissionsAdapterFactory code");
        assertEq(address(HOOK).codehash, HOOK_CODEHASH, "PermissionedHooks code");
        assertEq(STATE_VIEW.codehash, STATE_VIEW_CODEHASH, "StateView code");
        assertEq(FACTORY.POOL_MANAGER(), address(PM), "factory -> PM");
        assertEq(address(ILabsHookView(address(HOOK)).poolManager()), address(PM), "hook -> PM");
        assertEq(
            address(ILabsHookView(address(HOOK)).PERMISSIONS_ADAPTER_FACTORY()), address(FACTORY), "hook -> factory"
        );
        assertEq(address(ILabsStateViewView(STATE_VIEW).poolManager()), address(PM), "StateView -> PM");
    }

    // ================================================================== fixture
    /// @notice Builds a complete, independent world. Can be called again inside a test (e.g. for the other currency
    ///         order); the state variables then point at the new world.
    /// @param paIs0 true: PA sorts below USDC (PA is currency0). false: PA is currency1.
    /// @param blockableUsdc true: USDC is the test-only SpecBlockableUSDC (receiver-rejection cases).
    /// @dev Records logs from the PA creation to the end and drains them into paWrapperUpdates, so a caller that
    ///      wants its own log window calls vm.recordLogs() after this returns.
    function _deployFixture(bool paIs0, bool blockableUsdc) internal {
        fixtureCount++;
        delete paWrapperUpdates;
        _deployRwaAndVerifiedAdapter();
        _deployUsdcInOrder(paIs0, blockableUsdc);
        _initializePool();
        _deployProtocol();
        _seedRoles();
        _recordWrapperUpdates(vm.getRecordedLogs());
    }

    function _deployRwaAndVerifiedAdapter() private {
        vm.startPrank(issuer);
        rwa = new MockRWA3643(issuer);
        rwa.setFlags(issuer, rwa.HOLDER()); // O3: issuer keeps HOLDER only, no SWAP/LIQUIDITY
        vm.recordLogs();
        address created =
            FACTORY.createPermissionsAdapter(IERC20(address(rwa)), issuer, IAllowlistChecker(address(rwa)));
        Vm.Log[] memory creationLogs = vm.getRecordedLogs(); // recording stays on until _deployFixture drains it
        pa = IPermissionsAdapter(_paFromFactoryEvent(creationLogs));
        _recordWrapperUpdates(creationLogs);
        assertEq(address(pa), created, "PA from PermissionsAdapterCreated == returned PA");
        rwa.setFlags(address(pa), rwa.HOLDER());
        rwa.mint(issuer, VERIFICATION_DEPOSIT);
        rwa.approve(address(pa), VERIFICATION_DEPOSIT);
        pa.depositForVerification(VERIFICATION_DEPOSIT);
        FACTORY.verifyPermissionsAdapter(address(pa));
        pa.updateAllowedHook(HOOK, true);
        pa.updateSwappingEnabled(true);
        vm.stopPrank();
    }

    function _paFromFactoryEvent(Vm.Log[] memory logs) private view returns (address found) {
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(FACTORY) && logs[i].topics[0] == PA_CREATED_TOPIC) {
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(rwa)))), "event token == RWA");
                found = address(uint160(uint256(logs[i].topics[1])));
                n++;
            }
        }
        assertEq(n, 1, "exactly one PermissionsAdapterCreated from the real factory");
    }

    function _recordWrapperUpdates(Vm.Log[] memory logs) private {
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory lg = logs[i];
            if (lg.emitter != address(pa) || lg.topics.length != 2 || lg.topics[0] != PA_WRAPPER_TOPIC) continue;
            paWrapperUpdates.push(
                WrapperUpdate({wrapper: address(uint160(uint256(lg.topics[1]))), allowed: abi.decode(lg.data, (bool))})
            );
        }
    }

    /// @dev CREATE2 with a mined salt so the requested (PA, USDC) order holds; the PA address is fixed by the
    ///      shared factory's CREATE nonce, so only the USDC address is chosen.
    function _deployUsdcInOrder(bool paIs0, bool blockableUsdc) private {
        bytes memory initCode = _usdcInitCode(blockableUsdc);
        bytes32 initHash = keccak256(initCode);
        for (uint256 i; i < MAX_SALT_TRIES; i++) {
            bytes32 salt = keccak256(abi.encode("bailiff.finalspec.usdc", fixtureCount, i));
            address predicted = vm.computeCreate2Address(salt, initHash, address(this));
            if (predicted.code.length != 0 || (address(pa) < predicted) != paIs0) continue;
            address deployed;
            assembly ("memory-safe") {
                deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
            }
            assertEq(deployed, predicted, "USDC CREATE2 address");
            usdc = ISpecMockUSDC(deployed);
            usdcIsBlockable = blockableUsdc;
            paIsCurrency0 = paIs0;
            return;
        }
        revert("FinalSpecFixture: no USDC salt for the requested currency order");
    }

    /// @dev Product R2 MockUSDC when its artifact exists, otherwise the ABI-identical stand-in. The blockable
    ///      variant is always test-only. The minter is the issuer in every case.
    function _usdcInitCode(bool blockableUsdc) private returns (bytes memory) {
        bytes memory args = abi.encode(issuer);
        usdcIsProductMock = false;
        if (blockableUsdc) return abi.encodePacked(type(SpecBlockableUSDC).creationCode, args);
        try vm.getCode(PRODUCT_MOCK_USDC) returns (bytes memory code) {
            usdcIsProductMock = true;
            return abi.encodePacked(code, args);
        } catch {
            return abi.encodePacked(type(SpecMockUSDC).creationCode, args);
        }
    }

    function _initializePool() private {
        Currency cPa = Currency.wrap(address(pa));
        Currency cUsdc = Currency.wrap(address(usdc));
        key =
            paIsCurrency0 ? PoolKey(cPa, cUsdc, FEE, TICK_SPACING, HOOK) : PoolKey(cUsdc, cPa, FEE, TICK_SPACING, HOOK);
        poolId = key.toId();
        vm.prank(issuer);
        PM.initialize(key, sqrtPriceX96ForNav(NAV0));
    }

    function _deployProtocol() private {
        vm.startPrank(issuer);
        market = new MiniLend(
            IERC20(address(rwa)), IERC20(address(usdc)), issuer, NAV0, ORACLE_NAV_MIN, ORACLE_NAV_MAX, NAV_STALENESS
        );
        adapter = new LiquidationAdapter(
            PM, FACTORY, pa, IERC20(address(usdc)), IMiniLend(address(market)), HOOK, FEE, TICK_SPACING, KEEPER_BPS
        );
        desk = new LiquidityDesk(PM, pa, mm);
        uint16 holder = rwa.HOLDER();
        rwa.setFlags(address(market), holder);
        rwa.setFlags(address(adapter), holder | rwa.SWAP());
        rwa.setFlags(address(desk), holder);
        rwa.setFlags(mm, holder | rwa.SWAP() | rwa.LIQUIDITY());
        rwa.setFlags(borrower, holder);
        pa.updateAllowedWrapper(address(adapter), true);
        pa.updateAllowedWrapper(address(desk), true);
        vm.stopPrank();
    }

    function _seedRoles() private {
        // the minter (issuer) distributes demo mocks; the keeper never receives any
        vm.startPrank(issuer);
        rwa.mint(mm, MM_RWA);
        usdc.mint(mm, MM_USDC);
        usdc.mint(lender, LENDER_USDC);
        rwa.mint(borrower, BORROWER_COLLATERAL);
        vm.stopPrank();
        // the independent MM funds its desk and is the only LP
        vm.startPrank(mm);
        assertTrue(rwa.transfer(address(desk), MM_RWA), "MM funds desk RWA");
        assertTrue(usdc.transfer(address(desk), MM_USDC), "MM funds desk USDC");
        desk.modifyLiquidity(key, TICK_LOWER, TICK_UPPER, L);
        vm.stopPrank();
        vm.startPrank(lender);
        usdc.approve(address(market), type(uint256).max);
        market.supply(LENDER_USDC);
        vm.stopPrank();
        vm.startPrank(borrower);
        rwa.approve(address(market), type(uint256).max);
        market.depositCollateral(BORROWER_COLLATERAL);
        market.borrow(BORROWER_DEBT);
        vm.stopPrank();
        vm.deal(keeper, 1 ether); // gas only
    }

    // ================================================================== role actions
    /// @notice O4 Crash: exactly market.setNav(85e18) by the issuer. No swap, no liquidity change.
    function crashNav() internal {
        setNavAsIssuer(CRASH_NAV);
    }

    function setNavAsIssuer(uint256 newNav) internal {
        vm.prank(issuer);
        market.setNav(newNav);
    }

    function mmModifyLiquidity(int256 liquidityDelta) internal {
        vm.prank(mm);
        desk.modifyLiquidity(key, TICK_LOWER, TICK_UPPER, liquidityDelta);
    }

    /// @notice O7 thin pool: the MM removes 4.75e17 of its 5e17.
    function mmThinPool() internal {
        mmModifyLiquidity(-THIN_POOL_REMOVE);
    }

    /// @notice Explicit test fixture only (R6): the MM moves spot. Never part of Crash.
    function mmSwapToPrice(uint160 targetSqrtPriceX96, uint256 maxIn) internal {
        vm.prank(mm);
        desk.swapToPrice(key, targetSqrtPriceX96, maxIn);
    }

    /// @notice Only valid on a fixture built with blockableUsdc = true.
    function setUsdcRecipientBlocked(address account, bool isBlocked) internal {
        assertTrue(usdcIsBlockable, "fixture USDC is not the blockable test variant");
        vm.prank(issuer);
        SpecBlockableUSDC(address(usdc)).setBlocked(account, isBlocked);
    }

    // ================================================================== pricing and spec math
    /// @notice O3 quote: PA currency0 sqrt(P*2^192/1e30), reverse sqrt(1e30*2^192/P); floor, as the snapshot does.
    function sqrtPriceX96ForNav(uint256 navWad) internal view returns (uint160) {
        return sqrtPriceX96ForNav(navWad, paIsCurrency0);
    }

    function sqrtPriceX96ForNav(uint256 navWad, bool paIs0) internal pure returns (uint160) {
        uint256 ratio = paIs0 ? Math.mulDiv(navWad, Q192, PRICE_SCALE) : Math.mulDiv(PRICE_SCALE, Q192, navWad);
        return toSqrtPriceX96(Math.sqrt(ratio));
    }

    /// @notice R5 conservative NAV-floor limit, exactly as the table in CONTRACTS.md:
    ///         p = ceil(nav*9900/10000); PA currency0: ceil_sqrt(ceil(p*Q/S)); PA currency1: floor_sqrt(floor(S*Q/p)).
    /// @dev Returned unbounded (uint256) so boundary tests can check the TickMath bounds before any cast.
    function navFloorLimitSqrtPriceX96(uint256 navWad, bool paIs0) internal pure returns (uint256) {
        uint256 p = Math.mulDiv(navWad, NAV_FLOOR_BPS, BPS, Math.Rounding.Ceil);
        if (paIs0) return Math.sqrt(Math.mulDiv(p, Q192, PRICE_SCALE, Math.Rounding.Ceil), Math.Rounding.Ceil);
        return Math.sqrt(Math.mulDiv(PRICE_SCALE, Q192, p), Math.Rounding.Floor);
    }

    function navFloorLimitSqrtPriceX96(uint256 navWad) internal view returns (uint160) {
        return toSqrtPriceX96(navFloorLimitSqrtPriceX96(navWad, paIsCurrency0));
    }

    function spotSqrtPriceX96() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = PM.getSlot0(poolId);
    }

    /// @notice R4 split recomputed independently: bounty = min(floor(surplus*keeperBps/B), floor(repaid*lb/B)).
    function expectedSplit(uint256 proceeds, uint256 repaid) internal pure returns (uint256 bounty, uint256 residual) {
        uint256 surplus = proceeds - repaid;
        bounty = Math.min(surplus * KEEPER_BPS / BPS, repaid * LB_BPS / BPS);
        residual = surplus - bounty;
    }

    /// @notice R3 seize for a nominal repay at a NAV: floor(repay*(B+LB)*S/(nav*B)).
    function expectedSeize(uint256 repay, uint256 navWad) internal pure returns (uint256) {
        return Math.mulDiv(repay * (BPS + LB_BPS), PRICE_SCALE, navWad * BPS);
    }

    /// @notice Revert data the real PoolManager produces when the Labs hook rejects inside beforeSwap.
    function hookWrappedError(bytes memory hookReason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(HOOK),
            IHooks.beforeSwap.selector,
            hookReason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @notice Validated narrowing: strictly inside (TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE).
    function toSqrtPriceX96(uint256 v) internal pure returns (uint160) {
        assertGt(v, uint256(TickMath.MIN_SQRT_PRICE), "sqrtPrice above TickMath.MIN_SQRT_PRICE");
        assertLt(v, uint256(TickMath.MAX_SQRT_PRICE), "sqrtPrice below TickMath.MAX_SQRT_PRICE");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(v); // bounded by the two assertions above
    }
}
