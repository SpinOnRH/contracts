// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {SpinPositions, IERC6551RegistryView} from "../../src/positions/SpinPositions.sol";
import {SpinPosition} from "../../src/positions/SpinPosition.sol";
import {UpStableGaugeAdapter} from "../../src/positions/adapters/UpStableGaugeAdapter.sol";
import {UpGaugeVenue, IUpClPool, IUpGauge, IUpPositionManager} from "../../src/positions/adapters/UpGaugeVenue.sol";
import {WethUsdgVenue, IAggregatorV3, ISwapPool} from "../../src/positions/adapters/WethUsdgVenue.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

interface IRegistryCreateStable {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

interface IAccountExecuteStable {
    function execute(address to, uint256 value, bytes calldata data, uint8 operation) external payable returns (bytes memory);
}

contract StableForkSpinners {
    mapping(uint256 => address) public ownerOf;

    function isActive(uint256) external pure returns (bool) {
        return true;
    }

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }
}

/// Swaps directly in a pool, paying from its own balance: to move a price in a test.
contract StablePoolPusher {
    function push(IUpClPool pool, bool zeroForOne, uint256 amountIn) external {
        pool.swap(address(this), zeroForOne, int256(amountIn), zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341, "");
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        if (a0 > 0) IERC20(IUpClPool(msg.sender).token0()).transfer(msg.sender, uint256(a0));
        if (a1 > 0) IERC20(IUpClPool(msg.sender).token1()).transfer(msg.sender, uint256(a1));
    }
}

/**
 * A Stable LP SpinPosition in UP's aUSD/USDG pool, staked in its gauge, on a
 * fork of Robinhood Chain: the real pool, gauge, position manager, UP/WETH
 * pool, WETH/USDG route and Chainlink feeds, owned by a real Tokenbound
 * account.
 *
 *   RPC_URL=<archive rpc> npm run test
 */
contract UpStableGaugeAdapterFork is Test {
    address constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant UP = 0x57C0E45cB534413D1C20A4240955d6bB250BB4F1;
    address constant AUSD = 0x4f11d7603D1B0D0f021Db552D8A6d88d7fa38ecf;
    IUpClPool constant POOL = IUpClPool(0x29e3F3d9891cAcF213361Bcbcb7728970D53BaA8);
    IUpGauge constant GAUGE = IUpGauge(0x28E041Aa25b0a11D97E6F159A55F60043d479e52);
    IUpPositionManager constant NPM = IUpPositionManager(0x07F44c47743A2f36414A82b9F558ECFCf0EEdCEf);
    IUpClPool constant UP_POOL = IUpClPool(0x23D641FeCcD207E8794c593e8240444A0674C4Ba);
    ISwapPool constant ROUTE_POOL = ISwapPool(0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca);
    IAggregatorV3 constant ETH_USD = IAggregatorV3(0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9);
    IAggregatorV3 constant USDG_USD = IAggregatorV3(0x61B7e5650328764B076A108EFF5fa7282a1B9aD2);
    uint256 constant PINNED_BLOCK = 92_557_000;
    uint256 constant ID = 1;
    uint256 constant E6 = 1e6;
    uint8 constant STABLE_LP = 4;

    SpinPositions positions;
    UpStableGaugeAdapter sv;
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

        StableForkSpinners spinners = new StableForkSpinners();
        spinners.mint(holder, ID);
        account = IRegistryCreateStable(REGISTRY).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), ID);

        positions = new SpinPositions(
            IERC6551RegistryView(REGISTRY), ACCOUNT_V3, address(spinners), USDG, admin, treasury, 500, 1 gwei, 0.001 ether, 110_000, 80_000
        );
        // Peg band 0.5%; ranges ±0.1% to ±1%; UP sales within 300 ticks of a 30-minute average; WETH checked against
        // Chainlink within 1%, feeds at most 25 h old.
        sv = new UpStableGaugeAdapter(
            UpGaugeVenue.Config(POOL, GAUGE, NPM, WETH, USDG, UP, UP_POOL, ROUTE_POOL, ETH_USD, USDG_USD, 100, 25 hours, 20, 200, 1800, 300),
            50
        );
        vm.startPrank(admin);
        positions.setOperator(operator, true);
        positions.setVenue(address(sv), STABLE_LP);
        vm.stopPrank();

        position = positions.create(ID);
        _asHolder(abi.encodeCall(SpinPosition.configure, ((1 << 1) | (1 << STABLE_LP), uint64(block.timestamp + 365 days))));
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
        IAccountExecuteStable(account).execute(address(position), 0, data, 0);
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
        jobs[0] = SpinPositions.Job(ID, kind, address(sv), abi.encode(action, data));
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
        int24 mid = (tick / 10) * 10;
        lower = mid - halfWidth;
        upper = mid + halfWidth;
    }

    /// In and Stake in one run: a ±0.3% range with `amount` USDG, about a fifth of it swapped to aUSD
    /// (the pool's price sits near the top of the range's mix).
    function _enterAndStake(uint256 amount) internal {
        (int24 lower, int24 upper) = _range(30);
        SpinPositions.Job[] memory jobs = new SpinPositions.Job[](2);
        jobs[0] = SpinPositions.Job(ID, SpinPosition.Kind.Manage, address(sv), abi.encode(UpGaugeVenue.Action.In, abi.encode(amount, amount / 2, lower, upper)));
        jobs[1] = SpinPositions.Job(ID, SpinPosition.Kind.Harvest, address(sv), abi.encode(UpGaugeVenue.Action.Stake, bytes("")));
        (bool[] memory ok, bytes memory reason) = _jobs(jobs);
        if (!ok[0] || !ok[1]) emit log_bytes(reason);
        assertTrue(ok[0], "in");
        assertTrue(ok[1], "staked");
    }

    /// Someone sells `amount` aUSD into the pool.
    function _dumpAusd(uint256 amount) internal {
        StablePoolPusher pusher = new StablePoolPusher();
        deal(AUSD, address(pusher), amount);
        pusher.push(POOL, POOL.token0() == AUSD, amount);
    }

    // ── Tests ───────────────────────────────────────────────────────────

    function test_thePoolIsOnPegAtTheFork() public forked {
        emit log_named_uint("USDG per aUSD (18 decimals)", sv.poolPrice());
        assertApproxEqRel(sv.poolPrice(), 1e18, 0.005e18);
        assertEq(sv.other(), AUSD);
    }

    function test_inAndStakeInOneRun() public forked {
        _enterAndStake(10_000 * E6);
        assertEq(GAUGE.stakedLength(address(position)), 1, "staked for the position");
        assertTrue(sv.holds(address(position)));
        assertEq(position.venue(), address(sv));
        assertGt(position.deployed(), 9_000 * E6);
        assertEq(IERC20(USDG).balanceOf(address(sv)) + IERC20(AUSD).balanceOf(address(sv)) + IERC20(UP).balanceOf(address(sv)), 0, "the adapter holds nothing");
        emit log_named_uint("left over USDG (6 decimals)", IERC20(USDG).balanceOf(address(position)));
        emit log_named_uint("left over aUSD (18 decimals)", IERC20(AUSD).balanceOf(address(position)));
    }

    function test_harvestSellsTheEmissionsForUsdg() public forked {
        _enterAndStake(10_000 * E6);
        _warp(1 days);
        uint256 earned = GAUGE.earned(address(position), GAUGE.stakedValues(address(position))[0]);
        emit log_named_uint("UP earned in a day (18 decimals)", earned);
        assertGt(earned, 0, "emissions accrued");
        uint256 idle = IERC20(USDG).balanceOf(address(position));
        (bool ok, bytes memory reason) = _one(SpinPosition.Kind.Harvest, UpGaugeVenue.Action.Harvest, "");
        if (!ok) emit log_bytes(reason);
        assertTrue(ok, "harvested");
        uint256 fee = IERC20(USDG).balanceOf(treasury);
        uint256 kept = IERC20(USDG).balanceOf(address(position)) - idle;
        emit log_named_uint("emissions in a day as USDG (6 decimals)", fee + kept);
        assertGt(fee + kept, 0);
        assertApproxEqAbs(fee, (fee + kept) * 500 / 10_000, 1, "5% of them");
        assertEq(IERC20(UP).balanceOf(address(position)), 0, "all UP sold");
    }

    function test_outTakesItAllBackToUsdg() public forked {
        _enterAndStake(10_000 * E6);
        (bool ok, bytes memory reason) = _one(SpinPosition.Kind.Manage, UpGaugeVenue.Action.Out, "");
        if (!ok) emit log_bytes(reason);
        assertTrue(ok, "out");
        assertFalse(sv.holds(address(position)));
        assertEq(IERC20(AUSD).balanceOf(address(position)) + IERC20(UP).balanceOf(address(position)), 0);
        assertEq(position.venue(), address(0));
        uint256 back = IERC20(USDG).balanceOf(address(position));
        emit log_named_uint("round trip cost (USDG, 6 decimals)", 10_000 * E6 - back);
        assertGt(back, 9_980 * E6);
    }

    function test_theHolderWithdrawsHalfThenTheRest() public forked {
        _enterAndStake(10_000 * E6);
        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(sv), 0.5e18, bytes(""))));
        assertGt(IERC20(USDG).balanceOf(account), 4_980 * E6);
        assertEq(GAUGE.stakedLength(address(position)), 1, "the half that stays is staked again");
        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(sv), 1e18, bytes(""))));
        assertFalse(sv.holds(address(position)));
        assertGt(IERC20(USDG).balanceOf(account), 9_980 * E6);
        assertEq(IERC20(AUSD).balanceOf(account), 0, "all of it as USDG while on peg");
    }

    function test_noNewMoneyGoesInOffPeg() public forked {
        _dumpAusd(400_000e18);
        emit log_named_uint("USDG per aUSD after the dump (18 decimals)", sv.poolPrice());
        (int24 lower, int24 upper) = _range(30);
        (bool ok, bytes memory reason) =
            _one(SpinPosition.Kind.Manage, UpGaugeVenue.Action.In, abi.encode(10_000 * E6, 5_000 * E6, lower, upper));
        assertFalse(ok);
        assertEq(bytes4(reason), UpStableGaugeAdapter.OffPeg.selector);
    }

    function test_inADepegTheHolderStillGetsOutWithTheRestInKind() public forked {
        _enterAndStake(10_000 * E6);
        _dumpAusd(400_000e18);
        assertLt(sv.poolPrice(), 0.995e18, "off peg");

        // The operator cannot sell aUSD off peg ...
        (bool ok, bytes memory reason) = _one(SpinPosition.Kind.Manage, UpGaugeVenue.Action.Out, "");
        assertFalse(ok);
        assertEq(bytes4(reason), UpStableGaugeAdapter.OffPeg.selector);
        // ... nor can a partial withdrawal ...
        vm.prank(holder);
        vm.expectRevert(UpStableGaugeAdapter.OffPeg.selector);
        IAccountExecuteStable(account).execute(address(position), 0, abi.encodeCall(SpinPosition.withdraw, (address(sv), 0.5e18, bytes(""))), 0);

        // ... but the holder's full withdrawal always goes through: the aUSD comes as it is.
        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(sv), 1e18, bytes(""))));
        assertFalse(sv.holds(address(position)));
        assertEq(position.venue(), address(0));
        assertEq(position.lossCarry(), 0, "the book is closed");
        uint256 ausd = IERC20(AUSD).balanceOf(account);
        uint256 usdg = IERC20(USDG).balanceOf(account);
        emit log_named_uint("aUSD to the holder (18 decimals)", ausd);
        emit log_named_uint("USDG to the holder (6 decimals)", usdg);
        assertGt(ausd, 0, "aUSD in kind");
        assertGt(ausd / 1e12 + usdg, 9_900 * E6, "everything is there, in one token or the other");
        assertEq(IERC20(AUSD).balanceOf(address(position)) + IERC20(AUSD).balanceOf(address(sv)), 0, "nothing stuck");
    }

    function test_withAStaleFeedTheHolderGetsTheUpInKind() public forked {
        _enterAndStake(10_000 * E6);
        vm.warp(block.timestamp + 2 days); // the feeds are now older than 25 h
        (bool ok, bytes memory reason) = _one(SpinPosition.Kind.Harvest, UpGaugeVenue.Action.Harvest, "");
        assertFalse(ok);
        assertEq(bytes4(reason), WethUsdgVenue.StaleFeed.selector);

        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(sv), 1e18, bytes(""))));
        assertFalse(sv.holds(address(position)));
        assertGt(IERC20(UP).balanceOf(account), 0, "the rewards as UP");
        assertGt(IERC20(USDG).balanceOf(account), 9_980 * E6, "the pool's tokens as USDG: the peg needs no feed");
        assertEq(IERC20(UP).balanceOf(address(position)) + IERC20(UP).balanceOf(address(sv)), 0, "nothing stuck");
    }

    function test_aHarvestCannotExit() public forked {
        _enterAndStake(10_000 * E6);
        (bool ok, bytes memory reason) = _one(SpinPosition.Kind.Harvest, UpGaugeVenue.Action.Out, "");
        assertFalse(ok);
        assertEq(bytes4(reason), UpGaugeVenue.WrongKind.selector);
    }

    function test_onlyAListedClassCanUseIt() public forked {
        _asHolder(abi.encodeCall(SpinPosition.configure, (1 << 1, uint64(block.timestamp + 365 days))));
        (int24 lower, int24 upper) = _range(30);
        (bool ok, bytes memory reason) =
            _one(SpinPosition.Kind.Manage, UpGaugeVenue.Action.In, abi.encode(10_000 * E6, 5_000 * E6, lower, upper));
        assertFalse(ok);
        assertEq(bytes4(reason), SpinPosition.ClassNotAllowed.selector);
    }
}
