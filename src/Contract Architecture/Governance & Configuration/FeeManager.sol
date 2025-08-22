// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title FeeManager
 * @notice Collects and distributes protocol fees.
 */
contract FeeManager {
    address public treasury;
    uint256 public feeBps; // basis points (1% = 100)
    uint256 public constant MAX_FEE_BPS = 1000; // 10%

    event FeeUpdated(uint256 newFee);
    event FeeCollected(address indexed from, uint256 amount);

    constructor(address _treasury, uint256 _feeBps) {
        require(_feeBps <= MAX_FEE_BPS, "FeeManager: too high");
        treasury = _treasury;
        feeBps = _feeBps;
    }

    function setFee(uint256 _feeBps) external {
        require(_feeBps <= MAX_FEE_BPS, "FeeManager: too high");
        feeBps = _feeBps;
        emit FeeUpdated(_feeBps);
    }

    function takeFee() external payable {
        uint256 fee = (msg.value * feeBps) / 10000;
        (bool success,) = payable(treasury).call{value: fee}("");
        require(success, "FeeManager: fee transfer failed");
        emit FeeCollected(msg.sender, fee);
    }
}
