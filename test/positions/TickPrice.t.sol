// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {TickPrice} from "../../src/positions/adapters/TickPrice.sol";

contract TickPriceTest is Test {
    function test_thePriceAtATickIs1Point0001ToThatPower() public pure {
        assertEq(TickPrice.at(0), 1e18);
        assertEq(TickPrice.at(1), 1.0001e18);
        assertApproxEqRel(TickPrice.at(-1), 0.99990001e18, 1e10);
        // 1.0001^69082 = 1000.0 (to 5 digits), and its inverse.
        assertApproxEqRel(TickPrice.at(69_082), 1_000e18, 1e14);
        assertApproxEqRel(TickPrice.at(-69_082), 0.001e18, 1e14);
        // The ends of Uniswap's tick range do not overflow.
        assertApproxEqRel(TickPrice.at(887_272), 3.4025678e56, 1e13);
        assertEq(TickPrice.at(-887_272), 0);
    }

    /// Over prices from 2e-9 to 5e8 (UP's pool sits near ±115,000); far below that, 18 decimals run out.
    function testFuzz_eachTickIsOneBasisPointAboveTheLast(int24 tick) public pure {
        tick = int24(bound(tick, -200_000, 200_000));
        assertApproxEqRel(TickPrice.at(tick + 1), (TickPrice.at(tick) * 10_001) / 10_000, 1e12);
    }
}
