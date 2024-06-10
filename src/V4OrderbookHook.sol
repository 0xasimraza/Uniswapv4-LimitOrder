// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDeltaLibrary, BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

import {IEngine} from "@standardweb3/contracts/exchange/interfaces/IEngine.sol";

import {IERC20} from "@openzeppelin/contracts/token/erc20/IERC20.sol";

contract V4OrderbookHook is BaseHook {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    mapping(address => address) public referredBy;

    address matchingEngine;
    address weth;

    uint256 public constant POINTS_FOR_REFERRAL = 500 * 10 ** 18;

    constructor(
        IPoolManager _manager,
        address matchingEngine_,
        address weth_
    ) BaseHook(_manager) {
        matchingEngine = matchingEngine_;
        weth = weth_;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Creates a BeforeSwapDelta from specified and unspecified
    function _toBeforeSwapDelta(
        int128 deltaSpecified,
        int128 deltaUnspecified
    ) internal pure returns (BeforeSwapDelta beforeSwapDelta) {
        /// @solidity memory-safe-assembly
        assembly {
            beforeSwapDelta := or(
                shl(128, deltaSpecified),
                and(sub(shl(128, 1), 1), deltaUnspecified)
            )
        }
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData
    )
        external
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // get original deltas
        BeforeSwapDelta before = BeforeSwapDelta.wrap(
            swapParams.amountSpecified
        );

        uint128 amount = _limitOrder(key, swapParams, hookData);

        // TODO: setup delta after taking input fund from pool manager and settle
        //int128 afterOrder = before.getSpecifiedDelta() - int128(amount);

        return (
            this.beforeSwap.selector,
            _toBeforeSwapDelta(int128(amount), 0),
            0
        );
    }

    function _limitOrder(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData
    ) internal returns (uint128 amountDelta) {
        if (hookData.length == 0) return 0;

        (
            uint256 limitPrice,
            uint256 amount,
            address recipient,
            bool isMaker,
            uint32 n
        ) = abi.decode(hookData, (uint256, uint256, address, bool, uint32));

        // TODO: check if amount is bigger than delta, if it is, return delta
        _take(
            swapParams.zeroForOne ? key.currency0 : key.currency1,
            uint128(amount)
        );

        _trade(
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            swapParams.zeroForOne,
            limitPrice,
            amount,
            isMaker,
            n,
            recipient
        );
        return uint128(amount);
    }

    function getHookData(
        uint256 limitPrice,
        uint256 amount,
        address recipient,
        bool isMaker,
        uint32 n
    ) public pure returns (bytes memory) {
        return abi.encode(limitPrice, amount, recipient, isMaker, n);
    }

    function _settle(Currency currency, uint128 amount) internal {
        // Transfer tokens to PM and let it know
        currency.transfer(address(poolManager), amount);
        poolManager.settle(currency);
    }

    function _take(Currency currency, uint128 amount) internal {
        // Take tokens out of PM to our hook contract
        poolManager.take(currency, address(this), amount);
    }

    function _trade(
        address token0,
        address token1,
        bool zeroForOne,
        uint256 limitPrice,
        uint256 amount,
        bool isMaker,
        uint32 n,
        address recipient
    ) internal returns (uint256 total) {
        if (zeroForOne) {
            if (token0 == address(0)) {
                IEngine(payable(matchingEngine)).limitSellETH{value: amount}(
                    token1,
                    limitPrice,
                    isMaker,
                    n,
                    0,
                    recipient
                );
                return amount;
            }
            IERC20(token0).approve(matchingEngine, amount);
            (uint makePrice, uint placed, uint id) = IEngine(matchingEngine)
                .limitSell(
                    token0 == address(0) ? weth : token0,
                    token1 == address(0) ? weth : token1,
                    limitPrice,
                    amount,
                    isMaker,
                    n,
                    0,
                    recipient
                );
            return amount;
        } else {
            if (token1 == address(0)) {
                IEngine(payable(matchingEngine)).limitBuyETH{value: amount}(
                    token0,
                    limitPrice,
                    isMaker,
                    n,
                    0,
                    recipient
                );
                return amount;
            }
            IERC20(token1).approve(matchingEngine, amount);
            IEngine(matchingEngine).limitBuy(
                token0 == address(0) ? weth : token0,
                token1 == address(0) ? weth : token1,
                limitPrice,
                amount,
                isMaker,
                n,
                0,
                recipient
            );
            return amount;
        }
    }

    receive() external payable {
        // You can add any custom logic here if needed
    }
}
