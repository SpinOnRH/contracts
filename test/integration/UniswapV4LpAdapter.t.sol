// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {SpinPositions, IERC6551RegistryView} from "../../src/positions/SpinPositions.sol";
import {SpinPosition} from "../../src/positions/SpinPosition.sol";
import {
    UniswapV4LpAdapter,
    PoolKey,
    IPositionManagerV4,
    IStateView,
    IWETH9
} from "../../src/positions/adapters/UniswapV4LpAdapter.sol";
import {WethUsdgVenue, ISwapPool, IAggregatorV3} from "../../src/positions/adapters/WethUsdgVenue.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManagerSwap {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 delta);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

/// Swaps exact-in through one V4 pool, paying in native ETH or USDG.
contract V4Swapper {
    IPoolManagerSwap immutable pm;
    PoolKey key;

    constructor(IPoolManagerSwap pm_, PoolKey memory key_) {
        pm = pm_;
        key = key_;
    }

    receive() external payable {}

    function swap(bool ethIn, uint256 amountIn) external payable {
        pm.unlock(abi.encode(ethIn, amountIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool ethIn, uint256 amountIn) = abi.decode(data, (bool, uint256));
        int256 delta = pm.swap(
            key,
            SwapParams(ethIn, -int256(amountIn), ethIn ? 4295128740 : 1461446703485210103287273052203988822378723970341),
            ""
        );
        int128 d0 = int128(delta >> 128);
        int128 d1 = int128(delta);
        if (ethIn) {
            pm.settle{value: uint256(uint128(-d0))}();
            pm.take(key.currency1, address(this), uint256(uint128(d1)));
        } else {
            pm.sync(key.currency1);
            IERC20(key.currency1).transfer(address(pm), uint256(uint128(-d1)));
            pm.settle();
            pm.take(address(0), address(this), uint256(uint128(d0)));
        }
        return "";
    }
}

interface IRegistryCreateV4 {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

interface IAccountExecuteV4 {
    function execute(address to, uint256 value, bytes calldata data, uint8 operation) external payable returns (bytes memory);
}

contract V4ForkSpinners {
    mapping(uint256 => address) public ownerOf;

    function isActive(uint256) external pure returns (bool) {
        return true;
    }

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }
}

/**
 * A Balanced SpinPosition in the Fables ETH/USDG Uniswap V4 pool on a fork of
 * Robinhood Chain: the real pool, hook, PositionManager and Chainlink feeds,
 * swaps routed through the V3 WETH/USDG 0.01% pool, owned by a real
 * Tokenbound account.
 *
 *   RPC_URL=<archive rpc> npm run test
 */
contract UniswapV4LpAdapterFork is Test {
    address constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant FABLES_HOOK = 0x06a889870C8f83640D6816319f72e2aA579b6080;
    IPositionManagerV4 constant POSM = IPositionManagerV4(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    IPoolManagerSwap constant PM = IPoolManagerSwap(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IStateView constant STATE_VIEW = IStateView(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b);
    ISwapPool constant ROUTE_POOL = ISwapPool(0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca);
    IAggregatorV3 constant ETH_USD = IAggregatorV3(0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9);
    IAggregatorV3 constant USDG_USD = IAggregatorV3(0x61B7e5650328764B076A108EFF5fa7282a1B9aD2);
    uint256 constant PINNED_BLOCK = 92_557_000;
    uint256 constant ID = 1;
    uint256 constant E6 = 1e6;

    SpinPositions positions;
    UniswapV4LpAdapter lp;
    SpinPosition position;
    V4Swapper swapper;
    PoolKey key;
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

        V4ForkSpinners spinners = new V4ForkSpinners();
        spinners.mint(holder, ID);
        account = IRegistryCreateV4(REGISTRY).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), ID);

        positions = new SpinPositions(
            IERC6551RegistryView(REGISTRY), ACCOUNT_V3, address(spinners), USDG, admin, treasury, 500, 1 gwei, 0.001 ether, 110_000, 80_000
        );
        key = PoolKey(address(0), USDG, 0x800000, 10, FABLES_HOOK);
        // 1% band around Chainlink, feeds at most 25 hours old, ranges from ±1% to ±100%.
        lp = new UniswapV4LpAdapter(key, POSM, STATE_VIEW, ROUTE_POOL, WETH, USDG, ETH_USD, USDG_USD, 100, 25 hours, 200, 14_000);
        vm.startPrank(admin);
        positions.setOperator(operator, true);
        positions.setVenue(address(lp), 2);
        vm.stopPrank();

        position = positions.create(ID);
        _asHolder(abi.encodeCall(SpinPosition.configure, ((1 << 1) | (1 << 2), uint64(block.timestamp + 365 days))));
        deal(USDG, address(position), 10_000 * E6);
        vm.deal(address(position), 0.002 ether);
        swapper = new V4Swapper(PM, key);
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
        IAccountExecuteV4(account).execute(address(position), 0, data, 0);
    }

    function _job(SpinPosition.Kind kind, UniswapV4LpAdapter.Action action, bytes memory data) internal returns (bool ok, bytes memory reason) {
        SpinPositions.Job[] memory jobs = new SpinPositions.Job[](1);
        jobs[0] = SpinPositions.Job(ID, kind, address(lp), abi.encode(action, data));
        vm.recordLogs();
        vm.prank(operator);
        ok = positions.run(jobs)[0];
        if (!ok) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            (, reason) = abi.decode(logs[logs.length - 1].data, (uint256, bytes));
        }
    }

    /// A range of ±`halfWidth` ticks around the pool's current tick.
    function _range(int24 halfWidth) internal view returns (int24 lower, int24 upper) {
        (, int24 tick,,) = STATE_VIEW.getSlot0(lp.poolId());
        int24 mid = (tick / 10) * 10;
        lower = mid - halfWidth;
        upper = mid + halfWidth;
    }

    function _in(uint256 amount, uint256 swapAmount, int24 halfWidth) internal returns (bool ok, bytes memory reason) {
        (int24 lower, int24 upper) = _range(halfWidth);
        return _job(SpinPosition.Kind.Manage, UniswapV4LpAdapter.Action.In, abi.encode(amount, swapAmount, lower, upper));
    }

    /// Opens a ±10% range with 10,000 USDG, about half of it swapped to ETH.
    function _enter() internal {
        (bool ok, bytes memory reason) = _in(10_000 * E6, 5_000 * E6, 1_000);
        if (!ok) emit log_bytes(reason);
        assertTrue(ok, "entered");
    }

    /// Trades through the Fables pool both ways: `rounds` round trips of `usdgSize`.
    function _trade(uint256 rounds, uint256 usdgSize) internal {
        deal(USDG, address(swapper), usdgSize);
        for (uint256 i; i < rounds; i++) {
            uint256 before = address(swapper).balance;
            swapper.swap(false, usdgSize);
            swapper.swap(true, address(swapper).balance - before);
            usdgSize = IERC20(USDG).balanceOf(address(swapper));
        }
    }

    function _liquidity() internal view returns (uint128) {
        return POSM.getPositionLiquidity(lp.tokenOf(address(position)));
    }

    // ── Tests ───────────────────────────────────────────────────────────

    function test_inOpensOneRangeInThePosition() public forked {
        _enter();
        uint256 tokenId = lp.tokenOf(address(position));
        assertGt(tokenId, 0);
        assertEq(POSM.ownerOf(tokenId), address(position), "the position holds the NFT");
        assertGt(_liquidity(), 0);
        assertTrue(lp.holds(address(position)));
        assertEq(position.venue(), address(lp));
        assertGt(position.deployed(), 9_900 * E6, "nearly all of it went in");
        assertEq(IERC20(USDG).balanceOf(address(lp)) + IERC20(WETH).balanceOf(address(lp)) + address(lp).balance, 0, "the adapter holds nothing");
        assertLe(address(position).balance, 0.002 ether);
        // What the range did not use came back as WETH or USDG, not as ETH.
        emit log_named_uint("left over (USDG, 6 decimals)", IERC20(USDG).balanceOf(address(position)));
        emit log_named_uint("left over (WETH)", IERC20(WETH).balanceOf(address(position)));
    }

    function test_inAgainAddsToTheSameRange() public forked {
        _enter();
        uint256 tokenId = lp.tokenOf(address(position));
        uint128 before = _liquidity();
        deal(USDG, address(position), IERC20(USDG).balanceOf(address(position)) + 2_000 * E6);
        (bool ok, bytes memory reason) = _in(2_000 * E6, 1_000 * E6, 0);
        if (!ok) emit log_bytes(reason);
        assertTrue(ok, "added");
        assertEq(lp.tokenOf(address(position)), tokenId, "the same NFT");
        assertGt(_liquidity(), before, "more liquidity");
    }

    function test_harvestCollectsTheFeesAsUsdg() public forked {
        _enter();
        _trade(10, 200_000 * E6); // $4M of volume through the pool
        uint256 idle = IERC20(USDG).balanceOf(address(position));
        (bool ok, bytes memory reason) = _job(SpinPosition.Kind.Harvest, UniswapV4LpAdapter.Action.Harvest, "");
        if (!ok) emit log_bytes(reason);
        assertTrue(ok, "harvested");
        uint256 fee = IERC20(USDG).balanceOf(treasury);
        uint256 kept = IERC20(USDG).balanceOf(address(position)) - idle;
        emit log_named_uint("fees earned on $4M of volume (USDG, 6 decimals)", fee + kept);
        assertGt(fee + kept, 0, "fees as USDG");
        assertApproxEqAbs(fee, (fee + kept) * 500 / 10_000, 1, "5% of them");
        assertGt(_liquidity(), 0, "the liquidity stays");
    }

    function test_outTakesItAllBackToUsdg() public forked {
        _enter();
        (bool ok, bytes memory reason) = _job(SpinPosition.Kind.Manage, UniswapV4LpAdapter.Action.Out, "");
        if (!ok) emit log_bytes(reason);
        assertTrue(ok, "out");
        assertEq(lp.tokenOf(address(position)), 0, "burned");
        assertFalse(lp.holds(address(position)));
        assertEq(IERC20(WETH).balanceOf(address(position)), 0, "no WETH left");
        assertEq(position.venue(), address(0));
        // All of it is USDG again, the unused part of the entry included.
        uint256 back = IERC20(USDG).balanceOf(address(position));
        emit log_named_uint("round trip cost (USDG, 6 decimals)", 10_000 * E6 - back);
        assertGt(back, 9_990 * E6, "a round trip costs the swap fees and little else");
    }

    function test_theHolderWithdrawsHalfThenTheRest() public forked {
        _enter();
        uint256 cost = position.deployed();
        uint128 liquidity = _liquidity();
        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(lp), 0.5e18, bytes(""))));
        assertEq(position.deployed(), cost - cost / 2);
        assertGt(IERC20(USDG).balanceOf(account), 4_950 * E6, "about half to the account");
        assertApproxEqAbs(_liquidity(), liquidity / 2, 1, "the range stays, half as big");
        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(lp), 1e18, bytes(""))));
        assertFalse(lp.holds(address(position)));
        assertGt(IERC20(USDG).balanceOf(account), 9_980 * E6);
    }

    function test_anNftSentByAStrangerDoesNotBlockTheExit() public forked {
        _enter();
        // A stranger mints a dust position in the same pool straight to the SpinPosition.
        address stranger = makeAddr("stranger");
        UniswapV4LpAdapter other =
            new UniswapV4LpAdapter(key, POSM, STATE_VIEW, ROUTE_POOL, WETH, USDG, ETH_USD, USDG_USD, 100, 25 hours, 200, 14_000);
        deal(USDG, stranger, 10 * E6);
        // A range below the price holds only USDG.
        (int24 lower,) = _range(1_000);
        (int24 upper) = lower;
        lower -= 1_000;
        vm.startPrank(stranger);
        IERC20(USDG).approve(address(other), 10 * E6);
        other.enter(10 * E6, 0, lower, upper);
        vm.stopPrank();
        uint256 dust = other.tokenOf(stranger);
        vm.prank(stranger);
        (bool sent,) = address(POSM).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", stranger, address(position), dust));
        assertTrue(sent);
        assertEq(POSM.ownerOf(dust), address(position));

        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(lp), 1e18, bytes(""))));
        assertFalse(lp.holds(address(position)), "the adapter counts only its own NFT");
        assertEq(position.venue(), address(0));
        assertGt(IERC20(USDG).balanceOf(account), 9_980 * E6);
    }

    function test_aMovedPoolPriceIsRefused() public forked {
        // Someone pushes the V4 pool's price well above Chainlink before the operator's job.
        deal(USDG, address(swapper), 3_000_000 * E6);
        swapper.swap(false, 3_000_000 * E6);
        (bool ok, bytes memory reason) = _in(10_000 * E6, 5_000 * E6, 1_000);
        assertFalse(ok);
        assertEq(bytes4(reason), WethUsdgVenue.PriceOff.selector);
    }

    function test_withAStaleFeedTheHolderStillGetsOutWithTheEthAsWeth() public forked {
        _enter();
        vm.warp(block.timestamp + 2 days); // the feeds are now older than 25 h
        // A partial withdrawal needs a checked price ...
        vm.prank(holder);
        vm.expectRevert(WethUsdgVenue.StaleFeed.selector);
        IAccountExecuteV4(account).execute(address(position), 0, abi.encodeCall(SpinPosition.withdraw, (address(lp), 0.5e18, bytes(""))), 0);
        // ... the full one goes through: what is not USDG comes as WETH.
        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(lp), 1e18, bytes(""))));
        assertFalse(lp.holds(address(position)));
        assertEq(position.venue(), address(0));
        uint256 weth = IERC20(WETH).balanceOf(account);
        uint256 usdg = IERC20(USDG).balanceOf(account);
        emit log_named_uint("WETH to the holder", weth);
        emit log_named_uint("USDG to the holder (6 decimals)", usdg);
        assertGt(weth, 1 ether, "the ETH half as WETH");
        assertGt(usdg, 4_000 * E6, "the USDG half");
        assertEq(IERC20(WETH).balanceOf(address(position)) + IERC20(WETH).balanceOf(address(lp)), 0, "nothing stuck");
    }

    function test_aStaleFeedStopsIt() public forked {
        vm.warp(block.timestamp + 2 days);
        (bool ok, bytes memory reason) = _in(10_000 * E6, 5_000 * E6, 1_000);
        assertFalse(ok);
        assertEq(bytes4(reason), WethUsdgVenue.StaleFeed.selector);
    }

    function test_aRangeOutsideTheLimitsIsRefused() public forked {
        (bool ok, bytes memory reason) = _in(10_000 * E6, 5_000 * E6, 50); // ±0.5%, under the 200-tick minimum
        assertFalse(ok);
        assertEq(bytes4(reason), UniswapV4LpAdapter.BadRange.selector);
    }

    function test_onlyThePositionCanExitOrHarvestItsNft() public forked {
        _enter();
        vm.expectRevert(UniswapV4LpAdapter.NotOwnerOfPosition.selector);
        lp.exitFor(1e18, 0, false);
        vm.expectRevert(UniswapV4LpAdapter.NotOwnerOfPosition.selector);
        lp.harvestFor();
    }

    function test_aStrangerCannotSendEthToTheAdapter() public forked {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(lp).call{value: 1 ether}("");
        assertFalse(ok);
    }
}
