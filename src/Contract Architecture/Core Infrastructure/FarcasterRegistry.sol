// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title FarcasterRegistry
 * @notice Canonical registry mapping Farcaster IDs (FIDs) <-> Owners, with optional vault association.
 *         Supports meta-transactions via EIP-712 signatures (link, unlink, transfer).
 *
 *  Guarantees:
 *   - A FID maps to at most one owner.
 *   - An owner can link at most one FID (configurable via code change if multi-FID per owner is needed).
 *
 *  Flows:
 *   - Direct tx:   owner calls link(fid, vault) / unlink(fid) / transfer(fid, newOwner, newVault).
 *   - Meta-tx:     relayer calls linkWithSig / unlinkWithSig / transferWithSig using owner's EIP-712 signature.
 *
 *  Optional:
 *   - setProofVerifier() lets an external verifier contract authorize linking by calling linkWithProof.
 */

import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ECDSA} from "lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

interface IFarcasterProofVerifier {
    function verifyLink(address owner, uint256 fid, bytes calldata proof) external view returns (bool);
}

error ZeroAddress();
error FidAlreadyLinked();
error FidNotLinked();
error OwnerAlreadyLinked();
error NotFidOwner();
error InvalidSigner();
error SignatureExpired();
error Replay();
error VerifierRejected();
error VaultAlreadySet();

contract FarcasterRegistry is Ownable {
    using ECDSA for bytes32;

    // -------------------------
    // Storage
    // -------------------------

    /// @notice FID -> owner
    mapping(uint256 => address) public fidToOwner;

    /// @notice owner -> FID (0 if none)
    mapping(address => uint256) public ownerToFid;

    /// @notice FID -> vault (optional convenience pointer)
    mapping(uint256 => address) public fidToVault;

    /// @notice Nonces for EIP-712 (per-owner)
    mapping(address => uint256) public nonces;

    /// @notice Optional external verifier for offchain proofs
    IFarcasterProofVerifier public proofVerifier;

    // -------------------------
    // Events
    // -------------------------
    event Linked(uint256 indexed fid, address indexed owner, address vault);
    event Unlinked(uint256 indexed fid, address indexed owner);
    event Transferred(uint256 indexed fid, address indexed oldOwner, address indexed newOwner, address newVault);
    event ProofVerifierUpdated(address indexed verifier);

    // -------------------------
    // EIP-712 Domain
    // -------------------------
    bytes32 public immutable DOMAIN_SEPARATOR;

    // keccak256("Link(address owner,uint256 fid,address vault,uint256 nonce,uint256 deadline)")
    bytes32 public constant LINK_TYPEHASH =
        keccak256("Link(address owner,uint256 fid,address vault,uint256 nonce,uint256 deadline)");

    // keccak256("Unlink(address owner,uint256 fid,uint256 nonce,uint256 deadline)")
    bytes32 public constant UNLINK_TYPEHASH =
        keccak256("Unlink(address owner,uint256 fid,uint256 nonce,uint256 deadline)");

    // keccak256("Transfer(address owner,uint256 fid,address newOwner,address newVault,uint256 nonce,uint256 deadline)")
    bytes32 public constant TRANSFER_TYPEHASH =
        keccak256("Transfer(address owner,uint256 fid,address newOwner,address newVault,uint256 nonce,uint256 deadline)");

    constructor() Ownable() {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                // EIP-712 Domain: name, version, chainId, verifyingContract
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("FarcasterRegistry")),
                keccak256(bytes("1")),
                chainId,
                address(this)
            )
        );
    }

    // =========================
    // Admin
    // =========================

    /// @notice Set/replace external proof verifier
    function setProofVerifier(address verifier) external onlyOwner {
        proofVerifier = IFarcasterProofVerifier(verifier);
        emit ProofVerifierUpdated(verifier);
    }

    // =========================
    // Direct (EOA) flows
    // =========================

    /// @notice Link caller as the owner of `fid`, optionally storing a convenience `vault` address.
    function link(uint256 fid, address vault) external {
        _link(msg.sender, fid, vault);
    }

    /// @notice Unlink caller from their `fid`.
    function unlink(uint256 fid) external {
        if (fidToOwner[fid] != msg.sender) revert NotFidOwner();
        _unlink(fid, msg.sender);
    }

    /// @notice Transfer `fid` from caller to `newOwner`, optionally updating `newVault`.
    function transfer(uint256 fid, address newOwner, address newVault) external {
        if (fidToOwner[fid] != msg.sender) revert NotFidOwner();
        _transfer(fid, msg.sender, newOwner, newVault);
    }

    // =========================
    // Meta-tx flows (EIP-712)
    // =========================

    function linkWithSig(
        address owner_,
        uint256 fid,
        address vault,
        uint256 deadline,
        bytes calldata sig
    ) external {
        _checkDeadline(deadline);
        _verifyAndBump(owner_, _hashLink(owner_, fid, vault, nonces[owner_], deadline), sig);
        _link(owner_, fid, vault);
    }

    function unlinkWithSig(
        address owner_,
        uint256 fid,
        uint256 deadline,
        bytes calldata sig
    ) external {
        _checkDeadline(deadline);
        _verifyAndBump(owner_, _hashUnlink(owner_, fid, nonces[owner_], deadline), sig);

        if (fidToOwner[fid] != owner_) revert NotFidOwner();
        _unlink(fid, owner_);
    }

    function transferWithSig(
        address owner_,
        uint256 fid,
        address newOwner,
        address newVault,
        uint256 deadline,
        bytes calldata sig
    ) external {
        _checkDeadline(deadline);
        _verifyAndBump(owner_, _hashTransfer(owner_, fid, newOwner, newVault, nonces[owner_], deadline), sig);

        if (fidToOwner[fid] != owner_) revert NotFidOwner();
        _transfer(fid, owner_, newOwner, newVault);
    }

    // =========================
    // Proof-based linking
    // =========================

    /// @notice Link using an external proof verifier (e.g., Warpcast/Neynar signature proof).
    ///         Callable by anyone; proofVerifier decides validity.
    function linkWithProof(address owner_, uint256 fid, address vault, bytes calldata proof) external {
        IFarcasterProofVerifier v = proofVerifier;
        if (address(v) == address(0)) revert ZeroAddress();
        if (!v.verifyLink(owner_, fid, proof)) revert VerifierRejected();
        _link(owner_, fid, vault);
    }

    // =========================
    // Views
    // =========================

    function getOwnerByFid(uint256 fid) external view returns (address) {
        return fidToOwner[fid];
    }

    function getFidByOwner(address owner_) external view returns (uint256) {
        return ownerToFid[owner_];
    }

    function getVaultByFid(uint256 fid) external view returns (address) {
        return fidToVault[fid];
    }

    // =========================
    // Internal logic
    // =========================

    function _link(address owner_, uint256 fid, address vault) internal {
        if (owner_ == address(0)) revert ZeroAddress();
        if (fid == 0) revert FidNotLinked(); // disallow fid=0
        if (fidToOwner[fid] != address(0)) revert FidAlreadyLinked();
        if (ownerToFid[owner_] != 0) revert OwnerAlreadyLinked();

        fidToOwner[fid] = owner_;
        ownerToFid[owner_] = fid;

        if (vault != address(0)) {
            if (fidToVault[fid] != address(0)) revert VaultAlreadySet();
            fidToVault[fid] = vault;
        }

        emit Linked(fid, owner_, vault);
    }

    function _unlink(uint256 fid, address owner_) internal {
        delete fidToOwner[fid];
        delete fidToVault[fid];
        delete ownerToFid[owner_];
        emit Unlinked(fid, owner_);
    }

    function _transfer(uint256 fid, address oldOwner, address newOwner, address newVault) internal {
        if (newOwner == address(0)) revert ZeroAddress();
        if (ownerToFid[newOwner] != 0) revert OwnerAlreadyLinked();

        // Clear old mapping
        delete ownerToFid[oldOwner];

        // Set new mapping
        fidToOwner[fid] = newOwner;
        ownerToFid[newOwner] = fid;

        // Update optional vault pointer (0 to keep previous cleared, non-zero to set new)
        if (newVault != address(0)) {
            fidToVault[fid] = newVault;
        } else {
            // if not provided, clear to avoid stale vault pointers
            delete fidToVault[fid];
        }

        emit Transferred(fid, oldOwner, newOwner, newVault);
    }

    // =========================
    // EIP-712 helpers
    // =========================

    function _hashLink(
        address owner_,
        uint256 fid,
        address vault,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(LINK_TYPEHASH, owner_, fid, vault, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _hashUnlink(
        address owner_,
        uint256 fid,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(UNLINK_TYPEHASH, owner_, fid, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _hashTransfer(
        address owner_,
        uint256 fid,
        address newOwner,
        address newVault,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash =
            keccak256(abi.encode(TRANSFER_TYPEHASH, owner_, fid, newOwner, newVault, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _verifyAndBump(address expectedSigner, bytes32 digest, bytes calldata sig) internal {
        (address recovered,) = _recover(digest, sig);
        if (recovered == address(0) || recovered != expectedSigner) revert InvalidSigner();

        uint256 n = nonces[expectedSigner];
        // The nonce used in the hash is the *current* nonce; bump now.
        unchecked {
            nonces[expectedSigner] = n + 1;
        }
    }

    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address, bytes32) {
        if (sig.length != 65) return (address(0), bytes32(0));
        bytes32 r;
        bytes32 s;
        uint8 v;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        return (ECDSA.recover(digest, v, r, s), r);
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert SignatureExpired();
    }
}
