// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

/**
 * @title RandomnessProvider
 * @notice Wrapper around Chainlink VRF to provide secure randomness to other modules/contracts.
 */
contract RandomnessProvider is VRFConsumerBaseV2 {
    VRFCoordinatorV2Interface COORDINATOR;

    uint64 public subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit = 200000;
    uint16 public requestConfirmations = 3;

    mapping(uint256 => address) public requestToCaller;

    event RandomnessRequested(uint256 indexed requestId, address indexed caller);
    event RandomnessFulfilled(uint256 indexed requestId, uint256[] randomWords, address indexed caller);

    constructor(address vrfCoordinator, bytes32 _keyHash, uint64 _subscriptionId)
        VRFConsumerBaseV2(vrfCoordinator)
    {
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
    }

    function requestRandomness(uint32 numWords) external returns (uint256 requestId) {
        requestId = COORDINATOR.requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );

        requestToCaller[requestId] = msg.sender;
        emit RandomnessRequested(requestId, msg.sender);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        address caller = requestToCaller[requestId];
        require(caller != address(0), "RandomnessProvider: invalid requestId");

        emit RandomnessFulfilled(requestId, randomWords, caller);

        // Forward randomness to caller (must implement `receiveRandomness(uint256 requestId, uint256[] memory words)`)
        (bool success,) = caller.call(
            abi.encodeWithSignature("receiveRandomness(uint256,uint256[])", requestId, randomWords)
        );
        require(success, "RandomnessProvider: callback failed");
    }
}
