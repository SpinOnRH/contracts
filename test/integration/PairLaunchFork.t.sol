// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SpinBotGuard, IERC6551Registry} from "../../src/bots/SpinBotGuard.sol";
import {UniswapAdapter} from "../../src/bots/adapters/UniswapAdapter.sol";
import {IPonsFactory} from "../../src/bots/adapters/PonsAdapter.sol";
import {PairLaunchAdapter, ITorchTokens} from "../../src/bots/adapters/PairLaunchAdapter.sol";
import {HookList, HookListUser, IHookList} from "../../src/bots/HookList.sol";
import {Routes} from "../../src/bots/Routes.sol";
import {IVenueAdapter} from "../../src/bots/IVenueAdapter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {Spinners} from "../../src/collection/Spinners.sol";

interface ITokenboundPermissionsPair {
    function setPermissions(address[] calldata callers, bool[] calldata permissions) external;
}

interface IRegistryCreateAccountPair {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

/**
 * Launchpad tokens paired with another token, on a fork of Robinhood Chain: ETH goes through the
 * pair token on Uniswap (V3 or V4, directly or through USDG) to a Pons curve, a graduated Pons
 * token's own pool, or a Torch token's pool, and back.
 *
 *   RPC_URL=<archive rpc> npm run test
 */
contract PairLaunchFork is Test {
    IERC6551Registry constant REGISTRY = IERC6551Registry(0x000000006551c19487814612e58FE06813775758);
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    uint256 constant PINNED_BLOCK = 100897000;

    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant PONS = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant TORCH_FACTORY = 0x7891eA889899928aFE637e4Cca8106188427776a;

    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant TORCH = 0x000050E18ffa3F8F7aD170Eb9CeF160eb3Ed1111;
    /// ETH / USDG on V4: a dynamic fee, and its hook.
    address constant USDG_HOOK = 0x06a889870C8f83640D6816319f72e2aA579b6080;
    uint24 constant DYNAMIC = 0x800000;

    /// A Pons curve paired with USDG (3,236 USDG of virtual quote), and one paired with TSLA.
    address constant USDG_CURVE_TOKEN = 0x6b9565eFEeFf487e508Bb8dd4967DEC50859491c;
    address constant TSLA_CURVE_TOKEN = 0xd128973D08D6f11Efd26ce8A5D5120C842db8d73;
    /// Graduated Pons tokens: one paired with USDG, one with NVDA (its deep pool: V3 against wrapped ETH, 0.05%).
    address constant USDG_POOL_TOKEN = 0x57dDB5435C6CB7b1A52a246c70eDB08B4e084892;
    address constant NVDA_POOL_TOKEN = 0xD0fF6D6fA0228f03D09F74eBCE557726d2d4eE77;
    /// Torch tokens: one paired with TORCH, one with USDG.
    address constant TORCH_PAIRED = 0x9c87B4cfa21266d1638f437c96dBe1012CB81111;
    address constant USDG_TORCH = 0xD523Ff1DcC37275b346740DccE4406E147d41111;
    /// An ETH-paired Torch token: not this adapter's.
    address constant ETH_TORCH = TORCH;

    uint8 constant CURVE = 0;
    uint8 constant PONS_POOL = 1;
    uint8 constant TORCH_POOL = 2;

    SpinBotGuard guard;
    UniswapAdapter uni;
    PairLaunchAdapter pair;
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
        account = IRegistryCreateAccountPair(address(REGISTRY)).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), 1);
        vm.deal(account, 2 ether);

        guard = new SpinBotGuard(REGISTRY, ACCOUNT_V3, address(spinners), admin, treasury, 50, 1 gwei, 0.001 ether, 110_000, 80_000);
        address[] memory hooks = new address[](1);
        hooks[0] = USDG_HOOK;
        HookList hookList = new HookList(hooks);
        uni = new UniswapAdapter(UNIVERSAL_ROUTER, PERMIT2, WETH, IPonsFactory(PONS), PONS_HOOK, admin, hookList);
        pair = new PairLaunchAdapter(
            UNIVERSAL_ROUTER, PERMIT2, WETH, IPonsFactory(PONS), PONS_HOOK, ITorchTokens(TORCH_FACTORY), 3000, 60, hookList
        );
        vm.startPrank(admin);
        guard.setOperator(operator, true);
        guard.addVenue(address(uni));
        guard.addVenue(address(pair));
        vm.stopPrank();

        vm.startPrank(holder);
        address[] memory callers = new address[](1);
        callers[0] = address(guard);
        bool[] memory perms = new bool[](1);
        perms[0] = true;
        ITokenboundPermissionsPair(account).setPermissions(callers, perms);
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

    /// ETH / USDG on V4 (its dynamic fee and hook).
    function _usdgV4() internal pure returns (PairLaunchAdapter.Hop memory h) {
        h = PairLaunchAdapter.Hop(true, address(0), DYNAMIC, 10, USDG_HOOK, 0, 0, address(0));
    }

    /// Wrapped ETH / USDG on V3, 0.01%.
    function _usdgV3() internal pure returns (PairLaunchAdapter.Hop memory h) {
        h.fee = 100;
    }

    /// TSLA through USDG on V4: TSLA / USDG (0.3%, no hook), then USDG / ETH.
    function _tslaViaUsdgV4() internal pure returns (PairLaunchAdapter.Hop memory h) {
        h = PairLaunchAdapter.Hop(true, USDG, 3000, 60, address(0), DYNAMIC, 10, USDG_HOOK);
    }

    /// TSLA / wrapped ETH on V3, 0.3%.
    function _tslaV3() internal pure returns (PairLaunchAdapter.Hop memory h) {
        h.fee = 3000;
    }

    /// NVDA / wrapped ETH on V3, 0.05%.
    function _nvdaV3() internal pure returns (PairLaunchAdapter.Hop memory h) {
        h.fee = 500;
    }

    /// TORCH / ETH on V4: TORCH's own Torch pool (0.3%, no hook).
    function _torchV4() internal pure returns (PairLaunchAdapter.Hop memory h) {
        h = PairLaunchAdapter.Hop(true, address(0), 3000, 60, address(0), 0, 0, address(0));
    }

    function _params(uint8 kind, bool buy, address token, uint256 amountIn, uint256 minOut, uint256 pairOut, PairLaunchAdapter.Hop memory h)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(PairLaunchAdapter.Params(kind, buy, token, amountIn, minOut, pairOut, h));
    }

    /// A buy, then a sale of all of it; checks that ETH, not the pair token, is what moves, and nothing stays behind.
    function _roundTrip(uint8 kind, address token, address pairToken, uint256 eth, uint256 pairOut, PairLaunchAdapter.Hop memory h)
        internal
    {
        uint256 ethBefore = account.balance;
        uint256 pairBefore = IERC20(pairToken).balanceOf(account);
        uint256 routerPair = IERC20(pairToken).balanceOf(UNIVERSAL_ROUTER);
        vm.prank(operator);
        guard.trade(account, pair, _params(kind, true, token, eth, 1, pairOut, h));
        uint256 tokens = IERC20(token).balanceOf(account);
        assertGt(tokens, 0, "bought the token");
        uint256 spent = ethBefore - account.balance;
        assertGt(spent, 0, "with ETH");
        assertLe(spent, eth + eth / 200 + 0.001 ether, "at most the ETH given, its 0.5% fee and gas");
        assertGe(IERC20(pairToken).balanceOf(account), pairBefore, "no pair token was taken from the account");
        assertEq(UNIVERSAL_ROUTER.balance, 0, "no ETH left in the router");

        vm.prank(operator);
        guard.trade(account, pair, _params(kind, false, token, tokens, 1, 0, h));
        assertEq(IERC20(token).balanceOf(account), 0, "sold it all");
        assertGt(account.balance, ethBefore - spent, "ETH back from the sale");
        assertGe(IERC20(pairToken).balanceOf(account), pairBefore, "the pair token went back to ETH");
        assertEq(IERC20(pairToken).balanceOf(UNIVERSAL_ROUTER), routerPair, "none of it left in the router");
        assertEq(UNIVERSAL_ROUTER.balance, 0);
        assertEq(address(pair).balance, 0, "the adapter holds nothing");
    }

    // ── Pons curves ──────────────────────────────────────────────────

    function test_aUsdgCurveThroughTheV4Hop() public forked {
        _roundTrip(CURVE, USDG_CURVE_TOKEN, USDG, 0.05 ether, 100e6, _usdgV4());
    }

    function test_aUsdgCurveThroughTheV3Hop() public forked {
        _roundTrip(CURVE, USDG_CURVE_TOKEN, USDG, 0.05 ether, 100e6, _usdgV3());
    }

    function test_aStockCurveThroughUsdgOnV4() public forked {
        _roundTrip(CURVE, TSLA_CURVE_TOKEN, TSLA, 0.05 ether, 0.2 ether, _tslaViaUsdgV4());
    }

    function test_aStockCurveThroughItsV3Pool() public forked {
        _roundTrip(CURVE, TSLA_CURVE_TOKEN, TSLA, 0.05 ether, 0.2 ether, _tslaV3());
    }

    function test_aCurveBuyGetsExactlyThePairTokenItNeedsAndReturnsTheRestOfTheEth() public forked {
        uint256 ethBefore = account.balance;
        vm.prank(operator);
        guard.trade(account, pair, _params(CURVE, true, USDG_CURVE_TOKEN, 0.5 ether, 1, 100e6, _usdgV4()));
        // 100 USDG is about 0.043 ETH: the rest of the 0.5 ETH came back.
        assertLt(ethBefore - account.balance, 0.06 ether);
    }

    function test_aCurveBuyLeavesThePairTokenTheAccountAlreadyHeld() public forked {
        UniswapAdapter.Params memory u;
        (u.v4, u.buy, u.token, u.fee, u.tickSpacing, u.hooks, u.amountIn, u.minOut) = (true, true, USDG, DYNAMIC, 10, USDG_HOOK, 0.02 ether, 1);
        vm.prank(operator);
        guard.trade(account, uni, abi.encode(u));
        uint256 held = IERC20(USDG).balanceOf(account);
        assertGt(held, 0);
        _roundTrip(CURVE, USDG_CURVE_TOKEN, USDG, 0.05 ether, 100e6, _usdgV4());
        assertEq(IERC20(USDG).balanceOf(account), held, "the account's own USDG is untouched");
    }

    function test_theBalanceCheckRevertsWhenThePairBalanceFell() public forked {
        vm.expectRevert(PairLaunchAdapter.PairBalanceFell.selector);
        pair.checkBalance(USDG, account, 1);
    }

    // ── Graduated Pons tokens' own pools ─────────────────────────────

    function test_aGraduatedUsdgTokenInOneV4Path() public forked {
        _roundTrip(PONS_POOL, USDG_POOL_TOKEN, USDG, 0.02 ether, 0, _usdgV4());
    }

    function test_aGraduatedNvdaTokenThroughNvdasV3PoolThenItsOwnV4Pool() public forked {
        _roundTrip(PONS_POOL, NVDA_POOL_TOKEN, 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, 0.02 ether, 0, _nvdaV3());
    }

    function test_aPoolSaleOfATokenWithPermit2AtTheMaximumSkipsTheTokensApproval() public forked {
        // A token whose Permit2 allowance is already the maximum (as a token that fixes it there reports):
        // the sale sets and resets only Permit2's approval, and leaves the token's as it was.
        vm.prank(operator);
        guard.trade(account, pair, _params(PONS_POOL, true, USDG_POOL_TOKEN, 0.02 ether, 1, 0, _usdgV4()));
        uint256 tokens = IERC20(USDG_POOL_TOKEN).balanceOf(account);
        vm.prank(account);
        IERC20(USDG_POOL_TOKEN).approve(PERMIT2, type(uint256).max);
        (IVenueAdapter.Call[] memory calls,) = pair.plan(account, _params(PONS_POOL, false, USDG_POOL_TOKEN, tokens, 1, 0, _usdgV4()));
        assertEq(calls.length, 3, "Permit2's approval, the swap and its reset only");
        assertEq(calls[0].target, PERMIT2);
        vm.prank(operator);
        guard.trade(account, pair, _params(PONS_POOL, false, USDG_POOL_TOKEN, tokens, 1, 0, _usdgV4()));
        assertEq(IERC20(USDG_POOL_TOKEN).balanceOf(account), 0, "sold it all");
        assertEq(IERC20(USDG_POOL_TOKEN).allowance(account, PERMIT2), type(uint256).max, "the token's approval left as it was");
    }

    // ── Torch pools ──────────────────────────────────────────────────

    function test_aTorchTokenPairedWithTorch() public forked {
        _roundTrip(TORCH_POOL, TORCH_PAIRED, TORCH, 0.02 ether, 0, _torchV4());
    }

    function test_aTorchTokenPairedWithUsdg() public forked {
        _roundTrip(TORCH_POOL, USDG_TORCH, USDG, 0.02 ether, 0, _usdgV4());
    }

    // ── What the adapter refuses ─────────────────────────────────────

    function test_theKindsAreTheAdaptersOwn() public forked {
        assertEq(pair.CURVE(), CURVE);
        assertEq(pair.PONS_POOL(), PONS_POOL);
        assertEq(pair.TORCH(), TORCH_POOL);
    }

    function _hopId(PairLaunchAdapter.Hop memory h) internal pure returns (bytes32) {
        return Routes.uniswap(h.v4, h.fee, h.tickSpacing, h.hooks, h.via, h.viaFee, h.viaTickSpacing, h.viaHooks);
    }

    function test_routesNameTheLaunchpadAndTheHop_andAreNotOpen() public forked {
        (, IVenueAdapter.Route memory r) = pair.plan(account, _params(TORCH_POOL, true, USDG_TORCH, 1, 1, 0, _usdgV4()));
        assertEq(r.id, Routes.pair(Routes.TORCH, _hopId(_usdgV4())));
        assertFalse(r.open);
        (, r) = pair.plan(account, _params(CURVE, true, USDG_CURVE_TOKEN, 1, 1, 1, _usdgV4()));
        assertEq(r.id, Routes.pair(Routes.PONS, _hopId(_usdgV4())));
        assertFalse(r.open);
        (, IVenueAdapter.Route memory graduated) = pair.plan(account, _params(PONS_POOL, false, USDG_POOL_TOKEN, 1, 1, 0, _usdgV4()));
        assertEq(graduated.id, r.id, "a Pons token's curve and its graduated pool share a hop's route");
        (, r) = pair.plan(account, _params(CURVE, true, USDG_CURVE_TOKEN, 1, 1, 1, _usdgV3()));
        assertTrue(r.id != graduated.id, "another hop, another route");
        // The worker computes the same id.
        assertEq(Routes.pair(Routes.PONS, _hopId(_usdgV4())), PONS_USDG_V4_ROUTE);
    }

    /// Routes.pair(Routes.PONS, the ETH / USDG V4 hop), as the worker's pairRoute gives it.
    bytes32 constant PONS_USDG_V4_ROUTE = 0xb0ef74273c6b2148459e9c6e8efd652c24ce31ac5753b511d3da41ae070048cf;

    function test_aSaleOnlyGoesThroughAHopItsTokensWereBoughtThrough() public forked {
        vm.prank(operator);
        guard.trade(account, pair, _params(CURVE, true, USDG_CURVE_TOKEN, 0.05 ether, 1, 100e6, _usdgV4()));
        uint256 tokens = IERC20(USDG_CURVE_TOKEN).balanceOf(account);
        // A hop the tokens were not bought through (an attacker's thin pool would be one) has no credit.
        vm.prank(operator);
        vm.expectRevert(SpinBotGuard.NoCredit.selector);
        guard.trade(account, pair, _params(CURVE, false, USDG_CURVE_TOKEN, tokens, 1, 0, _usdgV3()));
        // The holder can move the credit to another hop; then the sale goes through it.
        bytes32 v4 = Routes.pair(Routes.PONS, _hopId(_usdgV4()));
        bytes32 v3 = Routes.pair(Routes.PONS, _hopId(_usdgV3()));
        assertEq(guard.credit(account, USDG_CURVE_TOKEN, v4), tokens);
        vm.prank(holder);
        guard.moveCredit(account, USDG_CURVE_TOKEN, v4, v3, tokens);
        vm.prank(operator);
        guard.trade(account, pair, _params(CURVE, false, USDG_CURVE_TOKEN, tokens, 1, 0, _usdgV3()));
        assertEq(IERC20(USDG_CURVE_TOKEN).balanceOf(account), 0);
    }

    function test_aHopThroughAHookTheUniswapAdapterDoesNotAllowIsRefused() public forked {
        PairLaunchAdapter.Hop memory h = _usdgV4();
        h.hooks = address(0xBAD);
        vm.expectRevert(abi.encodeWithSelector(HookListUser.HookNotAllowed.selector, address(0xBAD)));
        pair.plan(account, _params(CURVE, true, USDG_CURVE_TOKEN, 1, 1, 1, h));
    }

    function test_anEthPairedTokenIsNotThisAdaptersToTrade() public forked {
        vm.expectRevert(PairLaunchAdapter.NotPairToken.selector);
        pair.plan(account, _params(TORCH_POOL, true, ETH_TORCH, 1, 1, 0, _torchV4()));
    }

    function test_aCurveTokenIsNotAPoolTokenAndBack() public forked {
        // A Pons token's kind decides where it trades: a curve token's "pool" swap fails in the pool, never elsewhere.
        vm.prank(operator);
        vm.expectRevert();
        guard.trade(account, pair, _params(PONS_POOL, true, USDG_CURVE_TOKEN, 0.01 ether, 1, 0, _usdgV4()));
    }
}
