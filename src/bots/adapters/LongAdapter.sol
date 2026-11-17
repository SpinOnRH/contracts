// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVenueAdapter} from "../IVenueAdapter.sol";
import {Routes} from "../Routes.sol";
import {AdminWithdrawable} from "../../utils/Withdrawable.sol";
import {HookListUser, IHookList} from "../HookList.sol";

interface IUniversalRouterLong {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2Long {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IERC20Long {
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// Doppler's Airlock: every asset's launch modules.
interface IDopplerAirlock {
    function getAssetData(address asset)
        external
        view
        returns (
            address numeraire,
            address timelock,
            address governance,
            address liquidityMigrator,
            address poolInitializer,
            address pool,
            address migrationPool,
            uint256 numTokensToSell,
            uint256 totalSupply,
            address integrator
        );
}

/// Doppler's multicurve initializer, which is also the pools' V4 hook.
interface IDopplerHookInitializer {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    function getState(address asset)
        external
        view
        returns (
            address numeraire,
            uint256 totalTokensOnBondingCurve,
            address dopplerHook,
            bytes memory graduationDopplerHookCalldata,
            uint8 status,
            PoolKey memory poolKey,
            int24 farTick
        );
}

/**
 * @title LongAdapter
 * @notice Buys and sells the tokens Long.xyz launches: Doppler multicurve tokens that trade in their
 * own Uniswap V4 pool, whose hook is Doppler's initializer, from the first block. The pool pairs the
 * token with native ETH or another token (the pair token: a stock token, USDG, another launch
 * token). A pair token's trade goes through it on Uniswap in the same swap: a buy is ETH, then the
 * pair token, then the token; a sale is the way back.
 *
 * params = abi.encode(Params)
 *   buy:  `amountIn` ETH in, at least `minOut` tokens out
 *   sell: `amountIn` tokens in, at least `minOut` ETH out
 *   hop: the Uniswap V3 or V4 path between ETH and the pair token, directly or through one middle
 *        token (`via`), as in PairLaunchAdapter; unused for an ETH-paired token
 *
 * The pool is the one Doppler records for the token, never the caller's, and only a pool that
 * cannot change is traded: made by the initializer, Locked (it never migrates its liquidity), its
 * timelock the dead address (no one can ever set another Doppler hook on it), and its Doppler hook
 * none or one on this adapter's list. Every V4 hop pool's hook must be on the HookList (or none). An ETH-paired token's route is `Routes.LONG`; a pair token's names the hop
 * (`Routes.pair(Routes.LONG, Routes.uniswap(hop))`), so a sale needs credit from buys through the
 * same hop. Approvals are exact and reset to zero (a Doppler token's own allowance to Permit2 is fixed at
 * the maximum: only Permit2's to the router is set). Everything a trade produces goes to the account.
 *
 * The admin (the deploying address, until it sets another) keeps the Doppler hook list, can point
 * the adapter at another HookList (`setHookList`), and can withdraw any ETH or ERC-20 tokens sent to this contract, to the treasury it sets only.
 */
contract LongAdapter is IVenueAdapter, AdminWithdrawable, HookListUser {
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
    /// The initializer's PoolStatus.Locked: liquidity stays in the pool for good.
    uint8 private constant LOCKED = 2;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable router;
    address public immutable permit2;
    address public immutable weth;
    IDopplerAirlock public immutable airlock;
    IDopplerHookInitializer public immutable initializer;
    /// Doppler hooks (the initializer's per-pool hooks, such as Rehype) a traded pool may have.
    mapping(address dopplerHook => bool) public allowedDopplerHook;

    error NotLongToken();
    error AmountTooLarge();

    event DopplerHookSet(address indexed dopplerHook, bool allowed);

    constructor(
        address router_,
        address permit2_,
        address weth_,
        IDopplerAirlock airlock_,
        IDopplerHookInitializer initializer_,
        IHookList hookList_,
        address[] memory dopplerHooks
    ) HookListUser(hookList_) {
        router = router_;
        permit2 = permit2_;
        weth = weth_;
        airlock = airlock_;
        initializer = initializer_;
        for (uint256 i; i < dopplerHooks.length; i++) {
            allowedDopplerHook[dopplerHooks[i]] = true;
            emit DopplerHookSet(dopplerHooks[i], true);
        }
    }

    function _authorizeHookListChange() internal view override {
        if (msg.sender != admin) revert NotAdmin();
    }

    function setDopplerHook(address dopplerHook, bool allowed) external {
        if (msg.sender != admin) revert NotAdmin();
        allowedDopplerHook[dopplerHook] = allowed;
        emit DopplerHookSet(dopplerHook, allowed);
    }

    function plan(address account, bytes calldata params) external view returns (Call[] memory calls, Route memory route) {
        Params memory p = abi.decode(params, (Params));
        Market memory m = market(p.token);
        if (m.pair == address(0)) {
            route = Route(p.token, Routes.LONG, false);
        } else {
            if (p.hop.v4) {
                _checkHook(p.hop.hooks);
                if (p.hop.via != address(0)) _checkHook(p.hop.viaHooks);
            }
            bytes32 hop = Routes.uniswap(
                p.hop.v4, p.hop.fee, p.hop.tickSpacing, p.hop.hooks, p.hop.via, p.hop.viaFee, p.hop.viaTickSpacing, p.hop.viaHooks
            );
            route = Route(p.token, Routes.pair(Routes.LONG, hop), false);
        }
        bytes memory swap = m.pair == address(0) || p.hop.v4
            ? (p.buy ? _v4Buy(p, m) : _v4Sell(p, m))
            : (p.buy ? _v3ThenPoolBuy(p, m) : _poolThenV3Sell(account, p, m));
        if (p.buy) {
            calls = new Call[](1);
            calls[0] = Call(router, p.amountIn, swap);
            return (calls, route);
        }
        // Doppler's tokens fix Permit2's allowance at the maximum (their approve of it reverts): only Permit2's own is set.
        bool maxed = IERC20Long(p.token).allowance(account, permit2) == type(uint256).max;
        calls = new Call[](maxed ? 3 : 5);
        uint256 i;
        if (!maxed) calls[i++] = Call(p.token, 0, abi.encodeCall(IERC20Long.approve, (permit2, p.amountIn)));
        calls[i++] = Call(
            permit2, 0, abi.encodeCall(IPermit2Long.approve, (p.token, router, _uint160(p.amountIn), uint48(block.timestamp)))
        );
        calls[i++] = Call(router, 0, swap);
        calls[i++] = Call(permit2, 0, abi.encodeCall(IPermit2Long.approve, (p.token, router, 0, 0)));
        if (!maxed) calls[i] = Call(p.token, 0, abi.encodeCall(IERC20Long.approve, (permit2, 0)));
    }

    /// The token's pool and pair token, as Doppler records them; reverts unless the pool can never change.
    function market(address token) public view returns (Market memory m) {
        (address numeraire, address timelock,,, address poolInitializer,,,,,) = airlock.getAssetData(token);
        if (poolInitializer != address(initializer) || timelock != DEAD) revert NotLongToken();
        (,, address dopplerHook,, uint8 status, IDopplerHookInitializer.PoolKey memory key,) = initializer.getState(token);
        if (status != LOCKED || key.hooks != address(initializer)) revert NotLongToken();
        if (dopplerHook != address(0) && !allowedDopplerHook[dopplerHook]) revert HookNotAllowed(dopplerHook);
        bool paired = (key.currency0 == token && key.currency1 == numeraire) || (key.currency1 == token && key.currency0 == numeraire);
        // A wrapped-ETH pair has no Uniswap hop from native ETH.
        if (!paired || numeraire == weth) revert NotLongToken();
        m = Market(numeraire, key.fee, key.tickSpacing, key.hooks);
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
        return abi.encodeCall(IUniversalRouterLong.execute, (commands, inputs, block.timestamp));
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
        return abi.encodeCall(IUniversalRouterLong.execute, (commands, inputs, block.timestamp));
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
        return abi.encodeCall(IUniversalRouterLong.execute, (abi.encodePacked(V4_SWAP), inputs, block.timestamp));
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
