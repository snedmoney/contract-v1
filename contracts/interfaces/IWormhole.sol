// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IWormhole {
    struct TransferWithPayload {
        // PayloadID uint8 = 3
        uint8 payloadID;
        // Amount being transferred (big-endian uint256)
        uint256 amount;
        // Address of the token. Left-zero-padded if shorter than 32 bytes
        bytes32 tokenAddress;
        // Chain ID of the token
        uint16 tokenChain;
        // Address of the recipient. Left-zero-padded if shorter than 32 bytes
        bytes32 to;
        // Chain ID of the recipient
        uint16 toChain;
        // Address of the message sender. Left-zero-padded if shorter than 32 bytes
        bytes32 fromAddress;
        // An arbitrary payload
        bytes payload;
    }

    function transferTokensWithPayload(
        address token,
        uint256 amount,
        uint16 destWormChainId,
        bytes32 bridgeRecipient,
        uint32 nonce,
        bytes memory payload
    ) external returns (uint64);

    function completeTransferWithPayload(
        bytes memory encodedVm
    ) external returns (bytes memory);

    function parseTransferWithPayload(
        bytes memory encoded
    ) external pure returns (TransferWithPayload memory transfer);
}
