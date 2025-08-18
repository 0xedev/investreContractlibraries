// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title LimitOrderModule
 * @notice Stores user-defined limit orders and executes them when oracle price satisfies target.
 *
 * Trigger rule:
 *  - Let P = oracle price (tokenOut per 1 tokenIn, 1e18 scaled)
 *  - If `greaterThan` = true  => execute when P >= targetPrice1e18
 *  - If `greaterThan` = false => execute when P <= targetPrice1e18
 *
 * Execution:
 *  - Pull `amountIn` of tokenIn from the vault (msg.sender when placing; stored in order)
 *  - Approve router, swap exact-input (single pool), recipient = vault
 *  - Enforce `minOutBips` slippage bound relative to oracle price at execution
 *
 * Notes:
 *  - Vault must approve this module to spend `tokenIn` (or integrate Permit2).
 *  - Uses single-hop Uni V3 (fee provided). For multi-hop, extend as needed.
 */

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IOracleManager {
    /// @notice Returns price of base->quote as (quote per 1 base) in 1e18 and last update timestamp.
    function getPrice1e18(address base, address quote) external view returns (uint256 price1e18, uint256 updatedAt);
}

interface IUniswapV3Router {
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

contract LimitOrderModule is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant MODULE_ID = keccak256("LIMIT_ORDER_MODULE_V1");

    IOracleManager public oracle;
    IUniswapV3Router public router;

    struct Order {
        address vault;              // owner vault
        address tokenIn;
        address tokenOut;
        uint24  fee;                // Uni V3 fee tier
        uint256 amountIn;           // exact input amount
        uint256 targetPrice1e18;    // trigger price (tokenOut per 1 tokenIn)
        bool    greaterThan;        // trigger condition
        uint16  minOutBips;         // slippage bound vs oracle quote at execution (e.g., 9800 = -2%)
        uint64  expiry;             // 0 = no expiry (unix seconds)
        bool    active;
    }

    uint256 public nextOrderId;
    mapping(uint256 => Order) public orders;

    event OracleUpdated(address indexed oracle);
    event RouterUpdated(address indexed router);

    event OrderPlaced(
        uint256 indexed id,
        address indexed vault,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 targetPrice1e18,
        bool greaterThan,
        uint16 minOutBips,
        uint64 expiry
    );
    event OrderCancelled(uint256 indexed id, address indexed vault);
    event OrderExecuted(uint256 indexed id, address indexed vault, uint256 amountOut);

    constructor(address _oracle, address _router) Ownable(msg.sender) {
        require(_oracle != address(0) && _router != address(0), "ZeroAddr");
        oracle = IOracleManager(_oracle);
        router = IUniswapV3Router(_router);
        emit OracleUpdated(_oracle);
        emit RouterUpdated(_router);
    }

    // ---------- Admin ----------
    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "ZeroAddr");
        oracle = IOracleManager(_oracle);
        emit OracleUpdated(_oracle);
    }

    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "ZeroAddr");
        router = IUniswapV3Router(_router);
        emit RouterUpdated(_router);
    }

    // ---------- User flows ----------
    /**
     * @notice Place a limit order.
     * @dev Caller is the vault that will be debited when executing.
     */
    function placeOrder(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint256 targetPrice1e18,
        bool    greaterThan,
        uint16  minOutBips,     // 0 disables minOut guard; else [1..10000]
        uint64  expiry          // 0 = no expiry
    ) external returns (uint256 id) {
        require(tokenIn != address(0) && tokenOut != address(0), "ZeroToken");
        require(amountIn > 0 && targetPrice1e18 > 0, "BadParams");
        if (minOutBips > 10000) revert();

        id = ++nextOrderId;
        orders[id] = Order({
            vault: msg.sender,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            amountIn: amountIn,
            targetPrice1e18: targetPrice1e18,
            greaterThan: greaterThan,
            minOutBips: minOutBips,
            expiry: expiry,
            active: true
        });

        emit OrderPlaced(id, msg.sender, tokenIn, tokenOut, fee, amountIn, targetPrice1e18, greaterThan, minOutBips, expiry);
    }

    function cancelOrder(uint256 id) external {
        Order storage o = orders[id];
        require(o.active, "Inactive");
        require(o.vault == msg.sender, "NotVault");
        o.active = false;
        emit OrderCancelled(id, msg.sender);
    }

    /**
     * @notice Execute an eligible order (keeper or anyone).
     * @dev Pulls tokenIn from the order.vault; vault must have approved this module.
     */
    function executeOrder(uint256 id, uint256 deadline) external nonReentrant returns (uint256 amountOut) {
        Order storage o = orders[id];
        require(o.active, "Inactive");
        if (o.expiry != 0) require(block.timestamp <= o.expiry, "Expired");

        (uint256 px, ) = oracle.getPrice1e18(o.tokenIn, o.tokenOut); // tokenOut per 1 tokenIn
        require(px > 0, "NoPrice");

        // Check trigger
        if (o.greaterThan) {
            require(px >= o.targetPrice1e18, "NotReached");
        } else {
            require(px <= o.targetPrice1e18, "NotReached");
        }

        // Compute minOut from oracle * amountIn, then apply minOutBips if set
        uint256 minOut = (o.amountIn * px) / 1e18;
        if (o.minOutBips != 0) {
            minOut = (minOut * o.minOutBips) / 10000;
        }

        // Pull funds from vault into this module and approve router
        IERC20(o.tokenIn).safeTransferFrom(o.vault, address(this), o.amountIn);
        IERC20(o.tokenIn).approve(address(router), 0);
        IERC20(o.tokenIn).approve(address(router), o.amountIn);

        // Swap, recipient is the vault
        amountOut = router.exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: o.tokenIn,
                tokenOut: o.tokenOut,
                fee: o.fee,
                recipient: o.vault,
                deadline: deadline,
                amountIn: o.amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );

        // Mark inactive
        o.active = false;
        emit OrderExecuted(id, o.vault, amountOut);
    }
}


