// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UpGaugeVenue, IUpClPool, IUpGauge, IUpPositionManager} from "./UpGaugeVenue.sol";

/**
 * @title UpGaugeAdapter
 * @notice An UP concentrated WETH/USDG pool and its gauge as a SpinPosition
 * venue (UpGaugeVenue). The pool's price is checked against Chainlink before
 * liquidity is added or removed; WETH is bought and sold in `swapPool`, at an
 * average price checked against Chainlink.
 */
contract UpGaugeAdapter is UpGaugeVenue {
    constructor(Config memory c) UpGaugeVenue(c) {
        if (other != c.weth) revert WrongPool();
    }

    function _checkSpot(uint256 oracle) internal view override {
        _within(_poolPrice(), oracle);
    }

    function _spotOk(uint256 oracle, bool fresh) internal view override returns (bool) {
        return fresh && _isWithin(_poolPrice(), oracle);
    }

    function _buyOther(uint256 usdgIn, uint256 oracle) internal override {
        _swapWethUsdg(swapPool, swapWethIsToken0, false, usdgIn, oracle);
    }

    function _sellOther(uint256 amount, uint256 oracle) internal override {
        _swapWethUsdg(swapPool, swapWethIsToken0, true, amount, oracle);
    }

    function _otherPrice(uint256 oracle) internal pure override returns (uint256, uint256) {
        return (oracle, 1e30);
    }

    function _poolPrice() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,) = pool.slot0();
        return _spotPrice(sqrtPriceX96, otherIsToken0);
    }
}
