// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title SwapModule (Uniswap V3)
 * @notice ActionExecutor-registered module for buying/selling tokens from a UserVault via Uniswap V3.
 *         IMPORTANT: This module is intended to be called FROM a UserVault context using
 *         UserVault.executeCall(module, value, data). That means `msg.sender` is the vault,
 *         so token approvals and transfers operate on the vault's balances.
 *CA:0x28a62cfe6Ae10e930CDbdC76308761e1167144b4
 * Supported flows:
 *  - Exact Input Single (tokenIn -> tokenOut)
 *  - Exact Input Multi-hop (path-encoded)
 *  - Exact Output Single (target exact amountOut)
 *  - Wrap/Unwrap ETH (via WETH9) helpers
 *
 * Security:
 *  - No internal fund custody. All tokens remain in the vault.
 *  - Approval pattern resets to 0 before setting new allowance (non-standard ERC20 safety).
 *  - Slippage and deadlines must be provided by the caller/relayer.
 */

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IUniswapV3RouterLike {
    /// @dev Minimal subset of ISwapRouter we need

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96; // set 0 to ignore
    }

    struct ExactInputParams {
        bytes   path;       // encoded path: tokenIn, fee, tokenMid, fee, tokenOut...
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96; // set 0 to ignore
    }

    struct ExactOutputParams {
        bytes   path;       // note: path is reversed (tokenOut...tokenIn)
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}

contract SwapModule is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Module identifier to use when registering in ActionExecutor
    bytes32 public constant MODULE_ID = keccak256("SWAP_MODULE_V1");

    /// @notice Uniswap V3 router (ISwapRouter)
    IUniswapV3RouterLike public router;

    /// @notice Wrapped native token
    IWETH9 public weth;

    event RouterUpdated(address indexed newRouter);
    event WETHUpdated(address indexed newWETH);

    event SwapExactInputSingle(
        address indexed vault,
        address indexed tokenIn,
        address indexed tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOut
    );

    event SwapExactInputPath(
        address indexed vault,
        bytes path,
        uint256 amountIn,
        uint256 amountOut
    );

    event SwapExactOutputSingle(
        address indexed vault,
        address indexed tokenIn,
        address indexed tokenOut,
        uint24 fee,
        uint256 amountOut,
        uint256 amountInSpent
    );

    event SwapExactOutputPath(
        address indexed vault,
        bytes path,
        uint256 amountOut,
        uint256 amountInSpent
    );

    event Wrapped(address indexed vault, uint256 amount);
    event Unwrapped(address indexed vault, uint256 amount);

    constructor(address _router, address _weth) Ownable(msg.sender) {
        require(_router != address(0) && _weth != address(0), "ZeroAddr");
        router = IUniswapV3RouterLike(_router);
        weth = IWETH9(_weth);
        emit RouterUpdated(_router);
        emit WETHUpdated(_weth);
    }

    // ========= Admin =========

    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "ZeroAddr");
        router = IUniswapV3RouterLike(_router);
        emit RouterUpdated(_router);
    }

    function setWETH(address _weth) external onlyOwner {
        require(_weth != address(0), "ZeroAddr");
        weth = IWETH9(_weth);
        emit WETHUpdated(_weth);
    }

    // ========= Internal approval helper =========

    function _safeApprove(IERC20 token, address spender, uint256 amount) internal {
        // Reset to 0 first (handles tokens that require allowance to be 0 before set)
        token.approve(spender, 0);
        token.approve(spender, amount);
    }

    // ========= Public swap methods (to be called from the vault context) =========

    /**
     * @notice Exact-input single-pool swap (tokenIn -> tokenOut).
     * @dev Caller must be the vault (i.e., invoked via UserVault.executeCall).
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param fee Uniswap V3 pool fee (e.g., 500/3000/10000)
     * @param amountIn Amount of tokenIn to swap
     * @param amountOutMin Minimum acceptable tokenOut (slippage control)
     * @param deadline Unix timestamp after which the tx reverts
     */
    function swapExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        _safeApprove(IERC20(tokenIn), address(router), amountIn);

        amountOut = router.exactInputSingle(
            IUniswapV3RouterLike.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: msg.sender, // vault receives output
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: amountOutMin,
                sqrtPriceLimitX96: 0
            })
        );

        emit SwapExactInputSingle(msg.sender, tokenIn, tokenOut, fee, amountIn, amountOut);
    }

    /**
     * @notice Exact-input multihop swap using an encoded path.
     * @param path Uniswap V3 path (tokenIn,fee,tokenMid,fee,tokenOut...)
     * @param amountIn Amount of input token to spend
     * @param amountOutMin Minimum acceptable output (slippage)
     * @param deadline Expiry
     */
    function swapExactInputPath(
        bytes calldata path,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline,
        address tokenIn // needed to approve
    ) external returns (uint256 amountOut) {
        _safeApprove(IERC20(tokenIn), address(router), amountIn);

        amountOut = router.exactInput(
            IUniswapV3RouterLike.ExactInputParams({
                path: path,
                recipient: msg.sender,
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: amountOutMin
            })
        );

        emit SwapExactInputPath(msg.sender, path, amountIn, amountOut);
    }

    /**
     * @notice Exact-output single-pool swap (spend up to amountInMax to receive amountOut).
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param fee Pool fee
     * @param amountOut Desired exact output
     * @param amountInMax Max input you're willing to spend (slippage)
     * @param deadline Expiry
     */
    function swapExactOutputSingle(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountOut,
        uint256 amountInMax,
        uint256 deadline
    ) external returns (uint256 amountInSpent) {
        _safeApprove(IERC20(tokenIn), address(router), amountInMax);

        amountInSpent = router.exactOutputSingle(
            IUniswapV3RouterLike.ExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: msg.sender,
                deadline: deadline,
                amountOut: amountOut,
                amountInMaximum: amountInMax,
                sqrtPriceLimitX96: 0
            })
        );

        // Return any unspent approval to zero
        if (amountInSpent < amountInMax) {
            IERC20(tokenIn).approve(address(router), 0);
        }

        emit SwapExactOutputSingle(msg.sender, tokenIn, tokenOut, fee, amountOut, amountInSpent);
    }

    /**
     * @notice Exact-output multihop swap using reversed path (per Uniswap V3 convention).
     * @param path Reversed path (tokenOut,fee,tokenMid,fee,tokenIn)
     * @param amountOut Desired exact output
     * @param amountInMax Max input willing to spend
     * @param deadline Expiry
     * @param tokenIn Token to draw from vault & approve
     */
    function swapExactOutputPath(
        bytes calldata path,
        uint256 amountOut,
        uint256 amountInMax,
        uint256 deadline,
        address tokenIn
    ) external returns (uint256 amountInSpent) {
        _safeApprove(IERC20(tokenIn), address(router), amountInMax);

        amountInSpent = router.exactOutput(
            IUniswapV3RouterLike.ExactOutputParams({
                path: path,
                recipient: msg.sender,
                deadline: deadline,
                amountOut: amountOut,
                amountInMaximum: amountInMax
            })
        );

        if (amountInSpent < amountInMax) {
            IERC20(tokenIn).approve(address(router), 0);
        }

        emit SwapExactOutputPath(msg.sender, path, amountOut, amountInSpent);
    }

    // ========= ETH helpers (wrap/unwrap) =========

    /// @notice Wrap native ETH held by the vault into WETH.
    function wrapETH(uint256 amount) external payable {
        // Since this runs in vault context, the ETH must already be held by the vault,
        // or forwarded as `value` when calling UserVault.executeCall.
        require(msg.value == amount, "BadValue");
        weth.deposit{value: amount}();
        // WETH is now held by the vault
        emit Wrapped(msg.sender, amount);
    }

    /// @notice Unwrap WETH held by the vault back to native ETH.
    function unwrapWETH(uint256 amount) external {
        weth.withdraw(amount);
        // ETH is now in the module's balance *from vault context*; forward back to vault
        // Because msg.sender is the vault, simply sending to msg.sender returns it.
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "SendFail");
        emit Unwrapped(msg.sender, amount);
    }

    receive() external payable {}
}
