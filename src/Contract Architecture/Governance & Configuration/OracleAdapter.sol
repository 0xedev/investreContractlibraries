// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title OracleAdapter
 * @notice Provides price data to modules from different oracle sources (Chainlink, Uniswap, etc.).
 */
contract OracleAdapter {
    mapping(bytes32 => address) public feeds; // assetPairHash => oracle feed

    event OracleRegistered(bytes32 indexed pair, address feed);

    function registerOracle(string calldata pair, address feed) external {
        bytes32 hash = keccak256(abi.encodePacked(pair));
        feeds[hash] = feed;
        emit OracleRegistered(hash, feed);
    }

    function getOracle(string calldata pair) public view returns (address) {
        return feeds[keccak256(abi.encodePacked(pair))];
    }

    // Example: direct Chainlink-style latestAnswer fetch
    function getPrice(string calldata pair) external view returns (int256) {
        address feed = getOracle(pair);
        require(feed != address(0), "OracleAdapter: feed not set");

        (, int256 answer,,,) = AggregatorV3Interface(feed).latestRoundData();
        return answer;
    }
}

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}
