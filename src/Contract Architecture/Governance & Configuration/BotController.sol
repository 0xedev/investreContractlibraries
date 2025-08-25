// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BotController
 * @notice Governance-controlled contract for managing bots, upgrading modules,
 *         and adjusting system parameters like gas limits, execution thresholds, etc.
 */
contract BotController {
    address public governor; // DAO or multisig
    mapping(address => bool) public approvedBots;
    mapping(bytes32 => uint256) public systemParams; // generic param storage

    event BotApproved(address indexed bot, bool approved);
    event ParamUpdated(bytes32 indexed key, uint256 value);
    event GovernorTransferred(address indexed oldGov, address indexed newGov);

    modifier onlyGovernor() {
        require(msg.sender == governor, "BotController: not governor");
        _;
    }

    constructor(address _governor) {
        governor = _governor;
    }

    // --- Bot Management ---
    function setBot(address bot, bool approved) external onlyGovernor {
        approvedBots[bot] = approved;
        emit BotApproved(bot, approved);
    }

    function isBotApproved(address bot) external view returns (bool) {
        return approvedBots[bot];
    }

    // --- System Parameters ---
    function setParam(bytes32 key, uint256 value) external onlyGovernor {
        systemParams[key] = value;
        emit ParamUpdated(key, value);
    }

    function getParam(bytes32 key) external view returns (uint256) {
        return systemParams[key];
    }

    // --- Governor Upgrade ---
    function transferGovernorship(address newGov) external onlyGovernor {
        require(newGov != address(0), "BotController: zero addr");
        emit GovernorTransferred(governor, newGov);
        governor = newGov;
    }
}
