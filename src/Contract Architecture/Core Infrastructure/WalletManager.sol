// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title WalletManager
 * @notice Creates per-user vaults using EIP-1167 minimal proxies and links Farcaster IDs to owners.
 *         Keeps bijective relations: owner -> vault, FID -> owner. Each owner has at most one vault.
 *
 * @dev    Expects a deployed UserVault implementation that has an initialize(address owner) function.
 *         Uses OpenZeppelin Ownable & Clones. Safe for use as a core infra piece.
 */

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

interface IUserVault {
    function initialize(address owner_) external;
    function owner() external view returns (address);
}

/// @dev Basic errors to keep bytecode lean.
error ZeroAddress();
error AlreadyHasVault();
error VaultNotFound();
error FidAlreadyLinked();
error FidNotLinked();
error NotFidOwner();
error OwnerAlreadyLinked();
error ImplementationNotSet();

contract WalletManager is Ownable {
    using Clones for address;

    /// @notice UserVault implementation to be cloned for each new user.
    address public userVaultImplementation;

    /// @notice Owner -> Vault address (1:1).
    mapping(address => address) public ownerToVault;

    /// @notice Farcaster FID -> Owner address (1:1).
    mapping(uint256 => address) public fidToOwner;

    /// @notice Owner -> FID (0 when not linked).
    mapping(address => uint256) public ownerToFid;

    /// @notice Emitted when a new vault is created for an owner.
    event WalletCreated(address indexed owner, uint256 indexed fid, address vault);

    /// @notice Emitted when a FID is linked to an owner.
    event FidLinked(uint256 indexed fid, address indexed owner);

    /// @notice Emitted when a FID is unlinked from its owner.
    event FidUnlinked(uint256 indexed fid, address indexed previousOwner);

    /// @notice Emitted when the UserVault implementation is updated.
    event UserVaultImplementationUpdated(address indexed implementation);

    constructor(address _userVaultImplementation) Ownable(msg.sender) {
        if (_userVaultImplementation == address(0)) revert ZeroAddress();
        userVaultImplementation = _userVaultImplementation;
        emit UserVaultImplementationUpdated(_userVaultImplementation);
    }

    // ========= Admin =========

    /// @notice Update the UserVault implementation used by future clones.
    /// @dev Only affects *new* vaults; existing vaults remain unchanged.
    function setUserVaultImplementation(address _implementation) external onlyOwner {
        if (_implementation == address(0)) revert ZeroAddress();
        userVaultImplementation = _implementation;
        emit UserVaultImplementationUpdated(_implementation);
    }

    // ========= Public (Owner) Actions =========

    /**
     * @notice Create a vault for `owner_` and (optionally) link a Farcaster FID.
     * @dev    Reverts if owner already has a vault. If fid_ > 0, also links the FID.
     * @param  owner_ The EOA or smart account that will control the new vault.
     * @param  fid_   Farcaster ID to link (use 0 to skip linking).
     * @return vault  The address of the newly created vault clone.
     */
    function createWallet(address owner_, uint256 fid_) external returns (address vault) {
        if (userVaultImplementation == address(0)) revert ImplementationNotSet();
        if (owner_ == address(0)) revert ZeroAddress();
        if (ownerToVault[owner_] != address(0)) revert AlreadyHasVault();
        if (fid_ != 0 && fidToOwner[fid_] != address(0)) revert FidAlreadyLinked();

        // Deploy minimal proxy clone
        vault = Clones.clone(userVaultImplementation);

        // Initialize ownership inside the vault
        IUserVault(vault).initialize(owner_);

        // Record owner -> vault
        ownerToVault[owner_] = vault;

        // Optionally link FID
        if (fid_ != 0) {
            fidToOwner[fid_] = owner_;
            ownerToFid[owner_] = fid_;
            emit FidLinked(fid_, owner_);
        }

        emit WalletCreated(owner_, fid_, vault);
    }

    /**
     * @notice Link a Farcaster FID to msg.sender. Each FID and owner can be linked only once.
     * @dev    If msg.sender already has a different FID, unlink first by calling `unlinkFid`.
     */
    function linkFarcasterId(uint256 fid_) external {
        if (fid_ == 0) revert FidNotLinked();
        if (fidToOwner[fid_] != address(0)) revert FidAlreadyLinked();
        if (ownerToFid[msg.sender] != 0) revert OwnerAlreadyLinked();

        fidToOwner[fid_] = msg.sender;
        ownerToFid[msg.sender] = fid_;
        emit FidLinked(fid_, msg.sender);
    }

    /**
     * @notice Unlink the FID currently tied to msg.sender.
     */
    function unlinkFarcasterId() external {
        uint256 existing = ownerToFid[msg.sender];
        if (existing == 0) revert FidNotLinked();

        // Clear both mappings
        delete fidToOwner[existing];
        delete ownerToFid[msg.sender];

        emit FidUnlinked(existing, msg.sender);
    }

    // ========= Views =========

    /// @notice Get a vault by owner. Reverts if none exists.
    function getVault(address owner_) external view returns (address vault) {
        vault = ownerToVault[owner_];
        if (vault == address(0)) revert VaultNotFound();
    }

    /// @notice Get an owner by FID (returns address(0) if not linked).
    function getOwnerByFid(uint256 fid_) external view returns (address) {
        return fidToOwner[fid_];
    }

    /// @notice Get a vault by FID (reverts if FID not linked or vault missing).
    function getVaultByFid(uint256 fid_) external view returns (address vault) {
        address owner_ = fidToOwner[fid_];
        if (owner_ == address(0)) revert FidNotLinked();
        vault = ownerToVault[owner_];
        if (vault == address(0)) revert VaultNotFound();
    }
}
