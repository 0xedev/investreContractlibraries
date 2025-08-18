// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title PortfolioViewer
 * @notice Read-only aggregator to fetch balances (ERC20 + native) across UserVaults
 *         and compute USD values via Chainlink price feeds (when configured).
 *
 * Conventions:
 *  - USD values are returned in 1e18 decimals (wei-like), regardless of the oracle's decimals.
 *  - If a token has no configured price feed, USD value will be 0.
 *
 * Admin:
 *  - Owner can set/update token -> price feed mapping and optional heartbeat limits.
 *  - Native token uses the sentinel address: address(0).
 */

import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,       // price
            uint256 startedAt,
            uint256 updatedAt,   // timestamp
            uint80 answeredInRound
        );

    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
}

contract PortfolioViewer is Ownable {
    // Sentinel for native token (ETH/chain-native)
    address public constant NATIVE = address(0);

    struct FeedConfig {
        AggregatorV3Interface feed;
        uint48 heartbeat; // seconds; 0 = no freshness check
    }

    // token => feed config
    mapping(address => FeedConfig) public feeds;

    event FeedSet(address indexed token, address indexed feed, uint48 heartbeat);

    // ========= Admin: register price feeds =========

    /**
     * @notice Register or update the Chainlink price feed for a token.
     * @param token ERC20 address or address(0) for native token
     * @param feed Chainlink aggregator returning USD price
     * @param heartbeat Max allowed staleness in seconds (0 = no check)
     */
    function setFeed(address token, AggregatorV3Interface feed, uint48 heartbeat) external onlyOwner {
        require(address(feed) != address(0), "Feed=0");
        feeds[token] = FeedConfig(feed, heartbeat);
        emit FeedSet(token, address(feed), heartbeat);
    }

    // ========= Views: balances =========

    function balanceOf(address vault, address token) public view returns (uint256 bal, uint8 dec) {
        if (token == NATIVE) {
            bal = vault.balance;
            dec = 18;
        } else {
            bal = IERC20(token).balanceOf(vault);
            dec = _decimals(token);
        }
    }

    function balancesOf(address vault, address[] calldata tokens)
        external
        view
        returns (uint256[] memory bals, uint8[] memory decs)
    {
        uint256 len = tokens.length;
        bals = new uint256[](len);
        decs = new uint8[](len);
        for (uint256 i; i < len; ++i) {
            (bals[i], decs[i]) = balanceOf(vault, tokens[i]);
        }
    }

    // ========= Views: USD pricing =========

    /**
     * @notice Return USD price in 1e18 for a token (0 if no feed).
     */
    function priceUsd1e18(address token) public view returns (uint256 p) {
        FeedConfig memory cfg = feeds[token];
        if (address(cfg.feed) == address(0)) return 0;

        (, int256 answer,, uint256 updatedAt,) = cfg.feed.latestRoundData();
        if (answer <= 0) return 0;

        if (cfg.heartbeat != 0 && block.timestamp - updatedAt > cfg.heartbeat) {
            return 0; // stale
        }

        uint8 d = cfg.feed.decimals();
        // scale answer (d) -> 18
        // safe since d <= 18 for Chainlink USD feeds
        if (d < 18) {
            p = uint256(answer) * (10 ** (18 - d));
        } else if (d > 18) {
            p = uint256(answer) / (10 ** (d - 18));
        } else {
            p = uint256(answer);
        }
    }

    /**
     * @notice Compute USD value (1e18) for a (balance, token).
     * @dev balance decimals = token decimals; price decimals = 1e18
     */
    function valueUsd1e18(address token, uint256 balance) public view returns (uint256) {
        uint256 px = priceUsd1e18(token);
        if (px == 0 || balance == 0) return 0;

        uint8 dec = (token == NATIVE) ? 18 : _decimals(token);
        // USD value = balance * price / (10^dec)
        return (balance * px) / (10 ** dec);
    }

    /**
     * @notice Return per-token balances and USD values for a single vault.
     */
    function portfolioOf(address vault, address[] calldata tokens)
        external
        view
        returns (uint256[] memory bals, uint256[] memory usdValues, uint256 totalUsd1e18)
    {
        uint256 len = tokens.length;
        bals = new uint256[](len);
        usdValues = new uint256[](len);

        for (uint256 i; i < len; ++i) {
            (uint256 b,) = balanceOf(vault, tokens[i]);
            bals[i] = b;
            uint256 v = valueUsd1e18(tokens[i], b);
            usdValues[i] = v;
            totalUsd1e18 += v;
        }
    }

    /**
     * @notice Aggregate total USD value across many vaults and tokens.
     * @dev Useful for team or leaderboard views.
     */
    function totalValueUsd(address[] calldata vaults, address[] calldata tokens)
        external
        view
        returns (uint256 totalUsd1e18)
    {
        uint256 vLen = vaults.length;
        uint256 tLen = tokens.length;
        for (uint256 v; v < vLen; ++v) {
            for (uint256 t; t < tLen; ++t) {
                (uint256 b,) = balanceOf(vaults[v], tokens[t]);
                totalUsd1e18 += valueUsd1e18(tokens[t], b);
            }
        }
    }

    // ========= Internal helpers =========

    function _decimals(address token) internal view returns (uint8 d) {
        // try/catch to support non-metadata tokens (assume 18)
        try IERC20Metadata(token).decimals() returns (uint8 _d) {
            d = _d;
        } catch {
            d = 18;
        }
    }
}
