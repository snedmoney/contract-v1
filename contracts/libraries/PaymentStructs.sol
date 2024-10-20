// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

library PaymentStructs {
    struct SwapParams {
        address router;
        address[] route;
        uint24[] fees;
        uint256 amountOutMinimum;
        uint256 deadline;
        uint8 swapType;
    }

    struct PaymentParams {
        bytes32 paymentId;
        address destAddress;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
    }

    struct BridgeParams {
        uint16 destWormChainId;
        bytes32 bridgeRecipient;
    }
}
