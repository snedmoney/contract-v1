// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IWormhole {
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
}

contract SnedPayment is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    ISwapRouter public swapRouter;
    IWormhole public wormholeBridge;

    uint32 private nonce;
    uint16 public currentWormChainId;

    event BridgePaymentInitiated(
        string indexed paymentId,
        address indexed src,
        address indexed dest,
        uint16 destWormChainId,
        address tokenOut,
        uint256 amountOut,
        uint64 sequence
    );

    event PaymentSuccessful(
        string indexed paymentId,
        address indexed dest,
        address token,
        uint256 amount
    );

    event SwapExecuted(
        string indexed paymentId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    struct SwapParams {
        address[] route;
        uint24[] fees;
        uint256 amountInMaximum;
        uint256 deadline;
    }

    struct PaymentParams {
        string paymentId;
        address destAddress;
        address tokenIn;
        address tokenOut;
        uint256 amountOut;
    }

    struct BridgeParams {
        uint16 destWormChainId;
        bytes32 bridgeRecipient;
    }

    constructor(
        address _owner,
        address _swapRouter,
        address _wormholeBridge,
        uint16 _currentWormChainId
    ) Ownable(_owner) {
        require(_swapRouter != address(0), "Invalid swap router address");
        require(
            _wormholeBridge != address(0),
            "Invalid wormhole bridge address"
        );
        swapRouter = ISwapRouter(_swapRouter);
        wormholeBridge = IWormhole(_wormholeBridge);
        currentWormChainId = _currentWormChainId;
    }

    function makePayment(
        SwapParams calldata swapParams,
        PaymentParams calldata paymentParams,
        BridgeParams calldata bridgeParams
    ) external nonReentrant whenNotPaused {
        require(
            paymentParams.destAddress != address(0),
            "Invalid dest address"
        );

        if (paymentParams.tokenIn == paymentParams.tokenOut) {
            // Same token and same chain - Direct transfer
            if (bridgeParams.destWormChainId == currentWormChainId) {
                _transferToDest(
                    paymentParams.tokenOut,
                    paymentParams.destAddress,
                    paymentParams.amountOut,
                    paymentParams.paymentId
                );
            }
        } else {
            // Different src and dest token - Swap
            _executeSwap(swapParams, paymentParams);
        }

        if (bridgeParams.destWormChainId == currentWormChainId) {
            _transferToDest(
                paymentParams.tokenOut,
                paymentParams.destAddress,
                paymentParams.amountOut,
                paymentParams.paymentId
            );
        } else {
            bytes memory payload = abi.encode(
                paymentParams.paymentId,
                paymentParams.destAddress
            );
            _executeBridgeTransfer(
                paymentParams.tokenOut,
                paymentParams.amountOut,
                bridgeParams.destWormChainId,
                bridgeParams.bridgeRecipient,
                payload,
                paymentParams
            );
        }
    }

    function completePayment(
        bytes memory encodedVm
    ) external nonReentrant whenNotPaused onlyOwner {
        bytes memory transferData = wormholeBridge.completeTransferWithPayload(
            encodedVm
        );

        (
            address token,
            uint256 amount,
            bytes memory transferPayload
        ) = parseTransferData(transferData);
        (string memory paymentId, address destAddress) = abi.decode(
            transferPayload,
            (string, address)
        );

        _transferToDest(token, destAddress, amount, paymentId);
    }

    function _transferToDest(
        address token,
        address destAddress,
        uint256 amount,
        string memory paymentId
    ) internal {
        IERC20(token).safeTransfer(destAddress, amount);
        emit PaymentSuccessful(paymentId, destAddress, token, amount);
    }

    function _executeSwap(
        SwapParams calldata swapParams,
        PaymentParams calldata paymentParams
    ) private {
        require(paymentParams.amountOut > 0, "Invalid amount out");
        require(swapParams.amountInMaximum > 0, "Invalid amount in maximum");
        require(
            swapParams.deadline > block.timestamp,
            "Deadline must be in the future"
        );

        address tokenIn = swapParams.route[swapParams.route.length - 1];
        address tokenOut = swapParams.route[0];

        require(tokenIn != paymentParams.tokenIn, "Invalid tokenIn address");
        require(tokenOut != paymentParams.tokenOut, "Invalid tokenIn address");

        bytes memory path = _encodePath(swapParams.route, swapParams.fees);

        IERC20(tokenIn).safeTransferFrom(
            msg.sender,
            address(this),
            swapParams.amountInMaximum
        );
        IERC20(tokenIn).safeIncreaseAllowance(
            address(swapRouter),
            swapParams.amountInMaximum
        );

        ISwapRouter.ExactOutputParams memory params = ISwapRouter
            .ExactOutputParams({
                path: path,
                recipient: address(this),
                deadline: swapParams.deadline,
                amountOut: paymentParams.amountOut,
                amountInMaximum: swapParams.amountInMaximum
            });

        uint256 amountIn = swapRouter.exactOutput{value: msg.value}(params);
        uint256 consumedAmountIn = swapParams.amountInMaximum;

        if (amountIn < swapParams.amountInMaximum) {
            consumedAmountIn = swapParams.amountInMaximum - amountIn;
            IERC20(tokenIn).safeTransfer(
                msg.sender,
                swapParams.amountInMaximum - amountIn
            );
        }

        emit SwapExecuted(
            paymentParams.paymentId,
            tokenIn,
            tokenOut,
            consumedAmountIn,
            paymentParams.amountOut
        );
    }

    function _executeBridgeTransfer(
        address tokenOut,
        uint256 amountOut,
        uint16 destWormChainId,
        bytes32 bridgeRecipient,
        bytes memory payload,
        PaymentParams memory paymentParams
    ) private {
        require(bridgeRecipient != bytes32(0), "Invalid recipient");
        IERC20(tokenOut).safeIncreaseAllowance(
            address(wormholeBridge),
            amountOut
        );

        uint64 sequence = wormholeBridge.transferTokensWithPayload(
            tokenOut,
            amountOut,
            destWormChainId,
            bridgeRecipient,
            _getAndIncrementNonce(),
            payload
        );

        emit BridgePaymentInitiated(
            paymentParams.paymentId,
            msg.sender,
            paymentParams.destAddress,
            destWormChainId,
            tokenOut,
            amountOut,
            sequence
        );
    }

    function rescueTokens(address token, uint256 amount) external onlyOwner {
        require(amount > 0, "Invalid amount");
        IERC20(token).safeTransfer(owner(), amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _encodePath(
        address[] memory addresses,
        uint24[] memory fees
    ) private pure returns (bytes memory) {
        require(addresses.length == fees.length + 1, "Invalid path length");

        bytes memory path = new bytes(0);
        for (uint256 i = 0; i < fees.length; i++) {
            path = abi.encodePacked(path, addresses[i], fees[i]);
        }
        return abi.encodePacked(path, addresses[addresses.length - 1]);
    }

    function parseTransferData(
        bytes memory transferData
    )
        private
        pure
        returns (address token, uint256 amount, bytes memory transferPayload)
    {
        (token, amount, , transferPayload) = abi.decode(
            transferData,
            (address, uint256, bytes32, bytes)
        );
    }

    function _getAndIncrementNonce() private returns (uint32) {
        return nonce++;
    }
}
