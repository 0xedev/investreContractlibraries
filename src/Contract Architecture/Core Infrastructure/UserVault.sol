// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title UserVault (cloneable)
 * @notice Minimal, secure per-user vault meant to be cloned via EIP-1167 (WalletManager).
 *         Initialize once via `initialize(owner_)`.
 *
 * Security notes:
 *  - This contract is intentionally small and avoids full OpenZeppelin upgradeable patterns
 *    to keep clone bytecode minimal. It implements a simple initializer guard.
 *  - Owner controls funds; ActionExecutor should be whitelisted off-chain/onchain to call `executeCall`
 *    or Gnosis-style multisig flows should be used if you want shared control.
 */

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// Basic errors (cheaper than revert strings)
error AlreadyInitialized();
error NotOwner();
error ZeroAddress();
error TransferFailed();
error NotWhitelistedCaller();
error InvalidTarget();

contract UserVault {
    using SafeERC20 for IERC20;

    /// @notice Vault owner (the user)
    address private _owner;

    /// @notice Whether initialize has been called
    bool private _initialized;

    /// @notice Optional: an address allowed to call executeCall on behalf of the owner (e.g., ActionExecutor)
    mapping(address => bool) public executorWhitelist;

    /// ========== EVENTS ==========
    event Initialized(address indexed owner);
    event ETHReceived(address indexed from, uint256 amount);
    event ERC20Deposited(address indexed token, address indexed from, uint256 amount);
    event ETHWithdrawn(address indexed to, uint256 amount);
    event ERC20Withdrawn(address indexed token, address indexed to, uint256 amount);
    event ExecutorWhitelisted(address indexed executor, bool allowed);
    event ExecutedCall(address indexed caller, address indexed target, uint256 value, bytes data, bytes result);

    /// ========== MODIFIERS ==========
    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner();
        _;
    }

    modifier onlyOwnerOrExecutor() {
        if (msg.sender != _owner && !executorWhitelist[msg.sender]) revert NotOwner();
        _;
    }

    /// ========== INITIALIZER ==========
    /// @dev called by the clone right after creation
    function initialize(address owner_) external {
        if (_initialized) revert AlreadyInitialized();
        if (owner_ == address(0)) revert ZeroAddress();

        _owner = owner_;
        _initialized = true;

        emit Initialized(owner_);
    }

    /// ========== OWNER VIEW ==========
    function owner() external view returns (address) {
        return _owner;
    }

    /// ========== DEPOSITS ==========
    /// Accept ETH
    receive() external payable {
        emit ETHReceived(msg.sender, msg.value);
    }

    /// Convenience deposit function (no-op besides event)
    function depositETH() external payable {
        emit ETHReceived(msg.sender, msg.value);
    }

    /// Called by user (or any address) that transferred ERC20 tokens to vault via `transfer`
    /// Use only to emit an indexed event for offchain indexing systems.
    function notifyERC20Deposit(address token, uint256 amount) external {
        if (token == address(0)) revert ZeroAddress();
        emit ERC20Deposited(token, msg.sender, amount);
    }

    /// ========== WITHDRAWALS ==========
    /// Owner-only withdraw ETH
    function withdrawETH(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit ETHWithdrawn(to, amount);
    }

    /// Owner-only withdraw ERC20
    function withdrawERC20(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Withdrawn(token, to, amount);
    }

    /// Owner can approve a spender for ERC20
    function approveERC20(
        address token,
        address spender,
        uint256 amount
    ) external onlyOwner {
        if (token == address(0) || spender == address(0)) revert ZeroAddress();
        IERC20(token).approve(spender, amount);
        // No event for approve (ERC20 Approval emits its own)
    }

    /// ========== EXECUTOR WHITELIST (optional) ==========
    /// Add/remove an offchain/executor address allowed to call executeCall
    function setExecutorAllowed(address executor, bool allowed) external onlyOwner {
        if (executor == address(0)) revert ZeroAddress();
        executorWhitelist[executor] = allowed;
        emit ExecutorWhitelisted(executor, allowed);
    }

    /// ========== GENERIC CALL (for ActionExecutor integration) ==========
    /**
     * @notice Execute arbitrary call from the vault.
     * @dev    Must be called by owner or a whitelisted executor. Returns raw call return data.
     *         Use with caution — giving an executor this ability is equivalent to giving control
     *         of the vault's funds to that executor.
     *
     * @param target The destination contract / address to call.
     * @param value  Amount of ETH to send with the call.
     * @param data   Calldata to send.
     * @return result The returned data from the call.
     */
    function executeCall(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyOwnerOrExecutor returns (bytes memory result) {
        if (target == address(0)) revert InvalidTarget();

        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory res) = target.call{value: value}(data);
        if (!ok) {
            // bubble revert reason if present
            if (res.length > 0) {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(add(32, res), mload(res))
                }
            }
            revert TransferFailed();
        }

        emit ExecutedCall(msg.sender, target, value, data, res);
        return res;
    }

    /// ========== HELPERS ==========
    /// Approve then call helper (useful for DEX routing patterns)
    function approveAndCall(
    address token,
    address spender,
    uint256 amount,
    address target,
    bytes calldata data
) external onlyOwnerOrExecutor returns (bytes memory) {
    IERC20(token).approve(spender, amount);
    return this.executeCall(target, 0, data);
}

    /// ========== EMERGENCY ==========
    /// Emergency withdraw all ETH and tokens to owner (owner-only)
    function emergencyWithdrawERC20(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(_owner, bal);
        emit ERC20Withdrawn(token, _owner, bal);
    }

    function emergencyWithdrawETH() external onlyOwner {
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok, ) = payable(_owner).call{value: bal}("");
            if (!ok) revert TransferFailed();
            emit ETHWithdrawn(_owner, bal);
        }
    }

    /// ========== VIEW HELPERS ==========
    function isInitialized() external view returns (bool) {
        return _initialized;
    }
}
