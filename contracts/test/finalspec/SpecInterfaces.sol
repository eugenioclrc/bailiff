// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {
    IPermissionsAdapter
} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";

/// @notice Final ABI of the Bailiff contracts, copied from plan-i14n/CONTRACTS.md (R2, R3, R5).
/// @dev Acceptance tests cast the deployed snapshot contracts to these interfaces, so they compile today and
///      keep compiling once the spec is implemented. A call to a function the snapshot lacks reverts with empty
///      data; FinalSpecBase turns the getters it needs into named assertions instead of raw reverts.
///      Constructors cannot live in an interface; their spec signatures are quoted in each NatSpec block.

/// @notice R2 MockUSDC (src/e2e/MockUSDC.sol, new).
/// @dev constructor(address minter_); name "USD Coin (mock)", symbol "mUSDC"; ERC20 events/errors inherited.
interface ISpecMockUSDC is IERC20 {
    error OnlyMinter();

    function decimals() external pure returns (uint8);
    function mint(address to, uint256 amount) external;
    function minter() external view returns (address);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

/// @notice R3 MiniLend, existing plus new signatures, state, constants, events and errors.
/// @dev constructor(IERC20 rwa, IERC20 usdc, address oracleAdmin_, uint256 nav0, uint256 floor_, uint256 cap_,
///      uint256 staleness) is unchanged. Callback IMiniLendLiquidationCallback is unchanged.
interface ISpecMiniLend {
    event NavUpdated(uint256 nav, uint256 timestamp);
    event Liquidated(
        address indexed liquidator, address indexed borrower, uint256 repaid, uint256 seized, uint256 badDebt
    );
    event Supplied(address indexed lender, uint256 assets, uint256 shares);
    event Withdrawn(address indexed lender, uint256 assets, uint256 shares);
    event CollateralDeposited(address indexed borrower, uint256 amount);
    event CollateralWithdrawn(address indexed borrower, uint256 amount);
    event Borrowed(address indexed borrower, uint256 assets);
    event Repaid(address indexed payer, address indexed borrower, uint256 assets);
    event LiquidationBlockedSet(address indexed borrower, bool blocked);
    event ResidualApplied(
        address indexed borrower, uint256 debtRepaid, uint256 badDebtRecovered, uint256 borrowerCredit
    );
    event ResidualClaimed(address indexed borrower, uint256 assets);

    error StaleNav();
    error NavOutOfBounds(uint256 nav);
    error NotOracle();
    error Healthy(uint256 hf);
    error Unhealthy();
    error InsufficientLiquidity();
    error MustNotLeaveDust();
    error ZeroAmount();
    error LiquidationBlocked(address borrower);

    // ------------------------------------------------------------ existing signatures
    function setNav(uint256 newNav) external;
    function supply(uint256 assets) external returns (uint256 shares);
    function withdraw(uint256 shares) external returns (uint256 assets);
    function depositCollateral(uint256 amount) external;
    function withdrawCollateral(uint256 amount) external;
    function borrow(uint256 assets) external;
    function repay(address onBehalf, uint256 assets) external returns (uint256 repaid);
    /// @dev spec names the outputs (repay, seize); renamed repay_ only to avoid shadowing `repay` above
    function previewLiquidation(address borrower, uint256 repayAssets)
        external
        view
        returns (uint256 repay_, uint256 seize);
    function liquidate(address borrower, uint256 repayAssets, bytes calldata data)
        external
        returns (uint256 repaid, uint256 seized);
    function healthFactor(address borrower) external view returns (uint256);
    function collateralValue(uint256 rwaAmount) external view returns (uint256);

    // ------------------------------------------------------------ new signatures
    function setLiquidationBlocked(address borrower, bool blocked) external;
    function settleLiquidationResidual(address borrower, uint256 assets)
        external
        returns (uint256 debtRepaid, uint256 badDebtRecovered, uint256 borrowerCredit);
    function claimResidual() external returns (uint256 assets);

    // ------------------------------------------------------------ state kept
    function positions(address borrower) external view returns (uint256 collateral, uint256 debt);
    function supplyShares(address lender) external view returns (uint256);
    function totalSupplyShares() external view returns (uint256);
    function totalSupplyAssets() external view returns (uint256);
    function totalDebt() external view returns (uint256);
    function totalCollateral() external view returns (uint256);
    function totalBadDebt() external view returns (uint256);
    function nav() external view returns (uint256);
    function navUpdatedAt() external view returns (uint256);
    function RWA() external view returns (IERC20);
    function USDC() external view returns (IERC20);
    function PRICE_SCALE() external view returns (uint256);
    function oracleAdmin() external view returns (address);
    function NAV_FLOOR() external view returns (uint256);
    function NAV_CAP() external view returns (uint256);
    function MAX_STALENESS() external view returns (uint256);
    function LTV_BPS() external view returns (uint256);
    function LT_BPS() external view returns (uint256);
    function LB_BPS() external view returns (uint256);
    function CLOSE_FACTOR_BPS() external view returns (uint256);
    function FULL_CLOSE_HF() external view returns (uint256);
    function MIN_FULL_CLOSE_DEBT() external view returns (uint256);
    function MIN_LEFTOVER_DEBT() external view returns (uint256);

    // ------------------------------------------------------------ state added
    function liquidationBlocked(address borrower) external view returns (bool);
    function badDebtOf(address borrower) external view returns (uint256);
    function claimableResidual(address borrower) external view returns (uint256);
    function totalResidualClaims() external view returns (uint256);
}

/// @notice R5 LiquidationAdapter.
/// @dev constructor(IPoolManager pm, IPermissionsAdapterFactory factory, IPermissionsAdapter pa, IERC20 usdc_,
///      IMiniLend market_, IHooks hooks_, uint24 fee_, int24 tickSpacing_, uint256 keeperBps_) is unchanged.
///      `market()` returns the IMiniLend immutable; declared as address here (same ABI) so this file does not
///      depend on where the implementation keeps its IMiniLend interface.
interface ISpecLiquidationAdapter {
    event Liquidated(
        address indexed borrower,
        address indexed keeper,
        uint256 repaid,
        uint256 seized,
        uint256 proceeds,
        uint256 bounty,
        uint256 residual
    );

    error NotPoolManager();
    error AdapterNotVerified();
    error HookNotAllowed();
    error SwappingDisabled();
    error Unauthorized();
    error PartialFill(uint256 sold, uint256 seize);
    error MarketMismatch(uint256 repaid, uint256 seized);
    error BadConfig();
    error PoolBelowNavFloor(uint160 currentSqrtPriceX96, uint160 limitSqrtPriceX96);

    function msgSender() external view returns (address);
    function poolKey() external view returns (PoolKey memory);
    function liquidate(address borrower, uint256 repayAssets, uint256 minBounty) external returns (uint256 bounty);
    function unlockCallback(bytes calldata data) external returns (bytes memory);

    function poolManager() external view returns (IPoolManager);
    function permissionsAdapter() external view returns (IPermissionsAdapter);
    function rwa() external view returns (IERC20);
    function usdc() external view returns (IERC20);
    function market() external view returns (address);
    function hooks() external view returns (IHooks);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function rwaIsCurrency0() external view returns (bool);
    function lbBps() external view returns (uint256);
    function keeperBps() external view returns (uint256);
    function NAV_FLOOR_BPS() external view returns (uint256);
}
