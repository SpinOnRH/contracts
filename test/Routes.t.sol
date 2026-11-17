// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Routes} from "../src/bots/Routes.sol";

/// The route ids the worker computes too: its tests pin the same values.
contract RoutesTest is Test {
    function test_theIdsTheWorkerComputes() public pure {
        assertEq(
            Routes.uniswap(true, 3000, 60, address(0), address(0), 0, 0, address(0)),
            0x9ed7ed1de78585d71ea4a0624bf67cf84387db791d4b8dc15e619cf667e10f3f,
            "a Torch token's pool"
        );
        assertEq(
            Routes.up(true, false, 200, 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, false, 10),
            0xd249d94bcc800c6fd554bcec7eada008af135ad0ee2609fccb4bf4f1146e69d0,
            "an UP concentrated pool through USDG"
        );
        assertEq(Routes.PONS, keccak256("spin.route.pons"));
    }

    function test_aBuyAndASellOfOnePathShareAnIdAndOtherPathsDoNot() public pure {
        bytes32 v3 = Routes.uniswap(false, 10_000, 0, address(0), address(0), 0, 0, address(0));
        assertTrue(v3 != Routes.uniswap(false, 3000, 0, address(0), address(0), 0, 0, address(0)), "another fee tier");
        assertTrue(v3 != Routes.uniswap(true, 10_000, 0, address(0), address(0), 0, 0, address(0)), "V4");
        assertTrue(v3 != Routes.up(false, false, 0, address(0), false, 0), "another venue");
    }
}
