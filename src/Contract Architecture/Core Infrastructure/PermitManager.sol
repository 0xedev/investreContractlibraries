// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PermitManager
 * @notice Manages EIP-712 signature-based permissions for secure offchain-triggered actions.
 *         Users can sign typed data authorizing the ActionExecutor (or other contracts) to perform specific actions.
 *CA:0x3280DA07A699B0061dB5e0109c72D05fD72aC991
 */ 
contract PermitManager {
    /// @notice Mapping of used nonces for replay protection: user => nonce => used
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    /// @notice Domain separator for EIP-712
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice Typehash for the Permit struct
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address user,address target,bytes data,uint256 nonce,uint256 deadline)");

    event PermitUsed(address indexed user, address indexed target, uint256 nonce);

    constructor() {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("PermitManager")),
                keccak256(bytes("1")),
                chainId,
                address(this)
            )
        );
    }

    /**
     * @notice Validates an EIP-712 permit signature and marks it as used.
     * @param user The signer of the permit
     * @param target The contract authorized to be called
     * @param data Arbitrary call data authorized by the user
     * @param nonce The nonce to prevent replay attacks
     * @param deadline Expiry timestamp for the permit
     * @param v Signature v
     * @param r Signature r
     * @param s Signature s
     */
    function usePermit(
        address user,
        address target,
        bytes calldata data,
        uint256 nonce,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(block.timestamp <= deadline, "Permit: expired");
        require(!usedNonces[user][nonce], "Permit: already used");

        bytes32 structHash = keccak256(abi.encode(
            PERMIT_TYPEHASH,
            user,
            target,
            keccak256(data),
            nonce,
            deadline
        ));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address recovered = ecrecover(digest, v, r, s);
        require(recovered != address(0) && recovered == user, "Permit: invalid signature");

        usedNonces[user][nonce] = true;

        emit PermitUsed(user, target, nonce);

        // Forward the call to target
        (bool success, bytes memory result) = target.call(data);
        require(success, string(result));
    }
}
