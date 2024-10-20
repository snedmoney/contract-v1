// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./PaymentStructs.sol";

interface IPancakeSwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(
        ExactInputParams calldata params
    ) external payable returns (uint256 amountOut);
}

library SwapExecutor {
    using SafeERC20 for IERC20;

    uint8 constant SWAP_TYPE_UNISWAP = 0;
    uint8 constant SWAP_TYPE_PANCAKESWAP = 1;

    function executeSwap(
        PaymentStructs.SwapParams memory params,
        uint256 amountIn
    ) internal returns (uint256) {
        require(amountIn > 0, "Invalid amount in");
        require(params.amountOutMinimum > 0, "Invalid amount out minimum");
        require(
            params.deadline > block.timestamp,
            "Deadline must be in the future"
        );

        if (params.swapType == SWAP_TYPE_UNISWAP) {
            return _executeUniswap(params, amountIn);
        } else if (params.swapType == SWAP_TYPE_PANCAKESWAP) {
            return _executePancakeswap(params, amountIn);
        } else {
            revert("Invalid swap type");
        }
    }

    function _executeUniswap(
        PaymentStructs.SwapParams memory params,
        uint256 amountIn
    ) private returns (uint256) {
        address tokenIn = params.route[0];
        ISwapRouter router = ISwapRouter(params.router);

        IERC20(tokenIn).safeIncreaseAllowance(address(router), amountIn);

        bytes memory path = _encodePath(params.route, params.fees);

        ISwapRouter.ExactInputParams memory swapParams = ISwapRouter
            .ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: params.deadline,
                amountIn: amountIn,
                amountOutMinimum: params.amountOutMinimum
            });

        return router.exactInput(swapParams);
    }

    function _executePancakeswap(
        PaymentStructs.SwapParams memory params,
        uint256 amountIn
    ) private returns (uint256) {
        address tokenIn = params.route[0];
        IPancakeSwapRouter router = IPancakeSwapRouter(params.router);

        IERC20(tokenIn).safeIncreaseAllowance(address(router), amountIn);

        bytes memory path = _encodePath(params.route, params.fees);

        IPancakeSwapRouter.ExactInputParams
            memory swapParams = IPancakeSwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: params.amountOutMinimum
            });

        return router.exactInput(swapParams);
    }

    function _encodePath(
        address[] memory addresses,
        uint24[] memory fees
    ) private pure returns (bytes memory) {
        require(addresses.length > 1, "Invalid path length");
        require(
            addresses.length == fees.length + 1,
            "Invalid path and fees length"
        );

        bytes memory path = new bytes(0);
        for (uint256 i = 0; i < fees.length; i++) {
            path = abi.encodePacked(path, addresses[i], fees[i]);
        }
        return abi.encodePacked(path, addresses[addresses.length - 1]);
    }
}
