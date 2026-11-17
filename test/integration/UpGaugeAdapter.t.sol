// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {SpinPositions, IERC6551RegistryView} from "../../src/positions/SpinPositions.sol";
import {SpinPosition} from "../../src/positions/SpinPosition.sol";
import {UpGaugeAdapter} from "../../src/positions/adapters/UpGaugeAdapter.sol";
import {UpGaugeVenue, IUpClPool, IUpGauge, IUpPositionManager} from "../../src/positions/adapters/UpGaugeVenue.sol";
import {WethUsdgVenue, IAggregatorV3, ISwapPool} from "../../src/positions/adapters/WethUsdgVenue.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

interface IRegistryCreateUp {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

interface IAccountExecuteUp {
    function execute(address to, uint256 value, bytes calldata data, uint8 operation) external payable returns (bytes memory);
}

contract UpForkSpinners {
    mapping(uint256 => address) public ownerOf;

    function isActive(uint256) external pure returns (bool) {
        return true;
    }

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }
}

/// Swaps directly in a pool, paying from its own balance: to move a price in a test.
contract PoolPusher {
    function push(IUpClPool pool, bool zeroForOne, uint256 amountIn) external {
        pool.swap(address(this), zeroForOne, int256(amountIn), zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341, "");
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        if (a0 > 0) IERC20(IUpClPool(msg.sender).token0()).transfer(msg.sender, uint256(a0));
        if (a1 > 0) IERC20(IUpClPool(msg.sender).token1()).transfer(msg.sender, uint256(a1));
    }
}

/**
 * An Active SpinPosition in UP's WETH/USDG concentrated pool, staked in its
 * gauge, on a fork of Robinhood Chain: the real pool, gauge, position manager,
 * UP/WETH pool and Chainlink feeds, owned by a real Tokenbound account.
 *
 *   RPC_URL=<archive rpc> npm run test
 */
contract UpGaugeAdapterFork is Test {
    address constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant UP = 0x57C0E45cB534413D1C20A4240955d6bB250BB4F1;
    IUpClPool constant POOL = IUpClPool(0x16679e2ac1A798865eCf1c1639e67693ddB1C220);
    IUpGauge constant GAUGE = IUpGauge(0xC39791dF403a77E8Fb0f614d60eD96f790b69343);
    IUpPositionManager constant NPM = IUpPositionManager(0x07F44c47743A2f36414A82b9F558ECFCf0EEdCEf);
    // The deepest WETH/USDG pool (Uniswap V3 0.01%), where WETH is bought and sold.
    ISwapPool constant ROUTE_POOL = ISwapPool(0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca);
    IUpClPool constant UP_POOL = IUpClPool(0x23D641FeCcD207E8794c593e8240444A0674C4Ba);
    IAggregatorV3 constant ETH_USD = IAggregatorV3(0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9);
    IAggregatorV3 constant USDG_USD = IAggregatorV3(0x61B7e5650328764B076A108EFF5fa7282a1B9aD2);
    uint256 constant PINNED_BLOCK = 92_557_000;
    uint256 constant ID = 1;
    uint256 constant E6 = 1e6;

    SpinPositions positions;
    UpGaugeAdapter upv;
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

        UpForkSpinners spinners = new UpForkSpinners();
        spinners.mint(holder, ID);
        account = IRegistryCreateUp(REGISTRY).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), ID);

        positions = new SpinPositions(
            IERC6551RegistryView(REGISTRY), ACCOUNT_V3, address(spinners), USDG, admin, treasury, 500, 1 gwei, 0.001 ether, 110_000, 80_000
        );
        // 1% band around Chainlink, feeds at most 25 h old, ranges ±1% to ±100%; UP sales within 300 ticks (~3%) of a 30-minute average.
        upv = new UpGaugeAdapter(
            UpGaugeVenue.Config(
                POOL, GAUGE, NPM, WETH, USDG, UP, UP_POOL, ROUTE_POOL, ETH_USD, USDG_USD, 100, 25 hours, 200, 14_000, 1800, 300
            )
        );
        vm.startPrank(admin);
        positions.setOperator(operator, true);
        positions.setVenue(address(upv), 3);
        vm.stopPrank();

        position = positions.create(ID);
        _asHolder(abi.encodeCall(SpinPosition.configure, ((1 << 1) | (1 << 2) | (1 << 3), uint64(block.timestamp + 365 days))));
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

    // ── Helpers ─────────────────────────────────────────────────────────

    function _asHolder(bytes memory data) internal {
        vm.prank(holder);
        IAccountExecuteUp(account).execute(address(position), 0, data, 0);
    }

    function _jobs(SpinPositions.Job[] memory jobs) internal returns (bool[] memory ok, bytes memory lastReason) {
        vm.recordLogs();
        vm.prank(operator);
        ok = positions.run(jobs);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 failed = keccak256("JobFailed(uint256,uint256,bytes)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == failed) (, lastReason) = abi.decode(logs[i].data, (uint256, bytes));
        }
    }

    function _one(SpinPosition.Kind kind, UpGaugeVenue.Action action, bytes memory data) internal returns (bool ok, bytes memory reason) {
        SpinPositions.Job[] memory jobs = new SpinPositions.Job[](1);
        jobs[0] = SpinPositions.Job(ID, kind, address(upv), abi.encode(action, data));
        bool[] memory oks;
        (oks, reason) = _jobs(jobs);
        ok = oks[0];
    }

    /// Moves time on, and keeps the Chainlink feeds' last answers fresh (a fork gets no new rounds).
    function _warp(uint256 by) internal {
        vm.warp(block.timestamp + by);
        IAggregatorV3[2] memory feeds = [ETH_USD, USDG_USD];
        for (uint256 i; i < 2; i++) {
            (uint80 round, int256 answer,,, uint80 answered) = feeds[i].latestRoundData();
            vm.mockCall(
                address(feeds[i]),
                abi.encodeCall(IAggregatorV3.latestRoundData, ()),
                abi.encode(round, answer, block.timestamp, block.timestamp, answered)
            );
        }
    }

    function _range(int24 halfWidth) internal view returns (int24 lower, int24 upper) {
        (, int24 tick,,,,) = POOL.slot0();
        int24 spacing = POOL.tickSpacing();
        int24 mid = (tick / spacing) * spacing;
        lower = mid - halfWidth;
        upper = mid + halfWidth;
    }

    /// In and Stake in one run, as the worker sends them: a ±2% range with `amount` USDG.
    function _enterAndStake(uint256 amount) internal {
        (int24 lower, int24 upper) = _range(200);
        SpinPositions.Job[] memory jobs = new SpinPositions.Job[](2);
        jobs[0] = SpinPositions.Job(ID, SpinPosition.Kind.Manage, address(upv), abi.encode(UpGaugeVenue.Action.In, abi.encode(amount, amount / 2, lower, upper)));
        jobs[1] = SpinPositions.Job(ID, SpinPosition.Kind.Harvest, address(upv), abi.encode(UpGaugeVenue.Action.Stake, bytes("")));
        (bool[] memory ok, bytes memory reason) = _jobs(jobs);
        if (!ok[0] || !ok[1]) emit log_bytes(reason);
        assertTrue(ok[0], "in");
        assertTrue(ok[1], "staked");
    }

    // ── Tests ───────────────────────────────────────────────────────────

    function test_inAndStakeInOneRun() public forked {
        _enterAndStake(10_000 * E6);
        assertEq(GAUGE.stakedLength(address(position)), 1, "staked for the position");
        assertEq(NPM.balanceOf(address(position)), 0, "the gauge holds the NFT");
        assertTrue(upv.holds(address(position)));
        assertGt(position.deployed(), 9_900 * E6);
        assertEq(IERC20(USDG).balanceOf(address(upv)) + IERC20(WETH).balanceOf(address(upv)) + IERC20(UP).balanceOf(address(upv)), 0, "the adapter holds nothing");
    }

    function test_harvestSellsTheEmissionsForUsdg() public forked {
        _enterAndStake(10_000 * E6);
        _warp(1 days);
        uint256 earned = GAUGE.earned(address(position), GAUGE.stakedValues(address(position))[0]);
        emit log_named_uint("UP earned in a day (18 decimals)", earned);
        assertGt(earned, 0, "emissions accrued");
        (bool ok, bytes memory reason) = _one(SpinPosition.Kind.Harvest, UpGaugeVenue.Action.Harvest, "");
        if (!ok) emit log_bytes(reason);
        assertTrue(ok, "harvested");
        uint256 fee = IERC20(USDG).balanceOf(treasury);
        uint256 kept = IERC20(USDG).balanceOf(address(position));
        emit log_named_uint("emissions in a day as USDG (6 decimals)", fee + kept);
        assertGt(fee + kept, 0);
        assertApproxEqAbs(fee, (fee + kept) * 500 / 10_000, 1, "5% of them");
        assertEq(IERC20(UP).balanceOf(address(position)), 0, "all UP sold");
        assertEq(GAUGE.stakedLength(address(position)), 1, "still staked");
    }

    function test_compoundingWhileStakedStaysStaked() public forked {
        _enterAndStake(5_000 * E6);
        (int24 lower, int24 upper) = _range(200);
        (bool ok, bytes memory reason) = _one(SpinPosition.Kind.Manage, UpGaugeVenue.Action.In, abi.encode(5_000 * E6, 2_500 * E6, lower, upper));
        if (!ok) emit log_bytes(reason);
        assertTrue(ok, "added");
        assertEq(GAUGE.stakedLength(address(position)), 1, "staked again");
        assertGt(position.deployed(), 9_900 * E6);
    }

    function test_outTakesItAllBackToUsdg() public forked {
        _enterAndStake(10_000 * E6);
        _warp(1 hours);
        (bool ok, bytes memory reason) = _one(SpinPosition.Kind.Manage, UpGaugeVenue.Action.Out, "");
        if (!ok) emit log_bytes(reason);
        assertTrue(ok, "out");
        assertFalse(upv.holds(address(position)), "nothing left in the venue");
        assertEq(IERC20(WETH).balanceOf(address(position)) + IERC20(UP).balanceOf(address(position)), 0);
        assertEq(position.venue(), address(0));
        emit log_named_uint("USDG back after an hour (6 decimals)", IERC20(USDG).balanceOf(address(position)));
        assertGt(IERC20(USDG).balanceOf(address(position)), 9_950 * E6);
    }

    function test_anNftSentByAStrangerIsIgnored() public forked {
        // Before the position enters, a stranger mints a dust range in the same pool (below the
        // price: USDG only) and sends it to the SpinPosition.
        address stranger = makeAddr("stranger");
        (int24 lower,) = _range(200);
        deal(USDG, stranger, 10 * E6);
        vm.startPrank(stranger);
        IERC20(USDG).approve(address(NPM), 10 * E6);
        (uint256 dust,,,) = NPM.mint(
            IUpPositionManager.MintParams(
                POOL.token0(), POOL.token1(), POOL.tickSpacing(), lower - 400, lower, 0, 10 * E6, 0, 0, stranger, block.timestamp, 0
            )
        );
        (bool sent,) = address(NPM).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", stranger, address(position), dust));
        vm.stopPrank();
        assertTrue(sent);
        assertFalse(upv.holds(address(position)), "not the adapter's NFT");

        _enterAndStake(10_000 * E6);
        assertEq(GAUGE.stakedValues(address(position))[0], upv.tokenOf(address(position)), "the adapter staked its own NFT");
        assertEq(NPM.ownerOf(dust), address(position), "the stranger's NFT is left alone");

        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(upv), 1e18, bytes(""))));
        assertFalse(upv.holds(address(position)));
        assertEq(position.venue(), address(0));
        assertGt(IERC20(USDG).balanceOf(account), 9_900 * E6);
    }

    function test_theHolderWithdrawsHalfAndTheRestStaysStaked() public forked {
        _enterAndStake(10_000 * E6);
        uint256 cost = position.deployed();
        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(upv), 0.5e18, bytes(""))));
        assertEq(position.deployed(), cost - cost / 2);
        assertGt(IERC20(USDG).balanceOf(account), 4_950 * E6);
        assertEq(GAUGE.stakedLength(address(position)), 1, "the half that stays is staked again");
    }

    function test_aMovedUpPriceStopsTheSale() public forked {
        _enterAndStake(10_000 * E6);
        _warp(1 days);
        // Someone dumps UP into its pool just before the harvest.
        PoolPusher pusher = new PoolPusher();
        deal(UP, address(pusher), 2_000_000e18);
        pusher.push(UP_POOL, UP_POOL.token0() == UP, 2_000_000e18);
        (bool ok, bytes memory reason) = _one(SpinPosition.Kind.Harvest, UpGaugeVenue.Action.Harvest, "");
        assertFalse(ok);
        assertEq(bytes4(reason), WethUsdgVenue.PriceOff.selector);
    }

    /// Regression: UP sent to a staked position (here 100,000, about $26k) made
    /// every exit sell more UP than its pool could take within the band, so every withdrawal reverted.
    function test_aFullWithdrawalKeepsUpItCannotSellAndPaysTheOwnerTheRest() public forked {
        _enterAndStake(10_000 * E6);
        deal(UP, address(this), 100_000e18);
        IERC20(UP).transfer(address(position), 100_000e18);
        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(upv), 1e18, bytes(""))));
        assertFalse(upv.holds(address(position)), "the range is closed");
        assertEq(position.venue(), address(0));
        // The UP counts at its value: a gain, whose 5% fee is paid in USDG first.
        assertGt(IERC20(USDG).balanceOf(account) + IERC20(USDG).balanceOf(treasury), 9_900 * E6, "the USDG came back");
        assertGt(IERC20(USDG).balanceOf(treasury), 0, "the fee on the UP's value");
        assertGt(IERC20(UP).balanceOf(account), 90_000e18, "and the UP it could not sell, unsold");
        assertEq(IERC20(UP).balanceOf(address(upv)), 0, "the adapter holds nothing");
    }

    function test_onlyTheAdapterSellsUpThroughItsUndoableSale() public forked {
        vm.expectRevert(WethUsdgVenue.NotSelf.selector);
        upv.sellUpHere(1);
    }

    function test_aHarvestCannotExit() public forked {
        _enterAndStake(10_000 * E6);
        (bool ok, bytes memory reason) = _one(SpinPosition.Kind.Harvest, UpGaugeVenue.Action.Out, "");
        assertFalse(ok);
        assertEq(bytes4(reason), UpGaugeVenue.WrongKind.selector);
    }
}
