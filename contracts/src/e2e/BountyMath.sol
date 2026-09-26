// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Splits USDC swap proceeds of a liquidation. Shared by the real v4 adapter and the test sim.
library BountyMath {
    uint256 internal constant BPS = 10_000;

    error InsufficientProceeds(uint256 proceeds, uint256 repaid);
    error BountyTooLow(uint256 bounty, uint256 minBounty);

    /// @param proceeds    USDC received for the seized RWA (exact-in swap output)
    /// @param repaid      USDC the market pulls
    /// @param lbBps       market liquidation bonus (600 = 6%)
    /// @param keeperBps   share of the surplus paid to the keeper (10_000 = Aave-style "keeper keeps it all")
    /// @return bounty     USDC to msg.sender (keeper), capped at repaid * lb (the bonus valued at NAV)
    /// @return residual   USDC to the borrower (unused slippage budget + any pool premium over NAV)
    function split(uint256 proceeds, uint256 repaid, uint256 lbBps, uint256 keeperBps, uint256 minBounty)
        internal
        pure
        returns (uint256 bounty, uint256 residual)
    {
        if (proceeds < repaid) revert InsufficientProceeds(proceeds, repaid);
        uint256 surplus = proceeds - repaid;
        uint256 cap = repaid * lbBps / BPS; // round down
        bounty = surplus * keeperBps / BPS; // round down
        if (bounty > cap) bounty = cap;
        if (bounty < minBounty) revert BountyTooLow(bounty, minBounty);
        residual = surplus - bounty;
    }
}
