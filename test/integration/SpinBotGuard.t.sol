// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {SpinBotGuard, IERC6551Registry, IERC6551Executable} from "../../src/bots/SpinBotGuard.sol";
import {IVenueAdapter} from "../../src/bots/IVenueAdapter.sol";
import {PonsAdapter, IPonsFactory} from "../../src/bots/adapters/PonsAdapter.sol";
import {UniswapAdapter} from "../../src/bots/adapters/UniswapAdapter.sol";
import {HookList} from "../../src/bots/HookList.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {Spinners} from "../../src/collection/Spinners.sol";

interface ITokenboundV3 {
    function setPermissions(address[] calldata callers, bool[] calldata permissions) external;
    function lock(uint256 lockedUntil) external;
}

interface IPermit2Allowance {
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

interface IRegistryCreate {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

/// The spinner collection stand-in: just enough ERC-721 for Tokenbound's `ownerOf`.
contract MockSpinners {
    mapping(uint256 => address) public ownerOf;

    /// Activation is tested on the real collection; here every token counts as active.
    function isActive(uint256) external pure returns (bool) {
        return true;
    }

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && msg.sender == from, "not owner");
        ownerOf[id] = to;
    }
}

/// A bad venue: sends `amount` of the account's ETH to `thief`.
contract ThiefAdapter is IVenueAdapter {
    function plan(address, bytes calldata params) external pure returns (Call[] memory calls, Route memory route) {
        (address thief, uint256 amount) = abi.decode(params, (address, uint256));
        calls = new Call[](1);
        calls[0] = Call(thief, amount, "");
    }
}

/// A token that misbehaves when a trade touches it: it burns all the gas it gets, or reverts with a megabyte.
contract HostileToken {
    bool public big;

    constructor(bool big_) {
        big = big_;
    }

    fallback() external {
        if (big) {
            assembly {
                revert(0, 1048576)
            }
        }
        while (true) {}
    }
}

/// A venue whose one call goes to `target` (a hostile token).
contract TouchAdapter is IVenueAdapter {
    function plan(address, bytes calldata params) external pure returns (Call[] memory calls, Route memory route) {
        calls = new Call[](1);
        calls[0] = Call(abi.decode(params, (address)), 0, "");
    }
}

/// A bad venue: tries to make the account call itself (e.g. to change its permissions).
contract SelfCallAdapter is IVenueAdapter {
    function plan(address account, bytes calldata) external pure returns (Call[] memory calls, Route memory route) {
        calls = new Call[](1);
        calls[0] = Call(account, 0, "");
    }
}

/**
 * SpinBotGuard on a fork of Robinhood Chain, against the deployed ERC-6551
 * registry, the deployed Tokenbound AccountV3 and a live Pons V2 curve.
 * Pinned to a block where TOKEN is still on its curve.
 *
 *   RPC_URL=<archive rpc> npm run test
 *
 * (With Alchemy and Foundry 1.8, run `npm run rpc-shim` first and point the
 * variable at http://127.0.0.1:8547.)
 */
contract SpinBotGuardFork is Test {
    IERC6551Registry constant REGISTRY = IERC6551Registry(0x000000006551c19487814612e58FE06813775758);
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    IPonsFactory constant PONS_FACTORY = IPonsFactory(0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e);
    /// An ETH-paired Pons V2 token, on its curve at the pinned block.
    address constant TOKEN = 0x2891603B58f6a865FA84bEEc8E287F9791e2400E;
    uint256 constant PINNED_BLOCK = 84_174_500;
    /// A Pons token that graduated to its V4 pool at block 84,140,799 (4.2 ETH).
    address constant GRADUATED = 0x43C41B57CF771433D14C7108c650e712759d58aE;
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;

    uint256 constant MAX_GAS_PRICE = 1 gwei;
    uint256 constant MAX_GAS_REFUND = 0.001 ether;
    uint32 constant GAS_OVERHEAD = 110_000;
    uint32 constant BATCH_GAS_OVERHEAD = 80_000;

    SpinBotGuard guard;
    PonsAdapter pons;
    UniswapAdapter v4;
    Spinners spinners;
    address account;
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address holder = makeAddr("holder");
    address buyer = makeAddr("buyer");
    address stranger = makeAddr("stranger");

    function setUp() public {
        string memory rpc = vm.envOr("RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // every test below skips
        vm.createSelectFork(rpc, PINNED_BLOCK);
        // A fork does not run Arbitrum's precompiles; empty code there reads as no parent-chain fee, as the chain says today.
        vm.etch(0x000000000000000000000000000000000000006C, "");

        // The real collection, minted the real way: token 1 to the holder.
        spinners = new Spinners("Spinners", "SPIN", 7777, admin, payable(treasury), 500, "ipfs://art/", address(REGISTRY), ACCOUNT_V3);
        vm.prank(admin);
        spinners.setMintOpen(true);
        vm.startPrank(holder);
        spinners.mint(1);
        spinners.activate(1); // free here: no activation fee set
        vm.stopPrank();
        account = IRegistryCreate(address(REGISTRY)).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), 1);
        vm.deal(account, 1 ether);

        guard = new SpinBotGuard(REGISTRY, ACCOUNT_V3, address(spinners), admin, treasury, 100, MAX_GAS_PRICE, MAX_GAS_REFUND, GAS_OVERHEAD, BATCH_GAS_OVERHEAD);
        pons = new PonsAdapter(PONS_FACTORY);
        address[] memory hooks = new address[](1);
        hooks[0] = PONS_HOOK;
        v4 = new UniswapAdapter(UNIVERSAL_ROUTER, PERMIT2, WETH, PONS_FACTORY, PONS_HOOK, admin, new HookList(hooks));
        vm.startPrank(admin);
        guard.setOperator(operator, true);
        guard.addVenue(address(pons));
        guard.addVenue(address(v4));
        vm.stopPrank();

        // The owner switches the bot on: permission on the account, then caps on the guard.
        vm.startPrank(holder);
        _permit(true);
        guard.configure(account, SpinBotGuard.Limits(0.1 ether, 0.25 ether, uint64(block.timestamp + 30 days)));
        vm.stopPrank();
    }

    modifier forked() {
        if (address(guard) == address(0)) {
            emit log("skipped: set RPC_URL to run the fork tests");
            return;
        }
        _;
    }

    function _permit(bool on) internal {
        address[] memory callers = new address[](1);
        callers[0] = address(guard);
        bool[] memory perms = new bool[](1);
        perms[0] = on;
        ITokenboundV3(account).setPermissions(callers, perms);
    }

    function _buy(address acct, uint256 eth) internal {
        vm.prank(operator);
        guard.trade(acct, pons, abi.encode(true, TOKEN, eth, uint256(1)));
    }

    function _sell(uint256 tokens) internal {
        vm.prank(operator);
        guard.trade(account, pons, abi.encode(false, TOKEN, tokens, uint256(1)));
    }

    // ── Trading ─────────────────────────────────────────────────────────

    function test_engineBuysAndSellsForTheAccount() public forked {
        _buy(account, 0.05 ether);
        uint256 tokens = IERC20(TOKEN).balanceOf(account);
        assertGt(tokens, 0, "tokens land in the account");
        assertEq(account.balance, 1 ether - 0.05 ether - 0.0005 ether, "spent the buy plus the 1% fee");
        assertEq(treasury.balance, 0.0005 ether, "1% fee");

        _sell(tokens);
        assertEq(IERC20(TOKEN).balanceOf(account), 0);
        assertGt(account.balance, 0.99 ether, "ETH back in the account");
        assertGt(treasury.balance, 0.0005 ether, "fee on the sell too");
    }

    /// A trade in the V4 pool a graduated Pons token trades in (against native ETH).
    function _graduated(bool buy, uint256 amountIn) internal view returns (bytes memory) {
        IPonsFactory.LaunchedToken memory t = PONS_FACTORY.getLaunchedToken(GRADUATED);
        assertEq(t.pairToken, address(0), "ETH-paired");
        UniswapAdapter.Params memory p;
        p.v4 = true;
        p.buy = buy;
        p.token = GRADUATED;
        p.fee = t.poolFee;
        p.tickSpacing = t.tickSpacing;
        p.hooks = PONS_HOOK;
        p.amountIn = amountIn;
        p.minOut = 1;
        return abi.encode(p);
    }

    function test_v4BuysAndSellsAGraduatedToken() public forked {
        bytes memory buy = _graduated(true, 0.05 ether);
        vm.prank(operator);
        guard.trade(account, v4, buy);
        uint256 tokens = IERC20(GRADUATED).balanceOf(account);
        assertGt(tokens, 0, "tokens land in the account");
        assertEq(account.balance, 1 ether - 0.05 ether - 0.0005 ether, "spent the swap plus the 1% fee");

        bytes memory sell = _graduated(false, tokens);
        vm.prank(operator);
        guard.trade(account, v4, sell);
        assertEq(IERC20(GRADUATED).balanceOf(account), 0);
        assertGt(account.balance, 0.98 ether, "ETH back in the account");
        (uint160 left,,) = IPermit2Allowance(PERMIT2).allowance(account, GRADUATED, UNIVERSAL_ROUTER);
        assertEq(left, 0, "no Permit2 allowance left");
        assertEq(IERC20(GRADUATED).allowance(account, PERMIT2), 0, "no token allowance left");
    }

    function test_capsPerTradeAndPerDayIncludeTheFee() public forked {
        vm.expectRevert(SpinBotGuard.OverTradeLimit.selector);
        _buy(account, 0.1 ether); // 0.1 + 1% fee > 0.1 cap
        _buy(account, 0.099 ether);
        _buy(account, 0.099 ether);
        vm.expectRevert(SpinBotGuard.OverDailyLimit.selector);
        _buy(account, 0.05 ether);
        vm.warp(block.timestamp + 1 days);
        _buy(account, 0.05 ether);
    }

    // ── Gas ─────────────────────────────────────────────────────────────

    /// What the whole transaction costs in gas: the call as measured, its base cost and its calldata.
    function _txGas(bytes memory data, uint256 measured) internal pure returns (uint256 gas) {
        gas = 21_000 + measured;
        for (uint256 i = 0; i < data.length; i++) gas += data[i] == 0 ? 4 : 16;
    }

    /// One buy at `gasPrice`: the refund the operator got, and the gas the whole transaction used.
    function _buyAt(uint256 gasPrice, uint256 eth) internal returns (uint256 refund, uint256 txGas) {
        vm.txGasPrice(gasPrice);
        bytes memory params = abi.encode(true, TOKEN, eth, uint256(1));
        uint256 opBefore = operator.balance;
        uint256 g = gasleft();
        vm.prank(operator);
        guard.trade(account, pons, params);
        txGas = _txGas(abi.encodeCall(SpinBotGuard.trade, (account, pons, params)), g - gasleft());
        refund = operator.balance - opBefore;
    }

    function test_theOperatorsGasIsRefundedFromTheAccount() public forked {
        uint256 price = 0.02 gwei; // Robinhood Chain mainnet, October 2026
        uint256 accountBefore = account.balance;
        (uint256 refund, uint256 txGas) = _buyAt(price, 0.05 ether);
        assertGe(refund, txGas * price, "at least what the transaction cost");
        assertLe(refund, (txGas + 40_000) * price, "and not much more");
        emit log_named_uint("transaction gas", txGas);
        emit log_named_uint("refunded gas", refund / price);
        assertEq(account.balance, accountBefore - 0.05 ether - 0.0005 ether - refund, "paid by the account");
    }

    function test_theGasPriceAndTheRefundAreCapped() public forked {
        (uint256 refund, uint256 txGas) = _buyAt(100 gwei, 0.05 ether);
        assertLe(refund, (txGas * MAX_GAS_PRICE * 125) / 100, "priced at maxGasPrice, not the transaction's 100 gwei");
        assertLe(refund, MAX_GAS_REFUND);
        vm.prank(admin);
        guard.setGasOverhead(200_000, BATCH_GAS_OVERHEAD);
        (refund,) = _buyAt(100 gwei, 0.01 ether);
        assertLe(refund, MAX_GAS_REFUND, "never more than maxGasRefund");
    }

    function test_aTradeThatCannotPayItsGasReverts() public forked {
        vm.deal(account, 0.05 ether + 0.0005 ether); // the buy and its fee, nothing for gas
        vm.txGasPrice(0.02 gwei);
        vm.prank(operator);
        vm.expectRevert(SpinBotGuard.CannotPayGas.selector);
        guard.trade(account, pons, abi.encode(true, TOKEN, 0.05 ether, uint256(1)));
    }

    function test_theRefundCountsAgainstTheLimitsOnBuysButASellAlwaysGoes() public forked {
        vm.txGasPrice(0.02 gwei);
        vm.prank(operator);
        vm.expectRevert(SpinBotGuard.OverTradeLimit.selector);
        // 0.099008 + 1% fee = 0.09999808, inside the 0.1 cap; the gas refund takes it over.
        guard.trade(account, pons, abi.encode(true, TOKEN, 0.099008 ether, uint256(1)));
        _buyAt(0.02 gwei, 0.098 ether);
        _buyAt(0.02 gwei, 0.098 ether);
        vm.prank(operator);
        vm.expectRevert(SpinBotGuard.OverDailyLimit.selector);
        guard.trade(account, pons, abi.encode(true, TOKEN, 0.06 ether, uint256(1))); // 0.19797 so far + 0.0606 > 0.25
        // The day's limit is used up; the exit still goes, and still pays its gas.
        uint256 opBefore = operator.balance;
        _sell(IERC20(TOKEN).balanceOf(account));
        assertEq(IERC20(TOKEN).balanceOf(account), 0);
        assertGt(operator.balance, opBefore, "the sell refunded its gas");
    }

    function test_theAdminSetsAnyOverheadAndCaps() public forked {
        vm.startPrank(admin);
        guard.setGasOverhead(2_000_000, 1_000_000);
        guard.setGasCaps(1_000 gwei, 1 ether);
        vm.stopPrank();
        assertEq(guard.gasOverhead(), 2_000_000);
        assertEq(guard.maxGasRefund(), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(SpinBotGuard.NotAdmin.selector);
        guard.setGasCaps(2 gwei, 0.002 ether);
    }

    function test_theAdminCanChangeTheGasCaps() public forked {
        vm.prank(admin);
        guard.setGasCaps(0.01 gwei, 0.002 ether);
        (uint256 refund, uint256 txGas) = _buyAt(1 gwei, 0.05 ether);
        assertLe(refund, (txGas + 40_000) * 0.01 gwei, "priced at the new, lower cap");
        assertGt(refund, 0);
    }

    // ── Many trades in one transaction ──────────────────────────────────

    /// A second Spinner of the same holder, its account funded and the bot switched on.
    function _secondAccount() internal returns (address second) {
        vm.startPrank(holder);
        spinners.mint(1);
        spinners.activate(2);
        vm.stopPrank();
        second = IRegistryCreate(address(REGISTRY)).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), 2);
        vm.deal(second, 1 ether);
        vm.startPrank(holder);
        address[] memory callers = new address[](1);
        callers[0] = address(guard);
        bool[] memory perms = new bool[](1);
        perms[0] = true;
        ITokenboundV3(second).setPermissions(callers, perms);
        guard.configure(second, SpinBotGuard.Limits(0.1 ether, 0.25 ether, uint64(block.timestamp + 30 days)));
        vm.stopPrank();
    }

    function _buyTrade(address acct, address token, uint256 eth) internal view returns (SpinBotGuard.Trade memory) {
        return SpinBotGuard.Trade(acct, pons, abi.encode(true, token, eth, uint256(1)));
    }

    function test_tradeManyRunsEachTradeOnItsOwn() public forked {
        address second = _secondAccount();
        SpinBotGuard.Trade[] memory trades = new SpinBotGuard.Trade[](3);
        trades[0] = _buyTrade(account, TOKEN, 0.05 ether);
        trades[1] = _buyTrade(second, stranger, 0.05 ether); // not a Pons token: this one reverts
        trades[2] = _buyTrade(second, TOKEN, 0.02 ether);
        vm.expectEmit(true, false, false, false, address(guard));
        emit SpinBotGuard.TradeFailed(second, 1, "");
        vm.prank(operator);
        bool[] memory ok = guard.tradeMany(trades);
        assertTrue(ok[0] && !ok[1] && ok[2], "the bad one alone failed");
        assertGt(IERC20(TOKEN).balanceOf(account), 0);
        assertGt(IERC20(TOKEN).balanceOf(second), 0);
        assertEq(second.balance, 1 ether - 0.02 ether - 0.0002 ether, "only its good trade spent");
    }

    function test_inABatchEachAccountRefundsItsOwnGas() public forked {
        address second = _secondAccount();
        uint256 price = 0.02 gwei;
        vm.txGasPrice(price);
        SpinBotGuard.Trade[] memory trades = new SpinBotGuard.Trade[](2);
        trades[0] = _buyTrade(account, TOKEN, 0.05 ether);
        trades[1] = _buyTrade(second, TOKEN, 0.03 ether);
        uint256[2] memory before = [account.balance, second.balance];
        uint256 opBefore = operator.balance;
        uint256 g = gasleft();
        vm.prank(operator);
        guard.tradeMany(trades);
        uint256 txGas = _txGas(abi.encodeCall(SpinBotGuard.tradeMany, (trades)), g - gasleft());
        uint256 refund = operator.balance - opBefore;
        emit log_named_uint("batch transaction gas", txGas);
        emit log_named_uint("refunded gas", refund / price);
        assertGe(refund, txGas * price, "the batch's whole cost is refunded");
        assertLe(refund, (txGas + 60_000) * price, "and not much more");
        uint256 r0 = before[0] - account.balance - 0.05 ether - 0.0005 ether;
        uint256 r1 = before[1] - second.balance - 0.03 ether - 0.0003 ether;
        assertEq(r0 + r1, refund, "each account paid its own part");
        assertGt(r0, 0);
        assertGt(r1, 0);
    }

    function test_aFailedTradeInABatchPaysItsOwnGasSoTheOperatorNever() public forked {
        address second = _secondAccount();
        uint256 price = 0.02 gwei;
        vm.txGasPrice(price);
        SpinBotGuard.Trade[] memory trades = new SpinBotGuard.Trade[](2);
        trades[0] = _buyTrade(account, TOKEN, 0.05 ether);
        trades[1] = _buyTrade(second, stranger, 0.05 ether); // reverts: not a Pons token
        uint256 secondBefore = second.balance;
        uint256 opBefore = operator.balance;
        vm.expectEmit(true, false, false, false, address(guard));
        emit SpinBotGuard.FailedTradeCharged(second, 0);
        uint256 g = gasleft();
        vm.prank(operator);
        guard.tradeMany(trades);
        uint256 txGas = _txGas(abi.encodeCall(SpinBotGuard.tradeMany, (trades)), g - gasleft());
        uint256 refund = operator.balance - opBefore;
        emit log_named_uint("batch with a failed trade, transaction gas", txGas);
        emit log_named_uint("refunded gas", refund / price);
        assertGe(refund, txGas * price, "the operator is paid for the whole transaction, the failed trade too");
        assertGt(secondBefore - second.balance, 0, "the failed trade's account paid its gas");
        assertEq(IERC20(TOKEN).balanceOf(second), 0, "and traded nothing");
    }

    function test_aBatchOfOneWhoseTradeFailsCostsTheOperatorNothing() public forked {
        uint256 price = 0.02 gwei;
        vm.txGasPrice(price);
        SpinBotGuard.Trade[] memory trades = new SpinBotGuard.Trade[](1);
        trades[0] = SpinBotGuard.Trade(account, pons, abi.encode(true, TOKEN, 0.05 ether, type(uint256).max)); // a minimum the market cannot meet
        uint256 opBefore = operator.balance;
        uint256 g = gasleft();
        vm.prank(operator);
        bool[] memory ok = guard.tradeMany(trades);
        uint256 txGas = _txGas(abi.encodeCall(SpinBotGuard.tradeMany, (trades)), g - gasleft());
        assertFalse(ok[0], "the trade failed, the transaction did not");
        assertGe(operator.balance - opBefore, txGas * price, "its gas was paid by the account");
    }

    function test_chargeForIsTheGuardsOwn() public forked {
        vm.prank(operator);
        vm.expectRevert(SpinBotGuard.NotSelf.selector);
        guard.chargeFor(account, 100_000, operator, 0, 0);
    }

    function test_tradeForIsTheGuardsOwn() public forked {
        vm.prank(operator);
        vm.expectRevert(SpinBotGuard.NotSelf.selector);
        guard.tradeFor(account, pons, abi.encode(true, TOKEN, 0.01 ether, uint256(1)), operator, 0, 0);
    }

    function test_tradeManyOnlyForOperatorsAndNeverWhenPaused() public forked {
        SpinBotGuard.Trade[] memory trades = new SpinBotGuard.Trade[](1);
        trades[0] = _buyTrade(account, TOKEN, 0.01 ether);
        vm.prank(stranger);
        vm.expectRevert(SpinBotGuard.NotOperator.selector);
        guard.tradeMany(trades);
        vm.prank(admin);
        guard.setPaused(true);
        vm.prank(operator);
        vm.expectRevert(SpinBotGuard.Paused.selector);
        guard.tradeMany(trades);
    }

    function test_onlyPonsEthTokens() public forked {
        vm.prank(operator);
        vm.expectRevert(PonsAdapter.NotPonsEthToken.selector);
        guard.trade(account, pons, abi.encode(true, stranger, 0.01 ether, uint256(1)));
    }

    // ── Venues ──────────────────────────────────────────────────────────

    function test_onlyAddedVenuesTrade() public forked {
        PonsAdapter second = new PonsAdapter(PONS_FACTORY);
        vm.prank(operator);
        vm.expectRevert(SpinBotGuard.NotVenue.selector);
        guard.trade(account, second, abi.encode(true, TOKEN, 0.01 ether, uint256(1)));

        vm.prank(admin);
        guard.addVenue(address(second));
        vm.prank(operator);
        guard.trade(account, second, abi.encode(true, TOKEN, 0.01 ether, uint256(1)));
    }

    function test_aRemovedVenueStopsAtOnce() public forked {
        vm.prank(admin);
        guard.removeVenue(address(pons));
        vm.expectRevert(SpinBotGuard.NotVenue.selector);
        _buy(account, 0.01 ether);
    }

    function test_onlyTheAdminManagesVenues() public forked {
        vm.prank(stranger);
        vm.expectRevert(SpinBotGuard.NotAdmin.selector);
        guard.addVenue(stranger);
    }

    function test_aBadVenueIsHeldToTheCaps() public forked {
        ThiefAdapter thief = new ThiefAdapter();
        vm.prank(admin);
        guard.addVenue(address(thief));

        vm.startPrank(operator);
        vm.expectRevert(SpinBotGuard.OverTradeLimit.selector);
        guard.trade(account, thief, abi.encode(stranger, 0.5 ether));
        guard.trade(account, thief, abi.encode(stranger, 0.09 ether));
        guard.trade(account, thief, abi.encode(stranger, 0.09 ether));
        vm.expectRevert(SpinBotGuard.OverDailyLimit.selector);
        guard.trade(account, thief, abi.encode(stranger, 0.09 ether));
        vm.stopPrank();
        assertEq(stranger.balance, 0.18 ether, "ETH loss is bounded by the owner's daily cap");
    }

    function test_noCallsToTheAccountItself() public forked {
        SelfCallAdapter bad = new SelfCallAdapter();
        vm.prank(admin);
        guard.addVenue(address(bad));
        vm.prank(operator);
        vm.expectRevert(SpinBotGuard.ForbiddenTarget.selector);
        guard.trade(account, bad, "");
    }

    // ── Access ──────────────────────────────────────────────────────────

    function test_onlyOperatorsAndNeverWhenPaused() public forked {
        vm.prank(stranger);
        vm.expectRevert(SpinBotGuard.NotOperator.selector);
        guard.trade(account, pons, abi.encode(true, TOKEN, 0.01 ether, uint256(1)));

        vm.prank(admin);
        guard.setPaused(true);
        vm.expectRevert(SpinBotGuard.Paused.selector);
        _buy(account, 0.01 ether);
    }

    function test_operatorCannotCallTheAccountDirectly() public forked {
        vm.prank(operator);
        vm.expectRevert();
        IERC6551Executable(account).execute(operator, 1 ether, "", 0);
    }

    function test_ownerCanAlwaysWithdraw() public forked {
        vm.prank(holder);
        IERC6551Executable(account).execute(holder, 1 ether, "", 0);
        assertEq(holder.balance, 1 ether);
    }

    function test_onlySpinnerAccounts() public forked {
        // An account of another collection, even with the guard permitted, is refused.
        MockSpinners other = new MockSpinners();
        other.mint(stranger, 1);
        address foreign = IRegistryCreate(address(REGISTRY)).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(other), 1);
        vm.expectRevert(SpinBotGuard.NotSpinBot.selector);
        _buy(foreign, 0.01 ether);
        vm.expectRevert(SpinBotGuard.NotSpinBot.selector);
        _buy(stranger, 0.01 ether);
    }

    function test_ownerRevokesAtOnce() public forked {
        vm.prank(holder);
        _permit(false);
        vm.expectRevert();
        _buy(account, 0.01 ether);
    }

    function test_expiryStopsTheBot() public forked {
        vm.warp(block.timestamp + 31 days);
        vm.expectRevert(SpinBotGuard.NotEnabled.selector);
        _buy(account, 0.01 ether);
    }

    function test_saleSwitchesTheBotOff() public forked {
        vm.prank(holder);
        spinners.transferFrom(holder, buyer, 1);
        vm.expectRevert(SpinBotGuard.NotActive.selector);
        _buy(account, 0.01 ether);

        // The buyer activates it again; the seller's caps do not count.
        vm.prank(buyer);
        spinners.activate(1);
        vm.expectRevert(SpinBotGuard.NotEnabled.selector);
        _buy(account, 0.01 ether);

        // The buyer's own caps; the seller's old grant on the account does not count either.
        vm.prank(buyer);
        guard.configure(account, SpinBotGuard.Limits(0.1 ether, 0.1 ether, uint64(block.timestamp + 1 days)));
        vm.expectRevert(); // Tokenbound: the permission was the seller's
        _buy(account, 0.01 ether);
        vm.prank(buyer);
        _permit(true);
        _buy(account, 0.01 ether);
    }

    function test_inactiveSpinnerCannotTrade() public forked {
        vm.prank(holder);
        spinners.mint(1);
        address second = IRegistryCreate(address(REGISTRY)).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), 2);
        vm.deal(second, 1 ether);
        vm.startPrank(holder);
        ITokenboundV3(second).setPermissions(_one(address(guard)), _yes());
        guard.configure(second, SpinBotGuard.Limits(0.1 ether, 0.25 ether, uint64(block.timestamp + 30 days)));
        vm.stopPrank();

        vm.expectRevert(SpinBotGuard.NotActive.selector);
        _buy(second, 0.01 ether);
        vm.prank(holder);
        spinners.activate(2);
        _buy(second, 0.01 ether);
    }

    function _one(address a) private pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _yes() private pure returns (bool[] memory r) {
        r = new bool[](1);
        r[0] = true;
    }

    function test_lockFreezesTheAccount() public forked {
        vm.prank(holder);
        ITokenboundV3(account).lock(block.timestamp + 7 days);
        vm.expectRevert();
        _buy(account, 0.01 ether);
    }

    function test_aHostileTokenCannotSinkABatch() public forked {
        TouchAdapter touch = new TouchAdapter();
        vm.prank(admin);
        guard.addVenue(address(touch));
        SpinBotGuard.Trade[] memory trades = new SpinBotGuard.Trade[](3);
        trades[0] = SpinBotGuard.Trade(account, touch, abi.encode(address(new HostileToken(false)))); // burns its gas
        trades[1] = SpinBotGuard.Trade(account, touch, abi.encode(address(new HostileToken(true)))); // a megabyte of revert data
        trades[2] = _buyTrade(account, TOKEN, 0.01 ether);
        vm.recordLogs();
        vm.prank(operator);
        bool[] memory ok = guard.tradeMany{gas: 25_000_000}(trades);
        assertTrue(!ok[0] && !ok[1] && ok[2], "the good trade still went through");
        assertGt(IERC20(TOKEN).balanceOf(account), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != SpinBotGuard.TradeFailed.selector) continue;
            (, bytes memory reason) = abi.decode(logs[i].data, (uint256, bytes));
            assertLe(reason.length, guard.MAX_REASON_BYTES(), "the reason is cut short");
        }
    }

    function test_theAdminSetsTheTradeGasLimit() public forked {
        assertEq(guard.tradeGasLimit(), 10_000_000);
        vm.prank(stranger);
        vm.expectRevert(SpinBotGuard.NotAdmin.selector);
        guard.setTradeGasLimit(1);
        vm.prank(admin);
        guard.setTradeGasLimit(20_000_000);
        assertEq(guard.tradeGasLimit(), 20_000_000);
    }

    // ── Routes ──────────────────────────────────────────────────────────

    function test_ponsRoutesAreOpenEvenWithNoCredit() public forked {
        // Tokens that came in another way (here: dealt) still sell on the token's own curve.
        _buy(account, 0.02 ether);
        uint256 tokens = IERC20(TOKEN).balanceOf(account);
        deal(TOKEN, account, tokens * 2);
        _sell(tokens * 2);
        assertEq(IERC20(TOKEN).balanceOf(account), 0);
    }

    function test_aGraduatedPonsTokensOwnPoolIsOpen() public forked {
        deal(GRADUATED, account, 1e21);
        bytes memory sell = _graduated(false, 1e21);
        vm.prank(operator);
        guard.trade(account, v4, sell);
        assertEq(IERC20(GRADUATED).balanceOf(account), 0, "sold in the pool the Pons factory names");
    }

    function test_aV4PoolOfAPonsTokenWithOtherSettingsIsNotOpen() public forked {
        deal(GRADUATED, account, 1e21);
        UniswapAdapter.Params memory p = abi.decode(_graduated(false, 1e21), (UniswapAdapter.Params));
        p.hooks = address(0); // a hookless pool of the same token: anyone can make one
        vm.prank(operator);
        vm.expectRevert();
        guard.trade(account, v4, abi.encode(p));
        assertEq(IERC20(GRADUATED).balanceOf(account), 1e21, "nothing sold");
    }

    // ── Zero limits ─────────────────────────────────────────────────────

    function test_zeroLimitsStopBuysButSellsStillRun() public forked {
        _buy(account, 0.02 ether);
        uint256 tokens = IERC20(TOKEN).balanceOf(account);
        vm.prank(holder);
        guard.configure(account, SpinBotGuard.Limits(0, 0, uint64(block.timestamp + 30 days)));
        vm.expectRevert(SpinBotGuard.NotEnabled.selector);
        _buy(account, 0.01 ether);
        _sell(tokens);
        assertEq(IERC20(TOKEN).balanceOf(account), 0, "the exit still goes");
    }

    function test_withZeroLimitsATradeThatSpendsNothingIsRefused() public forked {
        // A venue that moves no ETH (a launch with no first buy is one).
        ThiefAdapter idle = new ThiefAdapter();
        vm.prank(admin);
        guard.addVenue(address(idle));
        vm.prank(holder);
        guard.configure(account, SpinBotGuard.Limits(0, 1 ether, uint64(block.timestamp + 30 days)));
        vm.prank(operator);
        vm.expectRevert(SpinBotGuard.NotEnabled.selector);
        guard.trade(account, idle, abi.encode(stranger, uint256(0)));
    }

    function test_onlyOwnerConfigures() public forked {
        vm.prank(stranger);
        vm.expectRevert(SpinBotGuard.NotOwner.selector);
        guard.configure(account, SpinBotGuard.Limits(1 ether, 1 ether, uint64(block.timestamp + 1 days)));
    }

    function test_theFeeIsAtMostTheWholeTrade() public forked {
        vm.startPrank(admin);
        guard.setFee(2_500);
        assertEq(guard.feeBps(), 2_500);
        vm.expectRevert(SpinBotGuard.FeeTooHigh.selector);
        guard.setFee(10_001);
        vm.stopPrank();
    }

    function test_theAdminWithdrawsEthAndTokensSentToTheGuardToTheTreasuryOnly() public forked {
        vm.deal(address(guard), 1 ether);
        deal(TOKEN, address(guard), 1_000);
        uint256 treasuryEth = treasury.balance;
        vm.prank(stranger);
        vm.expectRevert(SpinBotGuard.NotAdmin.selector);
        guard.withdrawEth(1 ether);
        vm.startPrank(admin);
        guard.withdrawEth(1 ether);
        guard.withdrawToken(TOKEN, 1_000);
        vm.stopPrank();
        assertEq(address(guard).balance, 0);
        assertEq(treasury.balance, treasuryEth + 1 ether);
        assertEq(IERC20(TOKEN).balanceOf(treasury), 1_000);
        assertEq(IERC20(TOKEN).balanceOf(admin), 0, "never to the admin");
    }

    // ── The collection ──────────────────────────────────────────────────

    function test_theAdminSetsTheCollection_andTheOldCollectionsAccountsStopAtOnce() public forked {
        vm.prank(stranger);
        vm.expectRevert(SpinBotGuard.NotAdmin.selector);
        guard.setCollection(stranger);
        vm.prank(admin);
        vm.expectRevert(SpinBotGuard.ZeroCollection.selector);
        guard.setCollection(address(0));

        Spinners next = new Spinners("Spinners", "SPINNERS", 7777, admin, payable(treasury), 777, "ipfs://art/", address(REGISTRY), ACCOUNT_V3);
        vm.expectEmit(address(guard));
        emit SpinBotGuard.CollectionSet(address(next));
        vm.prank(admin);
        guard.setCollection(address(next));
        assertEq(guard.collection(), address(next));
        // The old collection's account is no longer a Spinner's for the guard.
        vm.prank(holder);
        vm.expectRevert(SpinBotGuard.NotSpinBot.selector);
        guard.configure(account, SpinBotGuard.Limits(1 ether, 10 ether, uint64(block.timestamp + 30 days)));
        // Back to it: it is again.
        vm.prank(admin);
        guard.setCollection(address(spinners));
        vm.prank(holder);
        guard.configure(account, SpinBotGuard.Limits(1 ether, 10 ether, uint64(block.timestamp + 30 days)));
    }
}
