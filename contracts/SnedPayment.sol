// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IWormhole.sol";
import "./libraries/SwapExecutor.sol";
import "./libraries/PaymentEvents.sol";
import "./libraries/PaymentStructs.sol";

contract SnedPayment is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    ISwapRouter private uniswapRouter;
    PancakeSwapRouter.ISwapRouter private pancakeswapRouter;
    IWormhole private wormholeBridge;

    uint32 private nonce;
    uint16 public currentWormChainId;
    uint256 public constant COMMISSION_RATE = 100; // 1% commission (100 basis points)
    uint256 public constant BASIS_POINTS = 10000;

    constructor(
        address _owner,
        address _uniswapRouter,
        address _pancakeswapRouter,
        address _wormholeBridge,
        uint16 _currentWormChainId
    ) Ownable(_owner) {
        require(_uniswapRouter != address(0), "Invalid Uniswap router address");
        require(
            _pancakeswapRouter != address(0),
            "Invalid Pancakeswap router address"
        );
        require(
            _wormholeBridge != address(0),
            "Invalid wormhole bridge address"
        );
        uniswapRouter = ISwapRouter(_uniswapRouter);
        pancakeswapRouter = PancakeSwapRouter.ISwapRouter(_pancakeswapRouter);
        wormholeBridge = IWormhole(_wormholeBridge);
        currentWormChainId = _currentWormChainId;
    }

    function makePayment(
        PaymentStructs.UniswapParams calldata uniswapParams,
        PaymentStructs.PancakeswapParams calldata pancakeswapParams,
        PaymentStructs.PaymentParams calldata paymentParams,
        PaymentStructs.BridgeParams calldata bridgeParams
    ) external nonReentrant whenNotPaused {
        require(
            paymentParams.destAddress != address(0),
            "Invalid dest address"
        );

        uint256 amountAfterCommission;

        if (paymentParams.tokenIn == paymentParams.tokenOut) {
            // Same token and same chain - Direct transfer
            amountAfterCommission = _getAmountAfterCommision(
                uniswapParams.amountIn
            );
            if (bridgeParams.destWormChainId == currentWormChainId) {
                _transferToDest(
                    paymentParams.tokenOut,
                    paymentParams.destAddress,
                    amountAfterCommission,
                    paymentParams.paymentId
                );
            }
        } else {
            // Different src and dest token - Swap
            uint256 amountOut;
            address tokenIn;
            address tokenOut;

            if (bridgeParams.destWormChainId == currentWormChainId) {
                // Use Uniswap for same-chain swaps
                tokenIn = uniswapParams.route[0];
                tokenOut = uniswapParams.route[uniswapParams.route.length - 1];

                require(
                    tokenIn == paymentParams.tokenIn,
                    "Invalid tokenIn address"
                );
                require(
                    tokenOut == paymentParams.tokenOut,
                    "Invalid tokenOut address"
                );

                amountOut = SwapExecutor.executeUniswap(
                    uniswapRouter,
                    uniswapParams
                );
            } else {
                tokenIn = uniswapParams.route[0];
                tokenOut = pancakeswapParams.route[
                    pancakeswapParams.route.length - 1
                ];

                require(
                    tokenIn == paymentParams.tokenIn,
                    "Invalid tokenIn address"
                );
                require(
                    tokenOut == paymentParams.tokenOut,
                    "Invalid tokenOut address"
                );

                // Cross-chain swap: Uniswap first, then Pancakeswap
                uint256 uniswapAmountOut = SwapExecutor.executeUniswap(
                    uniswapRouter,
                    uniswapParams
                );
                amountOut = SwapExecutor.executePancakeswap(
                    pancakeswapRouter,
                    pancakeswapParams,
                    uniswapAmountOut
                );
            }

            emit PaymentEvents.SwapExecuted(
                paymentParams.paymentId,
                tokenIn,
                tokenOut,
                uniswapParams.amountIn,
                amountOut
            );

            amountAfterCommission = _getAmountAfterCommision(amountOut);
        }

        if (bridgeParams.destWormChainId == currentWormChainId) {
            _transferToDest(
                paymentParams.tokenOut,
                paymentParams.destAddress,
                amountAfterCommission,
                paymentParams.paymentId
            );
        } else {
            bytes32 destAddress = bytes32(
                uint256(uint160(paymentParams.destAddress))
            );
            bytes memory payload = abi.encode(
                paymentParams.paymentId,
                destAddress
            );
            _executeBridgeTransfer(
                paymentParams.tokenOut,
                amountAfterCommission,
                bridgeParams.destWormChainId,
                bridgeParams.bridgeRecipient,
                payload,
                paymentParams
            );
        }
    }

    function completePayment(
        bytes memory encodedVm,
        PaymentStructs.PancakeswapParams calldata params,
        uint256 fee
    ) external nonReentrant whenNotPaused onlyOwner {
        IWormhole.TransferWithPayload memory tc = wormholeBridge
            ._parseTransferCommon(encodedVm);

        uint256 amountIn = tc.amount;

        (bytes32 paymentId, bytes32 destination) = abi.decode(
            tc.payload,
            (bytes32, bytes32)
        );

        address destAddress = address(uint160(uint256(destination)));

        require(tc.toChain == currentWormChainId, "Invalid destination chain");
        require(amountIn > fee, "Amount must be greater than fee");

        address tokenOut = params.route[params.route.length - 1];

        uint256 amountInAfterFee = amountIn - fee;

        uint256 amountOut = SwapExecutor.executePancakeswap(
            pancakeswapRouter,
            params,
            amountInAfterFee
        );

        _transferToDest(tokenOut, destAddress, amountOut, paymentId);
    }

    function _executeBridgeTransfer(
        address tokenOut,
        uint256 amountOut,
        uint16 destWormChainId,
        bytes32 bridgeRecipient,
        bytes memory payload,
        PaymentStructs.PaymentParams memory paymentParams
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

        emit PaymentEvents.BridgePaymentInitiated(
            paymentParams.paymentId,
            msg.sender,
            paymentParams.destAddress,
            destWormChainId,
            tokenOut,
            amountOut,
            sequence
        );
    }

    function _transferToDest(
        address token,
        address destAddress,
        uint256 amount,
        bytes32 paymentId
    ) internal {
        IERC20(token).safeTransfer(destAddress, amount);
        emit PaymentEvents.PaymentSuccessful(
            paymentId,
            destAddress,
            token,
            amount
        );
    }

    function _getAmountAfterCommision(
        uint256 amount
    ) internal pure returns (uint256) {
        uint256 commission = (amount * COMMISSION_RATE) / BASIS_POINTS;
        return amount - commission;
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

    function _getAndIncrementNonce() private returns (uint32) {
        return nonce++;
    }
}
