// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AdminWithdrawable} from "../src/utils/Withdrawable.sol";
import {FeeSplitter} from "../src/fees/FeeSplitter.sol";

contract FeeToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FeeSplitterTest is Test {
    FeeSplitter splitter;
    FeeToken usdg;
    address payable treasury = payable(makeAddr("treasury"));
    address payable burnWallet = payable(makeAddr("burnWallet"));
    address stranger = makeAddr("stranger");

    function setUp() public {
        splitter = new FeeSplitter(treasury, burnWallet, 7_000);
        usdg = new FeeToken();
    }

    function test_feesArriveWithNoWorkAndAnyoneSplitsThem70To30() public {
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);
        usdg.mint(address(splitter), 100e18);
        assertEq(burnWallet.balance + treasury.balance, 0, "nothing moves until a distribution");

        vm.startPrank(stranger);
        splitter.distribute(address(0));
        splitter.distribute(address(usdg));
        vm.stopPrank();
        assertEq(burnWallet.balance, 0.7 ether);
        assertEq(treasury.balance, 0.3 ether);
        assertEq(usdg.balanceOf(burnWallet), 70e18);
        assertEq(usdg.balanceOf(treasury), 30e18);
        assertEq(address(splitter).balance, 0);

        splitter.distribute(address(0)); // nothing left: nothing happens
        assertEq(burnWallet.balance, 0.7 ether);
    }

    function test_theOddWeiGoesToTheTreasury() public {
        vm.deal(address(splitter), 7);
        splitter.distribute(address(0));
        assertEq(burnWallet.balance, 4);
        assertEq(treasury.balance, 3);
    }

    function test_theAdminSetsTheBurnWalletItsShareAndTheTreasury() public {
        vm.startPrank(stranger);
        vm.expectRevert(AdminWithdrawable.NotAdmin.selector);
        splitter.setBurnShare(5_000);
        vm.expectRevert(AdminWithdrawable.NotAdmin.selector);
        splitter.setBurnWallet(payable(stranger));
        vm.expectRevert(AdminWithdrawable.NotAdmin.selector);
        splitter.setTreasury(payable(stranger));
        vm.stopPrank();
        vm.expectRevert(FeeSplitter.BadShare.selector);
        splitter.setBurnShare(10_001);

        splitter.setBurnShare(10_000);
        vm.deal(address(splitter), 1 ether);
        splitter.distribute(address(0));
        assertEq(burnWallet.balance, 1 ether, "all of it to the burn wallet");

        splitter.setBurnWallet(payable(address(0)));
        vm.deal(address(splitter), 1 ether);
        vm.expectRevert(FeeSplitter.NoBurnWallet.selector);
        splitter.distribute(address(0));
        splitter.setBurnWallet(burnWallet);
        splitter.setTreasury(payable(address(0)));
        vm.expectRevert(AdminWithdrawable.NoTreasury.selector);
        splitter.distribute(address(0));
    }

    function test_theAdminWithdrawsToTheTreasuryOnly() public {
        vm.deal(address(splitter), 1 ether);
        usdg.mint(address(splitter), 10e18);
        vm.prank(stranger);
        vm.expectRevert(AdminWithdrawable.NotAdmin.selector);
        splitter.withdrawEth(1 ether);
        splitter.withdrawEth(1 ether);
        splitter.withdrawToken(address(usdg), 10e18);
        assertEq(treasury.balance, 1 ether);
        assertEq(usdg.balanceOf(treasury), 10e18);
    }
}
