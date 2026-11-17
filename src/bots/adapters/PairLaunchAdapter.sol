// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVenueAdapter} from "../IVenueAdapter.sol";
import {Routes} from "../Routes.sol";
import {AdminWithdrawable} from "../../utils/Withdrawable.sol";
import {HookListUser, IHookList} from "../HookList.sol";
import {IPonsCurve} from "../../interfaces/IPonsCurve.sol";
import {IPonsFactory} from "./PonsAdapter.sol";

interface IUniversalRouterPair {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2Pair {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IERC20Pair {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface ITorchTokens {
    function isTorchToken(address token) external view returns (bool);
    function quoteOf(address token) external view returns (address);
}

/**
 * @title PairLaunchAdapter
 * @notice Buys and sells Pons and Torch tokens that their launchpad pairs with another token (the
 * pair token: a dollar token, a stock token, another launchpad token), not native ETH. The ETH goes
 * through the pair token on Uniswap in the same trade: a buy is ETH, then the pair token, then the
 * token; a sale is the way back.
 *
 * params = abi.encode(Params)
 *   kind: CURVE (a Pons token on its bonding curve), PONS_POOL (a graduated Pons token's own V4
 *         pool) or TORCH (a Torch token's own V4 pool)
 *   buy:  `amountIn` ETH in, at least `minOut` tokens out
 *   sell: `amountIn` tokens in, at least `minOut` ETH out
 *   pairOut: a curve buy only: exactly this much of the pair token is bought, with at most
 *            `amountIn` ETH (the rest comes back), and paid into the curve
 *   hop: the Uniswap V3 or V4 path between ETH and the pair token, directly or through one middle
 *        token (`via`); its fields are those of UniswapAdapter.Params, for the pair token
 *
 * The pair token, the curve and the token's pool are the ones the launchpad's factory names for the
 * token, never the caller's. The hop is the caller's, so the route names it: `Routes.pair` of the
 * launchpad (`Routes.PONS`, `Routes.TORCH`) and the hop (`Routes.uniswap`), and a sale needs credit
 * from buys through the same hop (a Pons token's curve and its graduated pool share it). Every V4
 * hop pool's hook must be on the HookList (or none). A curve buy ends by checking that
 * the account holds at least as much of the pair token as before it. Approvals are exact and reset
 * to zero; a token that fixes Permit2's allowance at the maximum (its approve of Permit2 reverts)
 * gets only Permit2's own approval in a pool sale. Everything a trade produces goes to the account.
 *
 * The admin (the deploying address, until it sets another) can point the adapter at another
 * HookList (`setHookList`), and can withdraw any ETH or ERC-20 tokens sent to this contract, to
 * the treasury it sets (`setTreasury`) only.
 */
contract PairLaunchAdapter is IVenueAdapter, AdminWithdrawable, HookListUser {
    uint8 public constant CURVE = 0;
    uint8 public constant PONS_POOL = 1;
    uint8 public constant TORCH = 2;

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
        uint8 kind;
        bool buy;
        address token;
        uint256 amountIn;
        uint256 minOut;
        uint256 pairOut;
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

    struct ExactOutputParams {
        address currencyOut;
        PathKey[] path;
        uint256[] maxHopPriceX36;
        uint128 amountOut;
        uint128 amountInMaximum;
    }

    /// The launch token's market: the curve, or its own V4 pool (as a path step from the pair token).
    struct Market {
        address pair;
        address curve;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    /// Universal Router commands.
    uint8 private constant V3_SWAP_EXACT_IN = 0x00;
    uint8 private constant V3_SWAP_EXACT_OUT = 0x01;
    uint8 private constant SWEEP = 0x04;
    uint8 private constant WRAP_ETH = 0x0b;
    uint8 private constant UNWRAP_WETH = 0x0c;
    uint8 private constant V4_SWAP = 0x10;
    /// v4-periphery actions.
    uint8 private constant SWAP_EXACT_IN = 0x07;
    uint8 private constant SWAP_EXACT_OUT = 0x09;
    uint8 private constant SETTLE = 0x0b;
    uint8 private constant SETTLE_ALL = 0x0c;
    uint8 private constant TAKE = 0x0e;
    uint8 private constant TAKE_ALL = 0x0f;
    /// The Universal Router's name for itself as a recipient, its whole balance, and a whole open delta.
    address private constant ADDRESS_THIS = address(2);
    uint256 private constant CONTRACT_BALANCE = 1 << 255;
    uint128 private constant OPEN_DELTA = 0;

    address public immutable router;
    address public immutable permit2;
    address public immutable weth;
    IPonsFactory public immutable ponsFactory;
    address public immutable ponsHook;
    ITorchTokens public immutable torchFactory;
    /// Every Torch pool's fee and tick spacing (no hook).
    uint24 public immutable torchFee;
    int24 public immutable torchTickSpacing;
    error NotPairToken();
    error UnknownKind();
    error AmountTooLarge();
    error PairBalanceFell();

    constructor(
        address router_,
        address permit2_,
        address weth_,
        IPonsFactory ponsFactory_,
        address ponsHook_,
        ITorchTokens torchFactory_,
        uint24 torchFee_,
        int24 torchTickSpacing_,
        IHookList hookList_
    ) HookListUser(hookList_) {
        router = router_;
        permit2 = permit2_;
        weth = weth_;
        ponsFactory = ponsFactory_;
        ponsHook = ponsHook_;
        torchFactory = torchFactory_;
        torchFee = torchFee_;
        torchTickSpacing = torchTickSpacing_;
    }

    function _authorizeHookListChange() internal view override {
        if (msg.sender != admin) revert NotAdmin();
    }

    function plan(address account, bytes calldata params) external view returns (Call[] memory calls, Route memory route) {
        Params memory p = abi.decode(params, (Params));
        Market memory m = _market(p.kind, p.token);
        if (p.hop.v4) {
            _checkHook(p.hop.hooks);
            if (p.hop.via != address(0)) _checkHook(p.hop.viaHooks);
        }
        bytes32 hop = Routes.uniswap(
            p.hop.v4, p.hop.fee, p.hop.tickSpacing, p.hop.hooks, p.hop.via, p.hop.viaFee, p.hop.viaTickSpacing, p.hop.viaHooks
        );
        route = Route(p.token, Routes.pair(p.kind == TORCH ? Routes.TORCH : Routes.PONS, hop), false);
        if (p.kind == CURVE) calls = p.buy ? _curveBuy(account, p, m) : _curveSell(account, p, m);
        else calls = p.buy ? _poolBuy(p, m) : _poolSell(account, p, m);
    }

    /// Reverts if `account` holds less of `token` than `atLeast`: a curve buy must not spend pair tokens the account already held.
    function checkBalance(address token, address account, uint256 atLeast) external view {
        if (IERC20Pair(token).balanceOf(account) < atLeast) revert PairBalanceFell();
    }

    // ── The launch token's market ────────────────────────────────────

    function _market(uint8 kind, address token) internal view returns (Market memory m) {
        if (kind == TORCH) {
            if (!torchFactory.isTorchToken(token)) revert NotPairToken();
            m.pair = torchFactory.quoteOf(token);
            if (m.pair == address(0)) revert NotPairToken();
            (m.fee, m.tickSpacing) = (torchFee, torchTickSpacing);
            return m;
        }
        if (kind != CURVE && kind != PONS_POOL) revert UnknownKind();
        IPonsFactory.LaunchedToken memory t = ponsFactory.getLaunchedToken(token);
        if (!t.exists || t.token != token || t.pairToken == address(0) || t.curve == address(0)) revert NotPairToken();
        m.pair = t.pairToken;
        if (kind == CURVE) m.curve = t.curve;
        else (m.fee, m.tickSpacing, m.hooks) = (t.poolFee, t.tickSpacing, ponsHook);
    }

    // ── Pons curves ──────────────────────────────────────────────────

    /// ETH buys exactly `pairOut` of the pair token (the rest of `amountIn` comes back), which buys the token on its curve.
    function _curveBuy(address account, Params memory p, Market memory m) internal view returns (Call[] memory calls) {
        calls = new Call[](5);
        calls[0] = Call(router, p.amountIn, _hopExactOut(account, p.hop, m.pair, p.pairOut, p.amountIn));
        calls[1] = Call(m.pair, 0, abi.encodeCall(IERC20Pair.approve, (m.curve, p.pairOut)));
        calls[2] = Call(m.curve, 0, abi.encodeCall(IPonsCurve.buy, (p.pairOut, p.minOut, account)));
        calls[3] = Call(m.pair, 0, abi.encodeCall(IERC20Pair.approve, (m.curve, 0)));
        calls[4] = Call(
            address(this), 0, abi.encodeCall(this.checkBalance, (m.pair, account, IERC20Pair(m.pair).balanceOf(account)))
        );
    }

    /// The curve pays the pair token to the router, which sells all it holds of it for ETH to the account.
    function _curveSell(address account, Params memory p, Market memory m) internal view returns (Call[] memory calls) {
        calls = new Call[](4);
        calls[0] = Call(p.token, 0, abi.encodeCall(IERC20Pair.approve, (m.curve, p.amountIn)));
        calls[1] = Call(m.curve, 0, abi.encodeCall(IPonsCurve.sell, (p.amountIn, 0, router)));
        calls[2] = Call(p.token, 0, abi.encodeCall(IERC20Pair.approve, (m.curve, 0)));
        calls[3] = Call(router, 0, _hopSellBalance(account, p.hop, m.pair, p.minOut));
    }

    // ── Launch tokens' own V4 pools ──────────────────────────────────

    function _poolBuy(Params memory p, Market memory m) internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(router, p.amountIn, p.hop.v4 ? _v4PoolBuy(p, m) : _v3ThenPoolBuy(p, m));
    }

    function _poolSell(address account, Params memory p, Market memory m) internal view returns (Call[] memory calls) {
        bool maxed = IERC20Pair(p.token).allowance(account, permit2) == type(uint256).max;
        calls = new Call[](maxed ? 3 : 5);
        uint256 i;
        if (!maxed) calls[i++] = Call(p.token, 0, abi.encodeCall(IERC20Pair.approve, (permit2, p.amountIn)));
        calls[i++] = Call(
            permit2, 0, abi.encodeCall(IPermit2Pair.approve, (p.token, router, _uint160(p.amountIn), uint48(block.timestamp)))
        );
        calls[i++] = Call(router, 0, p.hop.v4 ? _v4PoolSell(p, m) : _poolThenV3Sell(account, p, m));
        calls[i++] = Call(permit2, 0, abi.encodeCall(IPermit2Pair.approve, (p.token, router, 0, 0)));
        if (!maxed) calls[i] = Call(p.token, 0, abi.encodeCall(IERC20Pair.approve, (permit2, 0)));
    }

    /// One V4 path: ETH, the middle token, the pair token, then the token in its own pool.
    function _v4PoolBuy(Params memory p, Market memory m) internal view returns (bytes memory) {
        PathKey[] memory toPair = _v4HopPath(p.hop, m.pair, true);
        PathKey[] memory path = new PathKey[](toPair.length + 1);
        for (uint256 i; i < toPair.length; i++) path[i] = toPair[i];
        path[toPair.length] = PathKey(p.token, m.fee, m.tickSpacing, m.hooks, "");
        bytes[] memory a = new bytes[](3);
        a[0] = abi.encode(ExactInputParams(address(0), path, new uint256[](0), _uint128(p.amountIn), _uint128(p.minOut)));
        a[1] = abi.encode(address(0), p.amountIn);
        a[2] = abi.encode(p.token, p.minOut);
        return _v4Only(abi.encodePacked(SWAP_EXACT_IN, SETTLE_ALL, TAKE_ALL), a);
    }

    /// The token in its own pool, then the pair token back to ETH: one V4 path.
    function _v4PoolSell(Params memory p, Market memory m) internal view returns (bytes memory) {
        PathKey[] memory fromPair = _v4HopPath(p.hop, m.pair, false);
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
        return abi.encodeCall(IUniversalRouterPair.execute, (commands, inputs, block.timestamp));
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
        return abi.encodeCall(IUniversalRouterPair.execute, (commands, inputs, block.timestamp));
    }

    // ── The hop between ETH and the pair token ───────────────────────

    /// Exactly `amountOut` of the pair token to the account, for at most `maxIn` ETH; the ETH not used comes back.
    function _hopExactOut(address account, Hop memory h, address pair, uint256 amountOut, uint256 maxIn)
        internal
        view
        returns (bytes memory)
    {
        if (h.v4) {
            // An exact-output path names each hop's input currency, from ETH.
            PathKey[] memory fromEth = new PathKey[](h.via == address(0) ? 1 : 2);
            if (h.via == address(0)) {
                fromEth[0] = PathKey(address(0), h.fee, h.tickSpacing, h.hooks, "");
            } else {
                fromEth[0] = PathKey(address(0), h.viaFee, h.viaTickSpacing, h.viaHooks, "");
                fromEth[1] = PathKey(h.via, h.fee, h.tickSpacing, h.hooks, "");
            }
            bytes[] memory a = new bytes[](3);
            a[0] = abi.encode(ExactOutputParams(pair, fromEth, new uint256[](0), _uint128(amountOut), _uint128(maxIn)));
            a[1] = abi.encode(address(0), maxIn);
            a[2] = abi.encode(pair, amountOut);
            bytes memory commands = abi.encodePacked(V4_SWAP, SWEEP);
            bytes[] memory inputs = new bytes[](2);
            inputs[0] = abi.encode(abi.encodePacked(SWAP_EXACT_OUT, SETTLE_ALL, TAKE_ALL), a);
            inputs[1] = abi.encode(address(0), account, uint256(0));
            return abi.encodeCall(IUniversalRouterPair.execute, (commands, inputs, block.timestamp));
        }
        bytes memory v3Commands = abi.encodePacked(WRAP_ETH, V3_SWAP_EXACT_OUT, UNWRAP_WETH);
        bytes[] memory v3Inputs = new bytes[](3);
        v3Inputs[0] = abi.encode(ADDRESS_THIS, maxIn);
        // An exact-output V3 path runs from the output back to the input.
        v3Inputs[1] = abi.encode(account, amountOut, maxIn, _v3Path(h, pair, false), false, new uint256[](0));
        v3Inputs[2] = abi.encode(account, uint256(0));
        return abi.encodeCall(IUniversalRouterPair.execute, (v3Commands, v3Inputs, block.timestamp));
    }

    /// Everything the router holds of the pair token, sold for at least `minOut` ETH to the account.
    function _hopSellBalance(address account, Hop memory h, address pair, uint256 minOut) internal view returns (bytes memory) {
        if (h.v4) {
            bytes[] memory a = new bytes[](3);
            a[0] = abi.encode(pair, CONTRACT_BALANCE, false);
            a[1] = abi.encode(ExactInputParams(pair, _v4HopPath(h, pair, false), new uint256[](0), OPEN_DELTA, _uint128(minOut)));
            a[2] = abi.encode(address(0), minOut);
            return _v4Only(abi.encodePacked(SETTLE, SWAP_EXACT_IN, TAKE_ALL), a);
        }
        bytes memory commands = abi.encodePacked(V3_SWAP_EXACT_IN, UNWRAP_WETH);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, uint256(0), _v3Path(h, pair, false), false, new uint256[](0));
        inputs[1] = abi.encode(account, minOut);
        return abi.encodeCall(IUniversalRouterPair.execute, (commands, inputs, block.timestamp));
    }

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
        return abi.encodeCall(IUniversalRouterPair.execute, (abi.encodePacked(V4_SWAP), inputs, block.timestamp));
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
