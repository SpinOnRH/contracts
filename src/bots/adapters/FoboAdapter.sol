// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVenueAdapter} from "../IVenueAdapter.sol";
import {Routes} from "../Routes.sol";
import {AdminWithdrawable} from "../../utils/Withdrawable.sol";
import {HookListUser, IHookList} from "../HookList.sol";

interface IUniversalRouterFobo {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2Fobo {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IERC20Fobo {
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// FoboHook's record of each pool it made (its public `pools` getter).
interface IFoboHookPools {
    function pools(bytes32 poolId)
        external
        view
        returns (
            address token,
            address creator,
            uint40 launchedAt,
            int24 tickStart,
            int24 tickF,
            int24 refTick,
            uint64 refBlock,
            uint64 lastRaiseBlock,
            uint128 snipePot,
            uint128 snipeReleased,
            uint8 merged,
            uint128 liqBand,
            uint256 pot,
            uint256 creatorOwed,
            uint256 reserve
        );
}

/**
 * @title FoboAdapter
 * @notice Buys and sells the tokens fobo.fun launches. Each trades in its own Uniswap V4 pool whose
 * hook is FoboHook, against its pair (the pool's currency0): native ETH, or a token (fobo's own,
 * USDG, a stock token). A pair token's trade goes through it on Uniswap in the same swap: a buy is
 * ETH, then the pair token, then the token; a sale is the way back.
 *
 * params = abi.encode(Params)
 *   buy:  `amountIn` ETH in, at least `minOut` tokens out
 *   sell: `amountIn` tokens in, at least `minOut` ETH out
 *   pair: the token's pair (address(0): ETH)
 *   hop: the Uniswap V3 or V4 path between ETH and the pair token, directly or through one middle
 *        token (`via`), as in LongAdapter; unused for an ETH-paired token
 *
 * The pool is checked, never taken on trust: its key follows from the pair and the token (no fee,
 * tick spacing 60, FoboHook), and FoboHook's own record for that pool must name the token. Only
 * FoboHook initialises pools with itself as hook, and it keeps no other liquidity than its own, so
 * the pool is a fobo launch whose liquidity cannot be removed. Every V4 hop pool's hook must be on
 * the HookList, or none, or FoboHook (a hop through another fobo pool, such as fobo's own token's).
 * An ETH-paired token's route is `Routes.FOBO`; a pair token's names the hop
 * (`Routes.pair(Routes.FOBO, Routes.uniswap(hop))`), so a sale needs credit from buys through the
 * same hop. Approvals are exact and reset to zero. Everything a trade produces goes to the account.
 *
 * The admin (the deploying address, until it sets another) can point the adapter at another
 * HookList (`setHookList`), and can withdraw any ETH or ERC-20 tokens sent to this contract, to
 * the treasury it sets only.
 */
contract FoboAdapter is IVenueAdapter, AdminWithdrawable, HookListUser {
    struct Hop {
        bool v4;
        address via;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        uint24 viaFee;
        int24 viaTickSpacing;
        address viaHooks;
    }

    struct Params {
        bool buy;
        address token;
        address pair;
        uint256 amountIn;
        uint256 minOut;
        Hop hop;
    }

    struct PathKey {
        address intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    struct ExactInputParams {
        address currencyIn;
        PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    /// The token's own pool, as a path step from its pair token.
    struct Market {
        address pair;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    /// Universal Router commands.
    uint8 private constant V3_SWAP_EXACT_IN = 0x00;
    uint8 private constant WRAP_ETH = 0x0b;
    uint8 private constant UNWRAP_WETH = 0x0c;
    uint8 private constant V4_SWAP = 0x10;
    /// v4-periphery actions.
    uint8 private constant SWAP_EXACT_IN = 0x07;
    uint8 private constant SETTLE = 0x0b;
    uint8 private constant SETTLE_ALL = 0x0c;
    uint8 private constant TAKE = 0x0e;
    uint8 private constant TAKE_ALL = 0x0f;
    /// The Universal Router's name for itself as a recipient, its whole balance, and a whole open delta.
    address private constant ADDRESS_THIS = address(2);
    uint256 private constant CONTRACT_BALANCE = 1 << 255;
    uint128 private constant OPEN_DELTA = 0;
    /// Every fobo pool's key, but its currencies (FoboHook.keyFor).
    uint24 public constant FOBO_FEE = 0;
    int24 public constant FOBO_TICK_SPACING = 60;

    address public immutable router;
    address public immutable permit2;
    address public immutable weth;
    /// FoboHook: every fobo pool's hook, and the record of the pools it made.
    address public immutable foboHook;

    error NotFoboToken();
    error AmountTooLarge();

    constructor(address router_, address permit2_, address weth_, address foboHook_, IHookList hookList_) HookListUser(hookList_) {
        router = router_;
        permit2 = permit2_;
        weth = weth_;
        foboHook = foboHook_;
    }

    function _authorizeHookListChange() internal view override {
        if (msg.sender != admin) revert NotAdmin();
    }

    function plan(address account, bytes calldata params) external view returns (Call[] memory calls, Route memory route) {
        Params memory p = abi.decode(params, (Params));
        Market memory m = market(p.token, p.pair);
        if (m.pair == address(0)) {
            route = Route(p.token, Routes.FOBO, false);
        } else {
            if (p.hop.v4) {
                _checkHopHook(p.hop.hooks);
                if (p.hop.via != address(0)) _checkHopHook(p.hop.viaHooks);
            }
            bytes32 hop = Routes.uniswap(
                p.hop.v4, p.hop.fee, p.hop.tickSpacing, p.hop.hooks, p.hop.via, p.hop.viaFee, p.hop.viaTickSpacing, p.hop.viaHooks
            );
            route = Route(p.token, Routes.pair(Routes.FOBO, hop), false);
        }
        bytes memory swap = m.pair == address(0) || p.hop.v4
            ? (p.buy ? _v4Buy(p, m) : _v4Sell(p, m))
            : (p.buy ? _v3ThenPoolBuy(p, m) : _poolThenV3Sell(account, p, m));
        if (p.buy) {
            calls = new Call[](1);
            calls[0] = Call(router, p.amountIn, swap);
            return (calls, route);
        }
        // A token that fixes Permit2's allowance at the maximum (its approve of it reverts): only Permit2's own is set.
        bool maxed = IERC20Fobo(p.token).allowance(account, permit2) == type(uint256).max;
        calls = new Call[](maxed ? 3 : 5);
        uint256 i;
        if (!maxed) calls[i++] = Call(p.token, 0, abi.encodeCall(IERC20Fobo.approve, (permit2, p.amountIn)));
        calls[i++] = Call(
            permit2, 0, abi.encodeCall(IPermit2Fobo.approve, (p.token, router, _uint160(p.amountIn), uint48(block.timestamp)))
        );
        calls[i++] = Call(router, 0, swap);
        calls[i++] = Call(permit2, 0, abi.encodeCall(IPermit2Fobo.approve, (p.token, router, 0, 0)));
        if (!maxed) calls[i] = Call(p.token, 0, abi.encodeCall(IERC20Fobo.approve, (permit2, 0)));
    }

    /// The token's pool against `pair`; reverts unless FoboHook made that pool for that token.
    function market(address token, address pair) public view returns (Market memory m) {
        // A wrapped-ETH pair has no Uniswap hop from native ETH; the pair sorts before the token (currency0).
        if (token == address(0) || pair == weth || uint160(pair) >= uint160(token)) revert NotFoboToken();
        bytes32 id = keccak256(abi.encode(pair, token, FOBO_FEE, FOBO_TICK_SPACING, foboHook));
        (address recorded,,,,,,,,,,,,,,) = IFoboHookPools(foboHook).pools(id);
        if (recorded != token) revert NotFoboToken();
        m = Market(pair, FOBO_FEE, FOBO_TICK_SPACING, foboHook);
    }

    /// A hop pool's hook: none, FoboHook (another fobo pool), or one on the HookList.
    function _checkHopHook(address hook) internal view {
        if (hook != foboHook) _checkHook(hook);
    }

    // ── Swaps ────────────────────────────────────────────────────────

    /// One V4 path: ETH (through the hop, for a pair token), then the token in its own pool.
    function _v4Buy(Params memory p, Market memory m) internal view returns (bytes memory) {
        PathKey[] memory toPair = m.pair == address(0) ? new PathKey[](0) : _v4HopPath(p.hop, m.pair, true);
        PathKey[] memory path = new PathKey[](toPair.length + 1);
        for (uint256 i; i < toPair.length; i++) path[i] = toPair[i];
        path[toPair.length] = PathKey(p.token, m.fee, m.tickSpacing, m.hooks, "");
        bytes[] memory a = new bytes[](3);
        a[0] = abi.encode(ExactInputParams(address(0), path, new uint256[](0), _uint128(p.amountIn), _uint128(p.minOut)));
        a[1] = abi.encode(address(0), p.amountIn);
        a[2] = abi.encode(p.token, p.minOut);
        return _v4Only(abi.encodePacked(SWAP_EXACT_IN, SETTLE_ALL, TAKE_ALL), a);
    }

    /// The token in its own pool, then (for a pair token) the hop back to ETH: one V4 path.
    function _v4Sell(Params memory p, Market memory m) internal view returns (bytes memory) {
        PathKey[] memory fromPair = m.pair == address(0) ? new PathKey[](0) : _v4HopPath(p.hop, m.pair, false);
        PathKey[] memory path = new PathKey[](fromPair.length + 1);
        path[0] = PathKey(m.pair, m.fee, m.tickSpacing, m.hooks, "");
        for (uint256 i; i < fromPair.length; i++) path[i + 1] = fromPair[i];
        bytes[] memory a = new bytes[](3);
        a[0] = abi.encode(ExactInputParams(p.token, path, new uint256[](0), _uint128(p.amountIn), _uint128(p.minOut)));
        a[1] = abi.encode(p.token, p.amountIn);
        a[2] = abi.encode(address(0), p.minOut);
        return _v4Only(abi.encodePacked(SWAP_EXACT_IN, SETTLE_ALL, TAKE_ALL), a);
    }

    /// V3 from wrapped ETH to the pair token, kept in the router; then V4 spends all of it on the token.
    function _v3ThenPoolBuy(Params memory p, Market memory m) internal view returns (bytes memory) {
        bytes memory commands = abi.encodePacked(WRAP_ETH, V3_SWAP_EXACT_IN, V4_SWAP);
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(ADDRESS_THIS, p.amountIn);
        inputs[1] = abi.encode(ADDRESS_THIS, p.amountIn, uint256(0), _v3Path(p.hop, m.pair, true), false, new uint256[](0));
        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey(p.token, m.fee, m.tickSpacing, m.hooks, "");
        bytes[] memory a = new bytes[](3);
        a[0] = abi.encode(m.pair, CONTRACT_BALANCE, false);
        a[1] = abi.encode(ExactInputParams(m.pair, path, new uint256[](0), OPEN_DELTA, _uint128(p.minOut)));
        a[2] = abi.encode(p.token, p.minOut);
        inputs[2] = abi.encode(abi.encodePacked(SETTLE, SWAP_EXACT_IN, TAKE_ALL), a);
        return abi.encodeCall(IUniversalRouterFobo.execute, (commands, inputs, block.timestamp));
    }

    /// V4 sells the token for the pair token, kept in the router; then V3 sells all of it for wrapped ETH, unwrapped to the account.
    function _poolThenV3Sell(address account, Params memory p, Market memory m) internal view returns (bytes memory) {
        bytes memory commands = abi.encodePacked(V4_SWAP, V3_SWAP_EXACT_IN, UNWRAP_WETH);
        bytes[] memory inputs = new bytes[](3);
        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey(m.pair, m.fee, m.tickSpacing, m.hooks, "");
        bytes[] memory a = new bytes[](3);
        a[0] = abi.encode(ExactInputParams(p.token, path, new uint256[](0), _uint128(p.amountIn), 0));
        a[1] = abi.encode(p.token, p.amountIn);
        a[2] = abi.encode(m.pair, ADDRESS_THIS, uint256(OPEN_DELTA));
        inputs[0] = abi.encode(abi.encodePacked(SWAP_EXACT_IN, SETTLE_ALL, TAKE), a);
        inputs[1] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, uint256(0), _v3Path(p.hop, m.pair, false), false, new uint256[](0));
        inputs[2] = abi.encode(account, p.minOut);
        return abi.encodeCall(IUniversalRouterFobo.execute, (commands, inputs, block.timestamp));
    }

    // ── The hop between ETH and the pair token ───────────────────────

    /// The V4 hop as exact-input path steps: from ETH to the pair token (`toPair`), or back.
    function _v4HopPath(Hop memory h, address pair, bool toPair) internal pure returns (PathKey[] memory path) {
        path = new PathKey[](h.via == address(0) ? 1 : 2);
        if (h.via == address(0)) {
            path[0] = PathKey(toPair ? pair : address(0), h.fee, h.tickSpacing, h.hooks, "");
        } else if (toPair) {
            path[0] = PathKey(h.via, h.viaFee, h.viaTickSpacing, h.viaHooks, "");
            path[1] = PathKey(pair, h.fee, h.tickSpacing, h.hooks, "");
        } else {
            path[0] = PathKey(h.via, h.fee, h.tickSpacing, h.hooks, "");
            path[1] = PathKey(address(0), h.viaFee, h.viaTickSpacing, h.viaHooks, "");
        }
    }

    /// The V3 hop between wrapped ETH and the pair token, from wrapped ETH (`fromWeth`) or from the pair token.
    function _v3Path(Hop memory h, address pair, bool fromWeth) internal view returns (bytes memory) {
        if (h.via == address(0)) return fromWeth ? abi.encodePacked(weth, h.fee, pair) : abi.encodePacked(pair, h.fee, weth);
        return fromWeth
            ? abi.encodePacked(weth, h.viaFee, h.via, h.fee, pair)
            : abi.encodePacked(pair, h.fee, h.via, h.viaFee, weth);
    }

    function _v4Only(bytes memory actions, bytes[] memory actionParams) internal view returns (bytes memory) {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, actionParams);
        return abi.encodeCall(IUniversalRouterFobo.execute, (abi.encodePacked(V4_SWAP), inputs, block.timestamp));
    }

    function _uint128(uint256 x) private pure returns (uint128) {
        if (x > type(uint128).max) revert AmountTooLarge();
        return uint128(x);
    }

    function _uint160(uint256 x) private pure returns (uint160) {
        if (x > type(uint160).max) revert AmountTooLarge();
        return uint160(x);
    }
}
