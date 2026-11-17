// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AdminWithdrawable} from "../src/utils/Withdrawable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IPonsFactory} from "../src/bots/adapters/PonsAdapter.sol";
import {
    SpinnerCreatorVaults,
    SpinnerCreatorVault,
    ITorchCreatorRouter,
    ITorchCreatorFactory,
    IPonsCreatorEscrow
} from "../src/bots/SpinnerCreatorVaults.sol";

contract PairToken is ERC20 {
    constructor() ERC20("Pair", "PAIR") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// A later implementation: the same vault, with a function for another launchpad.
contract SpinnerCreatorVaultNext is SpinnerCreatorVault {
    constructor(SpinnerCreatorVaults vaults_)
        SpinnerCreatorVault(vaults_, ITorchCreatorRouter(address(0)), ITorchCreatorFactory(address(0)), IPonsFactory(address(0)), IPonsCreatorEscrow(address(0)))
    {}

    function nextLaunchpad() external view returns (address) {
        return account;
    }
}

/// The vaults without the launchpads (the fork tests have them): addresses, the fee, paying on, the implementation.
contract SpinnerCreatorVaultsTest is Test {
    event Upgraded(address indexed implementation);

    SpinnerCreatorVaults vaults;
    address treasury = makeAddr("treasury");
    address account = makeAddr("account");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vaults = new SpinnerCreatorVaults(payable(treasury), 50);
        vaults.setImplementation(address(_implementation()));
    }

    function _implementation() internal returns (SpinnerCreatorVault) {
        return new SpinnerCreatorVault(vaults, ITorchCreatorRouter(address(0)), ITorchCreatorFactory(address(0)), IPonsFactory(address(0)), IPonsCreatorEscrow(address(0)));
    }

    function test_eachAccountHasOneVaultAtAKnownAddressAnyoneCanDeploy() public {
        address predicted = vaults.vaultOf(account);
        assertEq(predicted.code.length, 0);
        vm.prank(stranger);
        assertEq(vaults.deploy(account), predicted);
        assertGt(predicted.code.length, 0);
        assertEq(vaults.deploy(account), predicted, "deploying again is the same vault");
        SpinnerCreatorVault v = SpinnerCreatorVault(payable(predicted));
        assertEq(v.account(), account);
        assertEq(address(v.vaults()), address(vaults));
        assertTrue(vaults.vaultOf(stranger) != predicted, "another account, another vault");
    }

    function test_aVaultIsSetUpOnceAndTheImplementationIsNoAccountsVault() public {
        SpinnerCreatorVault v = SpinnerCreatorVault(payable(vaults.deploy(account)));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v.initialize(stranger);
        vm.prank(address(vaults));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v.initialize(stranger);
        assertEq(v.account(), account);
        SpinnerCreatorVault impl = SpinnerCreatorVault(payable(vaults.implementation()));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(stranger);
        assertEq(impl.account(), address(0));
    }

    function test_theAdminSetsANewImplementationAndEveryVaultRunsItAtTheSameAddress() public {
        address vault = vaults.deploy(account);
        address next = address(new SpinnerCreatorVaultNext(vaults));
        vm.prank(stranger);
        vm.expectRevert(AdminWithdrawable.NotAdmin.selector);
        vaults.setImplementation(next);
        vm.expectRevert(SpinnerCreatorVaults.BadImplementation.selector);
        vaults.setImplementation(stranger);
        address notAVault = address(new PairToken());
        address otherVaults = address(new SpinnerCreatorVaultNext(new SpinnerCreatorVaults(payable(treasury), 50)));
        vm.expectRevert(SpinnerCreatorVaults.BadImplementation.selector);
        vaults.setImplementation(notAVault); // a contract, but no vault
        vm.expectRevert(SpinnerCreatorVaults.BadImplementation.selector);
        vaults.setImplementation(otherVaults); // a vault made for other vaults
        assertEq(SpinnerCreatorVault(payable(vault)).account(), account, "a refused one changes nothing");

        vm.expectEmit(address(vaults));
        emit Upgraded(next);
        vaults.setImplementation(next);
        assertEq(SpinnerCreatorVaultNext(payable(vault)).nextLaunchpad(), account, "the same vault, its account kept, the new function");
        assertEq(vaults.vaultOf(account), vault, "the address does not change");
        assertEq(vaults.deploy(stranger), vaults.vaultOf(stranger), "new vaults run it too");
    }

    function test_noVaultIsDeployedBeforeAnImplementationIsSet() public {
        SpinnerCreatorVaults bare = new SpinnerCreatorVaults(payable(treasury), 50);
        vm.expectRevert();
        bare.deploy(account);
    }

    function test_whatAVaultReceivesIsPaidOnLessTheProtocolsHalfPercent() public {
        SpinnerCreatorVault v = SpinnerCreatorVault(payable(vaults.deploy(account)));
        vm.deal(address(v), 1 ether);
        PairToken pair = new PairToken();
        pair.mint(address(v), 1_000e18);
        vm.startPrank(stranger);
        v.pay(address(0));
        v.pay(address(pair));
        vm.stopPrank();
        assertEq(treasury.balance, 0.005 ether, "0.5% to the treasury");
        assertEq(account.balance, 0.995 ether, "the rest to the Spinner's account");
        assertEq(pair.balanceOf(treasury), 5e18);
        assertEq(pair.balanceOf(account), 995e18);
        assertEq(address(v).balance, 0);
        v.pay(address(0)); // nothing left: nothing happens
    }

    function test_aVaultTakesEthSentWithAPlainCall() public {
        address v = vaults.deploy(account);
        (bool ok,) = v.call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(v.balance, 1 ether);
    }

    function test_theAdminSetsTheFeeAndTheTreasury_andWithoutATreasuryThereIsNoFee() public {
        vm.prank(stranger);
        vm.expectRevert(AdminWithdrawable.NotAdmin.selector);
        vaults.setFee(100);
        vm.expectRevert(SpinnerCreatorVaults.BadFee.selector);
        vaults.setFee(10_001);
        vaults.setFee(100);
        (uint256 bps, address to) = vaults.feeOf();
        assertEq(bps, 100);
        assertEq(to, treasury);

        vaults.setTreasury(payable(address(0)));
        (bps, to) = vaults.feeOf();
        assertEq(bps, 0);
        SpinnerCreatorVault v = SpinnerCreatorVault(payable(vaults.deploy(account)));
        vm.deal(address(v), 1 ether);
        v.pay(address(0));
        assertEq(account.balance, 1 ether, "all to the account");
    }

    function test_onlyTheAccountSetsATorchTokensLinks() public {
        SpinnerCreatorVault v = SpinnerCreatorVault(payable(vaults.deploy(account)));
        vm.prank(stranger);
        vm.expectRevert(SpinnerCreatorVault.NotAccount.selector);
        v.setTorchMetadata(address(1), "ipfs://x");
    }
}
