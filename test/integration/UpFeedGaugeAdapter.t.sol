// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {SpinPositions, IERC6551RegistryView} from "../../src/positions/SpinPositions.sol";
import {SpinPosition} from "../../src/positions/SpinPosition.sol";
import {UpFeedGaugeAdapter} from "../../src/positions/adapters/UpFeedGaugeAdapter.sol";
import {UpGaugeVenue, IUpClPool, IUpGauge, IUpPositionManager} from "../../src/positions/adapters/UpGaugeVenue.sol";
import {WethUsdgVenue, IAggregatorV3, ISwapPool} from "../../src/positions/adapters/WethUsdgVenue.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

interface IRegistryCreateFeed {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

interface IAccountExecuteFeed {
    function execute(address to, uint256 value, bytes calldata data, uint8 operation) external payable returns (bytes memory);
}

contract FeedForkSpinners {
    mapping(uint256 => address) public ownerOf;

    function isActive(uint256) external pure returns (bool) {
        return true;
    }

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }
}

/// Swaps directly in a pool, paying from its own balance: to move a price in a test.
contract FeedPoolPusher {
    function push(IUpClPool pool, bool zeroForOne, uint256 amountIn) external {
        pool.swap(address(this), zeroForOne, int256(amountIn), zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341, "");
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        if (a0 > 0) IERC20(IUpClPool(msg.sender).token0()).transfer(msg.sender, uint256(a0));
        if (a1 > 0) IERC20(IUpClPool(msg.sender).token1()).transfer(msg.sender, uint256(a1));
    }
}

/**
 * An Active SpinPosition in UP's USDG/NVDA pool (Robinhood's tokenized NVDA),
 * staked in its gauge, on a fork of Robinhood Chain: the real pool, gauge,
 * position manager, UP/WETH pool, WETH/USDG route and Chainlink feeds
 * (NVDA/USD, ETH/USD, USDG/USD), owned by a real Tokenbound account.
 *
 *   RPC_URL=<archive rpc> npm run test
 */
contract UpFeedGaugeAdapterFork is Test {
    address constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant UP = 0x57C0E45cB534413D1C20A4240955d6bB250BB4F1;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    IUpClPool constant POOL = IUpClPool(0x18A5aF4E442F8be68968Cc1f00D537F8af2D12Cd);
    IUpGauge constant GAUGE = IUpGauge(0xCeE5D9356415A28407F723b1F5837F79de7D67EC);
    IUpPositionManager constant NPM = IUpPositionManager(0x07F44c47743A2f36414A82b9F558ECFCf0EEdCEf);
    IUpClPool constant UP_POOL = IUpClPool(0x23D641FeCcD207E8794c593e8240444A0674C4Ba);
    ISwapPool constant ROUTE_POOL = ISwapPool(0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca);
    IAggregatorV3 constant NVDA_USD = IAggregatorV3(0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15);
    IAggregatorV3 constant ETH_USD = IAggregatorV3(0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9);
    IAggregatorV3 constant USDG_USD = IAggregatorV3(0x61B7e5650328764B076A108EFF5fa7282a1B9aD2);
    uint256 constant PINNED_BLOCK = 92_557_000;
    uint256 constant ID = 1;
    uint256 constant E6 = 1e6;
    uint8 constant ACTIVE = 3;

    SpinPositions positions;
    UpFeedGaugeAdapter fv;
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

        FeedForkSpinners spinners = new FeedForkSpinners();
        spinners.mint(holder, ID);
        account = IRegistryCreateFeed(REGISTRY).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), ID);

        positions = new SpinPositions(
            IERC6551RegistryView(REGISTRY), ACCOUNT_V3, address(spinners), USDG, admin, treasury, 500, 1 gwei, 0.001 ether, 110_000, 80_000
        );
        // 1% band around Chainlink; ETH and USDG feeds at most 25 h old, the NVDA feed (24/5) at most 80 h (a long
        // weekend); ranges ±1.2% to ±120%; UP sales within 300 ticks of a 30-minute average.
        fv = new UpFeedGaugeAdapter(
            UpGaugeVenue.Config(POOL, GAUGE, NPM, WETH, USDG, UP, UP_POOL, ROUTE_POOL, ETH_USD, USDG_USD, 100, 25 hours, 240, 15_000, 1800, 300),
            NVDA_USD,
            80 hours
        );
        vm.startPrank(admin);
        positions.setOperator(operator, true);
        positions.setVenue(address(fv), ACTIVE);
        vm.stopPrank();

        position = positions.create(ID);
        _asHolder(abi.encodeCall(SpinPosition.configure, ((1 << 1) | (1 << 2) | (1 << ACTIVE), uint64(block.timestamp + 365 days))));
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
        IAccountExecuteFeed(account).execute(address(position), 0, data, 0);
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
        jobs[0] = SpinPositions.Job(ID, kind, address(fv), abi.encode(action, data));
        bool[] memory oks;
        (oks, reason) = _jobs(jobs);
        ok = oks[0];
    }

    /// Moves time on, and keeps the last answers of `feeds` fresh (a fork gets no new rounds).
    function _warp(uint256 by, IAggregatorV3[] memory feeds) internal {
        vm.warp(block.timestamp + by);
        for (uint256 i; i < feeds.length; i++) {
            (uint80 round, int256 answer,,, uint80 answered) = feeds[i].latestRoundData();
            vm.mockCall(
                address(feeds[i]),
                abi.encodeCall(IAggregatorV3.latestRoundData, ()),
                abi.encode(round, answer, block.timestamp, block.timestamp, answered)
            );
        }
    }

    function _allFeeds() internal pure returns (IAggregatorV3[] memory f) {
        f = new IAggregatorV3[](3);
        f[0] = ETH_USD;
        f[1] = USDG_USD;
        f[2] = NVDA_USD;
    }

    function _range(int24 halfWidth) internal view returns (int24 lower, int24 upper) {
        (, int24 tick,,,,) = POOL.slot0();
        int24 mid = (tick / 60) * 60;
        lower = mid - halfWidth;
        upper = mid + halfWidth;
    }

    /// In and Stake in one run: a ±5% range with `amount` USDG, half of it swapped to NVDA.
    function _enterAndStake(uint256 amount) internal {
        (int24 lower, int24 upper) = _range(480);
        SpinPositions.Job[] memory jobs = new SpinPositions.Job[](2);
        jobs[0] = SpinPositions.Job(ID, SpinPosition.Kind.Manage, address(fv), abi.encode(UpGaugeVenue.Action.In, abi.encode(amount, amount / 2, lower, upper)));
        jobs[1] = SpinPositions.Job(ID, SpinPosition.Kind.Harvest, address(fv), abi.encode(UpGaugeVenue.Action.Stake, bytes("")));
        (bool[] memory ok, bytes memory reason) = _jobs(jobs);
        if (!ok[0] || !ok[1]) emit log_bytes(reason);
        assertTrue(ok[0], "in");
        assertTrue(ok[1], "staked");
    }

    // ── Tests ───────────────────────────────────────────────────────────

    function test_thePoolTracksTheFeed() public forked {
        (, int256 answer,,,) = NVDA_USD.latestRoundData();
        emit log_named_uint("pool: USDG per NVDA (18 decimals)", fv.poolPrice());
        emit log_named_int("Chainlink NVDA / USD (8 decimals)", answer);
        assertApproxEqRel(fv.poolPrice(), uint256(answer) * 1e10, 0.01e18);
        assertEq(fv.other(), NVDA);
    }

    function test_inAndStakeInOneRun() public forked {
        _enterAndStake(10_000 * E6);
        assertEq(GAUGE.stakedLength(address(position)), 1);
        assertTrue(fv.holds(address(position)));
        assertGt(position.deployed(), 9_000 * E6);
        assertEq(IERC20(USDG).balanceOf(address(fv)) + IERC20(NVDA).balanceOf(address(fv)) + IERC20(UP).balanceOf(address(fv)), 0, "the adapter holds nothing");
    }

    function test_harvestSellsTheEmissionsForUsdg() public forked {
        _enterAndStake(10_000 * E6);
        _warp(1 days, _allFeeds());
        uint256 earned = GAUGE.earned(address(position), GAUGE.stakedValues(address(position))[0]);
        emit log_named_uint("UP earned in a day (18 decimals)", earned);
        uint256 idle = IERC20(USDG).balanceOf(address(position));
        (bool ok, bytes memory reason) = _one(SpinPosition.Kind.Harvest, UpGaugeVenue.Action.Harvest, "");
        if (!ok) emit log_bytes(reason);
        assertTrue(ok, "harvested");
        uint256 fee = IERC20(USDG).balanceOf(treasury);
        uint256 kept = IERC20(USDG).balanceOf(address(position)) - idle;
        emit log_named_uint("emissions in a day as USDG (6 decimals)", fee + kept);
        assertGt(fee + kept, 0);
        assertApproxEqAbs(fee, (fee + kept) * 500 / 10_000, 1, "5% of them");
    }

    function test_outTakesItAllBackToUsdg() public forked {
        _enterAndStake(10_000 * E6);
        (bool ok, bytes memory reason) = _one(SpinPosition.Kind.Manage, UpGaugeVenue.Action.Out, "");
        if (!ok) emit log_bytes(reason);
        assertTrue(ok, "out");
        assertFalse(fv.holds(address(position)));
        assertEq(IERC20(NVDA).balanceOf(address(position)), 0);
        uint256 back = IERC20(USDG).balanceOf(address(position));
        emit log_named_uint("round trip cost (USDG, 6 decimals)", 10_000 * E6 - back);
        assertGt(back, 9_950 * E6);
    }

    function test_theHolderWithdrawsHalfThenTheRest() public forked {
        _enterAndStake(10_000 * E6);
        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(fv), 0.5e18, bytes(""))));
        assertGt(IERC20(USDG).balanceOf(account), 4_950 * E6);
        assertEq(GAUGE.stakedLength(address(position)), 1, "the half that stays is staked again");
        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(fv), 1e18, bytes(""))));
        assertFalse(fv.holds(address(position)));
        assertGt(IERC20(USDG).balanceOf(account), 9_950 * E6);
        assertEq(IERC20(NVDA).balanceOf(account), 0, "all of it as USDG");
    }

    function test_aMovedPoolPriceIsRefused() public forked {
        // Someone buys NVDA in this pool until its price is well above Chainlink.
        FeedPoolPusher pusher = new FeedPoolPusher();
        deal(USDG, address(pusher), 200_000 * E6);
        pusher.push(POOL, POOL.token0() == USDG, 200_000 * E6);
        emit log_named_uint("pool after the push: USDG per NVDA", fv.poolPrice());
        (int24 lower, int24 upper) = _range(480);
        (bool ok, bytes memory reason) =
            _one(SpinPosition.Kind.Manage, UpGaugeVenue.Action.In, abi.encode(10_000 * E6, 5_000 * E6, lower, upper));
        assertFalse(ok);
        assertEq(bytes4(reason), WethUsdgVenue.PriceOff.selector);
    }

    /// The ETH and USDG feeds keep updating; the NVDA feed (24/5) keeps its Friday price for `by`.
    function _closedMarket(uint256 by) internal {
        IAggregatorV3[] memory live = new IAggregatorV3[](2);
        live[0] = ETH_USD;
        live[1] = USDG_USD;
        _warp(by, live);
    }

    function test_overAWeekendTheVenueStillActsWhileThePoolStaysNearTheLastPrice() public forked {
        _enterAndStake(10_000 * E6);
        _closedMarket(54 hours); // Friday 18:21 UTC to Monday 00:12 UTC, as on 16-19 October 2026
        (bool ok,) = _one(SpinPosition.Kind.Harvest, UpGaugeVenue.Action.Harvest, "");
        assertTrue(ok, "harvest at the weekend");
        (bool out, bytes memory reason) = _one(SpinPosition.Kind.Manage, UpGaugeVenue.Action.Out, "");
        if (!out) emit log_bytes(reason);
        assertTrue(out, "the worker can still move the balance out at the weekend");
        assertGt(IERC20(USDG).balanceOf(address(position)), 9_950 * E6);
    }

    function test_overAWeekendAPoolThatMovedAwayFromTheLastPriceWaitsForMonday() public forked {
        _enterAndStake(10_000 * E6);
        _closedMarket(30 hours);
        // Weekend trading takes the pool more than 1% away from Friday's price.
        FeedPoolPusher pusher = new FeedPoolPusher();
        deal(USDG, address(pusher), 30_000 * E6);
        pusher.push(POOL, POOL.token0() == USDG, 30_000 * E6);
        emit log_named_uint("pool: USDG per NVDA", fv.poolPrice());
        (bool ok, bytes memory reason) = _one(SpinPosition.Kind.Manage, UpGaugeVenue.Action.Out, "");
        assertFalse(ok);
        assertEq(bytes4(reason), WethUsdgVenue.PriceOff.selector);
    }

    function test_pastTheLimitTheVenueWaitsAndTheHolderStillGetsOut() public forked {
        _enterAndStake(10_000 * E6);
        _closedMarket(4 days); // longer than any market closure: something is wrong with the feed
        (bool ok, bytes memory reason) = _one(SpinPosition.Kind.Manage, UpGaugeVenue.Action.Out, "");
        assertFalse(ok);
        assertEq(bytes4(reason), WethUsdgVenue.StaleFeed.selector);
        (ok,) = _one(SpinPosition.Kind.Harvest, UpGaugeVenue.Action.Harvest, "");
        assertTrue(ok, "the rewards can still be sold: they need only the UP and ETH prices");

        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(fv), 1e18, bytes(""))));
        assertFalse(fv.holds(address(position)));
        uint256 nvda = IERC20(NVDA).balanceOf(account);
        emit log_named_uint("NVDA to the holder (18 decimals)", nvda);
        assertGt(nvda, 0, "the NVDA in kind");
        assertEq(IERC20(NVDA).balanceOf(address(position)) + IERC20(NVDA).balanceOf(address(fv)), 0, "nothing stuck");
    }

    function test_aHarvestCannotExit() public forked {
        _enterAndStake(10_000 * E6);
        (bool ok, bytes memory reason) = _one(SpinPosition.Kind.Harvest, UpGaugeVenue.Action.Out, "");
        assertFalse(ok);
        assertEq(bytes4(reason), UpGaugeVenue.WrongKind.selector);
    }
}
