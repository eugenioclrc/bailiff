// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BaseAllowlistChecker} from "@uniswap/v4-periphery/src/hooks/permissionedPools/BaseAllowListChecker.sol";
import {PermissionFlag} from "@uniswap/v4-periphery/src/hooks/permissionedPools/libraries/PermissionFlags.sol";

/// @notice ERC-3643-like restricted token: BOTH sender and receiver must be verified by the issuer.
contract MockRWA is ERC20 {
    address public immutable issuer;
    mapping(address account => bool) public verified;

    error NotAllowlisted(address account);
    error OnlyIssuer();

    constructor() ERC20("Tokyo T-Bill", "tTBILL") {
        issuer = msg.sender;
        verified[msg.sender] = true;
    }

    function setVerified(address account, bool isVerified) external {
        if (msg.sender != issuer) revert OnlyIssuer();
        verified[account] = isVerified;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != issuer) revert OnlyIssuer();
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && !verified[from]) revert NotAllowlisted(from);
        if (to != address(0) && !verified[to]) revert NotAllowlisted(to);
        super._update(from, to, value);
    }
}

/// @notice Issuer-controlled IAllowlistChecker (ERC165) consumed by PermissionsAdapter.isAllowed.
contract RWAAllowlistChecker is BaseAllowlistChecker {
    address public immutable issuer;
    mapping(address account => PermissionFlag) public flags;

    error OnlyIssuer();

    constructor() {
        issuer = msg.sender;
    }

    function setFlags(address account, PermissionFlag flag) external {
        if (msg.sender != issuer) revert OnlyIssuer();
        flags[account] = flag;
    }

    function checkAllowlist(address account, address) public view override returns (PermissionFlag) {
        return flags[account];
    }
}
