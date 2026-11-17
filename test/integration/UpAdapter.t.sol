// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SpinBotGuard, IERC6551Registry} from "../../src/bots/SpinBotGuard.sol";
import {UpAdapter} from "../../src/bots/adapters/UpAdapter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {Spinners} from "../../src/collection/Spinners.sol";
import {Routes} from "../../src/bots/Routes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ITokenboundPermissions {
    function setPermissions(address[] calldata callers, bool[] calldata permissions) external;
}

interface IRegistryCreateAccount {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

interface IUpPoolFactory {
    function createPool(address a, address b, bool stable) external returns (address);
}

interface IUpV2Pool {
    function mint(address to) external returns (uint256);
}

interface IWeth {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
}

/// An attacker's own token, for pools it makes.
contract AttackerToken is ERC20 {
    constructor() ERC20("ATK", "ATK") {
        _mint(msg.sender, 1e30);
    }
}

/**
 * UpAdapter on a fork of Robinhood Chain, against UP's deployed router, CL
 * swap router and pools, with the real guard and Tokenbound account. Buys and
 * sells through v2-style volatile and concentrated pools, directly against
 * wrapped ETH and through USDG.
 *
 *   RPC_URL=<archive rpc> npm run test
 */
contract UpAdapterFork is Test {
    IERC6551Registry constant REGISTRY = IERC6551Registry(0x000000006551c19487814612e58FE06813775758);
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    uint256 constant PINNED_BLOCK = 89_100_000;

    address constant ROUTER = 0xf5198743240fAC98db71868F34c70139b1eb0474;
    address constant POOL_FACTORY = 0xFA5429AEBa338BEa2BFcc1b9a889862Ee395bc28;
    address constant CL_ROUTER = 0xC062b870E813fcA720f1e002c234369Ab3aB9415;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// Wrapped ETH / USDG: a volatile v2-style pool and a concentrated pool (tick spacing 10).
    int24 constant USDG_TICK_SPACING = 10;
    /// UP's own token: pools of both kinds against wrapped ETH, and a volatile one against USDG.
    address constant UP = 0x57C0E45cB534413D1C20A4240955d6bB250BB4F1;
    int24 constant UP_TICK_SPACING = 200;
    /// NET: a concentrated pool against USDG only.
    address constant NET = 0xCA9c78Dd337A67F6e0077F65F5E9218719d30eDf;
    int24 constant NET_TICK_SPACING = 200;

    SpinBotGuard guard;
    UpAdapter up;
    Spinners spinners;
    address account;
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address holder = makeAddr("holder");

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
        up = new UpAdapter(ROUTER, POOL_FACTORY, CL_ROUTER, WETH);
        vm.startPrank(admin);
        guard.setOperator(operator, true);
        guard.addVenue(address(up));
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

    function _params(bool concentrated, bool buy, address token, int24 tickSpacing, bool viaUsdg, uint256 amountIn, uint256 minOut)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            UpAdapter.Params({
                concentrated: concentrated,
                buy: buy,
                token: token,
                stable: false,
                tickSpacing: tickSpacing,
                via: viaUsdg ? USDG : address(0),
                viaStable: false,
                viaTickSpacing: viaUsdg ? USDG_TICK_SPACING : int24(0),
                amountIn: amountIn,
                minOut: minOut
            })
        );
    }

    function _roundTrip(bool concentrated, address token, int24 tickSpacing, bool viaUsdg) internal {
        uint256 ethBefore = account.balance;
        vm.prank(operator);
        guard.trade(account, up, _params(concentrated, true, token, tickSpacing, viaUsdg, 0.05 ether, 1));
        uint256 tokens = IERC20(token).balanceOf(account);
        assertGt(tokens, 0, "bought the token into the account");
        assertEq(account.balance, ethBefore - 0.05 ether - 0.00025 ether, "spent the buy plus the 0.5% fee");

        vm.prank(operator);
        guard.trade(account, up, _params(concentrated, false, token, tickSpacing, viaUsdg, tokens, 1));
        assertEq(IERC20(token).balanceOf(account), 0, "sold it all");
        assertEq(IERC20(token).allowance(account, concentrated ? CL_ROUTER : ROUTER), 0, "approval reset");
        assertGt(account.balance, ethBefore - 0.01 ether, "ETH back in the account, less fees and the pools' spread");
        assertEq(address(up).balance, 0, "the adapter holds nothing");
        assertEq(IERC20(WETH).balanceOf(account), 0, "no wrapped ETH left behind");
        assertEq(IERC20(USDG).balanceOf(account), 0, "no USDG left behind");
    }

    /// Regression: a stolen operator key sells the account's tokens into pools it
    /// made itself, for almost nothing. Those pools hold no credit for the account's tokens.
    function test_tokensCannotBeSoldIntoAPoolTheyWereNotBoughtIn() public forked {
        vm.prank(operator);
        guard.trade(account, up, _params(false, true, UP, 0, false, 0.15 ether, 1));
        uint256 tokens = IERC20(UP).balanceOf(account);
        assertEq(guard.credit(account, UP, Routes.up(false, false, 0, address(0), false, 0)), tokens, "credited to its pool");

        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        AttackerToken atk = new AttackerToken();
        deal(UP, attacker, 1e12);
        vm.deal(attacker, 1 ether);
        address a = IUpPoolFactory(POOL_FACTORY).createPool(UP, address(atk), false);
        IERC20(UP).transfer(a, 1e12);
        atk.transfer(a, 1e18);
        IUpV2Pool(a).mint(attacker);
        address b = IUpPoolFactory(POOL_FACTORY).createPool(address(atk), WETH, false);
        IWeth(WETH).deposit{value: 1e9}();
        IWeth(WETH).transfer(b, 1e9);
        atk.transfer(b, 1e18);
        IUpV2Pool(b).mint(attacker);
        vm.stopPrank();

        bytes memory drain = abi.encode(UpAdapter.Params(false, false, UP, false, 0, address(atk), false, 0, tokens, 1));
        vm.prank(operator);
        vm.expectRevert(SpinBotGuard.NoCredit.selector);
        guard.trade(account, up, drain);
        assertEq(IERC20(UP).balanceOf(account), tokens, "the tokens stay in the account");
    }

    function test_theOwnerMovesACreditToAnotherPoolAndTheBotSellsThere() public forked {
        // Bought in the volatile v2 pool; that pool is the only way out for the bot ...
        vm.prank(operator);
        guard.trade(account, up, _params(false, true, UP, 0, false, 0.05 ether, 1));
        uint256 tokens = IERC20(UP).balanceOf(account);
        bytes32 v2 = Routes.up(false, false, 0, address(0), false, 0);
        bytes32 cl = Routes.up(true, false, UP_TICK_SPACING, address(0), false, 0);
        bytes memory sellCl = _params(true, false, UP, UP_TICK_SPACING, false, tokens, 1);
        vm.prank(operator);
        vm.expectRevert(SpinBotGuard.NoCredit.selector);
        guard.trade(account, up, sellCl);

        // ... until the owner moves the credit. No one else can.
        address[2] memory others = [operator, makeAddr("stranger")];
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(SpinBotGuard.NotOwner.selector);
            guard.moveCredit(account, UP, v2, cl, tokens);
        }
        vm.prank(holder);
        vm.expectRevert(SpinBotGuard.NoCredit.selector);
        guard.moveCredit(account, UP, v2, cl, tokens + 1);
        vm.prank(holder);
        guard.moveCredit(account, UP, v2, cl, tokens);
        assertEq(guard.credit(account, UP, v2), 0);
        assertEq(guard.credit(account, UP, cl), tokens);

        vm.prank(operator);
        guard.trade(account, up, sellCl);
        assertEq(IERC20(UP).balanceOf(account), 0, "sold through the concentrated pool");
    }

    function test_v2PoolBuysAndSells() public forked {
        _roundTrip(false, UP, 0, false);
    }

    function test_concentratedPoolBuysAndSells() public forked {
        _roundTrip(true, UP, UP_TICK_SPACING, false);
    }

    function test_v2PoolThroughUsdg() public forked {
        _roundTrip(false, UP, 0, true);
    }

    function test_concentratedPoolThroughUsdg() public forked {
        _roundTrip(true, NET, NET_TICK_SPACING, true);
    }

    /// What the whole transaction costs in gas: the call as measured, its base cost and its calldata.
    function _txGas(bytes memory data, uint256 measured) internal pure returns (uint256 gas) {
        gas = 21_000 + measured;
        for (uint256 i = 0; i < data.length; i++) gas += data[i] == 0 ? 4 : 16;
    }

    /// The refund covers UP's costliest route (a concentrated pool through USDG), alone and in a batch of one.
    function test_theGasRefundCoversUpTrades() public forked {
        uint256 price = 0.02 gwei;
        vm.txGasPrice(price);
        bytes memory params = _params(true, true, NET, NET_TICK_SPACING, true, 0.05 ether, 1);
        uint256 opBefore = operator.balance;
        uint256 g = gasleft();
        vm.prank(operator);
        guard.trade(account, up, params);
        uint256 txGas = _txGas(abi.encodeCall(SpinBotGuard.trade, (account, up, params)), g - gasleft());
        uint256 refund = operator.balance - opBefore;
        emit log_named_uint("UP via USDG, trade: transaction gas", txGas);
        emit log_named_uint("refunded gas", refund / price);
        assertGe(refund, txGas * price, "trade: the whole cost is refunded");

        SpinBotGuard.Trade[] memory trades = new SpinBotGuard.Trade[](1);
        trades[0] = SpinBotGuard.Trade(account, up, params);
        opBefore = operator.balance;
        g = gasleft();
        vm.prank(operator);
        guard.tradeMany(trades);
        txGas = _txGas(abi.encodeCall(SpinBotGuard.tradeMany, (trades)), g - gasleft());
        refund = operator.balance - opBefore;
        emit log_named_uint("UP via USDG, tradeMany of one: transaction gas", txGas);
        emit log_named_uint("refunded gas", refund / price);
        assertGe(refund, txGas * price, "tradeMany of one: the whole cost is refunded");
    }

    function test_aMinimumTheMarketCannotMeetReverts() public forked {
        vm.prank(operator);
        vm.expectRevert();
        guard.trade(account, up, _params(true, true, UP, UP_TICK_SPACING, false, 0.05 ether, type(uint256).max));
    }
}
