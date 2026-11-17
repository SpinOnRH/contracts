// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UpGaugeVenue} from "./UpGaugeVenue.sol";
import {UpTokenGaugeVenue} from "./UpTokenGaugeVenue.sol";
import {IAggregatorV3} from "./WethUsdgVenue.sol";

/**
 * @title UpFeedGaugeAdapter
 * @notice An UP concentrated pool of USDG and a token with a Chainlink USD
 * feed (for example a tokenized stock), and its gauge, as a SpinPosition
 * venue (UpTokenGaugeVenue). The token's reference price in USDG is its feed
 * over the USDG/USD feed; both must be positive, the token's feed no older
 * than `maxTokenFeedAge` and the USDG feed no older than `maxFeedAge`, and the
 * pool's price must be within `maxDeviationBps` of it.
 *
 * A feed that only updates in market hours keeps its last price while the
 * market is closed; `maxTokenFeedAge` can be set to cover that (a weekend, or
 * a long weekend). The band stays around the last price, so the venue acts
 * only while the pool is still within it. Past `maxTokenFeedAge` an operator
 * action fails, and the owner's full withdrawal goes through with the token
 * unsold, valued at the feed's last price.
 */
contract UpFeedGaugeAdapter is UpTokenGaugeVenue {
    IAggregatorV3 public immutable tokenUsd;
    uint32 public immutable maxTokenFeedAge;

    constructor(UpGaugeVenue.Config memory c, IAggregatorV3 tokenUsd_, uint32 maxTokenFeedAge_)
        UpTokenGaugeVenue(c, c.maxDeviationBps)
    {
        tokenUsd = tokenUsd_;
        maxTokenFeedAge = maxTokenFeedAge_;
    }

    function _reference() internal view override returns (uint256, bool) {
        return _feedPrice(tokenUsd, maxTokenFeedAge);
    }

    function _revertOffBand(bool ok) internal pure override {
        if (!ok) revert StaleFeed();
        revert PriceOff();
    }
}
