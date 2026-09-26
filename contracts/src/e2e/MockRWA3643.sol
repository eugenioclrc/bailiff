// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAllowlistChecker} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {PermissionFlag, PermissionFlags} from "@uniswap/v4-periphery/src/hooks/permissionedPools/libraries/PermissionFlags.sol";

/// @title MockRWA - ERC-3643-style restricted ERC-20 that is also its own IAllowlistChecker
/// @notice One registry, two layers:
///   - token layer  : HOLDER bit gates who may RECEIVE raw RWA (ERC-3643 `isVerified(_to)`),
///                    frozen wallets cannot send or receive, `paused` blocks all transfers.
///   - pool layer   : SWAP_ALLOWED / LIQUIDITY_ALLOWED bits are served to Uniswap's
///                    PermissionsAdapter through `checkAllowlist` (bits 0 and 1, see PermissionFlags).
contract MockRWA3643 is ERC20, ERC165, IAllowlistChecker {
    uint16 public constant SWAP = 0x0001; // == PermissionFlags.SWAP_ALLOWED
    uint16 public constant LIQUIDITY = 0x0002; // == PermissionFlags.LIQUIDITY_ALLOWED
    uint16 public constant HOLDER = 0x8000; // token-level "identity verified"

    address public immutable issuer; // ERC-3643 "agent"
    bool public paused;
    mapping(address => uint16) public flags;
    mapping(address => bool) public frozen;

    event FlagsSet(address indexed account, uint16 flags);
    event FrozenSet(address indexed account, bool frozen);
    event PausedSet(bool paused);

    error OnlyIssuer();
    error NotAllowlisted(address to);
    error WalletFrozen(address account);
    error TokenPaused();

    modifier onlyIssuer() {
        if (msg.sender != issuer) revert OnlyIssuer();
        _;
    }

    constructor(address issuer_) ERC20("Tokyo RE Fund (mock)", "tTRE") {
        issuer = issuer_;
        flags[issuer_] = HOLDER | SWAP | LIQUIDITY;
        emit FlagsSet(issuer_, flags[issuer_]);
    }

    // ---------------------------------------------------------------- admin (issuer / agent)
    function setFlags(address account, uint16 newFlags) external onlyIssuer {
        flags[account] = newFlags;
        emit FlagsSet(account, newFlags);
    }

    function setFrozen(address account, bool isFrozen) external onlyIssuer {
        frozen[account] = isFrozen;
        emit FrozenSet(account, isFrozen);
    }

    function setPaused(bool isPaused) external onlyIssuer {
        paused = isPaused;
        emit PausedSet(isPaused);
    }

    function mint(address to, uint256 amount) external onlyIssuer {
        _mint(to, amount); // _update enforces HOLDER on `to`
    }

    /// @notice ERC-3643 forcedTransfer: agent may move tokens (ignores freeze/pause), recipient must still be verified.
    function forcedTransfer(address from, address to, uint256 amount) external onlyIssuer {
        if (flags[to] & HOLDER == 0) revert NotAllowlisted(to);
        super._update(from, to, amount);
    }

    // ---------------------------------------------------------------- IAllowlistChecker (Uniswap PermissionsAdapter)
    function checkAllowlist(address account, address tokenAddress) external view returns (PermissionFlag) {
        if (tokenAddress != address(this)) return PermissionFlags.NONE;
        return PermissionFlag.wrap(bytes2(flags[account]));
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IAllowlistChecker).interfaceId || super.supportsInterface(interfaceId);
    }

    // ---------------------------------------------------------------- transfer restriction
    function isHolder(address account) public view returns (bool) {
        return flags[account] & HOLDER != 0;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (to != address(0)) {
            if (paused && from != address(0)) revert TokenPaused();
            if (frozen[to]) revert WalletFrozen(to);
            if (!isHolder(to)) revert NotAllowlisted(to);
        }
        if (from != address(0) && frozen[from]) revert WalletFrozen(from);
        super._update(from, to, amount);
    }
}
