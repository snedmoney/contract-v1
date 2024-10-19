// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@pancakeswap/v3-periphery/contracts/interfaces/ISwapRouter.sol" as PancakeSwapRouter;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./PaymentStructs.sol";

library SwapExecutor {
    using SafeERC20 for IERC20;

    function executeUniswap(
        ISwapRouter uniswapRouter,
        PaymentStructs.UniswapParams memory params
    ) internal returns (uint256) {
        require(params.amountIn > 0, "Invalid amount in");
        require(params.amountOutMinimum > 0, "Invalid amount out minimum");
        require(
            params.deadline > block.timestamp,
            "Deadline must be in the future"
        );

        address tokenIn = params.route[0];

        bytes memory path = _encodePath(params.route, params.fees);

        IERC20(tokenIn).safeTransferFrom(
            msg.sender,
            address(this),
            params.amountIn
        );
        IERC20(tokenIn).safeIncreaseAllowance(
            address(uniswapRouter),
            params.amountIn
        );

        ISwapRouter.ExactInputParams memory uniswapParams = ISwapRouter
            .ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: params.deadline,
                amountIn: params.amountIn,
                amountOutMinimum: params.amountOutMinimum
            });

        return uniswapRouter.exactInput(uniswapParams);
    }

    function executePancakeswap(
        PancakeSwapRouter.ISwapRouter pancakeswapRouter,
        PaymentStructs.PancakeswapParams memory params,
        uint256 amountIn
    ) internal returns (uint256) {
        require(amountIn > 0, "Invalid amount in");
        require(params.amountOutMinimum > 0, "Invalid amount out minimum");
        require(
            params.deadline > block.timestamp,
            "Deadline must be in the future"
        );

        address tokenIn = params.route[0];

        IERC20(tokenIn).safeIncreaseAllowance(
            address(pancakeswapRouter),
            amountIn
        );

        bytes memory path = _encodePath(params.route, params.fees);

        PancakeSwapRouter.ISwapRouter.ExactInputParams
            memory pancakeParams = PancakeSwapRouter
                .ISwapRouter
                .ExactInputParams({
                    path: path,
                    recipient: address(this),
                    deadline: params.deadline,
                    amountIn: amountIn,
                    amountOutMinimum: params.amountOutMinimum
                });

        return pancakeswapRouter.exactInput(pancakeParams);
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
