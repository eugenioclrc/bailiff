// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MiniLend, IMiniLendLiquidationCallback} from "../../../src/e2e/MiniLend.sol";
import {BountyMath} from "../../../src/e2e/BountyMath.sol";

contract MockUSDC is ERC20("USD Coin (mock)", "USDC") {
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @notice x*y=k stand-in for the vRWA/USDC Permissioned Pool (holds RAW RWA, so it must be HOLDER, like the PermissionsAdapter).
contract SimVenue {
    IERC20 public immutable rwa;
    IERC20 public immutable usdc;
    uint256 public feeBps = 5;

    constructor(IERC20 rwa_, IERC20 usdc_) { (rwa, usdc) = (rwa_, usdc_); }

    function quote(uint256 rwaIn) public view returns (uint256) {
        uint256 x = rwa.balanceOf(address(this));
        uint256 y = usdc.balanceOf(address(this));
        uint256 inAfterFee = rwaIn * (10_000 - feeBps) / 10_000;
        return y * inAfterFee / (x + inAfterFee);
    }

    function sell(uint256 rwaIn) external returns (uint256 out) {
        out = quote(rwaIn);
        rwa.transferFrom(msg.sender, address(this), rwaIn);
        usdc.transfer(msg.sender, out);
    }
}

/// @notice Same economics as the v4 LiquidationAdapter (sell seized RWA, repay, split surplus), minus v4 plumbing.
contract SimAdapter is IMiniLendLiquidationCallback {
    MiniLend public immutable market;
    SimVenue public immutable venue;
    IERC20 public immutable rwa;
    IERC20 public immutable usdc;
    uint256 public immutable keeperBps;

    event Bounty(address indexed keeper, address indexed borrower, uint256 proceeds, uint256 repaid, uint256 bounty, uint256 residual);

    constructor(MiniLend m, SimVenue v, uint256 keeperBps_) {
        (market, venue, rwa, usdc, keeperBps) = (m, v, m.RWA(), m.USDC(), keeperBps_);
    }

    function liquidate(address borrower, uint256 repayAssets, uint256 minBounty) external returns (uint256 bounty, uint256 residual) {
        market.liquidate(borrower, repayAssets, abi.encode(msg.sender, minBounty));
        (bounty, residual) = (lastBounty, lastResidual);
    }

    uint256 internal lastBounty;
    uint256 internal lastResidual;

    function onMiniLendLiquidation(address borrower, uint256 seized, uint256 repaid, bytes calldata data) external {
        require(msg.sender == address(market), "only market");
        (address keeper, uint256 minBounty) = abi.decode(data, (address, uint256));
        rwa.approve(address(venue), seized);
        uint256 proceeds = venue.sell(seized);
        (uint256 bounty, uint256 residual) = BountyMath.split(proceeds, repaid, market.LB_BPS(), keeperBps, minBounty);
        usdc.approve(address(market), repaid);
        if (bounty != 0) usdc.transfer(keeper, bounty);
        if (residual != 0) usdc.transfer(borrower, residual);
        (lastBounty, lastResidual) = (bounty, residual);
        emit Bounty(keeper, borrower, proceeds, repaid, bounty, residual);
    }
}
