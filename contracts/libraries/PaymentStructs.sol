// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

library PaymentStructs {
    struct UniswapParams {
        address[] route;
        uint24[] fees;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint256 deadline;
    }

    struct PancakeswapParams {
        address[] route;
        uint24[] fees;
        uint256 amountOutMinimum;
        uint256 deadline;
    }

    struct PaymentParams {
        bytes32 paymentId;
        address destAddress;
        address tokenIn;
        address tokenOut;
    }

    struct BridgeParams {
        uint16 destWormChainId;
        bytes32 bridgeRecipient;
    }
}
