// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Treasury
 * @notice Holds protocol fees and community funds, controlled by GovernanceModule.
 */
contract Treasury {
    address public governance;
    event FundsDeposited(address indexed from, uint256 amount);
    event FundsReleased(address indexed to, uint256 amount);

    modifier onlyGovernance() {
        require(msg.sender == governance, "Treasury: not governance");
        _;
    }

    constructor(address _governance) {
        governance = _governance;
    }

    receive() external payable {
        emit FundsDeposited(msg.sender, msg.value);
    }

    function release(address payable to, uint256 amount) external onlyGovernance {
        require(address(this).balance >= amount, "Treasury: insufficient funds");
        (bool success,) = to.call{value: amount}("");
        require(success, "Treasury: transfer failed");
        emit FundsReleased(to, amount);
    }

    function balance() external view returns (uint256) {
        return address(this).balance;
    }
}
