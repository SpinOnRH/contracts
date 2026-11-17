// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20 as OZIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SpinPositions, IERC6551RegistryView} from "../../src/positions/SpinPositions.sol";
import {SpinPosition} from "../../src/positions/SpinPosition.sol";
import {IPositionAdapter} from "../../src/positions/IPositionAdapter.sol";
import {MorphoVaultAdapter, IERC4626Vault} from "../../src/positions/adapters/MorphoVaultAdapter.sol";
import {AdminWithdrawable} from "../../src/utils/Withdrawable.sol";

contract MockUSDG is ERC20 {
    constructor() ERC20("Global Dollar", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// An ERC-4626 vault whose value moves when USDG is minted to it (interest) or burned from it (a loss).
contract MockVault is ERC4626 {
    constructor(OZIERC20 asset_) ERC20("Vault", "vUSDG") ERC4626(asset_) {}
}

contract MockSpinners {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => bool) public isActive;

    function set(uint256 id, address owner, bool active) external {
        ownerOf[id] = owner;
        isActive[id] = active;
    }
}

/// Each token id's account is an address the test sets (the test acts as it with `prank`).
contract MockRegistry is IERC6551RegistryView {
    mapping(uint256 => address) public accounts;

    function set(uint256 id, address account_) external {
        accounts[id] = account_;
    }

    function account(address, bytes32, uint256, address, uint256 tokenId) external view returns (address) {
        return accounts[tokenId];
    }
}

/// A bad venue: spends the position's ETH float.
contract EthSpendingAdapter is IPositionAdapter {
    address public immutable thief;

    constructor(address thief_) {
        thief = thief_;
    }

    function plan(address, bool, bytes calldata) external view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(thief, 0.001 ether, "");
    }

    function exitPlan(address, uint256, bytes calldata) external view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(thief, 0.001 ether, "");
    }

    function holds(address) external pure returns (bool) {
        return false;
    }

    function unsold(address) external pure returns (address[] memory, uint256[] memory, uint256) {}
}

/// A venue whose exit returns `back` USDG and `kept` of `token` unsold, worth `keptValue` USDG.
contract InKindAdapter is IPositionAdapter {
    MockUSDG public immutable usdg;
    MockUSDG public immutable token;
    uint256 public back;
    uint256 public kept;
    uint256 public keptValue;
    mapping(address => bool) public held;

    constructor(MockUSDG usdg_, MockUSDG token_) {
        usdg = usdg_;
        token = token_;
    }

    function set(uint256 back_, uint256 kept_, uint256 keptValue_) external {
        (back, kept, keptValue) = (back_, kept_, keptValue_);
    }

    function plan(address, bool, bytes calldata params) external view returns (Call[] memory calls) {
        (, uint256 amount) = abi.decode(params, (uint8, uint256));
        calls = new Call[](2);
        calls[0] = Call(address(usdg), 0, abi.encodeCall(ERC20.transfer, (address(this), amount)));
        calls[1] = Call(address(this), 0, abi.encodeCall(this.enter, ()));
    }

    function enter() external {
        held[msg.sender] = true;
    }

    function exitPlan(address, uint256, bytes calldata) external view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(address(this), 0, abi.encodeCall(this.exit, ()));
    }

    function exit() external {
        held[msg.sender] = false;
        usdg.mint(msg.sender, back);
        token.mint(msg.sender, kept);
    }

    function holds(address position) external view returns (bool) {
        return held[position];
    }

    function unsold(address) external view returns (address[] memory tokens, uint256[] memory amounts, uint256) {
        tokens = new address[](1);
        tokens[0] = address(token);
        amounts = new uint256[](1);
        amounts[0] = kept;
        return (tokens, amounts, keptValue);
    }
}

contract SpinPositionTest is Test {
    uint256 constant ID = 7;
    uint256 constant E6 = 1e6;
    /// The app's presets: Stable allows class 1; Balanced classes 1 and 2.
    uint256 constant STABLE = 1 << 1;
    uint256 constant BALANCED = (1 << 1) | (1 << 2);

    MockUSDG usdg;
    MockVault vault;
    MockVault otherVault;
    MockSpinners spinners;
    MockRegistry registry;
    SpinPositions positions;
    MorphoVaultAdapter stable;
    MorphoVaultAdapter otherStable;
    MorphoVaultAdapter balancedVault;
    SpinPosition position;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address holder = makeAddr("holder");
    address account = makeAddr("account");
    address buyer = makeAddr("buyer");

    function setUp() public {
        usdg = new MockUSDG();
        vault = new MockVault(OZIERC20(address(usdg)));
        otherVault = new MockVault(OZIERC20(address(usdg)));
        spinners = new MockSpinners();
        spinners.set(ID, holder, true);
        registry = new MockRegistry();
        registry.set(ID, account);

        positions = new SpinPositions(registry, address(0xacc), address(spinners), address(usdg), admin, treasury, 500, 1 gwei, 0.001 ether, 110_000, 80_000);
        stable = new MorphoVaultAdapter(IERC4626Vault(address(vault)));
        otherStable = new MorphoVaultAdapter(IERC4626Vault(address(otherVault)));
        // A vault listed as level 2, to test the level check with a plain vault.
        balancedVault = new MorphoVaultAdapter(IERC4626Vault(address(otherVault)));
        vm.startPrank(admin);
        positions.setOperator(operator, true);
        positions.setVenue(address(stable), 1);
        positions.setVenue(address(otherStable), 1);
        positions.setVenue(address(balancedVault), 2);
        vm.stopPrank();

        position = positions.create(ID);
        vm.prank(account);
        position.configure(STABLE, uint64(block.timestamp + 30 days));
        usdg.mint(address(position), 1_000 * E6);
        vm.deal(address(position), 0.002 ether);
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    function _job(SpinPosition.Kind kind, address adapter, MorphoVaultAdapter.Action action, uint256 amount)
        internal
        pure
        returns (SpinPositions.Job[] memory jobs)
    {
        jobs = new SpinPositions.Job[](1);
        jobs[0] = SpinPositions.Job(ID, kind, adapter, abi.encode(action, amount));
    }

    function _run(SpinPosition.Kind kind, address adapter, MorphoVaultAdapter.Action action, uint256 amount) internal returns (bool) {
        vm.prank(operator);
        return positions.run(_job(kind, adapter, action, amount))[0];
    }

    /// Runs one job and returns the revert reason it failed with (empty if it went through).
    function _reason(SpinPosition.Kind kind, address adapter, MorphoVaultAdapter.Action action, uint256 amount) internal returns (bytes memory reason) {
        vm.recordLogs();
        if (_run(kind, adapter, action, amount)) return "";
        // JobFailed(uint256 indexed tokenId, uint256 index, bytes reason)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, reason) = abi.decode(logs[logs.length - 1].data, (uint256, bytes));
    }

    function _in(uint256 amount) internal {
        assertTrue(_run(SpinPosition.Kind.Manage, address(stable), MorphoVaultAdapter.Action.In, amount), "in");
    }

    function _out() internal {
        assertTrue(_run(SpinPosition.Kind.Manage, address(stable), MorphoVaultAdapter.Action.Out, 0), "out");
    }

    function _harvest() internal {
        assertTrue(_run(SpinPosition.Kind.Harvest, address(stable), MorphoVaultAdapter.Action.Harvest, 0), "harvest");
    }

    // ── Creation and settings ───────────────────────────────────────────

    function test_onePositionPerSpinnerAtAKnownAddress() public {
        assertEq(address(position), positions.positionOf(ID));
        assertEq(position.owner(), account, "owned by the Spinner's account");
        assertEq(position.tokenId(), ID);
        vm.expectRevert();
        positions.create(ID);
        vm.expectRevert(SpinPosition.AlreadyInitialized.selector);
        position.initialize(99);
    }

    function test_onlyTheAccountConfiguresAndWithdraws() public {
        vm.prank(holder);
        vm.expectRevert(SpinPosition.NotOwner.selector);
        position.configure(BALANCED, uint64(block.timestamp + 1 days));
        vm.prank(holder);
        vm.expectRevert(SpinPosition.NotOwner.selector);
        position.withdraw(address(0), 1e18, "");
        vm.prank(account);
        // Class 0 means "not listed": it can never be allowed.
        vm.expectRevert(SpinPosition.BadClasses.selector);
        position.configure(STABLE | 1, uint64(block.timestamp + 1 days));
    }

    function test_theOwnerWithdrawsEthAnyTimeAndTokensWhileIdle() public {
        MockUSDG other = new MockUSDG();
        other.mint(address(position), 5 * E6);
        _in(400 * E6);
        // Not the holder, the protocol's admin or an operator: only the Spinner's account.
        address[3] memory others = [holder, admin, operator];
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(SpinPosition.NotOwner.selector);
            position.withdrawToken(address(other), 5 * E6);
        }
        vm.startPrank(account);
        // Always to the Spinner's wallet: the holder's own funds go nowhere else.
        position.withdrawEth(0.001 ether);
        // In a venue, its tokens leave only through `withdraw`, which settles the fee.
        vm.expectRevert(SpinPosition.NotIdle.selector);
        position.withdrawToken(address(vault), 1);
        vm.expectRevert(SpinPosition.NotIdle.selector);
        position.withdrawToken(address(other), 5 * E6);
        vm.stopPrank();
        _out();
        vm.prank(account);
        position.withdrawToken(address(other), 5 * E6);
        assertEq(other.balanceOf(account), 5 * E6);
        assertEq(account.balance, 0.001 ether);
    }

    function test_theAdminWithdrawsWhatIsSentToTheFactoryOrAnAdapter() public {
        usdg.mint(address(positions), 10 * E6);
        usdg.mint(address(stable), 10 * E6);
        vm.deal(address(positions), 1 ether);
        vm.prank(holder);
        vm.expectRevert(SpinPositions.NotAdmin.selector);
        positions.withdrawToken(address(usdg), 10 * E6);
        vm.startPrank(admin);
        positions.withdrawToken(address(usdg), 10 * E6);
        positions.withdrawEth(1 ether);
        vm.stopPrank();
        // An adapter's admin is its deployer (this test), until it names another; until a treasury is set, nothing moves.
        vm.expectRevert(AdminWithdrawable.NoTreasury.selector);
        stable.withdrawToken(address(usdg), 10 * E6);
        stable.setAdmin(admin);
        vm.expectRevert(AdminWithdrawable.NotAdmin.selector);
        stable.withdrawToken(address(usdg), 10 * E6);
        vm.expectRevert(AdminWithdrawable.NotAdmin.selector);
        stable.setTreasury(payable(address(this)));
        vm.startPrank(admin);
        stable.setTreasury(payable(treasury));
        stable.withdrawToken(address(usdg), 10 * E6);
        vm.stopPrank();
        assertEq(usdg.balanceOf(treasury), 20 * E6);
        assertEq(treasury.balance, 1 ether);
    }

    function test_onlyOperatorsRunJobsAndOnlyThroughTheFactory() public {
        SpinPositions.Job[] memory jobs = _job(SpinPosition.Kind.Manage, address(stable), MorphoVaultAdapter.Action.In, 100 * E6);
        vm.prank(holder);
        vm.expectRevert(SpinPositions.NotOperator.selector);
        positions.run(jobs);

        vm.prank(operator);
        vm.expectRevert(SpinPosition.NotFactory.selector);
        position.operate(SpinPosition.Kind.Manage, address(stable), abi.encode(MorphoVaultAdapter.Action.In, 100 * E6), operator, 0, 0);

        vm.prank(admin);
        positions.setPaused(true);
        vm.prank(operator);
        vm.expectRevert(SpinPositions.Paused.selector);
        positions.run(jobs);
    }

    // ── In, harvest, out ────────────────────────────────────────────────

    function test_inThenHarvestTakesTheFeeOnTheInterestOnly() public {
        _in(1_000 * E6);
        assertEq(position.venue(), address(stable));
        assertEq(position.deployed(), 1_000 * E6);
        assertEq(usdg.balanceOf(address(position)), 0);

        usdg.mint(address(vault), 100 * E6); // 10% interest
        _harvest();
        // ERC-4626 rounding leaves the position a unit short of the interest at most.
        uint256 harvested = usdg.balanceOf(address(position)) + usdg.balanceOf(treasury);
        assertApproxEqAbs(harvested, 100 * E6, 1, "the interest, and only the interest");
        assertEq(usdg.balanceOf(treasury), harvested * 500 / 10_000, "5% of it");
        assertEq(position.deployed(), 1_000 * E6, "the principal is unchanged");
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(address(position))), 1_000 * E6, 1, "the principal stays in the vault");

        // Compounding: the rest goes back in.
        _in(usdg.balanceOf(address(position)));
        assertEq(position.deployed(), 1_000 * E6 + harvested - usdg.balanceOf(treasury));
    }

    function test_aFullExitSettlesTheGain() public {
        _in(1_000 * E6);
        usdg.mint(address(vault), 50 * E6);
        _out();
        assertEq(position.venue(), address(0));
        assertEq(position.deployed(), 0);
        assertApproxEqAbs(usdg.balanceOf(treasury), 2.5 * 1e6, 1, "5% of the 50 gained");
        assertApproxEqAbs(usdg.balanceOf(address(position)), 1_047.5 * 1e6, 1);
    }

    function test_aLossIsCarriedAndWonBackBeforeAnyFee() public {
        _in(1_000 * E6);
        usdg.burn(address(vault), 100 * E6); // the vault loses 10%
        _out();
        assertEq(position.lossCarry(), 100 * E6, "the loss is carried");
        assertEq(usdg.balanceOf(treasury), 0);

        _in(900 * E6);
        usdg.mint(address(vault), 150 * E6);
        _harvest();
        assertEq(position.lossCarry(), 0, "the first 100 of the gain pays the loss back");
        assertApproxEqAbs(usdg.balanceOf(treasury), 2.5 * 1e6, 1, "5% of the 50 above it");
    }

    function test_aHarvestCannotTakeOutPrincipal() public {
        _in(1_000 * E6);
        // A harvest job that asks the adapter for an exit would count the principal as income.
        bytes memory reason = _reason(SpinPosition.Kind.Harvest, address(stable), MorphoVaultAdapter.Action.Out, 0);
        assertEq(bytes4(reason), MorphoVaultAdapter.WrongKind.selector);
        reason = _reason(SpinPosition.Kind.Manage, address(stable), MorphoVaultAdapter.Action.Harvest, 0);
        assertEq(bytes4(reason), MorphoVaultAdapter.WrongKind.selector);
        assertEq(usdg.balanceOf(treasury), 0);
        assertEq(position.deployed(), 1_000 * E6);
    }

    function test_aPartialExitIsRefused() public {
        _in(1_000 * E6);
        // The vault adapter always redeems everything; a venue left holding something cannot settle.
        vm.mockCall(address(stable), abi.encodeCall(IPositionAdapter.holds, (address(position))), abi.encode(true));
        bytes memory reason = _reason(SpinPosition.Kind.Manage, address(stable), MorphoVaultAdapter.Action.Out, 0);
        assertEq(bytes4(reason), SpinPosition.StillHeld.selector);
    }

    // ── The holder's risk classes and one venue at a time ───────────────

    function test_onlyVenuesOfAnAllowedClass() public {
        bytes memory reason = _reason(SpinPosition.Kind.Manage, address(balancedVault), MorphoVaultAdapter.Action.In, 100 * E6);
        assertEq(bytes4(reason), SpinPosition.ClassNotAllowed.selector);

        vm.prank(account);
        position.configure(BALANCED, uint64(block.timestamp + 30 days));
        assertTrue(_run(SpinPosition.Kind.Manage, address(balancedVault), MorphoVaultAdapter.Action.In, 100 * E6));
    }

    function test_theAllowedClassesNeedNotBeInOrder() public {
        // Class 2 only, without class 1: a set, not a highest level.
        vm.prank(account);
        position.configure(1 << 2, uint64(block.timestamp + 30 days));
        assertEq(bytes4(_reason(SpinPosition.Kind.Manage, address(stable), MorphoVaultAdapter.Action.In, 100 * E6)), SpinPosition.ClassNotAllowed.selector);
        assertTrue(_run(SpinPosition.Kind.Manage, address(balancedVault), MorphoVaultAdapter.Action.In, 100 * E6));

        // A class the admin adds later (say 9) is open only to holders who allow it.
        MorphoVaultAdapter later = new MorphoVaultAdapter(IERC4626Vault(address(vault)));
        vm.prank(admin);
        positions.setVenue(address(later), 9);
        assertTrue(_run(SpinPosition.Kind.Manage, address(balancedVault), MorphoVaultAdapter.Action.Out, 0));
        assertEq(bytes4(_reason(SpinPosition.Kind.Manage, address(later), MorphoVaultAdapter.Action.In, 100 * E6)), SpinPosition.ClassNotAllowed.selector);
        vm.prank(account);
        position.configure(1 << 9, uint64(block.timestamp + 30 days));
        assertTrue(_run(SpinPosition.Kind.Manage, address(later), MorphoVaultAdapter.Action.In, 100 * E6));
    }

    function test_thePositionAcceptsErc721AndErc1155PositionTokens() public view {
        assertEq(position.onERC721Received(address(0), address(0), 1, ""), SpinPosition.onERC721Received.selector);
        assertEq(position.onERC1155Received(address(0), address(0), 1, 1, ""), SpinPosition.onERC1155Received.selector);
        assertEq(
            position.onERC1155BatchReceived(address(0), address(0), new uint256[](0), new uint256[](0), ""),
            SpinPosition.onERC1155BatchReceived.selector
        );
    }

    function test_anUnlistedVenueIsRefusedButAListedOneCanStillBeLeft() public {
        MorphoVaultAdapter unlisted = new MorphoVaultAdapter(IERC4626Vault(address(vault)));
        bytes memory reason = _reason(SpinPosition.Kind.Manage, address(unlisted), MorphoVaultAdapter.Action.In, 100 * E6);
        assertEq(bytes4(reason), SpinPosition.NotListed.selector);

        _in(100 * E6);
        vm.prank(admin);
        positions.setVenue(address(stable), 0);
        _out();
        assertEq(usdg.balanceOf(address(position)), 1_000 * E6, "out of a removed venue");
    }

    function test_oneVenueAtATime() public {
        _in(500 * E6);
        bytes memory reason = _reason(SpinPosition.Kind.Manage, address(otherStable), MorphoVaultAdapter.Action.In, 100 * E6);
        assertEq(bytes4(reason), SpinPosition.OtherVenue.selector);
        // Harvesting or leaving a venue the balance is not in is refused before its plan runs.
        reason = _reason(SpinPosition.Kind.Harvest, address(otherStable), MorphoVaultAdapter.Action.Harvest, 0);
        assertEq(bytes4(reason), SpinPosition.OtherVenue.selector);
        reason = _reason(SpinPosition.Kind.Manage, address(otherStable), MorphoVaultAdapter.Action.Out, 0);
        assertEq(bytes4(reason), SpinPosition.OtherVenue.selector);

        _out();
        assertTrue(_run(SpinPosition.Kind.Manage, address(otherStable), MorphoVaultAdapter.Action.In, 100 * E6), "free to move once out");
    }

    // ── Switching off ───────────────────────────────────────────────────

    function test_expiryLevelZeroAndANewHolderStopTheOperator() public {
        vm.warp(block.timestamp + 31 days);
        assertEq(bytes4(_reason(SpinPosition.Kind.Manage, address(stable), MorphoVaultAdapter.Action.In, 1)), SpinPosition.NotEnabled.selector);

        vm.prank(account);
        position.configure(0, uint64(block.timestamp + 30 days));
        assertEq(bytes4(_reason(SpinPosition.Kind.Manage, address(stable), MorphoVaultAdapter.Action.In, 1)), SpinPosition.NotEnabled.selector);

        vm.prank(account);
        position.configure(STABLE, uint64(block.timestamp + 30 days));
        spinners.set(ID, buyer, true); // sold
        assertEq(bytes4(_reason(SpinPosition.Kind.Manage, address(stable), MorphoVaultAdapter.Action.In, 1)), SpinPosition.NotEnabled.selector);

        spinners.set(ID, holder, false); // deactivated
        assertEq(bytes4(_reason(SpinPosition.Kind.Manage, address(stable), MorphoVaultAdapter.Action.In, 1)), SpinPosition.NotActive.selector);
    }

    // ── Withdraw ────────────────────────────────────────────────────────

    function test_withdrawExitsSettlesTheDaysGainAndPaysTheAccount() public {
        _in(1_000 * E6);
        usdg.mint(address(vault), 20 * E6); // a day's interest the worker has not harvested yet
        vm.prank(account);
        position.withdraw(address(stable), 1e18, "");
        assertApproxEqAbs(usdg.balanceOf(treasury), 1 * E6, 1, "5% of the 20, at withdrawal too");
        assertApproxEqAbs(usdg.balanceOf(account), 1_019 * E6, 1);
        assertEq(account.balance, 0.002 ether, "the ETH float too");
        assertEq(usdg.balanceOf(address(position)), 0);
        assertEq(position.venue(), address(0));
    }

    function test_withdrawWorksWhilePausedExpiredOrAfterASale() public {
        _in(1_000 * E6);
        vm.prank(admin);
        positions.setPaused(true);
        vm.warp(block.timestamp + 365 days);
        spinners.set(ID, buyer, false);
        // The new holder controls the account now; the position follows the account.
        vm.prank(account);
        position.withdraw(address(stable), 1e18, "");
        assertEq(usdg.balanceOf(account), 1_000 * E6);
    }

    function test_aPartialWithdrawSettlesTheSameShareOfTheCost() public {
        _in(1_000 * E6);
        usdg.mint(address(vault), 100 * E6); // +10%
        vm.prank(account);
        position.withdraw(address(stable), 0.25e18, "");
        // A quarter came back: 275 against a cost of 250, so a 25 gain and a 1.25 fee.
        assertApproxEqAbs(usdg.balanceOf(treasury), 1.25 * 1e6, 1);
        assertApproxEqAbs(usdg.balanceOf(account), 273.75 * 1e6, 1);
        assertEq(position.deployed(), 750 * E6, "three quarters of the cost stay");
        assertEq(position.venue(), address(stable), "still in the venue");
        assertEq(address(position).balance, 0.002 ether, "the ETH float stays");
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(address(position))), 825 * E6, 2);

        // The rest later: the remaining gain pays its own fee, no more.
        vm.prank(account);
        position.withdraw(address(stable), 1e18, "");
        assertApproxEqAbs(usdg.balanceOf(treasury), 5 * E6, 2, "5% of the whole 100 in the end");
        assertApproxEqAbs(usdg.balanceOf(account), 1_095 * E6, 2);
    }

    function test_aPartialWithdrawAtALossCarriesTheLoss() public {
        _in(1_000 * E6);
        usdg.burn(address(vault), 200 * E6); // -20%
        vm.prank(account);
        position.withdraw(address(stable), 0.5e18, "");
        assertApproxEqAbs(usdg.balanceOf(account), 400 * E6, 1);
        assertEq(position.deployed(), 500 * E6);
        assertApproxEqAbs(position.lossCarry(), 100 * E6, 1, "only the half that left is a realised loss");
        assertEq(usdg.balanceOf(treasury), 0);
    }

    function test_aFullWithdrawalClosesTheBook() public {
        _in(1_000 * E6);
        usdg.burn(address(vault), 200 * E6); // -20%
        vm.prank(account);
        position.withdraw(address(stable), 1e18, "");
        assertEq(position.lossCarry(), 0, "no loss credit is left for a later deposit");
        assertEq(position.deployed(), 0);

        // A later deposit pays the fee on its first gain.
        usdg.mint(address(position), 1_000 * E6);
        _in(1_000 * E6);
        usdg.mint(address(vault), 100 * E6);
        _harvest();
        assertApproxEqAbs(usdg.balanceOf(treasury), 5 * E6, 1);
    }

    function test_aPartialWithdrawOfAnIdlePosition() public {
        vm.prank(account);
        position.withdraw(address(0), 0.1e18, "");
        assertEq(usdg.balanceOf(account), 100 * E6);
        assertEq(usdg.balanceOf(address(position)), 900 * E6);
        assertEq(account.balance, 0);
    }

    function test_aWithdrawNeedsAFractionUpToTheWhole() public {
        vm.startPrank(account);
        vm.expectRevert(SpinPosition.BadFraction.selector);
        position.withdraw(address(0), 0, "");
        vm.expectRevert(SpinPosition.BadFraction.selector);
        position.withdraw(address(0), 1e18 + 1, "");
        vm.stopPrank();
    }

    function test_withdrawMustUseTheVenue() public {
        _in(1_000 * E6);
        vm.prank(account);
        vm.expectRevert(SpinPosition.NotVenue.selector);
        position.withdraw(address(otherStable), 1e18, "");
    }

    // ── Escape ──────────────────────────────────────────────────────────

    function test_escapeOpensAfterTheDelayAndResetsTheBook() public {
        _in(1_000 * E6);
        bytes memory takeShares = abi.encodeCall(ERC20.transfer, (account, vault.balanceOf(address(position))));
        vm.prank(account);
        vm.expectRevert(SpinPosition.EscapeNotOpen.selector);
        position.escape(address(vault), 0, takeShares);

        vm.prank(account);
        position.requestEscape();
        vm.warp(block.timestamp + 7 days - 1);
        vm.prank(account);
        vm.expectRevert(SpinPosition.EscapeNotOpen.selector);
        position.escape(address(vault), 0, takeShares);

        vm.warp(block.timestamp + 1);
        vm.prank(account);
        position.escape(address(vault), 0, takeShares);
        assertGt(vault.balanceOf(account), 0, "the raw shares");
        assertEq(position.deployed(), 0);
        assertEq(position.venue(), address(0));
        assertEq(position.lossCarry(), 0, "no loss credited for funds that left unsettled");
    }

    function test_whileAnEscapeWaitsOperatorsTakeTheBalanceOutAndTheFeeIsPaid() public {
        _in(1_000 * E6);
        usdg.mint(address(vault), 100 * E6); // interest: a 100 USDG gain
        usdg.mint(address(position), 10 * E6);
        vm.startPrank(account);
        // A request needs a float that can pay for the exit ...
        uint256 float = address(position).balance;
        position.withdrawEth(float);
        vm.expectRevert(SpinPosition.FloatTooLow.selector);
        position.requestEscape();
        vm.stopPrank();
        vm.deal(address(position), float);
        // ... and while it waits, the float stays, even with operators switched off.
        vm.startPrank(account);
        position.configure(0, 0);
        position.requestEscape();
        vm.expectRevert(SpinPosition.EscapePending.selector);
        position.withdrawEth(1);
        vm.stopPrank();
        // Nothing more goes in, and nothing but an exit runs ...
        assertEq(bytes4(_reason(SpinPosition.Kind.Manage, address(stable), MorphoVaultAdapter.Action.In, 10 * E6)), SpinPosition.EscapePending.selector);
        assertEq(bytes4(_reason(SpinPosition.Kind.Harvest, address(stable), MorphoVaultAdapter.Action.Harvest, 0)), SpinPosition.NotEnabled.selector);
        // ... and the exit pays its gas from the float and the fee on the gain.
        uint256 operatorBefore = operator.balance;
        vm.txGasPrice(1 gwei);
        _out();
        assertGt(operator.balance, operatorBefore, "the float refunded the exit's gas");
        assertEq(position.venue(), address(0));
        assertApproxEqAbs(usdg.balanceOf(treasury), 5 * E6, 1, "5% of the gain");
        // Out of the venue, the float can leave again.
        vm.prank(account);
        position.withdrawEth(1);
        vm.warp(block.timestamp + 7 days);
        vm.prank(account);
        position.escape(account, 0, "");
        assertEq(position.escapeAt(), 0, "the escape is used up");
        assertTrue(position.retired(), "and the position retired");
    }

    // ── After an escape ─────────────────────────────────────────────────

    function _escapeIdle(address target, bytes memory data) internal {
        vm.prank(account);
        position.requestEscape();
        vm.warp(block.timestamp + 7 days);
        vm.prank(account);
        position.escape(target, 0, data);
    }

    function test_anEscapeRetiresThePositionAndTheSpinnersNextOneIsNew() public {
        _in(500 * E6);
        _out();
        _escapeIdle(account, "");
        assertTrue(position.retired());
        assertEq(positions.generation(ID), 1);
        assertEq(positions.positionAt(ID, 0), address(position), "the first generation is the retired one");
        address next = positions.positionOf(ID);
        assertTrue(next != address(position), "the next position is another address");
        assertEq(next.code.length, 0, "not created yet");

        // Operators reach only the next position: until it exists, its jobs are skipped.
        assertFalse(_run(SpinPosition.Kind.Manage, address(stable), MorphoVaultAdapter.Action.In, 100 * E6));
        vm.prank(address(positions));
        vm.expectRevert(SpinPosition.Retired.selector);
        position.operate(SpinPosition.Kind.Manage, address(stable), abi.encode(MorphoVaultAdapter.Action.In, 100 * E6), operator, 0, 0);

        // The retired position keeps every way out for its owner.
        vm.startPrank(account);
        position.withdraw(address(stable), 1e18, "");
        position.requestEscape();
        vm.stopPrank();
        assertEq(usdg.balanceOf(address(position)), 0, "its USDG went to the owner");

        SpinPosition fresh = positions.create(ID);
        assertEq(address(fresh), next);
        assertEq(fresh.owner(), account, "owned by the same Spinner's account");
        assertFalse(fresh.retired());
        vm.prank(account);
        fresh.configure(STABLE, uint64(block.timestamp + 30 days));
        usdg.mint(address(fresh), 200 * E6);
        _in(200 * E6);
        assertEq(fresh.deployed(), 200 * E6, "operators run on the new position");
    }

    /// Regression: an approval made in an escape outlived it and a sale.
    function test_anApprovalMadeInAnEscapeNeverReachesTheNextHoldersPosition() public {
        address seller = holder;
        _escapeIdle(address(vault), abi.encodeCall(ERC20.approve, (seller, type(uint256).max)));
        assertGt(vault.allowance(address(position), seller), 0, "the seller's approval, on the retired position");

        // The Spinner is sold; the buyer's position is a new one.
        spinners.set(ID, buyer, true);
        SpinPosition fresh = positions.create(ID);
        vm.prank(account);
        fresh.configure(STABLE, uint64(block.timestamp + 30 days));
        usdg.mint(address(fresh), 1_000 * E6);
        _in(1_000 * E6);
        uint256 shares = vault.balanceOf(address(fresh));
        assertGt(shares, 0);
        assertEq(vault.allowance(address(fresh), seller), 0, "no approval on the new position");
        vm.prank(seller);
        vm.expectRevert();
        vault.transferFrom(address(fresh), seller, shares);
    }

    function test_idleUsdgLeavesAtOnceWhileTheVenueCannotExit() public {
        _in(500 * E6);
        // The vault is fully used: its redeem reverts, so the venue cannot exit.
        vm.mockCallRevert(address(vault), abi.encodeWithSelector(ERC4626.redeem.selector), "illiquid");
        vm.startPrank(account);
        vm.expectRevert(bytes("illiquid"));
        position.withdraw(address(stable), 1e18, "");
        // The 500 USDG that is not in the venue is the owner's at once.
        position.withdrawToken(address(usdg), 500 * E6);
        vm.stopPrank();
        assertEq(usdg.balanceOf(account), 500 * E6);
        assertEq(position.deployed(), 500 * E6, "the venue's part is still counted");
    }

    /// Regression: while an escape waited, refused harvests were charged to the
    /// float kept for the exit.
    function test_whileAnEscapeWaitsOnlyAFailedExitIsChargedToTheFloat() public {
        _in(1_000 * E6);
        vm.deal(address(position), 0.001 ether); // exactly maxGasRefund
        vm.startPrank(account);
        position.requestEscape();
        position.configure(0, 0); // operators off
        vm.stopPrank();
        vm.txGasPrice(1 gwei);
        for (uint256 i; i < 5; i++) {
            assertFalse(_run(SpinPosition.Kind.Harvest, address(stable), MorphoVaultAdapter.Action.Harvest, 0));
        }
        assertEq(address(position).balance, 0.001 ether, "refused harvests cost the float nothing");
        _out();
        assertLt(address(position).balance, 0.001 ether, "the exit paid its gas from it");
    }

    function test_aJobForAPositionNotCreatedIsSkipped() public {
        SpinPositions.Job[] memory jobs = new SpinPositions.Job[](2);
        jobs[0] = SpinPositions.Job(999, SpinPosition.Kind.Manage, address(stable), abi.encode(MorphoVaultAdapter.Action.In, 1));
        jobs[1] = SpinPositions.Job(ID, SpinPosition.Kind.Manage, address(stable), abi.encode(MorphoVaultAdapter.Action.In, 100 * E6));
        vm.prank(operator);
        bool[] memory ok = positions.run(jobs);
        assertFalse(ok[0], "skipped");
        assertTrue(ok[1], "the others still run");
    }

    function test_onlyTheSpinnersCurrentPositionRetiresIt() public {
        vm.prank(operator);
        vm.expectRevert(SpinPositions.NotPosition.selector);
        positions.retire(ID);
    }

    function test_anOwnersFullWithdrawalCountsWhatTheVenueLeftUnsold() public {
        MockUSDG weth = new MockUSDG();
        InKindAdapter venue = new InKindAdapter(usdg, weth);
        vm.prank(admin);
        positions.setVenue(address(venue), 1);
        vm.prank(operator);
        assertTrue(positions.run(_job(SpinPosition.Kind.Manage, address(venue), MorphoVaultAdapter.Action.In, 1_000 * E6))[0]);

        // 1,000 in; back: no USDG, and 600 tokens unsold worth 1,200: a 200 gain, a 10 USDG fee, all in kind.
        venue.set(0, 600e18, 1_200 * E6);
        vm.prank(account);
        position.withdraw(address(venue), 1e18, "");
        assertEq(usdg.balanceOf(treasury), 0);
        assertEq(weth.balanceOf(treasury), 5e18, "10 of the 1,200 in value");
        assertEq(weth.balanceOf(account), 595e18);
        assertEq(weth.balanceOf(address(position)), 0);
    }

    function test_aFeeOnUnsoldTokensIsPaidInUsdgFirst() public {
        MockUSDG weth = new MockUSDG();
        InKindAdapter venue = new InKindAdapter(usdg, weth);
        vm.prank(admin);
        positions.setVenue(address(venue), 1);
        vm.prank(operator);
        assertTrue(positions.run(_job(SpinPosition.Kind.Manage, address(venue), MorphoVaultAdapter.Action.In, 1_000 * E6))[0]);

        // Back: 4 USDG and tokens worth 1,200: a 204 gain, a 10.2 USDG fee; 4 in USDG, 6.2 in kind.
        venue.set(4 * E6, 600e18, 1_200 * E6);
        vm.prank(account);
        position.withdraw(address(venue), 1e18, "");
        assertEq(usdg.balanceOf(treasury), 4 * E6);
        assertEq(weth.balanceOf(treasury), 3.1e18);
        assertEq(weth.balanceOf(account), 596.9e18);
        assertEq(usdg.balanceOf(account), 0);
    }

    function test_unsoldTokensAtALossPayNoFee() public {
        MockUSDG weth = new MockUSDG();
        InKindAdapter venue = new InKindAdapter(usdg, weth);
        vm.prank(admin);
        positions.setVenue(address(venue), 1);
        vm.prank(operator);
        assertTrue(positions.run(_job(SpinPosition.Kind.Manage, address(venue), MorphoVaultAdapter.Action.In, 1_000 * E6))[0]);
        venue.set(100 * E6, 400e18, 800 * E6);
        vm.prank(account);
        position.withdraw(address(venue), 1e18, "");
        assertEq(usdg.balanceOf(treasury) + weth.balanceOf(treasury), 0);
        assertEq(weth.balanceOf(account), 400e18);
        assertEq(usdg.balanceOf(account), 100 * E6);
        assertEq(position.lossCarry(), 0, "the book is closed");
    }

    // ── Gas ─────────────────────────────────────────────────────────────

    function test_theEthFloatCannotBeSpentByAVenue() public {
        EthSpendingAdapter bad = new EthSpendingAdapter(makeAddr("thief"));
        vm.prank(admin);
        positions.setVenue(address(bad), 1);
        assertEq(bytes4(_reason(SpinPosition.Kind.Manage, address(bad), MorphoVaultAdapter.Action.In, 0)), SpinPosition.EthSpent.selector);
    }

    function test_theOperatorsGasIsRefundedFromTheFloatWithinTheCap() public {
        vm.txGasPrice(0.02 gwei);
        _in(1_000 * E6);
        uint256 refund = operator.balance;
        assertGt(refund, 0, "refunded");
        assertLt(refund, 0.001 ether, "under the cap");
        assertEq(address(position).balance, 0.002 ether - refund);

        vm.txGasPrice(1_000 gwei); // above every cap
        _out();
        assertLe(operator.balance - refund, 0.001 ether, "never more than maxGasRefund");
    }

    function _failingJob() internal returns (bool ok) {
        SpinPositions.Job[] memory jobs = new SpinPositions.Job[](1);
        // A venue above the position's chosen classes: it reverts inside the position.
        jobs[0] = SpinPositions.Job(ID, SpinPosition.Kind.Manage, address(balancedVault), abi.encode(MorphoVaultAdapter.Action.In, 1));
        vm.prank(operator);
        ok = positions.run(jobs)[0];
    }

    function test_aFailedJobPaysItsOwnGasFromTheFloat() public {
        vm.txGasPrice(0.02 gwei);
        vm.recordLogs();
        assertFalse(_failingJob());
        uint256 refund = operator.balance;
        assertGt(refund, 0, "the operator is not left paying for it");
        assertLt(refund, 0.001 ether);
        assertEq(address(position).balance, 0.002 ether - refund);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 charged = keccak256("FailedJobCharged(address,uint256)");
        bool seen;
        for (uint256 i; i < logs.length; i++) if (logs[i].topics[0] == charged) seen = true;
        assertTrue(seen, "FailedJobCharged");
    }

    function test_aFailedJobIsNotChargedToAPositionItsHolderHasNotEnabled() public {
        vm.txGasPrice(0.02 gwei);
        vm.warp(block.timestamp + 366 days); // past its expiry
        assertFalse(_failingJob());
        assertEq(operator.balance, 0);
        assertEq(address(position).balance, 0.002 ether, "the float is untouched");
    }

    function test_aFailedJobWithAnEmptyFloatIsSkippedWithoutStoppingTheRun() public {
        vm.txGasPrice(0.02 gwei);
        vm.deal(address(position), 0);
        assertFalse(_failingJob());
        assertEq(operator.balance, 0);
    }

    function test_aJobThatFailsDoesNotStopTheOthers() public {
        SpinPositions.Job[] memory jobs = new SpinPositions.Job[](2);
        jobs[0] = SpinPositions.Job(ID, SpinPosition.Kind.Manage, address(balancedVault), abi.encode(MorphoVaultAdapter.Action.In, 1)); // above level
        jobs[1] = SpinPositions.Job(ID, SpinPosition.Kind.Manage, address(stable), abi.encode(MorphoVaultAdapter.Action.In, 10 * E6));
        vm.prank(operator);
        bool[] memory ok = positions.run(jobs);
        assertFalse(ok[0]);
        assertTrue(ok[1]);
        assertEq(position.deployed(), 10 * E6);
    }

    function test_theAdminSetsTheCollection() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(SpinPositions.NotAdmin.selector);
        positions.setCollection(stranger);
        vm.prank(admin);
        vm.expectRevert(SpinPositions.ZeroCollection.selector);
        positions.setCollection(address(0));
        MockSpinners next = new MockSpinners();
        vm.expectEmit(address(positions));
        emit SpinPositions.CollectionSet(address(next));
        vm.prank(admin);
        positions.setCollection(address(next));
        assertEq(positions.collection(), address(next));
    }
}

import {Vm} from "forge-std/Vm.sol";
