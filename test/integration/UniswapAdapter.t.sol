// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SpinBotGuard, IERC6551Registry} from "../../src/bots/SpinBotGuard.sol";
import {UniswapAdapter} from "../../src/bots/adapters/UniswapAdapter.sol";
import {HookList, HookListUser, IHookList} from "../../src/bots/HookList.sol";
import {AdminWithdrawable} from "../../src/utils/Withdrawable.sol";
import {IPonsFactory} from "../../src/bots/adapters/PonsAdapter.sol";
import {IVenueAdapter} from "../../src/bots/IVenueAdapter.sol";
import {Routes} from "../../src/bots/Routes.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {Spinners} from "../../src/collection/Spinners.sol";

interface ITokenboundPermissions {
    function setPermissions(address[] calldata callers, bool[] calldata permissions) external;
}

interface IRegistryCreateAccount {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

interface IPermit2Allowance {
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/**
 * UniswapAdapter on a fork of Robinhood Chain, against the deployed Universal
 * Router, Permit2 and pools, with the real guard and Tokenbound account. Buys
 * and sells through V3 pools (against wrapped ETH, and through USDG) and V4
 * pools (no hook, and the hooks on the day-one list), and refuses a hook that
 * is not on the list.
 *
 *   RPC_URL=<archive rpc> npm run test
 */
contract UniswapAdapterFork is Test {
    IERC6551Registry constant REGISTRY = IERC6551Registry(0x000000006551c19487814612e58FE06813775758);
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    uint256 constant PINNED_BLOCK = 90025435;

    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint24 constant DYNAMIC_FEE = 0x800000;

    /// V3: PONS against wrapped ETH (1%); NVDA against USDG (0.05%); wrapped ETH / USDG (0.01%).
    address constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    uint24 constant V3_WETH_USDG_FEE = 100;

    /// V4 against native ETH: STONKBROKER (no hook), STANDARD (TaxHook), NOVAAI (Pons hook),
    /// MOW (Hookr: a fixed 1% fee, no cuts) and FENDI (Hookr: a 0.25% cut of buys, a fee that grows with size).
    address constant STONKBROKER = 0xe934e36A439C94017B64a3FecE66AF12099aBF50;
    address constant STANDARD = 0x88ad8DdF1E3898412146a534538d418c6F8A9062;
    address constant NOVAAI = 0x51250B135174Ca09450EC01c4afF73CF69DBb590;
    address constant MOW = 0x0B7C6c138dc75622f4200d157B13FB93e6BD94FA;
    address constant FENDI = 0xcA53d5d203c707aBEeA5036ffEd2607fD39bD910;
    /// V4 ETH / USDG (Fables, tick spacing 10), and PONS / USDG (Fables, tick spacing 60).
    int24 constant ETH_USDG_TICK_SPACING = 10;
    int24 constant PONS_USDG_TICK_SPACING = 60;

    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    IPonsFactory constant PONS_FACTORY = IPonsFactory(0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e);
    address constant FABLES_ETH_USDG = 0x06a889870C8f83640D6816319f72e2aA579b6080;
    address constant FABLES_USDG = 0x08E52564Bad99E05a694b4809F397edcA417A080;
    address constant TAX_HOOK = 0xF1eE073811B14359D850825E48d200483200eDcd;
    address constant HOOKR = 0xb3cA29cF721380CEe8b8e4755F3865Ebc68Fe8cC;
    /// Not on the list.
    address constant DOPPLER = 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544;

    SpinBotGuard guard;
    UniswapAdapter uni;
    HookList hookList;
    Spinners spinners;
    address account;
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address holder = makeAddr("holder");

    /// The hooks reviewed for the first deployment.
    function dayOneHooks() internal pure returns (address[] memory hooks) {
        hooks = new address[](11);
        hooks[0] = PONS_HOOK;
        hooks[1] = FABLES_ETH_USDG;
        hooks[2] = FABLES_USDG;
        hooks[3] = 0xB608a78761f179f7C56f15E7D13921B92F00a080;
        hooks[4] = 0xA0E8fBFf13E24Af2b5e61A72800E08a161bDe080;
        hooks[5] = 0x5Eb87F69bE00Df39981622Fd60A8De4b7837e080;
        hooks[6] = 0x594e8e6281eDf2d363a0293a50004Cf868E7a080;
        hooks[7] = TAX_HOOK;
        hooks[8] = 0xC15b155a3094934171A15625d1a80Aba267B6080;
        hooks[9] = 0x64E9ae1066c47Ac4a3cc0a5bd7B135908590e088;
        hooks[10] = HOOKR;
    }

    function setUp() public {
        string memory rpc = vm.envOr("RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // every test below skips
        vm.createSelectFork(rpc, PINNED_BLOCK);
        // A fork does not run Arbitrum's precompiles; empty code there reads as no parent-chain fee, as the chain says today.
        vm.etch(0x000000000000000000000000000000000000006C, "");

        spinners = new Spinners("Spinners", "SPIN", 7777, admin, payable(treasury), 500, "ipfs://art/", address(REGISTRY), ACCOUNT_V3);
        vm.prank(admin);
        spinners.setMintOpen(true);
        vm.startPrank(holder);
        spinners.mint(1);
        spinners.activate(1);
        vm.stopPrank();
        account = IRegistryCreateAccount(address(REGISTRY)).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), 1);
        vm.deal(account, 1 ether);

        guard = new SpinBotGuard(REGISTRY, ACCOUNT_V3, address(spinners), admin, treasury, 50, 1 gwei, 0.001 ether, 110_000, 80_000);
        vm.prank(admin);
        hookList = new HookList(dayOneHooks());
        uni = new UniswapAdapter(UNIVERSAL_ROUTER, PERMIT2, WETH, PONS_FACTORY, PONS_HOOK, admin, hookList);
        vm.startPrank(admin);
        guard.setOperator(operator, true);
        guard.addVenue(address(uni));
        vm.stopPrank();

        vm.startPrank(holder);
        address[] memory callers = new address[](1);
        callers[0] = address(guard);
        bool[] memory perms = new bool[](1);
        perms[0] = true;
        ITokenboundPermissions(account).setPermissions(callers, perms);
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

    function _v3(address token, uint24 fee) internal pure returns (UniswapAdapter.Params memory p) {
        p.token = token;
        p.fee = fee;
    }

    function _v3ViaUsdg(address token, uint24 fee) internal pure returns (UniswapAdapter.Params memory p) {
        p = _v3(token, fee);
        p.via = USDG;
        p.viaFee = V3_WETH_USDG_FEE;
    }

    function _v4(address token, uint24 fee, int24 tickSpacing, address hooks) internal pure returns (UniswapAdapter.Params memory p) {
        p.v4 = true;
        p.token = token;
        p.fee = fee;
        p.tickSpacing = tickSpacing;
        p.hooks = hooks;
    }

    function _v4ViaUsdg(address token, uint24 fee, int24 tickSpacing, address hooks)
        internal
        pure
        returns (UniswapAdapter.Params memory p)
    {
        p = _v4(token, fee, tickSpacing, hooks);
        p.via = USDG;
        p.viaFee = DYNAMIC_FEE;
        p.viaTickSpacing = ETH_USDG_TICK_SPACING;
        p.viaHooks = FABLES_ETH_USDG;
    }

    function _trade(UniswapAdapter.Params memory p, bool buy, uint256 amountIn) internal {
        p.buy = buy;
        p.amountIn = amountIn;
        p.minOut = 1;
        vm.prank(operator);
        guard.trade(account, uni, abi.encode(p));
    }

    function _roundTrip(UniswapAdapter.Params memory p, uint256 maxLoss) internal {
        uint256 ethBefore = account.balance;
        _trade(p, true, 0.05 ether);
        uint256 tokens = IERC20(p.token).balanceOf(account);
        assertGt(tokens, 0, "bought the token into the account");
        assertEq(account.balance, ethBefore - 0.05 ether - 0.00025 ether, "spent the buy plus the 0.5% fee");

        _trade(p, false, tokens);
        assertEq(IERC20(p.token).balanceOf(account), 0, "sold it all");
        assertEq(IERC20(p.token).allowance(account, PERMIT2), 0, "token approval reset");
        (uint160 left,,) = IPermit2Allowance(PERMIT2).allowance(account, p.token, UNIVERSAL_ROUTER);
        assertEq(left, 0, "Permit2 approval reset");
        assertGt(account.balance, ethBefore - maxLoss, "ETH back in the account, less fees and the pools' spread");
        assertEq(address(uni).balance, 0, "the adapter holds nothing");
        assertEq(IERC20(WETH).balanceOf(account), 0, "no wrapped ETH left behind");
        assertEq(IERC20(USDG).balanceOf(account), 0, "no USDG left behind");
    }

    function test_theAdminWithdrawsToTheTreasuryItSetsOnly() public forked {
        vm.deal(address(uni), 1 ether);
        vm.prank(admin);
        vm.expectRevert(UniswapAdapter.NoTreasury.selector);
        uni.withdrawEth(1 ether);
        vm.expectRevert(UniswapAdapter.NotAdmin.selector);
        uni.setTreasury(payable(address(this)));
        vm.startPrank(admin);
        uni.setTreasury(payable(treasury));
        uni.withdrawEth(1 ether);
        vm.stopPrank();
        assertEq(treasury.balance, 1 ether);
        vm.expectRevert(UniswapAdapter.NotAdmin.selector);
        uni.withdrawEth(0);
    }

    function test_aBuyCreditsItsRouteAndASellUsesItUp() public forked {
        UniswapAdapter.Params memory p = _v3(PONS, 10_000);
        bytes32 route = Routes.uniswap(false, 10_000, 0, address(0), address(0), 0, 0, address(0));
        _trade(p, true, 0.05 ether);
        uint256 tokens = IERC20(PONS).balanceOf(account);
        assertEq(guard.credit(account, PONS, route), tokens, "the tokens bought are credited to their route");
        _trade(p, false, tokens / 2);
        assertEq(guard.credit(account, PONS, route), tokens - tokens / 2, "a sell uses the credit up");
    }

    function test_tokensWithNoCreditCannotBeSoldThroughAPool() public forked {
        // Tokens that came in another way (here: dealt): the bot cannot sell them through any pool.
        deal(PONS, account, 1e21);
        UniswapAdapter.Params memory p = _v3(PONS, 10_000);
        p.buy = false;
        p.amountIn = 1e21;
        p.minOut = 1;
        vm.prank(operator);
        vm.expectRevert(SpinBotGuard.NoCredit.selector);
        guard.trade(account, uni, abi.encode(p));
    }

    function test_tokensBoughtInOnePoolCannotBeSoldInAnother() public forked {
        _trade(_v3(PONS, 10_000), true, 0.05 ether);
        uint256 tokens = IERC20(PONS).balanceOf(account);
        // The same token, through USDG: another route, with no credit.
        UniswapAdapter.Params memory q = _v3ViaUsdg(PONS, 10_000);
        q.buy = false;
        q.amountIn = tokens;
        q.minOut = 1;
        vm.prank(operator);
        vm.expectRevert();
        guard.trade(account, uni, abi.encode(q));
        assertEq(IERC20(PONS).balanceOf(account), tokens, "nothing sold");
    }

    function test_v3PoolAgainstWrappedEth() public forked {
        _roundTrip(_v3(PONS, 10_000), 0.003 ether);
    }

    function test_v3PoolThroughUsdg() public forked {
        _roundTrip(_v3ViaUsdg(NVDA, 500), 0.003 ether);
    }

    function test_v4PoolWithNoHook() public forked {
        _roundTrip(_v4(STONKBROKER, 10_000, 200, address(0)), 0.003 ether);
    }

    function test_v4PoolThroughUsdgWithFablesHooks() public forked {
        _roundTrip(_v4ViaUsdg(PONS, DYNAMIC_FEE, PONS_USDG_TICK_SPACING, FABLES_USDG), 0.006 ether);
    }

    function test_v4PoolWithTheTaxHook() public forked {
        // 2% tax on the buy, 3% on the sale, and the pool's 1% each way.
        _roundTrip(_v4(STANDARD, 10_000, 200, TAX_HOOK), 0.006 ether);
    }

    function test_v4PoolWithThePonsHook() public forked {
        _roundTrip(_v4(NOVAAI, 0, 200, PONS_HOOK), 0.006 ether);
    }

    function test_v4PoolWithTheHookrHookAndNoCuts() public forked {
        // MOW's frozen stack: a 1% fee each way, nothing else.
        _roundTrip(_v4(MOW, DYNAMIC_FEE, 60, HOOKR), 0.003 ether);
    }

    function test_v4PoolWithTheHookrHookAndACut() public forked {
        // A cut of the buy's input needs the router's full-range price limit, or the hook reverts.
        _roundTrip(_v4(FENDI, DYNAMIC_FEE, 60, HOOKR), 0.006 ether);
    }

    function test_aHookNotOnTheListIsRefused() public forked {
        UniswapAdapter.Params memory p = _v4(MOW, DYNAMIC_FEE, 60, DOPPLER);
        p.buy = true;
        p.amountIn = 0.05 ether;
        p.minOut = 1;
        vm.expectRevert(abi.encodeWithSelector(HookListUser.HookNotAllowed.selector, DOPPLER));
        uni.plan(account, abi.encode(p));

        // Through the route's other pool too.
        UniswapAdapter.Params memory q = _v4ViaUsdg(PONS, DYNAMIC_FEE, PONS_USDG_TICK_SPACING, FABLES_USDG);
        q.viaHooks = DOPPLER;
        vm.expectRevert(abi.encodeWithSelector(HookListUser.HookNotAllowed.selector, DOPPLER));
        uni.plan(account, abi.encode(q));

        vm.prank(admin);
        hookList.setHook(DOPPLER, true);
        (IVenueAdapter.Call[] memory calls,) = uni.plan(account, abi.encode(p));
        assertEq(calls.length, 1, "planned once the admin allows it");
        assertTrue(uni.allowedHook(DOPPLER), "the adapter answers from the list");
    }

    function test_onlyTheAdminKeepsTheList() public forked {
        vm.expectRevert(AdminWithdrawable.NotAdmin.selector);
        hookList.setHook(DOPPLER, true);
        vm.expectRevert(UniswapAdapter.NotAdmin.selector);
        uni.setAdmin(address(this));

        address next = makeAddr("next admin");
        vm.prank(admin);
        hookList.setAdmin(next);
        vm.prank(next);
        hookList.setHook(PONS_HOOK, false);
        assertFalse(uni.allowedHook(PONS_HOOK));
    }

    function test_theAdminPointsTheAdapterAtAnotherList() public forked {
        HookList next = new HookList(new address[](0));
        vm.expectRevert(UniswapAdapter.NotAdmin.selector);
        uni.setHookList(next);
        vm.prank(admin);
        vm.expectRevert(HookListUser.NoHookList.selector);
        uni.setHookList(IHookList(address(0)));

        vm.prank(admin);
        uni.setHookList(next);
        assertEq(address(uni.hookList()), address(next));
        assertFalse(uni.allowedHook(PONS_HOOK), "the new list's answer");
        UniswapAdapter.Params memory p = _v4(MOW, DYNAMIC_FEE, 60, HOOKR);
        p.buy = true;
        p.amountIn = 0.05 ether;
        vm.expectRevert(abi.encodeWithSelector(HookListUser.HookNotAllowed.selector, HOOKR));
        uni.plan(account, abi.encode(p));
    }

    function test_aMinimumTheMarketCannotMeetReverts() public forked {
        UniswapAdapter.Params memory p = _v4(STONKBROKER, 10_000, 200, address(0));
        p.buy = true;
        p.amountIn = 0.05 ether;
        p.minOut = type(uint128).max;
        vm.prank(operator);
        vm.expectRevert();
        guard.trade(account, uni, abi.encode(p));

        UniswapAdapter.Params memory q = _v3(PONS, 10_000);
        q.buy = true;
        q.amountIn = 0.05 ether;
        q.minOut = type(uint128).max;
        vm.prank(operator);
        vm.expectRevert();
        guard.trade(account, uni, abi.encode(q));
    }

    function test_theGasRefundCoversUniswapTrades() public forked {
        uint256 price = 0.02 gwei;
        vm.txGasPrice(price);
        UniswapAdapter.Params[] memory routes = new UniswapAdapter.Params[](4);
        routes[0] = _v3ViaUsdg(NVDA, 500);
        routes[1] = _v4ViaUsdg(PONS, DYNAMIC_FEE, PONS_USDG_TICK_SPACING, FABLES_USDG);
        routes[2] = _v4(STANDARD, 10_000, 200, TAX_HOOK);
        routes[3] = _v4(FENDI, DYNAMIC_FEE, 60, HOOKR);
        for (uint256 i; i < routes.length; i++) {
            UniswapAdapter.Params memory p = routes[i];
            p.buy = true;
            p.amountIn = 0.05 ether;
            p.minOut = 1;
            bytes memory params = abi.encode(p);
            uint256 opBefore = operator.balance;
            uint256 g = gasleft();
            vm.prank(operator);
            guard.trade(account, uni, params);
            uint256 txGas = _txGas(abi.encodeCall(SpinBotGuard.trade, (account, uni, params)), g - gasleft());
            uint256 refund = operator.balance - opBefore;
            emit log_named_uint("buy: transaction gas", txGas);
            emit log_named_uint("refunded gas", refund / price);
            assertGe(refund, txGas * price, "buy: the whole cost is refunded");

            p.buy = false;
            p.amountIn = IERC20(p.token).balanceOf(account);
            params = abi.encode(p);
            opBefore = operator.balance;
            g = gasleft();
            vm.prank(operator);
            guard.trade(account, uni, params);
            txGas = _txGas(abi.encodeCall(SpinBotGuard.trade, (account, uni, params)), g - gasleft());
            refund = operator.balance - opBefore;
            emit log_named_uint("sell: transaction gas", txGas);
            emit log_named_uint("refunded gas", refund / price);
            assertGe(refund, txGas * price, "sell: the whole cost is refunded");
        }
    }

    function _txGas(bytes memory data, uint256 measured) internal pure returns (uint256 gas) {
        gas = 21_000 + measured;
        for (uint256 i = 0; i < data.length; i++) gas += data[i] == 0 ? 4 : 16;
    }
}
