// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

import {IEngine} from "@standardweb3/contracts/exchange/interfaces/IEngine.sol";

import {IERC20} from "@openzeppelin/contracts/token/erc20/IERC20.sol";

contract PointsHook is BaseHook, ERC20 {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    mapping(address => address) public referredBy;

    address matchingEngine;
    address weth;

    uint256 public constant POINTS_FOR_REFERRAL = 500 * 10 ** 18;

    constructor(
        IPoolManager _manager,
        string memory _name,
        string memory _symbol,
        address matchingEngine_,
        address weth_
    ) BaseHook(_manager) ERC20(_name, _symbol, 18) {
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
                afterAddLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4, int128) {
        

        // Mint the points including any referral points
        //_assignPoints(hookData, pointsForSwap);
        //uint128 amount = _limitOrder(key, swapParams.zeroForOne, hookData);
        //_limitOrder(key, swapParams, hookData);
        //_swapAndSettleBalances(key, swapParams, delta);

        return (this.afterSwap.selector, 0);
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4, BalanceDelta) {
        // If this is not an ETH-TOKEN pool with this hook attached, ignore
        if (!key.currency0.isNative()) return (this.afterSwap.selector, delta);

        // Mint points equivalent to how much ETH they're adding in liquidity
        uint256 pointsForAddingLiquidity = uint256(int256(-delta.amount0()));

        return (this.afterAddLiquidity.selector, delta);
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
        _take(swapParams.zeroForOne ? key.currency1 : key.currency0, uint128(amount));

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

    function _swapAndSettleBalances(
        PoolKey calldata key,
        IPoolManager.SwapParams memory params,
        BalanceDelta delta
    ) internal returns (BalanceDelta) {

        // If we just did a zeroForOne swap
        // We need to send Token 0 to PM, and receive Token 1 from PM
        if (params.zeroForOne) {
            // Negative Value => Money leaving user's wallet
            // Settle with PoolManager
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }

            // Positive Value => Money coming into user's wallet
            // Take from PM
            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
            }
        } else {
            if (delta.amount1() < 0) {
                _settle(key.currency1, uint128(-delta.amount1()));
            }

            if (delta.amount0() > 0) {
                _take(key.currency0, uint128(delta.amount0()));
            }
        }

        return delta;
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
            IERC20(token1).approve(matchingEngine, amount);
            (uint makePrice, uint placed, uint id) = IEngine(matchingEngine)
                .limitBuy(
                    token0 == address(0) ? weth : token0,
                    token1 == address(0) ? weth : token1,
                    limitPrice,
                    amount,
                    isMaker,
                    n,
                    0,
                    recipient
                );
        } else {
            IERC20(token0).approve(matchingEngine, amount);
            IEngine(matchingEngine).limitSell(
                token0 == address(0) ? weth : token0,
                token1 == address(0) ? weth : token1,
                limitPrice,
                amount,
                isMaker,
                n,
                0,
                recipient
            );
        }

        return amount;
    }
}
