// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IWormhole {
    function transferTokens(
        address token,
        uint256 amount,
        uint16 recipientChain,
        bytes32 recipient,
        uint256 arbiterFee,
        uint32 nonce
    ) external returns (uint64);
}

contract SnedPayment is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    ISwapRouter public swapRouter;
    IWormhole public wormholeBridge;

    uint32 private nonce;

    event PaymentMade(
        address indexed sender,
        bytes32 indexed recipient,
        uint16 recipientChain,
        uint256 amount,
        uint64 sequence
    );
    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event BridgeAddressUpdated(address newAddress);
    event RouterAddressUpdated(address newAddress);

    constructor(
        address _owner,
        address _swapRouter,
        address _wormholeBridge
    ) Ownable(_owner) {
        require(_swapRouter != address(0), "Invalid swap router address");
        require(
            _wormholeBridge != address(0),
            "Invalid wormhole bridge address"
        );
        swapRouter = ISwapRouter(_swapRouter);
        wormholeBridge = IWormhole(_wormholeBridge);
    }

    function makePayment(
        address[] calldata route,
        uint24[] calldata fees,
        uint256 amountOut,
        uint256 amountInMaximum,
        bytes32 recipient,
        uint16 recipientChain,
        uint256 arbiterFee,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        require(recipient != bytes32(0), "Invalid recipient");
        require(amountOut > 0, "Invalid amount out");
        require(amountInMaximum > 0, "Invalid amount in maximum");
        require(deadline > block.timestamp, "Deadline must be in the future");

        address tokenIn = route[0];
        address tokenOut = route[route.length - 1];
        bytes memory path = _encodePath(route, fees);

        uint256 initialBalance = IERC20(tokenIn).balanceOf(msg.sender);
        require(initialBalance >= amountInMaximum, "Insufficient balance");

        IERC20(tokenIn).safeTransferFrom(
            msg.sender,
            address(this),
            amountInMaximum
        );
        IERC20(tokenIn).safeIncreaseAllowance(
            address(swapRouter),
            amountInMaximum
        );

        ISwapRouter.ExactOutputParams memory params = ISwapRouter
            .ExactOutputParams({
                path: path,
                recipient: address(this),
                deadline: deadline,
                amountOut: amountOut,
                amountInMaximum: amountInMaximum
            });

        uint256 amountIn = swapRouter.exactOutput(params);

        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut);

        if (amountIn < amountInMaximum) {
            IERC20(tokenIn).safeTransfer(
                msg.sender,
                amountInMaximum - amountIn
            );
        }

        IERC20(tokenOut).safeIncreaseAllowance(
            address(wormholeBridge),
            amountOut
        );

        uint64 sequence = wormholeBridge.transferTokens(
            tokenOut,
            amountOut,
            recipientChain,
            recipient,
            arbiterFee,
            _getAndIncrementNonce()
        );

        emit PaymentMade(
            msg.sender,
            recipient,
            recipientChain,
            amountOut,
            sequence
        );
    }

    function rescueTokens(address token, uint256 amount) external onlyOwner {
        require(amount > 0, "Invalid amount");
        IERC20(token).safeTransfer(owner(), amount);
    }

    function updateBridgeAddress(address newBridge) external onlyOwner {
        require(newBridge != address(0), "Invalid bridge address");
        wormholeBridge = IWormhole(newBridge);
        emit BridgeAddressUpdated(newBridge);
    }

    function updateRouterAddress(address newRouter) external onlyOwner {
        require(newRouter != address(0), "Invalid router address");
        swapRouter = ISwapRouter(newRouter);
        emit RouterAddressUpdated(newRouter);
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

        bytes memory path;

        for (uint256 i = 0; i < fees.length; i++) {
            path = abi.encodePacked(path, addresses[i], fees[i]);
        }

        path = abi.encodePacked(path, addresses[addresses.length - 1]);

        return path;
    }

    function _getAndIncrementNonce() private returns (uint32) {
        return nonce++;
    }
}
