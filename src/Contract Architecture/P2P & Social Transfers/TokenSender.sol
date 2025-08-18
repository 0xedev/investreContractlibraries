// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title TokenSender
 * @notice ActionExecutor-registered module for sending ERC20 & native ETH from a UserVault.
 *
 * Usage:
 *   - Must be invoked from a UserVault via UserVault.executeCall(module, value, data)
 *     so that `msg.sender` is the vault (funds come from the vault).
 *
 * Features:
 *   - sendToken / sendETH (single)
 *   - batchSendToken / batchSendETH (multiple recipients)
 *   - send by Farcaster FID using FarcasterRegistry
 *
 * Security:
 *   - No custody; transfers originate from the vault (msg.sender).
 *   - Reentrancy-safe ETH sends via .call{}().
 */

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IFarcasterRegistry {
    function getOwnerByFid(uint256 fid) external view returns (address);
    function getVaultByFid(uint256 fid) external view returns (address);
}

contract TokenSender is Ownable {
    using SafeERC20 for IERC20;

    bytes32 public constant MODULE_ID = keccak256("TOKEN_SENDER_V1");

    /// @notice Optional Farcaster registry for resolving FIDs -> addresses (EOA or vault)
    IFarcasterRegistry public registry;

    event RegistryUpdated(address indexed registry);

    event TokenSent(address indexed vault, address indexed token, address indexed to, uint256 amount);
    event TokenSentByFid(address indexed vault, address indexed token, uint256 fid, address resolved, uint256 amount);

    event EthSent(address indexed vault, address indexed to, uint256 amount);
    event EthSentByFid(address indexed vault, uint256 fid, address resolved, uint256 amount);

    event BatchTokenSent(address indexed vault, address indexed token, uint256 recipients);
    event BatchEthSent(address indexed vault, uint256 recipients);

    constructor(address _registry) Ownable(msg.sender) {
        if (_registry != address(0)) {
            registry = IFarcasterRegistry(_registry);
            emit RegistryUpdated(_registry);
        }
    }

    // ========= Admin =========

    function setRegistry(address _registry) external onlyOwner {
        registry = IFarcasterRegistry(_registry);
        emit RegistryUpdated(_registry);
    }

    // ========= ERC20 =========

    /// @notice Send ERC20 token from the calling vault to `to`.
    function sendToken(address token, address to, uint256 amount) external {
        require(to != address(0), "to=0");
        IERC20(token).safeTransferFrom(msg.sender, to, amount);
        emit TokenSent(msg.sender, token, to, amount);
    }

    /// @notice Send ERC20 token to an address resolved from a Farcaster FID.
    /// @dev Prefers vault mapping; falls back to owner if no vault set.
    function sendTokenByFid(address token, uint256 fid, uint256 amount) external {
        address to = _resolveFid(fid);
        IERC20(token).safeTransferFrom(msg.sender, to, amount);
        emit TokenSentByFid(msg.sender, token, fid, to, amount);
    }

    /// @notice Batch-send ERC20 token with equal amounts to many recipients.
    function batchSendTokenEqual(address token, address[] calldata recipients, uint256 amountEach) external {
        uint256 len = recipients.length;
        for (uint256 i; i < len; ++i) {
            address to = recipients[i];
            require(to != address(0), "to=0");
            IERC20(token).safeTransferFrom(msg.sender, to, amountEach);
        }
        emit BatchTokenSent(msg.sender, token, len);
    }

    /// @notice Batch-send ERC20 token with variable amounts to many recipients.
    function batchSendToken(address token, address[] calldata recipients, uint256[] calldata amounts) external {
        uint256 len = recipients.length;
        require(len == amounts.length, "len mismatch");
        for (uint256 i; i < len; ++i) {
            address to = recipients[i];
            require(to != address(0), "to=0");
            IERC20(token).safeTransferFrom(msg.sender, to, amounts[i]);
        }
        emit BatchTokenSent(msg.sender, token, len);
    }

    // ========= ETH =========

    /// @notice Send native ETH from the vault to `to`.
    /// @dev Must forward ETH into this call via UserVault.executeCall{value: amount}(...).
    function sendETH(address to, uint256 amount) external payable {
        require(to != address(0), "to=0");
        require(msg.value == amount, "bad msg.value");
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "eth send failed");
        emit EthSent(msg.sender, to, amount);
    }

    /// @notice Send native ETH by Farcaster FID (resolves to address).
    function sendETHByFid(uint256 fid, uint256 amount) external payable {
        address to = _resolveFid(fid);
        require(msg.value == amount, "bad msg.value");
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "eth send failed");
        emit EthSentByFid(msg.sender, fid, to, amount);
    }

    /// @notice Batch-send ETH with equal amounts to many recipients.
    function batchSendETHEqual(address[] calldata recipients, uint256 amountEach) external payable {
        uint256 len = recipients.length;
        require(msg.value == amountEach * len, "bad total");
        for (uint256 i; i < len; ++i) {
            address to = recipients[i];
            require(to != address(0), "to=0");
            (bool ok, ) = payable(to).call{value: amountEach}("");
            require(ok, "eth send failed");
        }
        emit BatchEthSent(msg.sender, len);
    }

    /// @notice Batch-send ETH with variable amounts to many recipients.
    function batchSendETH(address[] calldata recipients, uint256[] calldata amounts) external payable {
        uint256 len = recipients.length;
        require(len == amounts.length, "len mismatch");

        uint256 total;
        for (uint256 i; i < len; ++i) total += amounts[i];
        require(msg.value == total, "bad total");

        for (uint256 i; i < len; ++i) {
            address to = recipients[i];
            require(to != address(0), "to=0");
            (bool ok, ) = payable(to).call{value: amounts[i]}("");
            require(ok, "eth send failed");
        }
        emit BatchEthSent(msg.sender, len);
    }

    // ========= Internal =========

    function _resolveFid(uint256 fid) internal view returns (address to) {
        IFarcasterRegistry r = registry;
        require(address(r) != address(0), "registry not set");
        to = r.getVaultByFid(fid);
        if (to == address(0)) {
            to = r.getOwnerByFid(fid);
        }
        require(to != address(0), "fid not linked");
    }

    // receive enables refund safety if ever needed (should be empty)
    receive() external payable {}
}
