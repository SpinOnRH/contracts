// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HookList, HookListUser, IHookList} from "../src/bots/HookList.sol";
import {UniswapAdapter} from "../src/bots/adapters/UniswapAdapter.sol";
import {PairLaunchAdapter, ITorchTokens} from "../src/bots/adapters/PairLaunchAdapter.sol";
import {LongAdapter, IDopplerAirlock, IDopplerHookInitializer} from "../src/bots/adapters/LongAdapter.sol";
import {IPonsFactory} from "../src/bots/adapters/PonsAdapter.sol";
import {AdminWithdrawable} from "../src/utils/Withdrawable.sol";

/// The HookList, and the adapters that read it: each adapter's admin, and only it, points it at another list.
contract HookListTest is Test {
    address constant HOOK = address(0xA0);
    address constant OTHER = address(0xB0);
    address admin = makeAddr("admin");

    HookList list;
    UniswapAdapter uni;
    PairLaunchAdapter pair;
    LongAdapter long;

    function setUp() public {
        address[] memory hooks = new address[](1);
        hooks[0] = HOOK;
        vm.startPrank(admin);
        list = new HookList(hooks);
        uni = new UniswapAdapter(address(1), address(2), address(3), IPonsFactory(address(4)), address(5), admin, list);
        pair = new PairLaunchAdapter(address(1), address(2), address(3), IPonsFactory(address(4)), address(5), ITorchTokens(address(6)), 3000, 60, list);
        long = new LongAdapter(address(1), address(2), address(3), IDopplerAirlock(address(4)), IDopplerHookInitializer(address(5)), list, new address[](0));
        vm.stopPrank();
    }

    function test_theListStartsWithItsHooksAndOnlyItsAdminChangesIt() public {
        assertTrue(list.allowedHook(HOOK));
        assertFalse(list.allowedHook(OTHER));
        vm.expectRevert(AdminWithdrawable.NotAdmin.selector);
        list.setHook(OTHER, true);

        vm.expectEmit(address(list));
        emit HookList.HookSet(OTHER, true);
        vm.prank(admin);
        list.setHook(OTHER, true);
        assertTrue(uni.allowedHook(OTHER), "the Uniswap adapter answers from the list");
        vm.prank(admin);
        list.setHook(HOOK, false);
        assertFalse(uni.allowedHook(HOOK));
    }

    function test_eachAdaptersAdminPointsItAtAnotherList() public {
        HookList next = new HookList(new address[](0));
        HookListUser[3] memory users = [HookListUser(address(uni)), HookListUser(address(pair)), HookListUser(address(long))];
        for (uint256 i; i < users.length; i++) {
            assertEq(address(users[i].hookList()), address(list));
            vm.expectRevert();
            users[i].setHookList(next);
            vm.prank(admin);
            vm.expectRevert(HookListUser.NoHookList.selector);
            users[i].setHookList(IHookList(address(0)));

            vm.expectEmit(address(users[i]));
            emit HookListUser.HookListSet(address(next));
            vm.prank(admin);
            users[i].setHookList(next);
            assertEq(address(users[i].hookList()), address(next));
        }
        assertFalse(uni.allowedHook(HOOK), "the new list's answer");
    }

    function test_aListIsNeeded() public {
        vm.expectRevert(HookListUser.NoHookList.selector);
        new UniswapAdapter(address(1), address(2), address(3), IPonsFactory(address(4)), address(5), admin, IHookList(address(0)));
    }
}
