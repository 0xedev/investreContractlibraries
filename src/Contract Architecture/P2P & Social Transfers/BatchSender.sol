// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title BatchSender
 * @notice Gas-optimized batch distributions (ERC20 & native) from a UserVault.
 *
 * Design:
 *  - For ERC20, pulls the total amount once from the vault (msg.sender) into this module,
 *    then distributes via transfer — cheaper than multiple transferFrom calls.
 *  - For ETH, require msg.value to equal the total to distribute and fan out via .call.
 *  - Supports recipients by address[] or Farcaster FID[] (resolved to vault/owner).
 *
 * Security:
 *  - No custodial state; any failure reverts the whole txn (no partial sends).
 *  - Intended to be called via UserVault.executeCall(...) so msg.sender == the vault.
 */

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IFarcasterRegistry {
    function getVaultByFid(uint256 fid) external view returns (address);
    function getOwnerByFid(uint256 fid) external view returns (address);
}

contract BatchSender is Ownable {
    using SafeERC20 for IERC20;

    bytes32 public constant MODULE_ID = keccak256("BATCH_SENDER_V1");

    IFarcasterRegistry public registry;

    event RegistryUpdated(address indexed registry);
    event BatchTokenSent(address indexed vault, address indexed token, uint256 recipients, uint256 total);
    event BatchEthSent(address indexed vault, uint256 recipients, uint256 total);

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

    // ========= Helpers =========

    function _resolveFid(uint256 fid) internal view returns (address to) {
        IFarcasterRegistry r = registry;
        require(address(r) != address(0), "registry not set");
        to = r.getVaultByFid(fid);
        if (to == address(0)) to = r.getOwnerByFid(fid);
        require(to != address(0), "fid not linked");
    }

    // ========= ERC20: equal amounts =========

    /// @notice Distribute `amountEach` of `token` to every `recipients[i]`.
    function sendTokenEqual(address token, address[] calldata recipients, uint256 amountEach) external {
        uint256 len = recipients.length;
        require(len > 0, "empty");
        uint256 total = amountEach * len;

        // Pull total from the calling vault (msg.sender)
        IERC20(token).safeTransferFrom(msg.sender, address(this), total);

        for (uint256 i; i < len; ++i) {
            address to = recipients[i];
            require(to != address(0), "to=0");
            IERC20(token).safeTransfer(to, amountEach);
        }

        emit BatchTokenSent(msg.sender, token, len, total);
    }

    /// @notice Distribute `amountEach` of `token` to FID-resolved addresses.
    function sendTokenEqualByFid(address token, uint256[] calldata fids, uint256 amountEach) external {
        uint256 len = fids.length;
        require(len > 0, "empty");
        uint256 total = amountEach * len;

        IERC20(token).safeTransferFrom(msg.sender, address(this), total);

        for (uint256 i; i < len; ++i) {
            address to = _resolveFid(fids[i]);
            IERC20(token).safeTransfer(to, amountEach);
        }

        emit BatchTokenSent(msg.sender, token, len, total);
    }

    // ========= ERC20: variable amounts =========

    /// @notice Distribute variable `amounts[i]` of `token` to `recipients[i]`.
    function sendToken(address token, address[] calldata recipients, uint256[] calldata amounts) external {
        uint256 len = recipients.length;
        require(len == amounts.length && len > 0, "len mismatch");

        uint256 total;
        for (uint256 i; i < len; ++i) total += amounts[i];

        IERC20(token).safeTransferFrom(msg.sender, address(this), total);

        for (uint256 i; i < len; ++i) {
            address to = recipients[i];
            require(to != address(0), "to=0");
            IERC20(token).safeTransfer(to, amounts[i]);
        }

        emit BatchTokenSent(msg.sender, token, len, total);
    }

    /// @notice Distribute variable `amounts[i]` of `token` to FID-resolved addresses.
    function sendTokenByFid(address token, uint256[] calldata fids, uint256[] calldata amounts) external {
        uint256 len = fids.length;
        require(len == amounts.length && len > 0, "len mismatch");

        uint256 total;
        for (uint256 i; i < len; ++i) total += amounts[i];

        IERC20(token).safeTransferFrom(msg.sender, address(this), total);

        for (uint256 i; i < len; ++i) {
            IERC20(token).safeTransfer(_resolveFid(fids[i]), amounts[i]);
        }

        emit BatchTokenSent(msg.sender, token, len, total);
    }

    // ========= ETH: equal amounts =========

    /// @notice Distribute equal `amountEach` ETH to `recipients`. Provide exact total in msg.value.
    function sendEtHEqual(address[] calldata recipients, uint256 amountEach) external payable {
        uint256 len = recipients.length;
        require(len > 0, "empty");
        uint256 total = amountEach * len;
        require(msg.value == total, "bad total");

        for (uint256 i; i < len; ++i) {
            address to = recipients[i];
            require(to != address(0), "to=0");
            (bool ok, ) = payable(to).call{value: amountEach}("");
            require(ok, "eth send failed");
        }

        emit BatchEthSent(msg.sender, len, total);
    }

    /// @notice Distribute equal `amountEach` ETH to FID-resolved addresses.
    function sendEtHEqualByFid(uint256[] calldata fids, uint256 amountEach) external payable {
        uint256 len = fids.length;
        require(len > 0, "empty");
        uint256 total = amountEach * len;
        require(msg.value == total, "bad total");

        for (uint256 i; i < len; ++i) {
            address to = _resolveFid(fids[i]);
            (bool ok, ) = payable(to).call{value: amountEach}("");
            require(ok, "eth send failed");
        }

        emit BatchEthSent(msg.sender, len, total);
    }

    // ========= ETH: variable amounts =========

    /// @notice Distribute variable `amounts[i]` ETH to `recipients[i]`. Provide exact total in msg.value.
    function sendEtH(address[] calldata recipients, uint256[] calldata amounts) external payable {
        uint256 len = recipients.length;
        require(len == amounts.length && len > 0, "len mismatch");

        uint256 total;
        for (uint256 i; i < len; ++i) total += amounts[i];
        require(msg.value == total, "bad total");

        for (uint256 i; i < len; ++i) {
            address to = recipients[i];
            require(to != address(0), "to=0");
            (bool ok, ) = payable(to).call{value: amounts[i]}("");
            require(ok, "eth send failed");
        }

        emit BatchEthSent(msg.sender, len, total);
    }

    /// @notice Distribute variable `amounts[i]` ETH to FID-resolved addresses.
    function sendEtHByFid(uint256[] calldata fids, uint256[] calldata amounts) external payable {
        uint256 len = fids.length;
        require(len == amounts.length && len > 0, "len mismatch");

        uint256 total;
        for (uint256 i; i < len; ++i) total += amounts[i];
        require(msg.value == total, "bad total");

        for (uint256 i; i < len; ++i) {
            address to = _resolveFid(fids[i]);
            (bool ok, ) = payable(to).call{value: amounts[i]}("");
            require(ok, "eth send failed");
        }

        emit BatchEthSent(msg.sender, len, total);
    }

    // receive() to allow ETH refunds if ever needed in future extensions; unused otherwise.
    receive() external payable {}
}
