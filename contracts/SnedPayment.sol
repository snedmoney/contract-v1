// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "./interfaces/IWormhole.sol";
import "./libraries/SwapExecutor.sol";
import "./libraries/PaymentEvents.sol";
import "./libraries/PaymentStructs.sol";

contract SnedPayment is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    mapping(address => bool) public allowlistedRouters;
    IWormhole private wormholeBridge;
    IPyth pythContract;
    bytes32 priceId;

    uint32 private nonce;
    uint16 public currentWormChainId;
    uint256 public commissionRate = 100; // Initial commission rate of 1% (100 basis points)
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_COMMISSION_RATE = 200; // Maximum 2% commission (200 basis points)

    constructor(
        address _owner,
        address[] memory _initialRouters,
        address _wormholeBridge,
        uint16 _currentWormChainId,
        address _pythContract,
        bytes32 _priceId
    ) Ownable(_owner) {
        require(
            _wormholeBridge != address(0),
            "Invalid wormhole bridge address"
        );

        wormholeBridge = IWormhole(_wormholeBridge);
        currentWormChainId = _currentWormChainId;
        pythContract = IPyth(_pythContract);
        priceId = _priceId;

        for (uint i = 0; i < _initialRouters.length; i++) {
            require(_initialRouters[i] != address(0), "Invalid router address");
            allowlistedRouters[_initialRouters[i]] = true;
        }
    }

    function addRouterToAllowlist(
        address router,
        bool allowed
    ) external onlyOwner {
        require(router != address(0), "Invalid router address");
        allowlistedRouters[router] = allowed;
    }

    function removeRouterFromAllowlist(address router) external onlyOwner {
        require(router != address(0), "Invalid router address");
        require(allowlistedRouters[router], "Router not in allowlist");
        delete allowlistedRouters[router];
    }

    function makePayment(
        PaymentStructs.SwapParams[] calldata swapParamsArray,
        PaymentStructs.PaymentParams calldata paymentParams,
        PaymentStructs.BridgeParams calldata bridgeParams
    ) external nonReentrant whenNotPaused {
        require(
            paymentParams.destAddress != address(0),
            "Invalid dest address"
        );

        uint256 amountAfterCommission;
        uint256 amountOut;

        IERC20(paymentParams.tokenIn).safeTransferFrom(
            msg.sender,
            address(this),
            paymentParams.amountIn
        );

        if (paymentParams.tokenIn == paymentParams.tokenOut) {
            // Same token and same chain - Direct transfer
            amountOut = paymentParams.amountIn;
        } else {
            (address tokenIn, address tokenOut) = _getTokenInOut(
                swapParamsArray
            );
            require(
                tokenIn == paymentParams.tokenIn,
                "Invalid tokenIn address"
            );
            require(
                tokenOut == paymentParams.tokenOut,
                "Invalid tokenOut address"
            );

            amountOut = _executeSwaps(swapParamsArray, paymentParams.amountIn);

            emit PaymentEvents.SwapExecuted(
                paymentParams.paymentId,
                tokenIn,
                tokenOut,
                paymentParams.amountIn,
                amountOut
            );
        }

        amountAfterCommission = _getAmountAfterCommision(amountOut);

        if (bridgeParams.destWormChainId == currentWormChainId) {
            _transferToDest(
                paymentParams.tokenOut,
                paymentParams.destAddress,
                amountAfterCommission,
                paymentParams.paymentId
            );
        } else {
            _bridgeTransfer(paymentParams, bridgeParams, amountAfterCommission);
        }
    }

    function completePayment(
        bytes memory encodedVm,
        PaymentStructs.SwapParams[] calldata swapParamsArray
    ) external nonReentrant whenNotPaused onlyOwner {
        uint256 startGas = gasleft();
        (
            uint256 amountIn,
            bytes32 paymentId,
            address destAddress,
            address tokenAddress
        ) = _completeTransfer(encodedVm);

        uint256 amountOut;
        address tokenOut;

        if (swapParamsArray.length == 0) {
            amountOut = amountIn;
            tokenOut = tokenAddress;
        } else {
            amountOut = _executeSwaps(swapParamsArray, amountIn);
            tokenOut = _getLastTokenInRoute(swapParamsArray);
        }
        uint256 gasUsed = startGas - gasleft();
        uint256 gasPrice = tx.gasprice;

        uint256 gasFee = _calculateGasFee(gasUsed, gasPrice);

        require(amountOut > gasFee, "Amount must be greater than fee");
        uint256 amountOutAfterFee = amountOut - gasFee;

        _transferToDest(tokenOut, destAddress, amountOutAfterFee, paymentId);
    }

    function _executeSwaps(
        PaymentStructs.SwapParams[] calldata swapParamsArray,
        uint256 amountIn
    ) internal returns (uint256) {
        uint256 amountOut = amountIn;
        for (uint i = 0; i < swapParamsArray.length; i++) {
            PaymentStructs.SwapParams memory params = swapParamsArray[i];
            require(
                allowlistedRouters[params.router],
                "Router not allowlisted"
            );

            amountOut = SwapExecutor.executeSwap(params, amountOut);
        }
        return amountOut;
    }

    function _bridgeTransfer(
        PaymentStructs.PaymentParams memory paymentParams,
        PaymentStructs.BridgeParams memory bridgeParams,
        uint256 amountOut
    ) private {
        require(
            bridgeParams.bridgeRecipient != bytes32(0),
            "Invalid recipient"
        );
        IERC20(paymentParams.tokenOut).safeIncreaseAllowance(
            address(wormholeBridge),
            amountOut
        );

        bytes32 destAddress = bytes32(
            uint256(uint160(paymentParams.destAddress))
        );
        bytes memory payload = abi.encode(paymentParams.paymentId, destAddress);

        uint64 sequence = wormholeBridge.transferTokensWithPayload(
            paymentParams.tokenOut,
            amountOut,
            bridgeParams.destWormChainId,
            bridgeParams.bridgeRecipient,
            _getAndIncrementNonce(),
            payload
        );

        emit PaymentEvents.BridgePaymentInitiated(
            paymentParams.paymentId,
            msg.sender,
            paymentParams.destAddress,
            bridgeParams.destWormChainId,
            paymentParams.tokenOut,
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
    ) internal view returns (uint256) {
        uint256 commission = (amount * commissionRate) / BASIS_POINTS;
        return amount - commission;
    }

    function _getTokenInOut(
        PaymentStructs.SwapParams[] calldata swapParamsArray
    ) private pure returns (address tokenIn, address tokenOut) {
        tokenIn = swapParamsArray[0].route[0];
        tokenOut = swapParamsArray[swapParamsArray.length - 1].route[
            swapParamsArray[swapParamsArray.length - 1].route.length - 1
        ];
    }

    function _getLastTokenInRoute(
        PaymentStructs.SwapParams[] calldata swapParamsArray
    ) private pure returns (address) {
        PaymentStructs.SwapParams memory lastSwap = swapParamsArray[
            swapParamsArray.length - 1
        ];
        return lastSwap.route[lastSwap.route.length - 1];
    }

    function _completeTransfer(
        bytes memory encodedVm
    )
        private
        returns (
            uint256 amountIn,
            bytes32 paymentId,
            address destAddress,
            address tokenAddress
        )
    {
        bytes memory payload = wormholeBridge.completeTransferWithPayload(
            encodedVm
        );

        IWormhole.TransferWithPayload memory tc = wormholeBridge
            .parseTransferWithPayload(payload);

        require(tc.toChain == currentWormChainId, "Invalid destination chain");

        amountIn = tc.amount;
        tokenAddress = address(uint160(uint256(tc.tokenAddress)));
        (bytes32 _paymentId, bytes32 destination) = abi.decode(
            tc.payload,
            (bytes32, bytes32)
        );
        paymentId = _paymentId;
        destAddress = address(uint160(uint256(destination)));
    }

    function rescueTokens(address token, uint256 amount) external onlyOwner {
        require(amount > 0, "Invalid amount");
        IERC20(token).safeTransfer(owner(), amount);
    }

    function updateOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner cannot be the zero address");
        transferOwnership(newOwner);
    }

    function setCommissionRate(uint256 newRate) external onlyOwner {
        require(
            newRate <= MAX_COMMISSION_RATE,
            "Commission rate exceeds maximum commision rate of 2%"
        );
        commissionRate = newRate;
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

    function _calculateGasFee(
        uint256 gasUsed,
        uint256 gasPrice
    ) private view returns (uint256 cost) {
        uint256 gasCostInWei;
        unchecked {
            gasCostInWei = gasUsed * gasPrice;
        }
        require(
            gasPrice == 0 || gasCostInWei / gasPrice == gasUsed,
            "Gas cost calculation overflow"
        );

        PythStructs.Price memory pythPrice = pythContract.getPriceUnsafe(
            priceId
        );

        int64 price = pythPrice.price;
        int32 expo = pythPrice.expo;

        require(price > 0, "Invalid ETH price");
        require(expo <= 0, "Invalid price exponent");

        uint256 gasUsdPrice = uint256(uint64(price));

        uint256 scalingFactor = 10 ** uint32(-expo);
        gasUsdPrice = (gasUsdPrice * 1e8) / scalingFactor;

        uint256 intermediateResult;
        unchecked {
            intermediateResult = gasCostInWei * gasUsdPrice;
        }
        require(
            gasUsdPrice == 0 ||
                intermediateResult / gasUsdPrice == gasCostInWei,
            "USD conversion overflow"
        );

        uint256 gasCost = intermediateResult / 1e8;

        cost = gasCost / 1e12;

        uint256 buffer = (cost * 10) / 100;

        cost += buffer;

        require(cost > 0, "Cost calculation error");

        return cost;
    }
}
