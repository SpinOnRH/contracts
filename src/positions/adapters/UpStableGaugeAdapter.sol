// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UpGaugeVenue} from "./UpGaugeVenue.sol";
import {UpTokenGaugeVenue} from "./UpTokenGaugeVenue.sol";

/**
 * @title UpStableGaugeAdapter
 * @notice An UP concentrated pool of USDG and another dollar stablecoin, and
 * its gauge, as a SpinPosition venue (UpTokenGaugeVenue). There is no
 * Chainlink feed for the other stablecoin: its reference is the peg, 1 USDG,
 * and the band is `pegBps`.
 */
contract UpStableGaugeAdapter is UpTokenGaugeVenue {
    error OffPeg();

    constructor(UpGaugeVenue.Config memory c, uint16 pegBps_) UpTokenGaugeVenue(c, pegBps_) {}

    function pegBps() external view returns (uint16) {
        return bandBps;
    }

    function _reference() internal pure override returns (uint256, bool) {
        return (1e18, true);
    }

    function _revertOffBand(bool) internal pure override {
        revert OffPeg();
    }
}
