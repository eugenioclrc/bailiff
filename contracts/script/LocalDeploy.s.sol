// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Local demo deploy, phase 2 of 2 (deploy + seed): runs only after phase 1 is mined and the PA was read from
// the real factory's PermissionsAdapterCreated. Same steps and order as FinalSpecFixture._deployFixture.

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {
    IPermissionsAdapter
} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {MockRWA3643} from "../src/e2e/MockRWA3643.sol";
import {MiniLend} from "../src/e2e/MiniLend.sol";
import {LiquidationAdapter, IMiniLend} from "../src/e2e/LiquidationAdapter.sol";
import {LiquidityDesk} from "../src/e2e/LiquidityDesk.sol";
import {SpecMockUSDC} from "../test/finalspec/FinalSpecFixture.sol";
import {LocalStack} from "./LocalStack.sol";

contract LocalDeploy is LocalStack {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant MAX_SALT_TRIES = 64;

    uint256 private issuerPk;
    uint256 private mmPk;
    uint256 private borrowerPk;
    uint256 private lenderPk;
    address private issuer;
    address private mm;
    address private keeper;
    address private borrower;
    address private lender;
    bool private paIs0;

    MockRWA3643 private rwa;
    IPermissionsAdapter private pa;
    SpecMockUSDC private usdc;
    MiniLend private market;
    LiquidationAdapter private adapter;
    LiquidityDesk private desk;
    PoolKey private key;

    function run() external {
        _preflight();
        _loadInputs();
        _checkPhaseOne();
        _verifyPa();
        _deployUsdcInOrder();
        _initializePool();
        _deployProtocol();
        _seedRoles();
        _checkBaseline();
        _logAddresses();
    }

    function _loadInputs() private {
        issuerPk = vm.envUint("ISSUER_PK");
        mmPk = vm.envUint("MM_PK");
        borrowerPk = vm.envUint("BORROWER_PK");
        lenderPk = vm.envUint("LENDER_PK");
        (issuer, mm, borrower, lender) = (vm.addr(issuerPk), vm.addr(mmPk), vm.addr(borrowerPk), vm.addr(lenderPk));
        keeper = vm.envAddress("KEEPER");
        rwa = MockRWA3643(vm.envAddress("RWA"));
        pa = IPermissionsAdapter(vm.envAddress("PA"));
        paIs0 = vm.envOr("PA_IS_CURRENCY0", true);
    }

    /// @dev O4 Deploy preconditions: the PA really belongs to this RWA through the real factory, owned by the issuer.
    function _checkPhaseOne() private view {
        require(FACTORY.permissionsAdapterOf(address(pa)) == address(rwa), "factory.permissionsAdapterOf(PA) != RWA");
        require(FACTORY.verifiedPermissionsAdapterOf(address(pa)) == address(0), "PA already verified (not fresh)");
        require(address(pa.PERMISSIONED_TOKEN()) == address(rwa), "PA token != RWA");
        require(pa.owner() == issuer, "PA owner != issuer");
        require(address(pa.allowListChecker()) == address(rwa), "PA checker != RWA");
        require(pa.POOL_MANAGER() == address(PM), "PA -> PM");
        require(rwa.issuer() == issuer, "RWA issuer");
        require(rwa.flags(issuer) == HOLDER, "issuer flags != HOLDER");
        require(rwa.totalSupply() == 0, "RWA not fresh");
    }

    function _verifyPa() private {
        vm.startBroadcast(issuerPk);
        rwa.setFlags(address(pa), HOLDER);
        rwa.mint(issuer, VERIFICATION_DEPOSIT);
        rwa.approve(address(pa), VERIFICATION_DEPOSIT);
        pa.depositForVerification(VERIFICATION_DEPOSIT);
        FACTORY.verifyPermissionsAdapter(address(pa));
        pa.updateAllowedHook(HOOK, true);
        pa.updateSwappingEnabled(true);
        vm.stopBroadcast();
    }

    /// @dev CREATE2 through the canonical deterministic deployer with a mined salt so (PA, USDC) sorts as requested.
    function _deployUsdcInOrder() private {
        bytes memory initCode = abi.encodePacked(type(SpecMockUSDC).creationCode, abi.encode(issuer));
        bytes32 initHash = keccak256(initCode);
        for (uint256 i; i < MAX_SALT_TRIES; i++) {
            bytes32 salt = keccak256(abi.encode("bailiff.devenv.usdc", address(pa), i));
            address predicted = vm.computeCreate2Address(salt, initHash);
            if (predicted.code.length != 0 || (address(pa) < predicted) != paIs0) continue;
            vm.broadcast(issuerPk);
            usdc = new SpecMockUSDC{salt: salt}(issuer);
            require(address(usdc) == predicted, "USDC CREATE2 address");
            return;
        }
        revert("no USDC salt for the requested currency order");
    }

    function _initializePool() private {
        Currency cPa = Currency.wrap(address(pa));
        Currency cUsdc = Currency.wrap(address(usdc));
        key = paIs0 ? PoolKey(cPa, cUsdc, FEE, TICK_SPACING, HOOK) : PoolKey(cUsdc, cPa, FEE, TICK_SPACING, HOOK);
        vm.broadcast(issuerPk);
        PM.initialize(key, _sqrtPriceX96ForNav(NAV0, paIs0));
    }

    function _deployProtocol() private {
        vm.startBroadcast(issuerPk);
        market = new MiniLend(
            IERC20(address(rwa)), IERC20(address(usdc)), issuer, NAV0, ORACLE_NAV_MIN, ORACLE_NAV_MAX, NAV_STALENESS
        );
        adapter = new LiquidationAdapter(
            PM, FACTORY, pa, IERC20(address(usdc)), IMiniLend(address(market)), HOOK, FEE, TICK_SPACING, KEEPER_BPS
        );
        desk = new LiquidityDesk(PM, pa, mm);
        rwa.setFlags(address(market), HOLDER);
        rwa.setFlags(address(adapter), HOLDER | SWAP);
        rwa.setFlags(address(desk), HOLDER);
        rwa.setFlags(mm, HOLDER | SWAP | LIQUIDITY);
        rwa.setFlags(borrower, HOLDER);
        pa.updateAllowedWrapper(address(adapter), true);
        pa.updateAllowedWrapper(address(desk), true);
        vm.stopBroadcast();
    }

    function _seedRoles() private {
        vm.startBroadcast(issuerPk); // the minter distributes demo mocks; the keeper never receives any
        rwa.mint(mm, MM_RWA);
        usdc.mint(mm, MM_USDC);
        usdc.mint(lender, LENDER_USDC);
        rwa.mint(borrower, BORROWER_COLLATERAL);
        vm.stopBroadcast();

        vm.startBroadcast(mmPk); // the independent MM funds its desk and is the only LP
        require(rwa.transfer(address(desk), MM_RWA), "MM funds desk RWA");
        require(usdc.transfer(address(desk), MM_USDC), "MM funds desk USDC");
        desk.modifyLiquidity(key, TICK_LOWER, TICK_UPPER, L);
        vm.stopBroadcast();

        vm.startBroadcast(lenderPk);
        usdc.approve(address(market), type(uint256).max);
        market.supply(LENDER_USDC);
        vm.stopBroadcast();

        vm.startBroadcast(borrowerPk);
        rwa.approve(address(market), type(uint256).max);
        market.depositCollateral(BORROWER_COLLATERAL);
        market.borrow(BORROWER_DEBT);
        vm.stopBroadcast();
    }

    function _checkBaseline() private view {
        (uint256 coll, uint256 debt) = market.positions(borrower);
        require(coll == BORROWER_COLLATERAL && debt == BORROWER_DEBT, "borrower position");
        require(market.nav() == NAV0, "NAV0");
        require(market.healthFactor(borrower) == HF_BASELINE, "HF baseline");
        require(usdc.balanceOf(keeper) == 0 && rwa.balanceOf(keeper) == 0, "keeper not empty");
        require(rwa.flags(keeper) == 0, "keeper flags != NONE");
        require(pa.allowedWrappers(address(adapter)) && pa.allowedWrappers(address(desk)), "wrappers");
        require(pa.allowedHooks(HOOK) && pa.swappingEnabled(), "hook/swapping");
        require(FACTORY.verifiedPermissionsAdapterOf(address(pa)) == address(rwa), "PA verified");
        require(PM.getLiquidity(key.toId()) == L_UNSIGNED, "pool liquidity");
        (uint160 sqrtP,,,) = PM.getSlot0(key.toId());
        require(sqrtP == _sqrtPriceX96ForNav(NAV0, paIs0), "pool price moved");
    }

    function _logAddresses() private view {
        console2.log("simulated USDC", address(usdc));
        console2.log("simulated MARKET", address(market));
        console2.log("simulated ADAPTER", address(adapter));
        console2.log("simulated DESK", address(desk));
        console2.log("simulated POOL_ID");
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }
}
