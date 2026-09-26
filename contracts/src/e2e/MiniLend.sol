// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IMiniLendLiquidationCallback {
    function onMiniLendLiquidation(address borrower, uint256 seized, uint256 repaid, bytes calldata data) external;
}

/// @title MiniLend - isolated RWA(18d) -> USDC(6d) market priced by an issuer NAV oracle.
/// @notice Compliance-agnostic like Aave Horizon: the market never checks KYC; the RWA token's
///         transfer rule decides who can receive seized collateral (msg.sender of `liquidate`).
contract MiniLend is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 public constant LTV_BPS = 7_500; // max borrow
    uint256 public constant LT_BPS = 8_000; // liquidation threshold
    uint256 public constant LB_BPS = 600; // liquidation bonus: seize = repay * 1.06 / nav
    uint256 public constant CLOSE_FACTOR_BPS = 5_000;
    uint256 public constant FULL_CLOSE_HF = 0.95e18; // HF <= 0.95 -> 100% close factor
    uint256 public constant MIN_FULL_CLOSE_DEBT = 2_000e6; // small positions: 100% close factor
    uint256 public constant MIN_LEFTOVER_DEBT = 1_000e6; // partial liq must not leave dust
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    IERC20 public immutable RWA;
    IERC20 public immutable USDC;
    /// @dev usdcAmount = rwaAmount * nav / PRICE_SCALE, nav = USD per 1 whole RWA in WAD. 1e18*1e18/1e6 = 1e30.
    uint256 public immutable PRICE_SCALE;
    address public immutable oracleAdmin;
    uint256 public immutable NAV_FLOOR;
    uint256 public immutable NAV_CAP;
    uint256 public immutable MAX_STALENESS;

    struct Position {
        uint256 collateral; // RWA wei
        uint256 debt; // USDC units (0% APR demo market)
    }

    mapping(address => Position) public positions;
    mapping(address => uint256) public supplyShares;
    uint256 public totalSupplyShares;
    uint256 public totalSupplyAssets; // USDC owed to lenders; drops when bad debt is realized
    uint256 public totalDebt;
    uint256 public totalCollateral;
    uint256 public totalBadDebt;
    uint256 public nav;
    uint256 public navUpdatedAt;

    event NavUpdated(uint256 nav, uint256 timestamp);
    event Liquidated(address indexed liquidator, address indexed borrower, uint256 repaid, uint256 seized, uint256 badDebt);

    error StaleNav();
    error NavOutOfBounds(uint256 nav);
    error NotOracle();
    error Healthy(uint256 hf);
    error Unhealthy();
    error InsufficientLiquidity();
    error MustNotLeaveDust();
    error ZeroAmount();

    constructor(IERC20 rwa, IERC20 usdc, address oracleAdmin_, uint256 nav0, uint256 floor_, uint256 cap_, uint256 staleness)
    {
        RWA = rwa;
        USDC = usdc;
        PRICE_SCALE = 10 ** (18 + 18 - 6); // WAD * 10^(rwaDecimals - usdcDecimals)
        oracleAdmin = oracleAdmin_;
        (NAV_FLOOR, NAV_CAP, MAX_STALENESS) = (floor_, cap_, staleness);
        _setNav(nav0);
    }

    // ------------------------------------------------------------------ oracle
    function setNav(uint256 newNav) external {
        if (msg.sender != oracleAdmin) revert NotOracle();
        _setNav(newNav);
    }

    function _setNav(uint256 newNav) internal {
        if (newNav < NAV_FLOOR || newNav > NAV_CAP) revert NavOutOfBounds(newNav); // Horizon-style DON bounds
        (nav, navUpdatedAt) = (newNav, block.timestamp);
        emit NavUpdated(newNav, block.timestamp);
    }

    function _freshNav() internal view returns (uint256) {
        if (block.timestamp > navUpdatedAt + MAX_STALENESS) revert StaleNav();
        return nav;
    }

    // ------------------------------------------------------------------ lenders
    function supply(uint256 assets) external nonReentrant returns (uint256 shares) {
        shares = assets.mulDiv(totalSupplyShares + VIRTUAL_SHARES, totalSupplyAssets + VIRTUAL_ASSETS); // down
        (totalSupplyShares, totalSupplyAssets) = (totalSupplyShares + shares, totalSupplyAssets + assets);
        supplyShares[msg.sender] += shares;
        USDC.safeTransferFrom(msg.sender, address(this), assets);
    }

    function withdraw(uint256 shares) external nonReentrant returns (uint256 assets) {
        assets = shares.mulDiv(totalSupplyAssets + VIRTUAL_ASSETS, totalSupplyShares + VIRTUAL_SHARES); // down
        supplyShares[msg.sender] -= shares;
        (totalSupplyShares, totalSupplyAssets) = (totalSupplyShares - shares, totalSupplyAssets - assets);
        if (totalSupplyAssets < totalDebt) revert InsufficientLiquidity();
        USDC.safeTransfer(msg.sender, assets);
    }

    // ------------------------------------------------------------------ borrowers
    function depositCollateral(uint256 amount) external nonReentrant {
        positions[msg.sender].collateral += amount;
        totalCollateral += amount;
        RWA.safeTransferFrom(msg.sender, address(this), amount); // RWA rule: market must be HOLDER
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        positions[msg.sender].collateral -= amount;
        totalCollateral -= amount;
        if (!_withinLtv(positions[msg.sender], _freshNav())) revert Unhealthy();
        RWA.safeTransfer(msg.sender, amount);
    }

    function borrow(uint256 assets) external nonReentrant {
        positions[msg.sender].debt += assets;
        totalDebt += assets;
        if (!_withinLtv(positions[msg.sender], _freshNav())) revert Unhealthy();
        if (totalDebt > totalSupplyAssets) revert InsufficientLiquidity();
        USDC.safeTransfer(msg.sender, assets);
    }

    function repay(address onBehalf, uint256 assets) external nonReentrant returns (uint256 repaid) {
        repaid = Math.min(assets, positions[onBehalf].debt);
        positions[onBehalf].debt -= repaid;
        totalDebt -= repaid;
        USDC.safeTransferFrom(msg.sender, address(this), repaid);
    }

    // ------------------------------------------------------------------ liquidation
    /// @notice Seize-first, repay-by-end-of-call. Collateral goes to msg.sender, so a non-allowlisted caller
    ///         reverts inside RWA.transfer (Horizon semantics). Optional callback lets the caller sell first.
    function liquidate(address borrower, uint256 repayAssets, bytes calldata data)
        external
        nonReentrant
        returns (uint256 repaid, uint256 seized)
    {
        uint256 bad;
        (repaid, seized) = previewLiquidation(borrower, repayAssets);
        Position storage p = positions[borrower];
        p.collateral -= seized;
        p.debt -= repaid;
        (totalCollateral, totalDebt) = (totalCollateral - seized, totalDebt - repaid);
        if (p.collateral == 0 && p.debt != 0) {
            bad = p.debt; // no collateral left: write off, socialised to lenders via share price
            p.debt = 0;
            (totalDebt, totalSupplyAssets, totalBadDebt) = (totalDebt - bad, totalSupplyAssets - bad, totalBadDebt + bad);
        }
        RWA.safeTransfer(msg.sender, seized);
        if (data.length != 0) IMiniLendLiquidationCallback(msg.sender).onMiniLendLiquidation(borrower, seized, repaid, data);
        USDC.safeTransferFrom(msg.sender, address(this), repaid);
        emit Liquidated(msg.sender, borrower, repaid, seized, bad);
    }

    /// @return repay_ USDC pulled from msg.sender; seize RWA sent to msg.sender (same order as liquidate)
    function previewLiquidation(address borrower, uint256 repayAssets) public view returns (uint256 repay_, uint256 seize) {
        uint256 price = _freshNav();
        Position memory p = positions[borrower];
        uint256 hf = _healthFactor(p, price);
        if (hf >= WAD) revert Healthy(hf);
        uint256 maxRepay = (hf <= FULL_CLOSE_HF || p.debt <= MIN_FULL_CLOSE_DEBT) ? p.debt : p.debt * CLOSE_FACTOR_BPS / BPS;
        repay_ = Math.min(repayAssets, maxRepay);
        seize = (repay_ * (BPS + LB_BPS)).mulDiv(PRICE_SCALE, price * BPS); // round down: liquidator gets less
        if (seize > p.collateral) {
            seize = p.collateral;
            repay_ = seize.mulDiv(price * BPS, PRICE_SCALE * (BPS + LB_BPS), Math.Rounding.Ceil); // round up: pays more
        }
        if (seize == 0) revert ZeroAmount();
        if (repay_ < p.debt && seize < p.collateral && p.debt - repay_ < MIN_LEFTOVER_DEBT) revert MustNotLeaveDust();
    }

    // ------------------------------------------------------------------ views
    function healthFactor(address borrower) external view returns (uint256) {
        return _healthFactor(positions[borrower], nav);
    }

    function collateralValue(uint256 rwaAmount) public view returns (uint256) {
        return rwaAmount.mulDiv(nav, PRICE_SCALE); // USDC units, round down
    }

    function _healthFactor(Position memory p, uint256 price) internal view returns (uint256) {
        if (p.debt == 0) return type(uint256).max;
        uint256 adjColl = p.collateral.mulDiv(price * LT_BPS, PRICE_SCALE * BPS); // round down
        return adjColl.mulDiv(WAD, p.debt); // round down -> liquidatable marginally earlier
    }

    function _withinLtv(Position memory p, uint256 price) internal view returns (bool) {
        return p.debt <= p.collateral.mulDiv(price * LTV_BPS, PRICE_SCALE * BPS); // capacity rounds down
    }
}
