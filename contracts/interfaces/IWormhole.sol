// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IWormhole {
    struct TransferWithPayload {
        uint8 payloadID;
        uint256 amount;
        bytes32 tokenAddress;
        uint16 tokenChain;
        bytes32 to;
        uint16 toChain;
        bytes32 fromAddress;
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

    function _parseTransferCommon(
        bytes memory encoded
    ) external pure returns (TransferWithPayload memory transfer);
}
