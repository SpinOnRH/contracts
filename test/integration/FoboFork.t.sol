// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SpinBotGuard, IERC6551Registry} from "../../src/bots/SpinBotGuard.sol";
import {FoboAdapter} from "../../src/bots/adapters/FoboAdapter.sol";
import {HookList} from "../../src/bots/HookList.sol";
import {Routes} from "../../src/bots/Routes.sol";
import {IVenueAdapter} from "../../src/bots/IVenueAdapter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {Spinners} from "../../src/collection/Spinners.sol";

interface ITokenboundPermissionsFobo {
    function setPermissions(address[] calldata callers, bool[] calldata permissions) external;
}

interface IRegistryCreateAccountFobo {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

/**
 * fobo.fun on a fork of Robinhood Chain. Every fobo pool is a Uniswap V4 pool against its pair
 * (ETH, $FOBO, USDG or a stock token) whose hook, FoboHook, owns its liquidity and taxes the
 * quote side of each swap (2.5% after a token's first minute, buys and sells), before the router
 * checks its minimum. FoboAdapter trades every pair: a pair token's trade goes through it (a V4 hop
 * in the same path, or a V3 hop before it). The first swap of a block in a pool whose floor can
 * rise needs about 1.1M gas at the hook (the worker's FOBO_ONE_POOL_GAS covers it).
 *
 *   RPC_URL=<archive rpc> npm run test
 */
contract FoboFork is Test {
    IERC6551Registry constant REGISTRY = IERC6551Registry(0x000000006551c19487814612e58FE06813775758);
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    uint256 constant PINNED_BLOCK = 110_800_000;

    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    address constant FOBO_HOOK = 0x0Af57F62982D03066ef917AcAd87F771c06528Ec;
    /// $FOBO: fobo's own token, paired with ETH.
    address constant FOBO = 0x000DE658153f47f23e92973C8EB1e89762703676;
    /// TALON: paired with $FOBO (launched at block 110,413,070).
    address constant TALON = 0xBC94CD75231A86a89d59761AdE9Fe32233045b6D;
    /// HMM: paired with USDG (block 109,622,738).
    address constant HMM = 0x65083a089dcF6eD9d76abDE531176007B6Fc5feb;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// The worker's ETH / USDG V4 hop: a dynamic fee, spacing 10, the Fables ETH/USDG hook.
    address constant FABLES_ETH_USDG = 0x06a889870C8f83640D6816319f72e2aA579b6080;
    /// WHUFF: paired with NVDA (block 110,234,880); NVDA's deepest pool against ETH is V3 WETH 0.05%.
    address constant WHUFF = 0xF64554f95b5bD9f2E6C5E5A537bA053e33dB7611;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    int24 constant SPACING = 60;
    /// The worker's FOBO_ONE_POOL_GAS and FOBO_TWO_POOLS_GAS, before its 1.3 margin.
    uint256 constant ONE_POOL_GAS = 1_600_000;
    uint256 constant TWO_POOLS_GAS = 2_900_000;
    /// The worker's route ids for these: the guard's credit must match.
    bytes32 constant ROUTE_FOBO = 0x6e2aedd5761385c3601e3340e45070056e7d450b9891df341f9e2a1cc4aa5d4b;
    bytes32 constant TALON_ROUTE = 0x782f0e1f9132f5ad3c6e704711cb89877f31b150e4a706ae696c963d794deaa5;

    SpinBotGuard guard;
    FoboAdapter fobo;
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

        Spinners spinners = new Spinners("Spinners", "SPIN", 7777, admin, payable(treasury), 500, "ipfs://art/", address(REGISTRY), ACCOUNT_V3);
        vm.prank(admin);
        spinners.setMintOpen(true);
        vm.startPrank(holder);
        spinners.mint(1);
        spinners.activate(1);
        vm.stopPrank();
        account = IRegistryCreateAccountFobo(address(REGISTRY)).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), 1);
        vm.deal(account, 1 ether);

        guard = new SpinBotGuard(REGISTRY, ACCOUNT_V3, address(spinners), admin, treasury, 50, 1 gwei, 0.001 ether, 110_000, 80_000);
        // The HookList holds the hop pools' hooks (the Fables ETH/USDG hook); FoboHook needs no entry.
        address[] memory hooks = new address[](1);
        hooks[0] = FABLES_ETH_USDG;
        fobo = new FoboAdapter(UNIVERSAL_ROUTER, PERMIT2, WETH, FOBO_HOOK, new HookList(hooks));
        vm.startPrank(admin);
        guard.setOperator(operator, true);
        guard.addVenue(address(fobo));
        vm.stopPrank();

        vm.startPrank(holder);
        address[] memory callers = new address[](1);
        callers[0] = address(guard);
        bool[] memory perms = new bool[](1);
        perms[0] = true;
        ITokenboundPermissionsFobo(account).setPermissions(callers, perms);
        guard.configure(account, SpinBotGuard.Limits(0.2 ether, 1 ether, uint64(block.timestamp + 30 days)));
        vm.stopPrank();
    }

    modifier forked() {
        if (address(guard) == address(0)) {
            emit log("skipped: set RPC_URL to run the fork tests");
            return;
        }
        _;
    }

    function _noHop() internal pure returns (FoboAdapter.Hop memory h) {}

    /// $FOBO's own fobo pool, from ETH: the hop of a $FOBO-paired token (as the worker builds it).
    function _foboHop() internal pure returns (FoboAdapter.Hop memory h) {
        h.v4 = true;
        h.fee = 0;
        h.tickSpacing = SPACING;
        h.hooks = FOBO_HOOK;
    }

    function _usdgHop() internal pure returns (FoboAdapter.Hop memory h) {
        h.v4 = true;
        h.fee = 0x800000;
        h.tickSpacing = 10;
        h.hooks = FABLES_ETH_USDG;
    }

    function _nvdaHop() internal pure returns (FoboAdapter.Hop memory h) {
        h.fee = 500;
    }

    function _params(address token, address pair, FoboAdapter.Hop memory hop, bool buy, uint256 amountIn, uint256 minOut)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(FoboAdapter.Params(buy, token, pair, amountIn, minOut, hop));
    }

    /// guard.trade with exactly `gas`, in a new block (the first swap of a block is the one that may raise the floor).
    function _trade(bytes memory params, uint256 gas) internal returns (bool ok, uint256 used) {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        vm.prank(operator);
        uint256 before = gasleft();
        (ok,) = address(guard).call{gas: gas}(abi.encodeCall(guard.trade, (account, IVenueAdapter(address(fobo)), params)));
        used = before - gasleft();
    }

    /// A buy and the sale of all it got, each in a new block with the worker's gas; returns the ETH back per ETH in (1e18 = all of it).
    function _roundTrip(address token, address pair, FoboAdapter.Hop memory hop, uint256 gas) internal returns (uint256 back) {
        uint256 eth = 0.01 ether;
        uint256 ethBefore = account.balance;
        (bool ok, uint256 used) = _trade(_params(token, pair, hop, true, eth, 1), gas);
        assertTrue(ok, "the buy goes through with the worker's gas");
        emit log_named_uint("buy gas", used);
        uint256 tokens = IERC20(token).balanceOf(account);
        assertGt(tokens, 0);
        uint256 afterBuy = account.balance;
        (ok, used) = _trade(_params(token, pair, hop, false, tokens, 1), gas);
        assertTrue(ok, "the sale goes through with the worker's gas");
        emit log_named_uint("sale gas", used);
        assertEq(IERC20(token).balanceOf(account), 0, "a sale fills completely");
        back = ((account.balance - afterBuy) * 1e18) / (ethBefore - afterBuy);
        emit log_named_uint("ETH back per ETH in (1e18)", back);
    }

    function test_anEthPairedToken() public forked {
        uint256 back = _roundTrip(FOBO, address(0), _noHop(), ONE_POOL_GAS);
        // 2.5% each way and our 0.5% each way: about 94.6%, less a little price impact.
        assertGt(back, 0.935e18);
        assertLt(back, 0.947e18);
        (, IVenueAdapter.Route memory route) = fobo.plan(account, _params(FOBO, address(0), _noHop(), true, 1, 1));
        assertEq(route.id, Routes.FOBO);
        assertEq(route.id, ROUTE_FOBO);
    }

    function test_aFoboPairedTokenThroughFobosOwnPool() public forked {
        uint256 back = _roundTrip(TALON, FOBO, _foboHop(), TWO_POOLS_GAS);
        // Two taxed pools each way and our fee: about 89.5%, less impact in both pools.
        assertGt(back, 0.85e18);
        assertLt(back, 0.896e18);
        (, IVenueAdapter.Route memory route) = fobo.plan(account, _params(TALON, FOBO, _foboHop(), true, 1, 1));
        assertEq(route.id, Routes.pair(Routes.FOBO, Routes.uniswap(true, 0, SPACING, FOBO_HOOK, address(0), 0, 0, address(0))));
        assertEq(route.id, TALON_ROUTE);
    }

    function test_aUsdgPairedTokenThroughTheV4UsdgHop() public forked {
        uint256 back = _roundTrip(HMM, USDG, _usdgHop(), ONE_POOL_GAS);
        // The fobo pool's 2.5% each way, the hop pool's fee each way, our fee, and impact in a small pool.
        assertGt(back, 0.8e18);
        assertLt(back, 0.947e18);
    }

    function test_aStockPairedTokenThroughAV3Hop() public forked {
        uint256 back = _roundTrip(WHUFF, NVDA, _nvdaHop(), ONE_POOL_GAS);
        assertGt(back, 0.8e18);
        assertLt(back, 0.947e18);
        (, IVenueAdapter.Route memory route) = fobo.plan(account, _params(WHUFF, NVDA, _nvdaHop(), true, 1, 1));
        assertEq(route.id, Routes.pair(Routes.FOBO, Routes.uniswap(false, 500, 0, address(0), address(0), 0, 0, address(0))));
    }

    function test_onlyAPoolFoboHookMadeForTheTokenIsTraded() public forked {
        // The wrong pair, a token fobo did not launch, wrapped ETH as a pair: no such fobo pool.
        vm.expectRevert(FoboAdapter.NotFoboToken.selector);
        fobo.market(TALON, address(0));
        vm.expectRevert(FoboAdapter.NotFoboToken.selector);
        fobo.market(NVDA, address(0));
        vm.expectRevert(FoboAdapter.NotFoboToken.selector);
        fobo.market(FOBO, WETH);
        FoboAdapter.Market memory m = fobo.market(TALON, FOBO);
        assertEq(m.hooks, FOBO_HOOK);
    }

    function test_aHopHookNotOnTheListIsRefused() public forked {
        FoboAdapter.Hop memory h = _usdgHop();
        h.hooks = makeAddr("unreviewed hook");
        vm.expectRevert();
        fobo.plan(account, _params(HMM, USDG, h, true, 0.01 ether, 1));
    }
}
