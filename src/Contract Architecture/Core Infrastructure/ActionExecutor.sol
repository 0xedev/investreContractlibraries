// SPDX-License-Identifier: MIT
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

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

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
