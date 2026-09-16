// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal Uniswap V3 SwapRouter surface used by Pool for the ETH -> $BOT buyback.
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}