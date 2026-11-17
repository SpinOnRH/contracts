// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {UpGaugeVenue} from "./UpGaugeVenue.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

/**
 * @title UpTokenGaugeVenue
 * @notice An UP gauge venue (UpGaugeVenue) whose pool pairs USDG with a token
 * that is not WETH, priced against a reference (`_reference`: the token's
 * price in USDG). The pool's price must be within `bandBps` of the reference
 * before liquidity is added or removed. Swaps between the token and USDG run
 * in the pool itself with the band's edge as the price limit, so no part of a
 * swap is made outside it: a purchase may buy less than asked (the rest stays
 * as USDG), and a sale that cannot be made in full fails, except in the
 * owner's full withdrawal, where the rest goes back to the position unsold.
 */
abstract contract UpTokenGaugeVenue is UpGaugeVenue {
    uint16 public immutable bandBps;
    uint8 internal immutable otherDecimals;
    uint8 internal immutable usdgDecimals;
    /// USDG per whole `other` with 18 decimals = raw price times this (other is token0) or this over raw price.
    uint256 internal immutable scale;

    constructor(Config memory c, uint16 bandBps_) UpGaugeVenue(c) {
        if (other == c.weth || bandBps_ == 0 || bandBps_ >= 10_000) revert WrongPool();
        bandBps = bandBps_;
        otherDecimals = IDecimals(other).decimals();
        usdgDecimals = IDecimals(c.usdg).decimals();
        scale = 10 ** (18 + uint256(otherDecimals) - uint256(usdgDecimals));
    }

    /// The token's price in USDG (18 decimals; the last one even when it cannot be relied on), and whether it can be relied on now.
    function _reference() internal view virtual returns (uint256 price, bool ok);

    /// Reverts for a pool price outside the band (`ok`: whether the reference itself could be read).
    function _revertOffBand(bool ok) internal view virtual;

    function _checkSpot(uint256) internal view override {
        (uint256 ref, bool ok) = _reference();
        if (!ok || !_inBand(poolPrice(), ref)) _revertOffBand(ok);
    }

    function _spotOk(uint256, bool) internal view override returns (bool) {
        (uint256 ref, bool ok) = _reference();
        return ok && _inBand(poolPrice(), ref);
    }

    /// USDG to `other` in the pool, no further than the top of the band.
    function _buyOther(uint256 usdgIn, uint256) internal override {
        (uint256 ref,) = _reference();
        pool.swap(address(this), !otherIsToken0, int256(usdgIn), _sqrtPriceAt(ref + (ref * bandBps) / 10_000), "");
    }

    /// `other` to USDG in the pool, no further than the bottom of the band.
    function _sellOther(uint256 amount, uint256) internal override {
        (uint256 ref,) = _reference();
        pool.swap(address(this), otherIsToken0, int256(amount), _sqrtPriceAt(ref - (ref * bandBps) / 10_000), "");
    }

    function _otherPrice(uint256) internal view override returns (uint256 price, uint256) {
        (price,) = _reference();
        return (price, scale);
    }

    function _isPool(address p) internal view override returns (bool) {
        return p == address(pool) || super._isPool(p);
    }

    /// USDG per whole `other`, 18 decimals, at the pool's price.
    function poolPrice() public view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,) = pool.slot0();
        uint256 priceX96 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        if (otherIsToken0) return Math.mulDiv(priceX96, scale, 1 << 96);
        return Math.mulDiv(1 << 96, scale, priceX96);
    }

    function _inBand(uint256 price, uint256 ref) internal view returns (bool) {
        uint256 band = (ref * bandBps) / 10_000;
        return price + band >= ref && price <= ref + band;
    }

    /// The pool's sqrt price (X96) at `q` USDG per whole `other` (18 decimals).
    function _sqrtPriceAt(uint256 q) internal view returns (uint160) {
        // Raw price = token1 per token0 in base units; times 2^192 so its square root is X96.
        uint256 rawX192 = otherIsToken0
            ? Math.mulDiv(q, (10 ** uint256(usdgDecimals)) << 192, 1e18 * 10 ** uint256(otherDecimals))
            : Math.mulDiv(1e18, (10 ** uint256(otherDecimals)) << 192, q * 10 ** uint256(usdgDecimals));
        return uint160(Math.sqrt(rawX192));
    }
}
