// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    IPermissionsAdapterFactory
} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {
    IPermissionsAdapter
} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {PermissionFlags} from "@uniswap/v4-periphery/src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {MockRWA3643} from "../../src/e2e/MockRWA3643.sol";
import {MiniLend} from "../../src/e2e/MiniLend.sol";
import {LiquidationAdapter, IMiniLend} from "../../src/e2e/LiquidationAdapter.sol";
import {LiquidityDesk} from "../../src/e2e/LiquidityDesk.sol";
import {BountyMath} from "../../src/e2e/BountyMath.sol";
import {ISpecMiniLend, ISpecMockUSDC, ISpecLiquidationAdapter} from "./SpecInterfaces.sol";
import {ILabsHookView, ILabsStateViewView, SpecMockUSDC} from "./FinalSpecFixture.sol";
import {FinalSpecBase} from "./FinalSpecBase.sol";

/// @notice Test-only stand-in with the factory view surface R5 reads. It reports the fixture PA as verified so a
///         constructor case breaks exactly one relation. It creates, verifies and hosts nothing.
contract ConfigFactory {
    address public immutable POOL_MANAGER;
    address internal immutable reportedAdapter;
    address internal immutable reportedToken;

    constructor(address poolManager_, address permissionsAdapter_, address token_) {
        POOL_MANAGER = poolManager_;
        reportedAdapter = permissionsAdapter_;
        reportedToken = token_;
    }

    function permissionsAdapterOf(address permissionsAdapter) external view returns (address) {
        return permissionsAdapter == reportedAdapter ? reportedToken : address(0);
    }

    function verifiedPermissionsAdapterOf(address permissionsAdapter) external view returns (address) {
        return permissionsAdapter == reportedAdapter ? reportedToken : address(0);
    }
}

/// @notice Test-only stand-in with the two PermissionedHooks getters R5 cross-checks. Never used in a pool.
contract ConfigHook {
    IPoolManager public immutable poolManager;
    IPermissionsAdapterFactory public immutable PERMISSIONS_ADAPTER_FACTORY;

    constructor(IPoolManager poolManager_, IPermissionsAdapterFactory factory_) {
        poolManager = poolManager_;
        PERMISSIONS_ADAPTER_FACTORY = factory_;
    }
}

/// @notice Roles piece of the TRACEABILITY fork acceptance: pinned Labs stack, R2 MockUSDC, R5 constructor, keeper
///         outside the holder set, O3/O7 three-role NAV-only demo. Each test's NatSpec states GREEN/RED on the snapshot.
contract RolesTest is FinalSpecBase {
    using StateLibrary for IPoolManager;
    using TickBitmap for mapping(int16 => uint256);

    uint256 internal constant FORK_TIMESTAMP = 1_790_382_672; // read at FORK_BLOCK
    uint256 internal constant CRASH_DELAY = 1 hours; // crash later than deploy so navUpdatedAt must move
    uint256 internal constant NAV_FLOOR_PRICE_AT_CRASH = 84.15e18; // ceil(85e18 * 9900 / 10000)
    // O7 amounts measured on the real PoolManager; each proceeds also equals the independent _quoteSale
    uint256 internal constant FULL_CLOSE_PROCEEDS = 91_541_594_333; // O7 estimate 91,541.59
    uint256 internal constant FULL_CLOSE_BOUNTY = 4_500e6; // LB cap binds: 75000e6 * 600 / 10000
    uint256 internal constant FULL_CLOSE_RESIDUAL = 12_041_594_333; // O7 borrower credit 12,041.59
    uint256 internal constant CHUNK = 10_000e6; // O7 nominal tranche
    uint256 internal constant CHUNK_SEIZE = 124_705_882_352_941_176_470; // floor(10000e6*10600*1e30/(85e18*1e4))
    uint256 internal constant CHUNK_PROCEEDS = 12_402_336_383;
    uint256 internal constant CHUNK_BOUNTY = 600e6; // LB cap binds: 10000e6 * 600 / 10000
    uint256 internal constant MIN_BOUNTY_PCT = 97; // O5/O6: minBounty = floor(quote * 97 / 100)
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    uint256 internal constant POOL_HEADER_WORDS = 4; // Pool.State: slot0, feeGrowthGlobal0X128/1X128, liquidity

    // R5 constructor relations, indexes into _relations()
    uint256 internal constant REL_HOOK_FACTORY = 0;
    uint256 internal constant REL_FACTORY_PM = 1;
    uint256 internal constant REL_PA_PM = 2;
    uint256 internal constant REL_HOOK_PM = 3;
    uint256 internal constant REL_MARKET_RWA = 4;
    uint256 internal constant REL_MARKET_USDC = 5;
    uint256 internal constant REL_KEEPER_BPS = 6;
    uint256 internal constant REL_VERIFIED = 7;

    /// @dev Mirror of the pool's tick bitmap (only the MM range); _nextTick checks each word against the real pool.
    mapping(int16 => uint256) internal mmTickBitmap;

    struct QuoteState {
        uint160 price;
        int24 tick;
        uint128 liquidity;
        uint24 lpFee;
        uint160 limit;
        bool zeroForOne;
        int256 remaining;
        uint256 amountOut;
    }

    /// @dev Pool state a NAV update must leave bit for bit: the decoded slot0 tuple and the raw Pool.State header.
    struct PoolStorage {
        uint160 price;
        int24 tick;
        uint24 protocolFee;
        uint24 lpFee;
        bytes32[] header;
    }

    struct AdapterArgs {
        IPoolManager pm;
        IPermissionsAdapterFactory factory;
        IPermissionsAdapter pa;
        IERC20 usdc;
        IMiniLend market;
        IHooks hooks;
        uint256 keeperBps;
    }

    function setUp() public override {
        super.setUp();
        mmTickBitmap.flipTick(TICK_LOWER, TICK_SPACING);
        mmTickBitmap.flipTick(TICK_UPPER, TICK_SPACING);
    }

    // ================================================================== tests
    /// @notice GREEN. Block 11782723; pinned non-empty code; factory/hook/PA/StateView point at the expected PM; hook
    ///         surface; Bailiff contracts wired to that stack; block data and codehashes logged as evidence.
    function test_stackIdentity() public {
        assertEq(block.number, 11_782_723, "fork pinned to Sepolia block 11782723");
        assertEq(block.chainid, 11_155_111, "Sepolia chain id");
        assertEq(blockhash(11_782_722), FORK_PARENT_HASH, "parent hash of the pinned block");
        assertEq(block.timestamp, FORK_TIMESTAMP, "timestamp of the pinned block");
        _assertLabsStack();
        _assertHookSurface();
        _assertFixtureOnPinnedStack();
        emit log_named_bytes32("fork parent hash", blockhash(block.number - 1));
        emit log_named_bytes32("fixture poolId", PoolId.unwrap(poolId));
    }

    /// @notice RED (R2 missing). The fixture USDC is the product MockUSDC (6 decimals, R2 name/symbol, minter = issuer);
    ///         only the minter mints (OnlyMinter otherwise), it minted exactly the O3 fixture, the keeper stays at 0.
    function test_mockUsdcOnlyMinter() public {
        _assertProductMockUsdcExists();
        assertTrue(usdcIsProductMock, "fixture USDC is the product MockUSDC");
        ISpecMockUSDC twin = ISpecMockUSDC(deployCode(PRODUCT_MOCK_USDC, abi.encode(issuer)));
        // size, not codehash: an address-bound immutable (e.g. an EIP-712 domain) would differ per deployment
        assertEq(address(usdc).code.length, address(twin).code.length, "fixture USDC runs the product runtime");
        _assertR2Metadata(usdc);
        _assertR2Metadata(twin);
        assertEq(twin.totalSupply(), 0, "no premint in the constructor");
        assertEq(usdc.balanceOf(keeper), 0, "keeper starts at 0 USDC");
        _assertFixtureDistribution();
        _assertOnlyMinterMints(usdc);
        _assertOnlyMinterMints(twin); // the deployer (this test) is not the minter either
        _assertMinterMints(1_000e6);
        assertEq(usdc.balanceOf(keeper), 0, "keeper still at 0 USDC");
    }

    /// @notice RED (no BadConfig). Unverified PA -> AdapterNotVerified; keeperBps > 10000 and each broken relation (hook->
    ///         factory, factory->PM, PA->PM, hook->PM, market->RWA/USDC) -> BadConfig, one relation per case, no deploy.
    function test_constructorRejectsBadConfig() public {
        World memory pre = captureWorld(borrower);
        AdapterArgs memory valid =
            AdapterArgs(PM, FACTORY, pa, IERC20(address(usdc)), IMiniLend(address(market)), HOOK, KEEPER_BPS);
        AdapterArgs memory atBound = _copy(valid);
        atBound.keeperBps = 10_000;
        _assertAdapterDeploys(atBound); // control: keeperBps upper bound is valid
        _assertAdapterReverts(
            _unverifiedPaArgs(valid),
            abi.encodeWithSelector(ISpecLiquidationAdapter.AdapterNotVerified.selector),
            REL_VERIFIED,
            "PA created by the real factory, never verified"
        );
        _assertCrossRelationsRejected(valid);
        _assertMarketTokensRejected(valid);
        assertWorldUnchanged(pre);
    }

    /// @notice GREEN. Same unhealthy borrower and keeper (NONE, 0 USDC, no approvals): direct route NotAllowlisted for any
    ///         size, callback or capital; the adapter succeeds twice (tranche, full close) and the keeper holds only USDC.
    function test_anonDirectFails_adapterSucceeds() public {
        _assertKeeperOutsideHolderSet();
        vm.warp(block.timestamp + CRASH_DELAY);
        _crashNavOnly();
        assertEq(market.healthFactor(borrower), HF_AFTER_CRASH, "unhealthy after the NAV-only crash");
        _assertDirectRejected(CHUNK, "");
        _assertDirectRejected(type(uint256).max, "");
        _assertDirectRejected(type(uint256).max, abi.encode(keeper)); // flash-style callback route

        QuoteState memory q1 = _quoteSale(CHUNK_SEIZE);
        Liquidation memory r1 = liquidateViaAdapter(borrower, CHUNK, 0);
        _assertAdapterSale(r1, q1);
        assertEq(r1.repaid, CHUNK, "tranche repaid");
        assertEq(r1.seized, CHUNK_SEIZE, "tranche seize");
        assertEq(r1.seized, expectedSeize(CHUNK, CRASH_NAV), "R3 seize formula");
        assertEq(r1.proceeds, CHUNK_PROCEEDS, "tranche proceeds");
        assertEq(r1.eventBounty, CHUNK_BOUNTY, "tranche bounty (LB cap)");
        _assertKeeperHoldsOnlyUsdc(CHUNK_BOUNTY);
        assertEq(usdc.allowance(keeper, address(adapter)), 0, "adapter needed no keeper approval");
        assertEq(usdc.allowance(keeper, address(market)), 0, "MiniLend needed no keeper approval");
        assertAccountingIdentityAnyVersion();
        assertLedgerSums();
        assertLe(market.healthFactor(borrower), market.FULL_CLOSE_HF(), "still HF <= 0.95 after the tranche");

        // capital is not what the direct route lacks: USDC in hand plus an approval, still refused
        vm.prank(keeper);
        assertTrue(usdc.approve(address(market), type(uint256).max), "keeper approves MiniLend");
        _assertDirectRejected(type(uint256).max, "");

        (, uint256 debtLeft) = market.positions(borrower);
        (uint256 repay, uint256 seize) = market.previewLiquidation(borrower, type(uint256).max);
        assertEq(repay, debtLeft, "HF <= 0.95: full close");
        QuoteState memory q2 = _quoteSale(seize);
        Liquidation memory r2 = liquidateViaAdapter();
        _assertAdapterSale(r2, q2);
        assertEq(r2.repaid, repay, "full close repays the preview");
        assertEq(r2.seized, seize, "full close seizes the preview");
        assertEq(r2.seized, expectedSeize(repay, CRASH_NAV), "R3 seize formula");
        assertEq(r2.post.ledger.debt, 0, "position closed");
        _assertKeeperHoldsOnlyUsdc(r1.eventBounty + r2.eventBounty);
        assertAccountingIdentityAnyVersion();
        assertLedgerSums();
    }

    /// @notice RED (residual paid to the borrower). O3/O7 three roles, MM sole LP, NAV-only Crash, direct NotAllowlisted,
    ///         keeper closes to debt 0 from 0 USDC; the residual is MiniLend credit, not a payment; strict identity.
    function test_demoThreeRoles_navOnlyCrash() public {
        _assertThreeRoles();
        _assertMarketMakerSoleLp();
        _assertIssuerCannotRunDesk();
        _assertDemoBaseline();

        vm.warp(block.timestamp + CRASH_DELAY);
        _crashNavOnly();
        _assertAfterNavOnlyCrash();
        _assertDirectRejected(type(uint256).max, ""); // O5 "horizon"
        uint256 minBounty = _keeperSimulatesAndGuards();

        QuoteState memory q = _quoteSale(CRASH_FULL_CLOSE_SEIZE);
        Liquidation memory r = liquidateViaAdapter(borrower, type(uint256).max, minBounty);
        _assertAdapterSale(r, q);
        _assertFullCloseAmounts(r);

        _assertDemoTokenFlow(r);
        _assertBorrowerCreditedNotPaid(r);
        assertAccountingIdentity();
        assertBadDebtSum();
        assertLedgerSums();
        assertTrue(usdcIsProductMock, "R2/O3: the demo runs on the product MockUSDC");
    }

    // ================================================================== stack identity
    /// @dev O2 addresses and codehashes, then the O2 preflight relations and the fixture PA's provenance.
    function _assertLabsStack() private {
        // O2 table literals, so the fixture constants cannot drift
        assertEq(address(PM), 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543, "O2 PoolManager address");
        assertEq(address(FACTORY), 0xE6B0d96919334C33d06266d1420F97f6f434fA2B, "O2 factory address");
        assertEq(address(HOOK), 0x51247E2291d290d17C08813A175AC86465EdE8c0, "O2 hook address");
        assertEq(STATE_VIEW, 0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C, "O2 StateView address");
        address[4] memory labs = [address(PM), address(FACTORY), address(HOOK), STATE_VIEW];
        bytes32[4] memory hashes = [PM_CODEHASH, FACTORY_CODEHASH, HOOK_CODEHASH, STATE_VIEW_CODEHASH];
        string[4] memory names = ["PoolManager", "PermissionsAdapterFactory", "PermissionedHooks", "StateView"];
        for (uint256 i; i < labs.length; i++) {
            assertGt(labs[i].code.length, 0, string.concat(names[i], " has code"));
            assertEq(labs[i].codehash, hashes[i], string.concat(names[i], " codehash pinned"));
            emit log_named_bytes32(string.concat(names[i], " codehash"), labs[i].codehash); // evidence
        }
        ILabsHookView hook = ILabsHookView(address(HOOK));
        assertEq(FACTORY.POOL_MANAGER(), address(PM), "factory.POOL_MANAGER == PM");
        assertEq(address(hook.poolManager()), address(PM), "hook.poolManager == PM");
        assertEq(address(hook.PERMISSIONS_ADAPTER_FACTORY()), address(FACTORY), "hook.PERMISSIONS_ADAPTER_FACTORY");
        assertEq(address(ILabsStateViewView(STATE_VIEW).poolManager()), address(PM), "StateView.poolManager == PM");
        assertEq(pa.POOL_MANAGER(), address(PM), "PA.POOL_MANAGER == PM");
        assertEq(FACTORY.permissionsAdapterOf(address(pa)), address(rwa), "factory created the PA for the RWA");
        assertEq(FACTORY.verifiedPermissionsAdapterOf(address(pa)), address(rwa), "factory verified the PA");
        assertEq(address(pa.PERMISSIONED_TOKEN()), address(rwa), "PA wraps the RWA");
        assertEq(address(pa.allowListChecker()), address(rwa), "RWA is the PA allowlist checker");
        assertEq(pa.owner(), issuer, "issuer owns the PA");
        assertEq(FACTORY.verifiedPermissionsAdapterOf(address(usdc)), address(0), "USDC is an ordinary currency");
    }

    /// @dev Exactly beforeInitialize|beforeAddLiquidity|beforeSwap|afterSwap (0x28C0): no *ReturnDelta flag, so the hook
    ///      cannot alter swap deltas and sale proceeds are pure pool math (_quoteSale).
    function _assertHookSurface() private pure {
        uint160 expected = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG;
        assertEq(uint160(address(HOOK)) & Hooks.ALL_HOOK_MASK, expected, "hook address permission bits == 0x28C0");
    }

    function _assertFixtureOnPinnedStack() private view {
        assertEq(address(key.hooks), address(HOOK), "fixture pool uses the canonical hook");
        _assertSlot0AtNav0("fixture pool in the pinned PM");
        assertEq(PM.protocolFeeController(), address(0), "no protocol fee controller at the pinned block");
        _readPoolStorage(); // StateView reads the same slot0 tuple, fee growth and L as PM storage
        assertEq(address(adapter.poolManager()), address(PM), "adapter -> PM");
        assertEq(address(adapter.permissionsAdapter()), address(pa), "adapter -> PA");
        assertEq(address(adapter.hooks()), address(HOOK), "adapter -> hook");
        assertEq(address(desk.pm()), address(PM), "desk -> PM");
        assertEq(address(desk.pa()), address(pa), "desk -> PA");
    }

    // ================================================================== MockUSDC (R2)
    function _assertProductMockUsdcExists() private view {
        bool found;
        try vm.getCode(PRODUCT_MOCK_USDC) returns (bytes memory) {
            found = true;
        } catch {}
        assertTrue(found, "R2: src/e2e/MockUSDC.sol:MockUSDC does not exist (fixture fell back to the test stand-in)");
    }

    function _assertR2Metadata(ISpecMockUSDC token) private view {
        assertEq(token.decimals(), 6, "R2 decimals 6");
        assertEq(token.name(), "USD Coin (mock)", "R2 name");
        assertEq(token.symbol(), "mUSDC", "R2 symbol");
        assertEq(token.minter(), issuer, "O3: the issuer is the minter");
    }

    /// @dev O3: the minter gave the MM 6,000,000 and the lender 500,000; nothing else exists.
    function _assertFixtureDistribution() private view {
        assertEq(usdc.totalSupply(), MM_USDC + LENDER_USDC, "supply == exactly the minter's O3 distribution");
        assertEq(usdc.balanceOf(address(desk)) + usdc.balanceOf(address(PM)), MM_USDC, "MM's USDC: desk + pool");
        assertEq(usdc.balanceOf(address(market)) + usdc.balanceOf(borrower), LENDER_USDC, "lender's: cash + loan");
        address[6] memory empty = [keeper, issuer, mm, lender, address(adapter), address(pa)];
        for (uint256 i; i < empty.length; i++) {
            assertEq(usdc.balanceOf(empty[i]), 0, "account holds no USDC after the fixture");
        }
    }

    function _assertOnlyMinterMints(ISpecMockUSDC token) private {
        address[9] memory callers = [
            keeper, mm, borrower, lender, address(market), address(adapter), address(desk), address(PM), address(this)
        ];
        uint256 supply = token.totalSupply();
        for (uint256 i; i < callers.length; i++) {
            uint256 balance = token.balanceOf(callers[i]);
            vm.prank(callers[i]);
            vm.expectRevert(ISpecMockUSDC.OnlyMinter.selector);
            token.mint(callers[i], 1);
            assertEq(token.balanceOf(callers[i]), balance, "rejected mint leaves the caller's balance");
        }
        assertEq(token.totalSupply(), supply, "rejected mints leave the supply");
    }

    function _assertMinterMints(uint256 amount) private {
        uint256 supply = usdc.totalSupply();
        uint256 balance = usdc.balanceOf(lender);
        vm.expectEmit(true, true, false, true, address(usdc));
        emit IERC20.Transfer(address(0), lender, amount);
        vm.prank(issuer);
        usdc.mint(lender, amount);
        assertEq(usdc.totalSupply(), supply + amount, "minter mint: supply += amount");
        assertEq(usdc.balanceOf(lender), balance + amount, "minter mint: recipient += amount");
    }

    // ================================================================== adapter constructor (R5)
    function _copy(AdapterArgs memory a) private pure returns (AdapterArgs memory) {
        return AdapterArgs(a.pm, a.factory, a.pa, a.usdc, a.market, a.hooks, a.keeperBps);
    }

    function _assertCrossRelationsRejected(AdapterArgs memory valid) private {
        bytes memory badConfig = abi.encodeWithSelector(ISpecLiquidationAdapter.BadConfig.selector);
        IPoolManager otherPm = IPoolManager(makeAddr("otherPoolManager"));
        IPermissionsAdapterFactory lookalike = _configFactory(PM); // same PM, not the hook's factory
        IPermissionsAdapterFactory foreign = _configFactory(otherPm); // factory of another PM

        AdapterArgs memory k = _copy(valid);
        k.keeperBps = 10_001;
        _assertAdapterReverts(k, badConfig, REL_KEEPER_BPS, "keeperBps 10001");
        k.keeperBps = type(uint256).max;
        _assertAdapterReverts(k, badConfig, REL_KEEPER_BPS, "keeperBps max");
        AdapterArgs memory a = _copy(valid);
        a.factory = lookalike;
        _assertAdapterReverts(a, badConfig, REL_HOOK_FACTORY, "hook->factory: canonical hook, look-alike factory");
        AdapterArgs memory b = _copy(valid);
        b.hooks = _allowedConfigHook(PM, lookalike);
        _assertAdapterReverts(b, badConfig, REL_HOOK_FACTORY, "hook->factory: hook of another factory");
        AdapterArgs memory c = _copy(valid);
        (c.factory, c.hooks) = (foreign, _allowedConfigHook(PM, foreign));
        _assertAdapterReverts(c, badConfig, REL_FACTORY_PM, "factory->PM");
        AdapterArgs memory d = _copy(valid);
        (d.pm, d.factory, d.hooks) = (otherPm, foreign, _allowedConfigHook(otherPm, foreign));
        _assertAdapterReverts(d, badConfig, REL_PA_PM, "PA->PM");
        AdapterArgs memory e = _copy(valid);
        e.hooks = _allowedConfigHook(otherPm, FACTORY);
        _assertAdapterReverts(e, badConfig, REL_HOOK_PM, "hook->PM");
    }

    function _assertMarketTokensRejected(AdapterArgs memory valid) private {
        bytes memory badConfig = abi.encodeWithSelector(ISpecLiquidationAdapter.BadConfig.selector);
        vm.startPrank(issuer);
        IERC20 otherRwa = IERC20(address(new MockRWA3643(issuer)));
        IERC20 otherUsdc = IERC20(address(new SpecMockUSDC(issuer)));
        IMiniLend otherRwaMarket = _newMarket(otherRwa, IERC20(address(usdc)));
        IMiniLend otherUsdcMarket = _newMarket(IERC20(address(rwa)), otherUsdc);
        vm.stopPrank();

        AdapterArgs memory a = _copy(valid);
        a.market = otherRwaMarket;
        _assertAdapterReverts(a, badConfig, REL_MARKET_RWA, "market.RWA is another token");
        AdapterArgs memory b = _copy(valid);
        b.market = otherUsdcMarket;
        _assertAdapterReverts(b, badConfig, REL_MARKET_USDC, "market.USDC is another token");
        AdapterArgs memory c = _copy(valid);
        c.usdc = otherUsdc;
        _assertAdapterReverts(c, badConfig, REL_MARKET_USDC, "adapter USDC is not market.USDC");
    }

    function _unverifiedPaArgs(AdapterArgs memory valid) private returns (AdapterArgs memory a) {
        vm.startPrank(issuer);
        MockRWA3643 rwa2 = new MockRWA3643(issuer);
        address pa2 = FACTORY.createPermissionsAdapter(IERC20(address(rwa2)), issuer, IAllowlistChecker(address(rwa2)));
        IMiniLend market2 = _newMarket(IERC20(address(rwa2)), IERC20(address(usdc)));
        vm.stopPrank();
        assertEq(FACTORY.permissionsAdapterOf(pa2), address(rwa2), "precondition: PA created by the real factory");
        assertEq(FACTORY.verifiedPermissionsAdapterOf(pa2), address(0), "precondition: PA not verified");
        a = _copy(valid);
        (a.pa, a.market) = (IPermissionsAdapter(pa2), market2);
    }

    function _newMarket(IERC20 rwa_, IERC20 usdc_) private returns (IMiniLend) {
        return
            IMiniLend(address(new MiniLend(rwa_, usdc_, issuer, NAV0, ORACLE_NAV_MIN, ORACLE_NAV_MAX, NAV_STALENESS)));
    }

    function _configFactory(IPoolManager pm_) private returns (IPermissionsAdapterFactory) {
        return IPermissionsAdapterFactory(address(new ConfigFactory(address(pm_), address(pa), address(rwa))));
    }

    /// @dev Allowed on the fixture PA so the only defect in the configuration is the relation under test.
    function _allowedConfigHook(IPoolManager pm_, IPermissionsAdapterFactory factory_) private returns (IHooks h) {
        h = IHooks(address(new ConfigHook(pm_, factory_)));
        vm.prank(issuer);
        pa.updateAllowedHook(h, true);
    }

    function _assertAdapterDeploys(AdapterArgs memory a) private {
        _assertOnlyBroken(a, type(uint256).max, "valid configuration");
        address predicted = vm.computeCreateAddress(issuer, vm.getNonce(issuer));
        vm.prank(issuer);
        LiquidationAdapter deployed =
            new LiquidationAdapter(a.pm, a.factory, a.pa, a.usdc, a.market, a.hooks, FEE, TICK_SPACING, a.keeperBps);
        assertEq(address(deployed), predicted, "deployed at the predicted address");
        assertEq(deployed.keeperBps(), a.keeperBps, "keeperBps stored");
        assertEq(keccak256(abi.encode(deployed.poolKey())), keccak256(abi.encode(key)), "same fixed PoolKey");
        assertEq(usdc.allowance(address(deployed), address(market)), type(uint256).max, "USDC approval to market");
    }

    function _assertAdapterReverts(AdapterArgs memory a, bytes memory expected, uint256 broken, string memory what)
        private
    {
        _assertOnlyBroken(a, broken, what);
        address predicted = vm.computeCreateAddress(issuer, vm.getNonce(issuer));
        vm.prank(issuer);
        try new LiquidationAdapter(
            a.pm, a.factory, a.pa, a.usdc, a.market, a.hooks, FEE, TICK_SPACING, a.keeperBps
        ) returns (
            LiquidationAdapter deployed
        ) {
            assertEq(address(deployed), address(0), string.concat("R5 ", what, ": constructor accepted it"));
        } catch (bytes memory reason) {
            assertEq(reason, expected, string.concat("R5 ", what, ": exact revert data"));
        }
        assertEq(predicted.code.length, 0, string.concat(what, ": nothing deployed"));
        assertEq(a.usdc.allowance(predicted, address(a.market)), 0, string.concat(what, ": no approval left"));
    }

    /// @dev Every R5 relation holds except `broken` (max: all hold), so each case isolates one defect. The
    ///      getters read here are the ones a spec constructor reads, so the stand-ins are proven to answer them.
    function _assertOnlyBroken(AdapterArgs memory a, uint256 broken, string memory what) private view {
        bool[8] memory ok = _relations(a);
        for (uint256 i; i < ok.length; i++) {
            assertEq(ok[i], i != broken, string.concat(what, ": precondition on relation #", vm.toString(i)));
        }
    }

    function _relations(AdapterArgs memory a) private view returns (bool[8] memory ok) {
        address token = address(a.pa.PERMISSIONED_TOKEN());
        ILabsHookView hook = ILabsHookView(address(a.hooks));
        ISpecMiniLend m = ISpecMiniLend(address(a.market));
        ok[REL_HOOK_FACTORY] = address(hook.PERMISSIONS_ADAPTER_FACTORY()) == address(a.factory);
        ok[REL_FACTORY_PM] = a.factory.POOL_MANAGER() == address(a.pm);
        ok[REL_PA_PM] = a.pa.POOL_MANAGER() == address(a.pm);
        ok[REL_HOOK_PM] = address(hook.poolManager()) == address(a.pm);
        ok[REL_MARKET_RWA] = address(m.RWA()) == token;
        ok[REL_MARKET_USDC] = address(m.USDC()) == address(a.usdc);
        ok[REL_KEEPER_BPS] = a.keeperBps <= BPS;
        ok[REL_VERIFIED] = a.factory.verifiedPermissionsAdapterOf(address(a.pa)) == token;
    }

    // ================================================================== keeper routes
    function _assertKeeperOutsideHolderSet() private view {
        _assertKeeperHoldsOnlyUsdc(0); // NONE flags, no USDC, RWA, vRWA or 6909 claim
        assertFalse(rwa.isHolder(keeper), "keeper: not a holder");
        assertFalse(pa.isAllowed(keeper, PermissionFlags.SWAP_ALLOWED), "keeper cannot swap");
        assertFalse(pa.isAllowed(keeper, PermissionFlags.LIQUIDITY_ALLOWED), "keeper cannot provide liquidity");
        assertFalse(pa.allowedWrappers(keeper), "keeper is not a wrapper");
        assertEq(usdc.allowance(keeper, address(adapter)), 0, "keeper: no approval to the adapter");
        assertEq(usdc.allowance(keeper, address(market)), 0, "keeper: no approval to MiniLend");
        assertEq(keeper.balance, 1 ether, "keeper: gas ETH only");
    }

    /// @dev The position IS liquidatable (preview succeeds); only the RWA holder rule stops the keeper.
    function _assertDirectRejected(uint256 repayAssets, bytes memory data) private {
        (, uint256 seize) = market.previewLiquidation(borrower, repayAssets);
        assertGt(seize, 0, "position is liquidatable");
        World memory pre = captureWorld(borrower);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(MockRWA3643.NotAllowlisted.selector, keeper));
        market.liquidate(borrower, repayAssets, data);
        assertWorldUnchanged(pre);
    }

    function _assertKeeperHoldsOnlyUsdc(uint256 usdcAmount) private view {
        assertEq(usdc.balanceOf(keeper), usdcAmount, "keeper USDC == bounties earned");
        assertEq(rwa.balanceOf(keeper), 0, "keeper RWA 0");
        assertEq(pa.balanceOf(keeper), 0, "keeper vRWA 0");
        assertEq(PM.balanceOf(keeper, uint256(uint160(address(pa)))), 0, "keeper no vRWA claim");
        assertEq(PM.balanceOf(keeper, uint256(uint160(address(usdc)))), 0, "keeper no USDC claim");
        assertEq(rwa.flags(keeper), 0, "keeper: NONE in the checker (outside the holder set)");
    }

    /// @dev FinalSpecBase success path plus: proceeds and end price equal the independent v4 quote, L and the MM
    ///      position untouched, and the R5 NAV floor would not have cut the sale short.
    function _assertAdapterSale(Liquidation memory r, QuoteState memory q) private view {
        assertLiquidationSuccessPath(r);
        assertEq(q.remaining, 0, "quote sells the whole seize above its limit");
        assertEq(r.proceeds, q.amountOut, "proceeds == v4 exact-in quote");
        assertEq(r.post.pool.sqrtPriceX96, q.price, "post-sale price == quote");
        assertEq(r.post.pool.tick, q.tick, "post-sale tick == quote");
        assertEq(r.post.pool.liquidity, r.pre.pool.liquidity, "a sale leaves L");
        assertEq(r.post.pool.deskLiquidity, r.pre.pool.deskLiquidity, "a sale leaves the MM position");
        _assertSpotAboveNavFloor(r.post.pool.sqrtPriceX96, "post-sale spot vs R5 NAV floor");
    }

    /// @dev O5/O6: simulate, minBounty = 97% of the quote, re-simulate; a guard above the quote reverts; no trace.
    function _keeperSimulatesAndGuards() private returns (uint256 minBounty) {
        World memory pre = captureWorld(borrower);
        uint256 quote = _simulateLiquidation(0);
        assertEq(quote, FULL_CLOSE_BOUNTY, "simulated bounty");
        minBounty = quote * MIN_BOUNTY_PCT / 100;
        assertEq(_simulateLiquidation(minBounty), quote, "re-simulation with the 97% guard");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BountyMath.BountyTooLow.selector, quote, quote + 1));
        adapter.liquidate(borrower, type(uint256).max, quote + 1);
        assertWorldUnchanged(pre);
    }

    function _simulateLiquidation(uint256 minBounty) private returns (uint256 bounty) {
        uint256 snapshot = vm.snapshotState();
        vm.prank(keeper);
        bounty = adapter.liquidate(borrower, type(uint256).max, minBounty);
        assertTrue(vm.revertToState(snapshot), "simulation rolled back");
    }

    // ================================================================== three-role demo
    function _assertThreeRoles() private view {
        assertTrue(issuer != mm && mm != keeper && issuer != keeper, "issuer != MM != keeper");
        assertEq(pa.owner(), issuer, "issuer owns the PA");
        assertEq(market.oracleAdmin(), issuer, "issuer is oracleAdmin");
        assertEq(usdc.minter(), issuer, "issuer is the USDC minter");
        assertEq(desk.owner(), mm, "Desk.owner == MM");
        assertEq(desk.msgSender(), mm, "the hook sees the MM behind the desk");
        assertEq(rwa.flags(issuer), rwa.HOLDER(), "issuer: HOLDER only");
        assertFalse(pa.isAllowed(issuer, PermissionFlags.SWAP_ALLOWED), "issuer: no SWAP");
        assertFalse(pa.isAllowed(issuer, PermissionFlags.LIQUIDITY_ALLOWED), "issuer: no LIQUIDITY");
        assertEq(rwa.flags(mm), rwa.HOLDER() | rwa.SWAP() | rwa.LIQUIDITY(), "MM: HOLDER|SWAP|LIQUIDITY");
        assertTrue(pa.isAllowed(mm, PermissionFlags.SWAP_ALLOWED), "MM: SWAP");
        assertTrue(pa.isAllowed(mm, PermissionFlags.LIQUIDITY_ALLOWED), "MM: LIQUIDITY");
        assertFalse(pa.allowedWrappers(issuer) || pa.allowedWrappers(mm), "no role account is a wrapper");
        _assertKeeperOutsideHolderSet();
    }

    /// @dev O3: L=5e17 on [-887220, 887220] at P=100 is the MM desk's position only; the pool holds exactly what that
    ///      liquidity requires (rounded up, as when added) and the excess stays on the desk.
    function _assertMarketMakerSoleLp() private {
        assertEq(PM.getLiquidity(poolId), 5e17, "O3 L == 5e17");
        (uint128 deskPos,,) = PM.getPositionInfo(poolId, address(desk), -887_220, 887_220, bytes32(0));
        assertEq(deskPos, 5e17, "all of L is the MM desk's full-range position");
        (uint128 issuerPos,,) = PM.getPositionInfo(poolId, issuer, TICK_LOWER, TICK_UPPER, bytes32(0));
        assertEq(issuerPos, 0, "the issuer provides no liquidity");
        (uint256 paInPool, uint256 usdcInPool) = _fullRangeReserves(sqrtPriceX96ForNav(NAV0), L_UNSIGNED);
        assertEq(pa.balanceOf(address(PM)), paInPool, "pool vRWA == L=5e17 at P=100");
        assertEq(usdc.balanceOf(address(PM)), usdcInPool, "pool USDC == L=5e17 at P=100");
        assertEq(rwa.balanceOf(address(desk)), 100_000e18 - paInPool, "MM RWA excess stays on the desk");
        assertEq(usdc.balanceOf(address(desk)), 6_000_000e6 - usdcInPool, "MM USDC excess stays on the desk");
        assertEq(rwa.balanceOf(issuer) + usdc.balanceOf(issuer), 0, "the issuer holds no inventory");
        emit log_named_decimal_uint("pool vRWA at L=5e17, P=100", paInPool, 18);
        emit log_named_decimal_uint("pool USDC at L=5e17, P=100", usdcInPool, 6);
    }

    /// @dev O3: the issuer does not control the MM's desk (R6: the three mutators require the owner).
    function _assertIssuerCannotRunDesk() private {
        World memory pre = captureWorld(borrower);
        vm.startPrank(issuer);
        vm.expectRevert(LiquidityDesk.NotOwner.selector);
        desk.modifyLiquidity(key, TICK_LOWER, TICK_UPPER, -L);
        vm.expectRevert(LiquidityDesk.NotOwner.selector);
        desk.swapToPrice(key, sqrtPriceX96ForNav(CRASH_NAV), 1);
        vm.expectRevert(LiquidityDesk.NotOwner.selector);
        desk.withdraw(IERC20(address(usdc)), 1);
        vm.stopPrank();
        assertWorldUnchanged(pre);
    }

    function _assertDemoBaseline() private {
        assertEq(market.nav(), 100e18, "O7 baseline NAV 100");
        _assertSlot0AtNav0("O7 baseline");
        (uint256 coll, uint256 debt) = market.positions(borrower);
        assertEq(coll, 1_000e18, "O7 collateral 1000");
        assertEq(debt, 75_000e6, "O7 debt 75000");
        assertEq(usdc.balanceOf(borrower), 75_000e6, "borrower holds the loan");
        assertEq(market.totalSupplyAssets(), 500_000e6, "lender supplied 500000");
        assertEq(market.healthFactor(borrower), 1_066_666_666_666_666_666, "O7 HF 1.0667");
        vm.expectRevert(abi.encodeWithSelector(ISpecMiniLend.Healthy.selector, HF_BASELINE));
        market.previewLiquidation(borrower, type(uint256).max);
        assertAccountingIdentityAnyVersion();
    }

    /// @dev O7 after Crash: NAV 85 while slot0 is still the P=100 baseline tuple, so spot sits above the 84.15 floor.
    function _assertAfterNavOnlyCrash() private view {
        assertEq(market.nav(), 85e18, "O7 NAV 85");
        _assertSlot0AtNav0("after the NAV-only Crash");
        uint256 floor = Math.mulDiv(CRASH_NAV, NAV_FLOOR_BPS, BPS, Math.Rounding.Ceil);
        assertEq(floor, NAV_FLOOR_PRICE_AT_CRASH, "O7 NAV floor 84.15");
        _assertSpotAboveNavFloor(spotSqrtPriceX96(), "spot 100 above the 84.15 floor");
        assertEq(market.healthFactor(borrower), 906_666_666_666_666_666, "O7 HF 0.9067");
        (uint256 repay, uint256 seize) = market.previewLiquidation(borrower, type(uint256).max);
        assertEq(repay, 75_000e6, "HF <= 0.95: full close");
        assertEq(seize, CRASH_FULL_CLOSE_SEIZE, "O7 seize 935.294117");
    }

    function _assertFullCloseAmounts(Liquidation memory r) private view {
        assertEq(r.repaid, 75_000e6, "O7 repaid 75000");
        assertEq(r.seized, CRASH_FULL_CLOSE_SEIZE, "O7 seized 935.294117");
        assertEq(r.proceeds, FULL_CLOSE_PROCEEDS, "O7 proceeds 91541.594333");
        assertEq(r.eventBounty, FULL_CLOSE_BOUNTY, "O7 bounty 4500 (LB cap binds)");
        assertEq(r.residual, FULL_CLOSE_RESIDUAL, "O7 residual 12041.594333");
        assertEq(r.marketBadDebt, 0, "no write-off");
        assertEq(r.post.ledger.debt, 0, "O7 debt 0");
        assertEq(r.post.ledger.collateral, 1_000e18 - CRASH_FULL_CLOSE_SEIZE, "collateral left with the borrower");
        _assertKeeperHoldsOnlyUsdc(FULL_CLOSE_BOUNTY);
        assertEq(r.post.bal.issuerRwa + r.post.bal.issuerUsdc, 0, "issuer receives nothing");
        assertEq(r.post.pool.deskLiquidity, 5e17, "MM still the sole LP with L=5e17");
    }

    /// @dev R5 steps 6-8, per token and in order. The fourth USDC move is where the snapshot pays the borrower.
    function _assertDemoTokenFlow(Liquidation memory r) private view {
        address a = address(adapter);
        Vm.Log[] memory t = _transfersOf(r.logs, address(rwa));
        assertEq(t.length, 2, "RWA moves exactly twice");
        _assertTransfer(t[0], address(market), a, r.seized, "RWA 1: MiniLend -> adapter");
        _assertTransfer(t[1], a, address(pa), r.seized, "RWA 2: adapter -> PA");
        t = _transfersOf(r.logs, address(pa));
        assertEq(t.length, 1, "vRWA moves once");
        _assertTransfer(t[0], address(0), address(PM), r.seized, "vRWA minted to the PM only");
        t = _transfersOf(r.logs, address(usdc));
        assertEq(t.length, 4, "USDC moves: take, repay, bounty, residual");
        _assertTransfer(t[0], address(PM), a, r.proceeds, "USDC 1: take proceeds");
        _assertTransfer(t[1], a, address(market), r.repaid, "USDC 2: repay MiniLend");
        _assertTransfer(t[2], a, keeper, r.eventBounty, "USDC 3: bounty to the keeper");
        // R5 step 8: the residual settles in MiniLend, never straight to the borrower
        _assertTransfer(t[3], a, address(market), r.residual, "USDC 4: residual -> MiniLend");
    }

    /// @dev O7 "no afirmar que el borrower ya recibio su credito": debt 0 and no write-off, so the whole residual is
    ///      claimable credit and the borrower wallet is untouched.
    function _assertBorrowerCreditedNotPaid(Liquidation memory r) private view {
        (uint256 debtRepaid, uint256 recovered, uint256 credit) = assertResidualSettledInMarket(r);
        assertEq(debtRepaid, 0, "no live debt left to repay");
        assertEq(recovered, 0, "no write-off to recover");
        assertEq(credit, FULL_CLOSE_RESIDUAL, "O7 borrower credit 12041.594333");
        assertEq(specClaimableResidual(borrower), FULL_CLOSE_RESIDUAL, "claimableResidual(borrower)");
        assertEq(specTotalResidualClaims(), FULL_CLOSE_RESIDUAL, "totalResidualClaims");
        assertEq(specBadDebtOf(borrower), 0, "badDebtOf(borrower)");
        assertEq(usdc.balanceOf(borrower), 75_000e6, "borrower wallet: only the loan, credit not paid");
    }

    // ================================================================== NAV-only Crash vs slot0
    /// @dev O4 / TRACEABILITY "Crash solo NavUpdated, slot0/L sin modificacion": the base check (one NavUpdated log,
    ///      only nav/navUpdatedAt move) plus the whole getSlot0 tuple and the raw Pool.State header, across crashNav().
    function _crashNavOnly() private {
        PoolStorage memory pre = _readPoolStorage();
        crashNavAndAssertNavOnly();
        PoolStorage memory post = _readPoolStorage();
        assertEq(post.price, pre.price, "Crash: slot0.sqrtPriceX96 unchanged");
        assertEq(post.tick, pre.tick, "Crash: slot0.tick unchanged");
        assertEq(post.protocolFee, pre.protocolFee, "Crash: slot0.protocolFee unchanged");
        assertEq(post.lpFee, pre.lpFee, "Crash: slot0.lpFee unchanged");
        string[4] memory names = ["slot0", "feeGrowthGlobal0X128", "feeGrowthGlobal1X128", "liquidity"];
        for (uint256 i; i < names.length; i++) {
            assertEq(post.header[i], pre.header[i], string.concat("Crash: raw Pool.State word unchanged: ", names[i]));
        }
    }

    /// @dev getSlot0 through PM and StateView plus the raw Pool.State header (slot0, feeGrowthGlobal0/1, liquidity),
    ///      each raw word tied to its StateView getter so no word is compared blind.
    function _readPoolStorage() private view returns (PoolStorage memory s) {
        IStateView sv = IStateView(STATE_VIEW);
        (s.price, s.tick, s.protocolFee, s.lpFee) = PM.getSlot0(poolId);
        (uint160 svPrice, int24 svTick, uint24 svProtocolFee, uint24 svLpFee) = sv.getSlot0(poolId);
        bytes32 slot0 = _packSlot0(s.price, s.tick, s.protocolFee, s.lpFee);
        assertEq(_packSlot0(svPrice, svTick, svProtocolFee, svLpFee), slot0, "StateView slot0 tuple == PM slot0 tuple");
        s.header = PM.extsload(StateLibrary._getPoolStateSlot(poolId), POOL_HEADER_WORDS);
        assertEq(s.header[0], slot0, "raw slot0 word == getSlot0 tuple (no other bits)");
        (uint256 feeGrowth0, uint256 feeGrowth1) = sv.getFeeGrowthGlobals(poolId);
        assertEq(uint256(s.header[1]), feeGrowth0, "raw feeGrowthGlobal0X128 word == StateView");
        assertEq(uint256(s.header[2]), feeGrowth1, "raw feeGrowthGlobal1X128 word == StateView");
        assertEq(uint256(s.header[3]), sv.getLiquidity(poolId), "raw liquidity word == StateView L");
    }

    /// @dev v4 slot0 layout: lpFee(24) | protocolFee(24) | tick(24) | sqrtPriceX96(160).
    function _packSlot0(uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) private pure returns (bytes32) {
        return bytes32(
            // forge-lint: disable-next-line(unsafe-typecast) -- int24 -> uint24 keeps the 24-bit two's complement
            uint256(lpFee) << 208 | uint256(protocolFee) << 184 | uint256(uint24(tick)) << 160 | uint256(price)
        );
    }

    /// @dev O3/O7 pool at P=100: the whole slot0 tuple, and L = 5e17.
    function _assertSlot0AtNav0(string memory when) private view {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = PM.getSlot0(poolId);
        uint160 p100 = sqrtPriceX96ForNav(NAV0);
        assertEq(price, p100, string.concat(when, ": slot0.sqrtPriceX96 == P=100"));
        assertEq(tick, TickMath.getTickAtSqrtPrice(p100), string.concat(when, ": slot0.tick == tick(P=100)"));
        assertEq(protocolFee, 0, string.concat(when, ": slot0.protocolFee == 0"));
        assertEq(lpFee, FEE, string.concat(when, ": slot0.lpFee == 3000"));
        assertEq(PM.getLiquidity(poolId), L_UNSIGNED, string.concat(when, ": L == 5e17"));
    }

    // ================================================================== v4 math and logs
    /// @notice Independent exact-in quote of selling `amountIn` vRWA, mirroring Pool.swap step by step. Unbounded limit:
    ///         _assertAdapterSale shows the R5 floor does not bind, so a spec adapter with the floor gets the same result.
    function _quoteSale(uint256 amountIn) private view returns (QuoteState memory s) {
        uint24 protocolFee;
        (s.price, s.tick, protocolFee, s.lpFee) = PM.getSlot0(poolId);
        assertEq(protocolFee, 0, "quote: no protocol fee");
        s.liquidity = PM.getLiquidity(poolId);
        s.zeroForOne = paIsCurrency0;
        s.limit = s.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        // forge-lint: disable-next-line(unsafe-typecast) -- a seize is at most the fixture collateral (1000e18)
        s.remaining = -int256(amountIn);
        while (s.remaining != 0 && s.price != s.limit) {
            _quoteStep(s);
        }
    }

    function _quoteStep(QuoteState memory s) private view {
        (int24 next, bool initialized) = _nextTick(s.tick, s.zeroForOne);
        uint160 nextPrice = TickMath.getSqrtPriceAtTick(next);
        uint160 start = s.price;
        uint256 stepIn;
        uint256 stepOut;
        uint256 stepFee;
        (s.price, stepIn, stepOut, stepFee) = SwapMath.computeSwapStep(
            start, SwapMath.getSqrtPriceTarget(s.zeroForOne, nextPrice, s.limit), s.liquidity, s.remaining, s.lpFee
        );
        // forge-lint: disable-next-line(unsafe-typecast) -- bounded by |remaining| (SwapMath exact-in guarantee)
        s.remaining += int256(stepIn + stepFee);
        s.amountOut += stepOut;
        if (s.price == nextPrice) {
            assertFalse(initialized, "quote: the sale crosses no initialized tick");
            s.tick = s.zeroForOne ? next - 1 : next;
        } else if (s.price != start) {
            s.tick = TickMath.getTickAtSqrtPrice(s.price);
        }
    }

    /// @dev TickBitmap.nextInitializedTickWithinOneWord on the mirror, clamped to the TickMath range like Pool.swap.
    function _nextTick(int24 tick, bool lte) private view returns (int24 next, bool initialized) {
        int24 compressed = TickBitmap.compress(tick, TICK_SPACING);
        (int16 wordPos,) = TickBitmap.position(lte ? compressed : compressed + 1);
        assertEq(mmTickBitmap[wordPos], PM.getTickBitmap(poolId, wordPos), "quote: mirrored bitmap word");
        (next, initialized) = mmTickBitmap.nextInitializedTickWithinOneWord(tick, TICK_SPACING, lte);
        if (next < TickMath.MIN_TICK) next = TickMath.MIN_TICK;
        if (next > TickMath.MAX_TICK) next = TickMath.MAX_TICK;
    }

    /// @return paAmt vRWA and usdcAmt USDC owed for `liq` on [TICK_LOWER, TICK_UPPER] at `price`, rounded up
    function _fullRangeReserves(uint160 price, uint128 liq) private view returns (uint256 paAmt, uint256 usdcAmt) {
        uint160 upper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        uint160 lower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint256 amount0 = SqrtPriceMath.getAmount0Delta(price, upper, liq, true);
        uint256 amount1 = SqrtPriceMath.getAmount1Delta(lower, price, liq, true);
        (paAmt, usdcAmt) = paIsCurrency0 ? (amount0, amount1) : (amount1, amount0);
    }

    /// @dev R5 table at NAV 85: PA currency0 rejects current <= limit; PA currency1 rejects current >= limit.
    function _assertSpotAboveNavFloor(uint160 spot, string memory what) private view {
        uint256 limit = navFloorLimitSqrtPriceX96(CRASH_NAV, paIsCurrency0);
        if (paIsCurrency0) assertGt(uint256(spot), limit, what);
        else assertLt(uint256(spot), limit, what);
    }

    /// @dev The Transfer logs `token` emitted, in emission order.
    function _transfersOf(Vm.Log[] memory logs, address token) private pure returns (Vm.Log[] memory t) {
        uint256 n;
        t = new Vm.Log[](logs.length);
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory lg = logs[i];
            if (lg.emitter == token && lg.topics.length == 3 && lg.topics[0] == TRANSFER_TOPIC) t[n++] = lg;
        }
        assembly ("memory-safe") {
            mstore(t, n) // shrink to the n matches
        }
    }

    function _assertTransfer(Vm.Log memory lg, address from, address to, uint256 amount, string memory what)
        private
        pure
    {
        assertEq(address(uint160(uint256(lg.topics[2]))), to, string.concat(what, ": to"));
        assertEq(address(uint160(uint256(lg.topics[1]))), from, string.concat(what, ": from"));
        assertEq(abi.decode(lg.data, (uint256)), amount, string.concat(what, ": amount"));
    }
}
