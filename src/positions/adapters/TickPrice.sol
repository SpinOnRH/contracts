// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The price at a pool tick: 1.0001^tick, 18 decimals (so prices far below 1e-12 lose precision).
library TickPrice {
    function at(int24 tick) internal pure returns (uint256 p) {
        uint256 n = uint256(int256(tick < 0 ? -tick : tick));
        uint256 base = 1.0001e18;
        p = 1e18;
        while (n != 0) {
            if (n & 1 != 0) p = Math.mulDiv(p, base, 1e18);
            n >>= 1;
            if (n != 0) base = Math.mulDiv(base, base, 1e18);
        }
        if (tick < 0) p = 1e36 / p;
    }
}
