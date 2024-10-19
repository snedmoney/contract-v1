// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

library PaymentEvents {
    event BridgePaymentInitiated(
        bytes32 indexed paymentId,
        address indexed src,
        address indexed dest,
        uint16 destWormChainId,
        address tokenOut,
        uint256 amountOut,
        uint64 sequence
    );

    event PaymentSuccessful(
        bytes32 indexed paymentId,
        address indexed dest,
        address token,
        uint256 amount
    );

    event SwapExecuted(
        bytes32 indexed paymentId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
}
