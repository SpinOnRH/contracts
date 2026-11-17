// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {SpinPositions, IERC6551RegistryView} from "../../src/positions/SpinPositions.sol";
import {SpinPosition} from "../../src/positions/SpinPosition.sol";
import {MorphoVaultAdapter, IERC4626Vault} from "../../src/positions/adapters/MorphoVaultAdapter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

interface IRegistryCreate {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

interface IAccountExecute {
    function execute(address to, uint256 value, bytes calldata data, uint8 operation) external payable returns (bytes memory);
}

/// The collection stand-in: just enough for Tokenbound's `ownerOf` and the position's checks.
contract ForkSpinners {
    mapping(uint256 => address) public ownerOf;

    function isActive(uint256) external pure returns (bool) {
        return true;
    }

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }
}

/**
 * A SpinPosition in the Steakhouse USDG vault (Morpho Vault V2) on a fork of
 * Robinhood Chain, owned by a real Tokenbound account from the deployed
 * ERC-6551 registry. The holder acts on the position through the account.
 *
 *   RPC_URL=<archive rpc> npm run test
 */
contract MorphoVaultAdapterFork is Test {
    address constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    IERC4626Vault constant STEAKHOUSE = IERC4626Vault(0xBeEff033F34C046626B8D0A041844C5d1A5409dd);
    // Spark Savings USDG (spUSDG): a SparkVault, ERC-4626 at a savings rate Spark sets.
    IERC4626Vault constant SPARK = IERC4626Vault(0xde770c84FE66E063336b31737cFE9790f18c4087);
    uint256 constant PINNED_BLOCK = 92_557_000;
    uint256 constant ID = 1;
    uint256 constant E6 = 1e6;

    SpinPositions positions;
    MorphoVaultAdapter steakhouse;
    MorphoVaultAdapter spark;
    SpinPosition position;
    address account;
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address holder = makeAddr("holder");

    function setUp() public {
        string memory rpc = vm.envOr("RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // every test below skips
        vm.createSelectFork(rpc, PINNED_BLOCK);
        vm.etch(0x000000000000000000000000000000000000006C, "");

        ForkSpinners spinners = new ForkSpinners();
        spinners.mint(holder, ID);
        account = IRegistryCreate(REGISTRY).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), ID);

        positions = new SpinPositions(
            IERC6551RegistryView(REGISTRY), ACCOUNT_V3, address(spinners), USDG, admin, treasury, 500, 1 gwei, 0.001 ether, 110_000, 80_000
        );
        steakhouse = new MorphoVaultAdapter(STEAKHOUSE);
        spark = new MorphoVaultAdapter(SPARK);
        vm.startPrank(admin);
        positions.setOperator(operator, true);
        positions.setVenue(address(steakhouse), 1);
        positions.setVenue(address(spark), 1);
        vm.stopPrank();

        // The one-press setup: create the position, configure it from the account, fund it.
        position = positions.create(ID);
        _asHolder(address(position), 0, abi.encodeCall(SpinPosition.configure, (1 << 1, uint64(block.timestamp + 365 days))));
        deal(USDG, address(position), 10_000 * E6);
        vm.deal(address(position), 0.002 ether);
    }

    modifier forked() {
        if (address(positions) == address(0)) {
            emit log("skipped: set RPC_URL to run the fork tests");
            return;
        }
        _;
    }

    function _asHolder(address to, uint256 value, bytes memory data) internal {
        vm.prank(holder);
        IAccountExecute(account).execute(to, value, data, 0);
    }

    function _run(SpinPosition.Kind kind, MorphoVaultAdapter.Action action, uint256 amount) internal {
        _run(steakhouse, kind, action, amount);
    }

    function _run(MorphoVaultAdapter adapter, SpinPosition.Kind kind, MorphoVaultAdapter.Action action, uint256 amount) internal {
        SpinPositions.Job[] memory jobs = new SpinPositions.Job[](1);
        jobs[0] = SpinPositions.Job(ID, kind, address(adapter), abi.encode(action, amount));
        vm.prank(operator);
        bool[] memory ok = positions.run(jobs);
        assertTrue(ok[0], "job went through");
    }

    function test_theAccountOwnsThePosition() public forked {
        assertEq(position.owner(), account);
    }

    function test_depositHarvestTheInterestAndWithdraw() public forked {
        vm.txGasPrice(0.02 gwei);
        _run(SpinPosition.Kind.Manage, MorphoVaultAdapter.Action.In, 10_000 * E6);
        assertEq(position.deployed(), 10_000 * E6);
        assertEq(IERC20(USDG).balanceOf(address(position)), 0);
        assertGt(STEAKHOUSE.balanceOf(address(position)), 0, "vault shares in the position");

        // A month of interest at the vault's rate.
        vm.warp(block.timestamp + 30 days);
        uint256 value = STEAKHOUSE.previewRedeem(STEAKHOUSE.balanceOf(address(position)));
        assertGt(value, 10_000 * E6, "the vault paid interest");
        emit log_named_uint("interest over 30 days (USDG, 6 decimals)", value - 10_000 * E6);

        _run(SpinPosition.Kind.Harvest, MorphoVaultAdapter.Action.Harvest, 0);
        uint256 fee = IERC20(USDG).balanceOf(treasury);
        uint256 kept = IERC20(USDG).balanceOf(address(position));
        assertApproxEqAbs(fee + kept, value - 10_000 * E6, 2, "the interest was harvested");
        assertApproxEqAbs(fee, (fee + kept) * 500 / 10_000, 1, "5% of it");
        assertApproxEqAbs(STEAKHOUSE.previewRedeem(STEAKHOUSE.balanceOf(address(position))), 10_000 * E6, 2, "principal untouched");

        // Compound, then a few more days, then the holder withdraws through the account.
        _run(SpinPosition.Kind.Manage, MorphoVaultAdapter.Action.In, kept);
        vm.warp(block.timestamp + 3 days);
        uint256 feeBefore = IERC20(USDG).balanceOf(treasury);
        // Half first, then the rest.
        uint256 deployedBefore = position.deployed();
        _asHolder(address(position), 0, abi.encodeCall(SpinPosition.withdraw, (address(steakhouse), 0.5e18, bytes(""))));
        assertEq(position.deployed(), deployedBefore - deployedBefore / 2, "half the cost left with the half");
        // Half of the principal, the compounded interest and 3 more days of it, less the fee.
        assertGt(IERC20(USDG).balanceOf(account), 5_000 * E6, "half back in the account");
        assertLt(IERC20(USDG).balanceOf(account), 5_020 * E6, "and no more than half");
        _asHolder(address(position), 0, abi.encodeCall(SpinPosition.withdraw, (address(steakhouse), 1e18, bytes(""))));
        assertGt(IERC20(USDG).balanceOf(treasury), feeBefore, "the 3 days' gain paid the fee at withdrawal");
        assertGt(IERC20(USDG).balanceOf(account), 10_000 * E6, "principal and interest back in the account");
        assertEq(STEAKHOUSE.balanceOf(address(position)), 0);
        assertGt(account.balance, 0, "the rest of the ETH float back too");
        assertGt(operator.balance, 0, "the operator's gas was refunded");
    }

    function test_sparkSavingsDepositHarvestAndWithdraw() public forked {
        _run(spark, SpinPosition.Kind.Manage, MorphoVaultAdapter.Action.In, 10_000 * E6);
        assertEq(position.venue(), address(spark));
        assertEq(IERC20(USDG).balanceOf(address(position)), 0);

        vm.warp(block.timestamp + 30 days);
        uint256 value = SPARK.previewRedeem(SPARK.balanceOf(address(position)));
        emit log_named_uint("interest over 30 days (USDG, 6 decimals)", value - 10_000 * E6);
        // 3.80% a year is about 31 USDG on 10,000 over 30 days.
        assertGt(value, 10_028 * E6, "the savings rate paid");
        assertLt(value, 10_034 * E6, "at about 3.8% a year");

        _run(spark, SpinPosition.Kind.Harvest, MorphoVaultAdapter.Action.Harvest, 0);
        uint256 fee = IERC20(USDG).balanceOf(treasury);
        assertApproxEqAbs(fee, (value - 10_000 * E6) * 500 / 10_000, 2, "5% of the interest");
        assertApproxEqAbs(SPARK.previewRedeem(SPARK.balanceOf(address(position))), 10_000 * E6, 2, "principal untouched");

        _asHolder(address(position), 0, abi.encodeCall(SpinPosition.withdraw, (address(spark), 1e18, bytes(""))));
        assertEq(SPARK.balanceOf(address(position)), 0);
        assertEq(position.venue(), address(0));
        assertGt(IERC20(USDG).balanceOf(account), 10_000 * E6, "principal and interest back in the account");
    }

    function test_moveBetweenTheTwoStableVenues() public forked {
        _run(steakhouse, SpinPosition.Kind.Manage, MorphoVaultAdapter.Action.In, 10_000 * E6);
        vm.warp(block.timestamp + 10 days);

        // Out of Steakhouse: the gain is realised and pays the fee on the way out.
        _run(steakhouse, SpinPosition.Kind.Manage, MorphoVaultAdapter.Action.Out, 0);
        assertEq(position.venue(), address(0));
        assertEq(position.deployed(), 0);
        assertGt(IERC20(USDG).balanceOf(treasury), 0, "fee on the realised gain");
        uint256 idle = IERC20(USDG).balanceOf(address(position));
        assertGt(idle, 10_000 * E6);

        // Into Spark with all of it.
        _run(spark, SpinPosition.Kind.Manage, MorphoVaultAdapter.Action.In, idle);
        assertEq(position.venue(), address(spark));
        assertEq(position.deployed(), idle);
        assertApproxEqAbs(SPARK.previewRedeem(SPARK.balanceOf(address(position))), idle, 2);
    }
}
