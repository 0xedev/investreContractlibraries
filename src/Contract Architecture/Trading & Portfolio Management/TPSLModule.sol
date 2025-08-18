// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title TPSLModule
 * @notice Take-Profit / Stop-Loss automation for spot positions.
 *
 * Config (per vault + pair):
 *  - Sell `amountIn` of `base` into `quote` when:
 *      * TP: price >= takeProfitPrice1e18, OR
 *      * SL: price <= stopLossPrice1e18
 *  - Slippage guard via `minOutBips` against oracle-implied output
 *
 * Execution:
 *  - Anyone can call `execute(vault, base, quote, deadline)` when triggered.
 *  - Pull tokens from vault, swap exact-input (Uni V3), send proceeds to vault.
 *
 * Notes:
 *  - `amountIn=0` => sell entire base balance held by the vault.
 *  - Vault must approve this module to spend `base` (or integrate Permit2).
 */

import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface IOracleManager2 {
    function getPrice1e18(address base, address quote) external view returns (uint256 price1e18, uint256 updatedAt);
}

interface IUniswapV3Router2 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256 amountOut);
}

contract TPSLModule is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant MODULE_ID = keccak256("TPSL_MODULE_V1");

    IOracleManager2 public oracle;
    IUniswapV3Router2 public router;

    struct Config {
        bool    active;
        address base;                // token to sell when triggered
        address quote;               // token to receive
        uint24  fee;                 // Uni V3 fee tier
        uint256 amountIn;            // 0 => all base balance
        uint256 takeProfitPrice1e18; // 0 => disabled
        uint256 stopLossPrice1e18;   // 0 => disabled
        uint16  minOutBips;          // slippage vs oracle (e.g., 9800)
    }

    // vault => base => quote => config
    mapping(address => mapping(address => mapping(address => Config))) public configs;

    event OracleUpdated(address indexed oracle);
    event RouterUpdated(address indexed router);

    event ConfigSet(
        address indexed vault,
        address indexed base,
        address indexed quote,
        uint24 fee,
        uint256 amountIn,
        uint256 takeProfitPrice1e18,
        uint256 stopLossPrice1e18,
        uint16  minOutBips,
        bool    active
    );

    event Cleared(address indexed vault, address indexed base, address indexed quote);
    event Executed(address indexed vault, address indexed base, address indexed quote, uint256 sold, uint256 received, bool tpTriggered, bool slTriggered);

    constructor(address _oracle, address _router) {
        require(_oracle != address(0) && _router != address(0), "ZeroAddr");
        oracle = IOracleManager2(_oracle);
        router = IUniswapV3Router2(_router);
        emit OracleUpdated(_oracle);
        emit RouterUpdated(_router);
    }

    // ---------- Admin ----------
    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "ZeroAddr");
        oracle = IOracleManager2(_oracle);
        emit OracleUpdated(_oracle);
    }

    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "ZeroAddr");
        router = IUniswapV3Router2(_router);
        emit RouterUpdated(_router);
    }

    // ---------- Vault configuration ----------
    function setTPSL(
        address base,
        address quote,
        uint24  fee,
        uint256 amountIn,            // 0 => all
        uint256 takeProfitPrice1e18, // 0 => disabled
        uint256 stopLossPrice1e18,   // 0 => disabled
        uint16  minOutBips           // 0 => disabled
    ) external {
        require(base != address(0) && quote != address(0), "ZeroToken");
        require(takeProfitPrice1e18 > 0 || stopLossPrice1e18 > 0, "NoTriggers");
        require(minOutBips <= 10000, "BadBips");

        configs[msg.sender][base][quote] = Config({
            active: true,
            base: base,
            quote: quote,
            fee: fee,
            amountIn: amountIn,
            takeProfitPrice1e18: takeProfitPrice1e18,
            stopLossPrice1e18: stopLossPrice1e18,
            minOutBips: minOutBips
        });

        emit ConfigSet(msg.sender, base, quote, fee, amountIn, takeProfitPrice1e18, stopLossPrice1e18, minOutBips, true);
    }

    function clearTPSL(address base, address quote) external {
        delete configs[msg.sender][base][quote];
        emit Cleared(msg.sender, base, quote);
    }

    // ---------- Execution (keeper or anyone) ----------
    function execute(address vault, address base, address quote, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amountSold, uint256 amountReceived)
    {
        Config memory c = configs[vault][base][quote];
        require(c.active, "Inactive");

        (uint256 px, ) = oracle.getPrice1e18(base, quote); // quote per 1 base
        require(px > 0, "NoPrice");

        bool tp = (c.takeProfitPrice1e18 != 0 && px >= c.takeProfitPrice1e18);
        bool sl = (c.stopLossPrice1e18   != 0 && px <= c.stopLossPrice1e18);
        require(tp || sl, "NotTriggered");

        // Determine sell amount
        amountSold = c.amountIn;
        if (amountSold == 0) {
            amountSold = IERC20(base).balanceOf(vault);
            require(amountSold > 0, "NoBalance");
        }

        // Oracle-implied minOut with bips guard
        uint256 minOut = (amountSold * px) / 1e18;
        if (c.minOutBips != 0) {
            minOut = (minOut * c.minOutBips) / 10000;
        }

        // Pull base from vault, approve router
        IERC20(base).safeTransferFrom(vault, address(this), amountSold);
        IERC20(base).safeApprove(address(router), 0);
        IERC20(base).safeApprove(address(router), amountSold);

        // Swap to quote, recipient is vault
        amountReceived = router.exactInputSingle(
            IUniswapV3Router2.ExactInputSingleParams({
                tokenIn: base,
                tokenOut: quote,
                fee: c.fee,
                recipient: vault,
                deadline: deadline,
                amountIn: amountSold,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );

        // Clear config after execution (single-shot). If you want persistent, comment this out.
        delete configs[vault][base][quote];

        emit Executed(vault, base, quote, amountSold, amountReceived, tp, sl);
    }
}
