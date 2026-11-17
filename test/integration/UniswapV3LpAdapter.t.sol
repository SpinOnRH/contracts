// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {SpinPositions, IERC6551RegistryView} from "../../src/positions/SpinPositions.sol";
import {SpinPosition} from "../../src/positions/SpinPosition.sol";
import {
    UniswapV3LpAdapter,
    IUniswapV3PoolLp,
    INonfungiblePositionManager,
    IAggregatorV3
} from "../../src/positions/adapters/UniswapV3LpAdapter.sol";
import {WethUsdgVenue, IAggregatorV3} from "../../src/positions/adapters/WethUsdgVenue.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IRegistryCreateLp {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

interface IAccountExecuteLp {
    function execute(address to, uint256 value, bytes calldata data, uint8 operation) external payable returns (bytes memory);
}

contract LpForkSpinners {
    mapping(uint256 => address) public ownerOf;

    function isActive(uint256) external pure returns (bool) {
        return true;
    }

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }
}

/**
 * A Balanced SpinPosition in the Uniswap V3 WETH/USDG 0.05% pool on a fork of
 * Robinhood Chain: the real pool, position manager and Chainlink feeds, owned
 * by a real Tokenbound account.
 *
 *   RPC_URL=<archive rpc> npm run test
 */
contract UniswapV3LpAdapterFork is Test {
    address constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    IUniswapV3PoolLp constant POOL = IUniswapV3PoolLp(0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a);
    // The deepest WETH/USDG pool (0.01%), where the adapter swaps.
    IUniswapV3PoolLp constant ROUTE_POOL = IUniswapV3PoolLp(0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca);
    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3);
    ISwapRouter02 constant ROUTER = ISwapRouter02(0xCaf681a66D020601342297493863E78C959E5cb2);
    IAggregatorV3 constant ETH_USD = IAggregatorV3(0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9);
    IAggregatorV3 constant USDG_USD = IAggregatorV3(0x61B7e5650328764B076A108EFF5fa7282a1B9aD2);
    uint256 constant PINNED_BLOCK = 92_557_000;
    uint256 constant ID = 1;
    uint256 constant E6 = 1e6;

    SpinPositions positions;
    UniswapV3LpAdapter lp;
    SpinPosition position;
    address account;
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address holder = makeAddr("holder");
    address trader = makeAddr("trader");

    function setUp() public {
        string memory rpc = vm.envOr("RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // every test below skips
        vm.createSelectFork(rpc, PINNED_BLOCK);
        vm.etch(0x000000000000000000000000000000000000006C, "");

        LpForkSpinners spinners = new LpForkSpinners();
        spinners.mint(holder, ID);
        account = IRegistryCreateLp(REGISTRY).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), ID);

        positions = new SpinPositions(
            IERC6551RegistryView(REGISTRY), ACCOUNT_V3, address(spinners), USDG, admin, treasury, 500, 1 gwei, 0.001 ether, 110_000, 80_000
        );
        // 1% band around Chainlink, feeds at most 25 hours old, ranges from ±1% to ±100%.
        lp = new UniswapV3LpAdapter(POOL, NPM, ROUTE_POOL, WETH, USDG, ETH_USD, USDG_USD, 100, 25 hours, 200, 14_000);
        vm.startPrank(admin);
        positions.setOperator(operator, true);
        positions.setVenue(address(lp), 2);
        vm.stopPrank();

        position = positions.create(ID);
        _asHolder(abi.encodeCall(SpinPosition.configure, ((1 << 1) | (1 << 2), uint64(block.timestamp + 365 days))));
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
        IAccountExecuteLp(account).execute(address(position), 0, data, 0);
    }

    function _job(SpinPosition.Kind kind, UniswapV3LpAdapter.Action action, bytes memory data) internal returns (bool ok, bytes memory reason) {
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
        (, int24 tick,,,,,) = POOL.slot0();
        int24 spacing = POOL.tickSpacing();
        int24 mid = (tick / spacing) * spacing;
        lower = mid - halfWidth;
        upper = mid + halfWidth;
    }

    /// Opens a ±10% range with 10,000 USDG, about half of it swapped to WETH.
    function _enter() internal {
        (int24 lower, int24 upper) = _range(1_000);
        (bool ok, bytes memory reason) =
            _job(SpinPosition.Kind.Manage, UniswapV3LpAdapter.Action.In, abi.encode(10_000 * E6, 5_000 * E6, lower, upper));
        if (!ok) emit log_bytes(reason);
        assertTrue(ok, "entered");
    }

    /// Trades through the pool both ways: `rounds` round trips of `usdgSize`.
    function _trade(uint256 rounds, uint256 usdgSize) internal {
        deal(USDG, trader, usdgSize * rounds);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(ROUTER), type(uint256).max);
        IERC20(WETH).approve(address(ROUTER), type(uint256).max);
        for (uint256 i; i < rounds; i++) {
            uint256 got = ROUTER.exactInputSingle(ISwapRouter02.ExactInputSingleParams(USDG, WETH, 500, trader, usdgSize, 0, 0));
            ROUTER.exactInputSingle(ISwapRouter02.ExactInputSingleParams(WETH, USDG, 500, trader, got, 0, 0));
        }
        vm.stopPrank();
    }

    // ── Tests ───────────────────────────────────────────────────────────

    function test_inOpensOneRangeInThePosition() public forked {
        _enter();
        assertEq(NPM.balanceOf(address(position)), 1, "the position holds the NFT");
        assertEq(position.venue(), address(lp));
        assertGt(position.deployed(), 9_900 * E6, "nearly all of it went in");
        assertEq(IERC20(USDG).balanceOf(address(lp)) + IERC20(WETH).balanceOf(address(lp)), 0, "the adapter holds nothing");
        assertEq(address(position).balance <= 0.002 ether, true);
    }

    function test_harvestCollectsTheFeesAsUsdg() public forked {
        _enter();
        _trade(20, 50_000 * E6); // $2M of volume through the pool
        (bool ok,) = _job(SpinPosition.Kind.Harvest, UniswapV3LpAdapter.Action.Harvest, "");
        assertTrue(ok, "harvested");
        uint256 fee = IERC20(USDG).balanceOf(treasury);
        uint256 kept = IERC20(USDG).balanceOf(address(position));
        emit log_named_uint("fees earned on $2M of volume (USDG, 6 decimals)", fee + kept);
        assertGt(fee + kept, 0, "fees as USDG");
        assertApproxEqAbs(fee, (fee + kept) * 500 / 10_000, 1, "5% of them");
        (,,,,,,, uint128 liquidity,,,,) = NPM.positions(lp.tokenOf(address(position)));
        assertGt(liquidity, 0, "the liquidity stays");
    }

    function test_outTakesItAllBackToUsdg() public forked {
        _enter();
        uint256 cost = position.deployed();
        (bool ok,) = _job(SpinPosition.Kind.Manage, UniswapV3LpAdapter.Action.Out, "");
        assertTrue(ok, "out");
        assertEq(NPM.balanceOf(address(position)), 0, "burned");
        assertEq(IERC20(WETH).balanceOf(address(position)), 0, "no WETH left");
        assertEq(position.venue(), address(0));
        uint256 back = IERC20(USDG).balanceOf(address(position)) + (10_000 * E6 - cost);
        emit log_named_uint("round trip cost (USDG, 6 decimals)", 10_000 * E6 - back);
        assertGt(back, 9_980 * E6, "a round trip costs the pool fees and little else");
    }

    function test_theHolderWithdrawsHalfThenTheRest() public forked {
        _enter();
        uint256 cost = position.deployed();
        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(lp), 0.5e18, bytes(""))));
        assertEq(position.deployed(), cost - cost / 2);
        assertGt(IERC20(USDG).balanceOf(account), 4_950 * E6, "about half to the account");
        assertEq(NPM.balanceOf(address(position)), 1, "the range stays, half as big");
        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(lp), 1e18, bytes(""))));
        assertEq(NPM.balanceOf(address(position)), 0);
        assertGt(IERC20(USDG).balanceOf(account), 9_980 * E6);
    }

    function test_anNftSentByAStrangerIsIgnored() public forked {
        // Before the position enters, a stranger mints a dust range in the same pool (below the
        // price: USDG only) and sends it to the SpinPosition.
        address stranger = makeAddr("stranger");
        (int24 lower,) = _range(1_000);
        deal(USDG, stranger, 10 * E6);
        vm.startPrank(stranger);
        IERC20(USDG).approve(address(NPM), 10 * E6);
        (uint256 dust,,,) = NPM.mint(
            INonfungiblePositionManager.MintParams(
                POOL.token0(), POOL.token1(), 500, lower - 1_000, lower, 0, 10 * E6, 0, 0, stranger, block.timestamp
            )
        );
        (bool sent,) = address(NPM).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", stranger, address(position), dust));
        vm.stopPrank();
        assertTrue(sent);
        assertFalse(lp.holds(address(position)), "not the adapter's NFT");

        _enter();
        assertTrue(lp.tokenOf(address(position)) != dust, "the adapter minted its own");
        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(lp), 1e18, bytes(""))));
        assertFalse(lp.holds(address(position)));
        assertEq(position.venue(), address(0));
        assertEq(NPM.ownerOf(dust), address(position), "the stranger's NFT is left alone");
        assertGt(IERC20(USDG).balanceOf(account), 9_980 * E6);
    }

    function test_aMovedPoolPriceIsRefused() public forked {
        // Someone pushes the pool's price ~2% above Chainlink before the operator's job.
        deal(USDG, trader, 3_000_000 * E6);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(ROUTER), type(uint256).max);
        ROUTER.exactInputSingle(ISwapRouter02.ExactInputSingleParams(USDG, WETH, 500, trader, 3_000_000 * E6, 0, 0));
        vm.stopPrank();
        (int24 lower, int24 upper) = _range(1_000);
        (bool ok, bytes memory reason) =
            _job(SpinPosition.Kind.Manage, UniswapV3LpAdapter.Action.In, abi.encode(10_000 * E6, 5_000 * E6, lower, upper));
        assertFalse(ok);
        assertEq(bytes4(reason), WethUsdgVenue.PriceOff.selector);
    }

    function test_aSwapTooLargeForThePoolIsRefused() public forked {
        // Swapping a huge amount moves the price past the band: the average price is checked too.
        deal(USDG, address(position), 5_000_000 * E6);
        (int24 lower, int24 upper) = _range(1_000);
        (bool ok, bytes memory reason) =
            _job(SpinPosition.Kind.Manage, UniswapV3LpAdapter.Action.In, abi.encode(5_000_000 * E6, 4_000_000 * E6, lower, upper));
        assertFalse(ok);
        assertEq(bytes4(reason), WethUsdgVenue.PriceOff.selector);
    }

    /// Regression: the LP pool's price was in band, the route pool's was not, so
    /// the sale of the WETH reverted and with it the holder's full withdrawal.
    function test_whenTheRoutePoolIsOffTheFullWithdrawalStillGoesWithTheEthAsWeth() public forked {
        _enter();
        address pusher = makeAddr("pusher");
        deal(WETH, pusher, 2_000 ether);
        vm.startPrank(pusher);
        IERC20(WETH).approve(address(ROUTER), type(uint256).max);
        ROUTER.exactInputSingle(ISwapRouter02.ExactInputSingleParams(WETH, USDG, 100, pusher, 2_000 ether, 0, 0));
        vm.stopPrank();
        // A partial withdrawal sells at a checked price, so it waits ...
        vm.prank(holder);
        vm.expectRevert(WethUsdgVenue.PriceOff.selector);
        IAccountExecuteLp(account).execute(address(position), 0, abi.encodeCall(SpinPosition.withdraw, (address(lp), 0.5e18, bytes(""))), 0);
        // ... the full one goes through, with the ETH it could not sell as WETH.
        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(lp), 1e18, bytes(""))));
        assertFalse(lp.holds(address(position)));
        assertGt(IERC20(WETH).balanceOf(account), 1 ether, "the ETH half as WETH");
        assertGt(IERC20(USDG).balanceOf(account), 0, "the USDG half");
        assertEq(IERC20(WETH).balanceOf(address(lp)), 0, "the adapter holds nothing");
    }

    /// Regression: a Chainlink feed that reverts (a retired feed) stopped every exit.
    function test_whenAFeedRevertsTheFullWithdrawalStillGoesWithTheEthAsWeth() public forked {
        _enter();
        vm.mockCallRevert(address(ETH_USD), abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), "retired");
        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(lp), 1e18, bytes(""))));
        assertFalse(lp.holds(address(position)));
        assertGt(IERC20(WETH).balanceOf(account), 1 ether, "the ETH half as WETH");
    }

    function test_onlyTheAdapterSellsThroughItsUndoableSale() public forked {
        vm.expectRevert(WethUsdgVenue.NotSelf.selector);
        lp.sellWethHere(1);
    }

    function test_withAStaleFeedTheHolderStillGetsOutWithTheEthAsWeth() public forked {
        _enter();
        vm.warp(block.timestamp + 2 days); // the feeds are now older than 25 h
        // A partial withdrawal needs a checked price ...
        vm.prank(holder);
        vm.expectRevert(WethUsdgVenue.StaleFeed.selector);
        IAccountExecuteLp(account).execute(address(position), 0, abi.encodeCall(SpinPosition.withdraw, (address(lp), 0.5e18, bytes(""))), 0);
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

    function test_withAStaleFeedTheWethKeptCountsInTheFee() public forked {
        _enter();
        // A gain held as WETH: a full exit takes the position's WETH with the rest.
        deal(WETH, address(position), IERC20(WETH).balanceOf(address(position)) + 1 ether);
        vm.warp(block.timestamp + 2 days);
        vm.recordLogs();
        _asHolder(abi.encodeCall(SpinPosition.withdraw, (address(lp), 1e18, bytes(""))));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        int256 result;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(position) && logs[i].topics[0] == SpinPosition.Exited.selector) {
                (, result) = abi.decode(logs[i].data, (uint256, int256));
            }
        }
        emit log_named_int("result, with the WETH kept at Chainlink's last price (6 decimals)", result);
        assertGt(result, int256(2_000 * E6), "the kept ETH is counted");
        assertApproxEqAbs(IERC20(USDG).balanceOf(treasury), (uint256(result) * 500) / 10_000, 1, "5% of it, from the USDG");
        assertGt(IERC20(WETH).balanceOf(account), 1 ether, "the WETH to the holder");
        assertEq(IERC20(WETH).balanceOf(address(position)) + IERC20(WETH).balanceOf(address(lp)), 0, "nothing stuck");
    }

    function test_aStaleFeedStopsIt() public forked {
        vm.warp(block.timestamp + 2 days);
        (int24 lower, int24 upper) = _range(1_000);
        (bool ok, bytes memory reason) =
            _job(SpinPosition.Kind.Manage, UniswapV3LpAdapter.Action.In, abi.encode(10_000 * E6, 5_000 * E6, lower, upper));
        assertFalse(ok);
        assertEq(bytes4(reason), WethUsdgVenue.StaleFeed.selector);
    }

    function test_aRangeOutsideTheLimitsIsRefused() public forked {
        (int24 lower, int24 upper) = _range(50); // ±0.5%, under the 200-tick minimum width
        (bool ok, bytes memory reason) =
            _job(SpinPosition.Kind.Manage, UniswapV3LpAdapter.Action.In, abi.encode(10_000 * E6, 5_000 * E6, lower, upper));
        assertFalse(ok);
        assertEq(bytes4(reason), UniswapV3LpAdapter.BadRange.selector);
    }

    function test_onlyThePositionsOwnerCanExitItsNft() public forked {
        _enter();
        uint256 tokenId = lp.tokenOf(address(position));
        vm.expectRevert(UniswapV3LpAdapter.NotOwnerOfPosition.selector);
        lp.exitFor(tokenId, 1e18, 0, false);
        vm.expectRevert(UniswapV3LpAdapter.NotOwnerOfPosition.selector);
        lp.harvestFor(tokenId);
    }
}

import {Vm} from "forge-std/Vm.sol";
