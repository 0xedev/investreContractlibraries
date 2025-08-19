
// File: @openzeppelin/contracts/utils/Context.sol


// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)

pragma solidity ^0.8.20;

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}

// File: @openzeppelin/contracts/access/Ownable.sol


// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable.sol)

pragma solidity ^0.8.20;


/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * The initial owner is set to the address provided by the deployer. This can
 * later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    /**
     * @dev The caller account is not authorized to perform an operation.
     */
    error OwnableUnauthorizedAccount(address account);

    /**
     * @dev The owner is not a valid owner account. (eg. `address(0)`)
     */
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the initial owner.
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(initialOwner);
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        if (owner() != _msgSender()) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby disabling any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

// File: @openzeppelin/contracts/utils/cryptography/ECDSA.sol


// OpenZeppelin Contracts (last updated v5.1.0) (utils/cryptography/ECDSA.sol)

pragma solidity ^0.8.20;

/**
 * @dev Elliptic Curve Digital Signature Algorithm (ECDSA) operations.
 *
 * These functions can be used to verify that a message was signed by the holder
 * of the private keys of a given address.
 */
library ECDSA {
    enum RecoverError {
        NoError,
        InvalidSignature,
        InvalidSignatureLength,
        InvalidSignatureS
    }

    /**
     * @dev The signature derives the `address(0)`.
     */
    error ECDSAInvalidSignature();

    /**
     * @dev The signature has an invalid length.
     */
    error ECDSAInvalidSignatureLength(uint256 length);

    /**
     * @dev The signature has an S value that is in the upper half order.
     */
    error ECDSAInvalidSignatureS(bytes32 s);

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with `signature` or an error. This will not
     * return address(0) without also returning an error description. Errors are documented using an enum (error type)
     * and a bytes32 providing additional information about the error.
     *
     * If no error is returned, then the address can be used for verification purposes.
     *
     * The `ecrecover` EVM precompile allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {MessageHashUtils-toEthSignedMessageHash} on it.
     *
     * Documentation for signature generation:
     * - with https://web3js.readthedocs.io/en/v1.3.4/web3-eth-accounts.html#sign[Web3.js]
     * - with https://docs.ethers.io/v5/api/signer/#Signer-signMessage[ethers]
     */
    function tryRecover(
        bytes32 hash,
        bytes memory signature
    ) internal pure returns (address recovered, RecoverError err, bytes32 errArg) {
        if (signature.length == 65) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            // ecrecover takes the signature parameters, and the only way to get them
            // currently is to use assembly.
            assembly ("memory-safe") {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := byte(0, mload(add(signature, 0x60)))
            }
            return tryRecover(hash, v, r, s);
        } else {
            return (address(0), RecoverError.InvalidSignatureLength, bytes32(signature.length));
        }
    }

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature`. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM precompile allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {MessageHashUtils-toEthSignedMessageHash} on it.
     */
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        (address recovered, RecoverError error, bytes32 errorArg) = tryRecover(hash, signature);
        _throwError(error, errorArg);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `r` and `vs` short-signature fields separately.
     *
     * See https://eips.ethereum.org/EIPS/eip-2098[ERC-2098 short signatures]
     */
    function tryRecover(
        bytes32 hash,
        bytes32 r,
        bytes32 vs
    ) internal pure returns (address recovered, RecoverError err, bytes32 errArg) {
        unchecked {
            bytes32 s = vs & bytes32(0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
            // We do not check for an overflow here since the shift operation results in 0 or 1.
            uint8 v = uint8((uint256(vs) >> 255) + 27);
            return tryRecover(hash, v, r, s);
        }
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `r and `vs` short-signature fields separately.
     */
    function recover(bytes32 hash, bytes32 r, bytes32 vs) internal pure returns (address) {
        (address recovered, RecoverError error, bytes32 errorArg) = tryRecover(hash, r, vs);
        _throwError(error, errorArg);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `v`,
     * `r` and `s` signature fields separately.
     */
    function tryRecover(
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (address recovered, RecoverError err, bytes32 errArg) {
        // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
        // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
        // the valid range for s in (301): 0 < s < secp256k1n ÷ 2 + 1, and for v in (302): v ∈ {27, 28}. Most
        // signatures from current libraries generate a unique signature with an s-value in the lower half order.
        //
        // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
        // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
        // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
        // these malleable signatures as well.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return (address(0), RecoverError.InvalidSignatureS, s);
        }

        // If the signature is valid (and not malleable), return the signer address
        address signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) {
            return (address(0), RecoverError.InvalidSignature, bytes32(0));
        }

        return (signer, RecoverError.NoError, bytes32(0));
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `v`,
     * `r` and `s` signature fields separately.
     */
    function recover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address) {
        (address recovered, RecoverError error, bytes32 errorArg) = tryRecover(hash, v, r, s);
        _throwError(error, errorArg);
        return recovered;
    }

    /**
     * @dev Optionally reverts with the corresponding custom error according to the `error` argument provided.
     */
    function _throwError(RecoverError error, bytes32 errorArg) private pure {
        if (error == RecoverError.NoError) {
            return; // no error: do nothing
        } else if (error == RecoverError.InvalidSignature) {
            revert ECDSAInvalidSignature();
        } else if (error == RecoverError.InvalidSignatureLength) {
            revert ECDSAInvalidSignatureLength(uint256(errorArg));
        } else if (error == RecoverError.InvalidSignatureS) {
            revert ECDSAInvalidSignatureS(errorArg);
        }
    }
}

// File: src/Contract Architecture/Core Infrastructure/ActionExecutor.sol


pragma solidity ^0.8.24;

/**
 * @title ActionExecutor
 * @notice Central onchain dispatcher that executes module actions from user vaults.
 *         Uses EIP-712 signed approvals by the vault owner to allow a relayer/bot to
 *         call `executeModuleActionWithSig(...)` which will call `UserVault.executeCall(...)`.
 *CA: 0x2288B1E75e90B62012d527068A07bebE5F89be9d
 * Flow:
 *  1. Vault owner signs an EIP-712 message approving a module action for their vault.
 *  2. Offchain relayer (bot) pushes the signature and params to this contract.
 *  3. This contract validates signature, checks module whitelist, increments nonce,
 *     and calls `UserVault(vault).executeCall(module, value, data)`.
 *
 * Security notes:
 *  - The UserVault must whitelist this ActionExecutor via `setExecutorAllowed(executor, true)`
 *    for the call to succeed (UserVault enforces that).
 *  - Nonces are per-vault to prevent replay attacks.
 *  - Modules must be registered by the contract owner.
 */



interface IUserVault {
    function executeCall(address target, uint256 value, bytes calldata data) external returns (bytes memory);
    function owner() external view returns (address);
}

error ZeroAddress();
error ModuleNotRegistered();
error SignatureExpired();
error InvalidSigner();
error ExecutionFailed();
error ModuleAlreadyRegistered();
error ModuleNotFound();

contract ActionExecutor is Ownable {
    using ECDSA for bytes32;

    /// ========== EVENTS ==========
    event ModuleRegistered(bytes32 indexed moduleId, address indexed module);
    event ModuleUnregistered(bytes32 indexed moduleId, address indexed module);
    event ActionExecuted(
        address indexed vault,
        address indexed owner,
        bytes32 indexed moduleId,
        address module,
        uint256 value,
        bytes data,
        bytes result
    );

    /// ========== MODULE REGISTRY ==========
    /// moduleId => moduleAddress
    mapping(bytes32 => address) public modules;

    /// ========== NONCES ==========
    /// vault => nonce
    mapping(address => uint256) public nonces;

    /// EIP-712 domain separator parameters
    bytes32 public immutable DOMAIN_SEPARATOR;

    // keccak256("Action(address vault,bytes32 moduleId,uint256 value,bytes data,uint256 nonce,uint256 deadline)")
    bytes32 public constant ACTION_TYPEHASH = keccak256("Action(address vault,bytes32 moduleId,uint256 value,bytes data,uint256 nonce,uint256 deadline)");

    constructor() Ownable(msg.sender) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                // EIP-712 Domain: name + version + chainId + verifyingContract
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("ActionExecutor")),
                keccak256(bytes("1")),
                chainId,
                address(this)
            )
        );
    }

    /// ========== MODULE ADMIN ==========
    function registerModule(bytes32 moduleId, address module) external onlyOwner {
        if (module == address(0)) revert ZeroAddress();
        if (modules[moduleId] != address(0)) revert ModuleAlreadyRegistered();
        modules[moduleId] = module;
        emit ModuleRegistered(moduleId, module);
    }

    function unregisterModule(bytes32 moduleId) external onlyOwner {
        address mod = modules[moduleId];
        if (mod == address(0)) revert ModuleNotFound();
        delete modules[moduleId];
        emit ModuleUnregistered(moduleId, mod);
    }

    /// ========== META-TX / EXECUTION ==========
    /**
     * @notice Execute a registered module's action on behalf of user vault, authorized by owner's signature.
     *
     * @param moduleId Registered module id (bytes32)
     * @param vault Address of the UserVault clone
     * @param value ETH value to forward from vault to module (in wei)
     * @param data Calldata to pass to module (executed from vault context)
     * @param deadline Timestamp after which the signature is invalid
     * @param sig EIP-191 signature (65 bytes) from vault owner approving this action
     */
    function executeModuleActionWithSig(
        bytes32 moduleId,
        address vault,
        uint256 value,
        bytes calldata data,
        uint256 deadline,
        bytes calldata sig
    ) external returns (bytes memory result) {
        address module = modules[moduleId];
        if (module == address(0)) revert ModuleNotRegistered();
        if (vault == address(0)) revert ZeroAddress();
        if (block.timestamp > deadline) revert SignatureExpired();

        // Recreate digest
        uint256 nonce = nonces[vault];
        bytes32 structHash = keccak256(abi.encode(ACTION_TYPEHASH, vault, moduleId, value, keccak256(data), nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));

        // Recover signer
        address signer = digest.recover(sig);
        // Ensure signer is owner of the vault
        address vaultOwner = IUserVault(vault).owner();
        if (signer == address(0) || signer != vaultOwner) revert InvalidSigner();

        // increment nonce
        nonces[vault] = nonce + 1;

        // Call the vault to execute the action (vault must whitelist this executor)
        bytes memory res;
        try IUserVault(vault).executeCall(module, value, data) returns (bytes memory r) {
            res = r;
        } catch (bytes memory reason) {
            // Bubble revert if available
            if (reason.length > 0) {
                assembly {
                    revert(add(32, reason), mload(reason))
                }
            }
            revert ExecutionFailed();
        }

        emit ActionExecuted(vault, signer, moduleId, module, value, data, res);
        return res;
    }

    /// @notice Admin fallback: owner of this contract can execute module actions directly (no signature).
    /// Useful for governance-driven or emergency operations.
    function executeModuleActionByOwner(
        bytes32 moduleId,
        address vault,
        uint256 value,
        bytes calldata data
    ) external onlyOwner returns (bytes memory) {
        address module = modules[moduleId];
        if (module == address(0)) revert ModuleNotRegistered();
        if (vault == address(0)) revert ZeroAddress();

        bytes memory res;
        try IUserVault(vault).executeCall(module, value, data) returns (bytes memory r) {
            res = r;
        } catch (bytes memory reason) {
            if (reason.length > 0) {
                assembly {
                    revert(add(32, reason), mload(reason))
                }
            }
            revert ExecutionFailed();
        }

        // Owner is executing as a privileged op — vault owner unknown here.
        emit ActionExecuted(vault, address(0), moduleId, module, value, data, res);
        return res;
    }

    /// ========== HELPERS / VIEWS ==========
    function getModule(bytes32 moduleId) external view returns (address) {
        return modules[moduleId];
    }

    function getNonce(address vault) external view returns (uint256) {
        return nonces[vault];
    }
}
