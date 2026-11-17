// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SpinBotGuard, IERC6551Registry} from "../../src/bots/SpinBotGuard.sol";
import {UniswapAdapter} from "../../src/bots/adapters/UniswapAdapter.sol";
import {IPonsFactory} from "../../src/bots/adapters/PonsAdapter.sol";
import {LongAdapter, IDopplerAirlock, IDopplerHookInitializer} from "../../src/bots/adapters/LongAdapter.sol";
import {HookList, HookListUser, IHookList} from "../../src/bots/HookList.sol";
import {Routes} from "../../src/bots/Routes.sol";
import {IVenueAdapter} from "../../src/bots/IVenueAdapter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {Spinners} from "../../src/collection/Spinners.sol";
import {AdminWithdrawable} from "../../src/utils/Withdrawable.sol";

interface ITokenboundPermissionsLong {
    function setPermissions(address[] calldata callers, bool[] calldata permissions) external;
}

interface IRegistryCreateAccountLong {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

/**
 * Long.xyz tokens on a fork of Robinhood Chain: Doppler multicurve tokens in their own V4 pools
 * (the initializer's hook, Rehype's fees), paired with ETH, a stock token, USDG or a leveraged
 * token; ETH goes through the pair token on Uniswap (V3, or V4 directly or through USDG) and back.
 *
 *   RPC_URL=<archive rpc> npm run test
 */
contract LongFork is Test {
    IERC6551Registry constant REGISTRY = IERC6551Registry(0x000000006551c19487814612e58FE06813775758);
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    uint256 constant PINNED_BLOCK = 106600000;

    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant PONS = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant AIRLOCK = 0xeb7C034704eF8Dcd2D32324c1545f62fB4aD0862;
    address constant INITIALIZER = 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544;
    /// Rehype, the Doppler hook on every Long pool (fees decaying from 100% to 1.3% over 10 s).
    address constant REHYPE = 0x6f02324d20CC679d0E585290CAa6b16baCbC0F77;

    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
    address constant DJT = 0x1D11f0496982706C5e14A514D4E79F2e6BdE4516;
    address constant OPENAI_X1L = 0xfe09Fb328bE1c286B4f597eD34764b7472ae72c5;
    /// ETH / USDG on V4: a dynamic fee, and its hook.
    address constant USDG_HOOK = 0x06a889870C8f83640D6816319f72e2aA579b6080;
    uint24 constant DYNAMIC = 0x800000;

    /// Long tokens, one per kind of pair.
    address constant ETH_LONG = 0xCD9aA739e03a59654fE55215F5A5161d56c41E18;
    address constant SPCX_LONG = 0x6f4FD5FeB0be48ae245ec613d7D964aC38271E18;
    address constant DJT_LONG = 0x6ae59F9B39a0D6f92734696456826D87cF391E18;
    address constant USDG_LONG = 0xE11AB3c575F6d9348319C037A601ddcEEFff1e18;
    address constant OPENAI_LONG = 0x338F47412fEf6e8B24b231d5C6D03ba4458d1E18;
    /// Another front end's Doppler token: the same initializer and dead timelock, another Doppler hook.
    address constant OTHER_DOPPLER = 0xc1597CAB256Fc37a2e26002ec162795930246862;
    /// A Pons token: not Doppler's.
    address constant PONS_TOKEN = 0x6b9565eFEeFf487e508Bb8dd4967DEC50859491c;

    SpinBotGuard guard;
    UniswapAdapter uni;
    LongAdapter long;
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
        account = IRegistryCreateAccountLong(address(REGISTRY)).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), 1);
        vm.deal(account, 2 ether);

        guard = new SpinBotGuard(REGISTRY, ACCOUNT_V3, address(spinners), admin, treasury, 50, 1 gwei, 0.001 ether, 110_000, 80_000);
        address[] memory hooks = new address[](1);
        hooks[0] = USDG_HOOK;
        HookList hookList = new HookList(hooks);
        uni = new UniswapAdapter(UNIVERSAL_ROUTER, PERMIT2, WETH, IPonsFactory(PONS), PONS_HOOK, admin, hookList);
        address[] memory dopplerHooks = new address[](1);
        dopplerHooks[0] = REHYPE;
        vm.prank(admin);
        long = new LongAdapter(
            UNIVERSAL_ROUTER, PERMIT2, WETH, IDopplerAirlock(AIRLOCK), IDopplerHookInitializer(INITIALIZER), hookList, dopplerHooks
        );
        vm.startPrank(admin);
        guard.setOperator(operator, true);
        guard.addVenue(address(uni));
        guard.addVenue(address(long));
        vm.stopPrank();

        vm.startPrank(holder);
        address[] memory callers = new address[](1);
        callers[0] = address(guard);
        bool[] memory perms = new bool[](1);
        perms[0] = true;
        ITokenboundPermissionsLong(account).setPermissions(callers, perms);
        guard.configure(account, SpinBotGuard.Limits(1 ether, 10 ether, uint64(block.timestamp + 30 days)));
        vm.stopPrank();
    }

    modifier forked() {
        if (address(guard) == address(0)) {
            emit log("skipped: set RPC_URL to run the fork tests");
            return;
        }
        _;
    }

    // ── Hops ─────────────────────────────────────────────────────────

    function _noHop() internal pure returns (LongAdapter.Hop memory h) {}

    /// ETH / USDG on V4 (its dynamic fee and hook).
    function _usdgV4() internal pure returns (LongAdapter.Hop memory h) {
        h = LongAdapter.Hop(true, address(0), DYNAMIC, 10, USDG_HOOK, 0, 0, address(0));
    }

    /// SPCX / wrapped ETH on V3, 0.05%.
    function _spcxV3() internal pure returns (LongAdapter.Hop memory h) {
        h.fee = 500;
    }

    /// DJT / wrapped ETH on V3, 0.3%.
    function _djtV3() internal pure returns (LongAdapter.Hop memory h) {
        h.fee = 3000;
    }

    /// OPENAIx1L through USDG on V4: OPENAIx1L / USDG (0.5%, no hook), then USDG / ETH.
    function _openAiViaUsdgV4() internal pure returns (LongAdapter.Hop memory h) {
        h = LongAdapter.Hop(true, USDG, 5000, 50, address(0), DYNAMIC, 10, USDG_HOOK);
    }

    function _params(bool buy, address token, uint256 amountIn, uint256 minOut, LongAdapter.Hop memory h) internal pure returns (bytes memory) {
        return abi.encode(LongAdapter.Params(buy, token, amountIn, minOut, h));
    }

    /// A buy, then a sale of all of it; checks that ETH, not the pair token, is what moves, and nothing stays behind.
    function _roundTrip(address token, address pairToken, uint256 eth, LongAdapter.Hop memory h) internal returns (uint256 back) {
        uint256 ethBefore = account.balance;
        uint256 pairBefore = pairToken == address(0) ? 0 : IERC20(pairToken).balanceOf(account);
        uint256 routerPair = pairToken == address(0) ? 0 : IERC20(pairToken).balanceOf(UNIVERSAL_ROUTER);
        vm.prank(operator);
        guard.trade(account, long, _params(true, token, eth, 1, h));
        uint256 tokens = IERC20(token).balanceOf(account);
        assertGt(tokens, 0, "bought the token");
        uint256 spent = ethBefore - account.balance;
        assertLe(spent, eth + eth / 200 + 0.001 ether, "at most the ETH given, its 0.5% fee and gas");
        assertEq(UNIVERSAL_ROUTER.balance, 0, "no ETH left in the router");

        uint256 mid = account.balance;
        vm.prank(operator);
        guard.trade(account, long, _params(false, token, tokens, 1, h));
        assertEq(IERC20(token).balanceOf(account), 0, "sold it all");
        back = account.balance - mid;
        assertGt(back, 0, "ETH back from the sale");
        if (pairToken != address(0)) {
            assertEq(IERC20(pairToken).balanceOf(account), pairBefore, "the pair token went back to ETH");
            assertEq(IERC20(pairToken).balanceOf(UNIVERSAL_ROUTER), routerPair, "none of it left in the router");
        }
        assertEq(UNIVERSAL_ROUTER.balance, 0);
        assertEq(address(long).balance, 0, "the adapter holds nothing");
    }

    // ── Trades ───────────────────────────────────────────────────────

    function test_anEthPairedLongToken() public forked {
        uint256 back = _roundTrip(ETH_LONG, address(0), 0.01 ether, _noHop());
        // Both ways: the LP fee (0.2%) and Rehype's (1.3% after its first 10 s, 1.625% as charged), and the price impact.
        assertGt(back, 0.0094 ether, "about 3.5% lost there and back");
    }

    function test_aStockTokenPairThroughItsV3Pool() public forked {
        _roundTrip(SPCX_LONG, SPCX, 0.01 ether, _spcxV3());
    }

    function test_anotherStockTokenPairThroughItsV3Pool() public forked {
        _roundTrip(DJT_LONG, DJT, 0.005 ether, _djtV3());
    }

    function test_aUsdgPairInOneV4Path() public forked {
        _roundTrip(USDG_LONG, USDG, 0.01 ether, _usdgV4());
    }

    function test_aLeveragedTokenPairThroughUsdgInOneV4Path() public forked {
        _roundTrip(OPENAI_LONG, OPENAI_X1L, 0.01 ether, _openAiViaUsdgV4());
    }

    function test_theMarketIsDopplers() public forked {
        LongAdapter.Market memory m = long.market(SPCX_LONG);
        assertEq(m.pair, SPCX);
        assertEq(m.fee, DYNAMIC);
        assertEq(m.tickSpacing, 8);
        assertEq(m.hooks, INITIALIZER);
        assertEq(long.market(ETH_LONG).pair, address(0));
    }

    // ── Routes ───────────────────────────────────────────────────────

    function _hopId(LongAdapter.Hop memory h) internal pure returns (bytes32) {
        return Routes.uniswap(h.v4, h.fee, h.tickSpacing, h.hooks, h.via, h.viaFee, h.viaTickSpacing, h.viaHooks);
    }

    function test_routesNameTheHop_andAreNotOpen() public forked {
        (, IVenueAdapter.Route memory r) = long.plan(account, _params(true, USDG_LONG, 1, 1, _usdgV4()));
        assertEq(r.id, Routes.pair(Routes.LONG, _hopId(_usdgV4())));
        assertFalse(r.open);
        (, r) = long.plan(account, _params(true, ETH_LONG, 1, 1, _usdgV4()));
        assertEq(r.id, Routes.LONG, "an ETH-paired token's route ignores any hop");
        assertFalse(r.open);
        // The worker computes the same ids.
        assertEq(Routes.LONG, LONG_ROUTE);
        assertEq(Routes.pair(Routes.LONG, _hopId(_usdgV4())), LONG_USDG_V4_ROUTE);
    }

    /// keccak256("spin.route.long"), and Routes.pair(Routes.LONG, the ETH / USDG V4 hop), as the worker's routes give them.
    bytes32 constant LONG_ROUTE = keccak256("spin.route.long");
    bytes32 constant LONG_USDG_V4_ROUTE = 0x93d3db70c72c387f04c4240f5efbee7426a837ec76844996360c03619037a17c;

    function test_aSaleOnlyGoesThroughAHopItsTokensWereBoughtThrough() public forked {
        LongAdapter.Hop memory v3;
        v3.fee = 100; // wrapped ETH / USDG on V3, 0.01%
        vm.prank(operator);
        guard.trade(account, long, _params(true, USDG_LONG, 0.01 ether, 1, _usdgV4()));
        uint256 tokens = IERC20(USDG_LONG).balanceOf(account);
        vm.prank(operator);
        vm.expectRevert(SpinBotGuard.NoCredit.selector);
        guard.trade(account, long, _params(false, USDG_LONG, tokens, 1, v3));
        bytes32 from = Routes.pair(Routes.LONG, _hopId(_usdgV4()));
        bytes32 to = Routes.pair(Routes.LONG, _hopId(v3));
        vm.prank(holder);
        guard.moveCredit(account, USDG_LONG, from, to, tokens);
        vm.prank(operator);
        guard.trade(account, long, _params(false, USDG_LONG, tokens, 1, v3));
        assertEq(IERC20(USDG_LONG).balanceOf(account), 0);
    }

    // ── What the adapter refuses ─────────────────────────────────────

    function test_aTokenDopplerDidNotLaunchIsRefused() public forked {
        vm.expectRevert(LongAdapter.NotLongToken.selector);
        long.plan(account, _params(true, PONS_TOKEN, 1, 1, _usdgV4()));
    }

    function test_aDopplerHookNotOnTheListIsRefused() public forked {
        (,, address other,,,,) = IDopplerHookInitializer(INITIALIZER).getState(OTHER_DOPPLER);
        vm.expectRevert(abi.encodeWithSelector(HookListUser.HookNotAllowed.selector, other));
        long.plan(account, _params(true, OTHER_DOPPLER, 1, 1, _usdgV4()));
        vm.prank(admin);
        long.setDopplerHook(REHYPE, false);
        vm.expectRevert(abi.encodeWithSelector(HookListUser.HookNotAllowed.selector, REHYPE));
        long.plan(account, _params(true, ETH_LONG, 1, 1, _noHop()));
    }

    function test_aPoolWhoseDopplerHookCanChangeIsRefused() public forked {
        // Its timelock could set another Doppler hook on it: refused, whatever hook it has now.
        vm.mockCall(
            AIRLOCK,
            abi.encodeCall(IDopplerAirlock.getAssetData, (USDG_LONG)),
            abi.encode(USDG, address(0x7117), address(0), address(0), INITIALIZER, address(0), address(0), 0, 0, address(0))
        );
        vm.expectRevert(LongAdapter.NotLongToken.selector);
        long.plan(account, _params(true, USDG_LONG, 1, 1, _usdgV4()));
    }

    function test_aHopThroughAHookTheUniswapAdapterDoesNotAllowIsRefused() public forked {
        LongAdapter.Hop memory h = _usdgV4();
        h.hooks = address(0xBAD);
        vm.expectRevert(abi.encodeWithSelector(HookListUser.HookNotAllowed.selector, address(0xBAD)));
        long.plan(account, _params(true, USDG_LONG, 1, 1, h));
    }

    function test_onlyTheAdminKeepsTheList() public forked {
        vm.expectRevert(AdminWithdrawable.NotAdmin.selector);
        long.setDopplerHook(address(0xBAD), true);
        assertTrue(long.allowedDopplerHook(REHYPE));
    }
}
