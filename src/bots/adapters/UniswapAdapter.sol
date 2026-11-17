// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVenueAdapter} from "../IVenueAdapter.sol";
import {Routes} from "../Routes.sol";
import {IPonsFactory} from "./PonsAdapter.sol";
import {Withdrawable} from "../../utils/Withdrawable.sol";
import {HookListUser, IHookList} from "../HookList.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

/**
 * @title UniswapAdapter
 * @notice An exact-input swap between native ETH and a token on Uniswap V3 or
 * V4, through the Universal Router: directly in the token's pool against ETH,
 * or through a second token (`via`, such as a dollar token) in the same swap.
 *
 * params = abi.encode(Params)
 *
 * V3 pools are against wrapped ETH: a buy wraps the ETH in the router, a sell
 * unwraps the output there and pays native ETH to the account. V4 pools are
 * against native ETH (currency zero). `tickSpacing` and `hooks` apply to V4
 * only; `fee` is the pool's fee tier (V3) or its key's fee (V4).
 *
 * V4 pools may only use a hook on the HookList (or none). Every hop's hook is
 * checked when the trade is planned. The admin can point the adapter at
 * another list (`setHookList`).
 *
 * The route (`Routes.uniswap`) is the whole path. A graduated Pons token's own
 * V4 pool (the key the Pons factory records, with the Pons hook) is the open
 * `Routes.PONS` route, the same as its curve.
 *
 * Buys send `amountIn` of ETH as value. Sells approve exactly `amountIn` of the
 * token to Permit2, and Permit2 to the router until the end of this block; both
 * are reset to zero in the same plan. A token that fixes Permit2's allowance at
 * the maximum (its approve of Permit2 reverts) gets only Permit2's own approval.
 * The output goes to the account. No per-hop minimum price is set; `minOut`
 * bounds the whole swap.
 *
 * The admin can withdraw any ETH or ERC-20 tokens sent to this contract, to the treasury it
 * sets (`setTreasury`) only.
 */
contract UniswapAdapter is IVenueAdapter, Withdrawable, HookListUser {
    struct Params {
        bool v4;
        bool buy;
        address token;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        address via;
        uint24 viaFee;
        int24 viaTickSpacing;
        address viaHooks;
        uint256 amountIn;
        uint256 minOut;
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

    /// Universal Router commands.
    uint8 private constant V3_SWAP_EXACT_IN = 0x00;
    uint8 private constant WRAP_ETH = 0x0b;
    uint8 private constant UNWRAP_WETH = 0x0c;
    uint8 private constant V4_SWAP = 0x10;
    /// v4-periphery actions.
    uint8 private constant SWAP_EXACT_IN = 0x07;
    uint8 private constant SETTLE_ALL = 0x0c;
    uint8 private constant TAKE_ALL = 0x0f;
    /// The Universal Router's name for itself as a recipient.
    address private constant ADDRESS_THIS = address(2);

    address public immutable router;
    address public immutable permit2;
    address public immutable weth;
    /// Pons, for its graduated tokens' pools; zero where Pons does not graduate to V4.
    IPonsFactory public immutable ponsFactory;
    address public immutable ponsHook;

    address public admin;
    /// Where withdrawals go (the admin sets it; none until then).
    address payable public treasury;

    error NotAdmin();
    error NoTreasury();
    error AmountTooLarge();

    event AdminSet(address admin);
    event TreasurySet(address treasury);

    constructor(
        address router_,
        address permit2_,
        address weth_,
        IPonsFactory ponsFactory_,
        address ponsHook_,
        address admin_,
        IHookList hookList_
    ) HookListUser(hookList_) {
        router = router_;
        permit2 = permit2_;
        weth = weth_;
        ponsFactory = ponsFactory_;
        ponsHook = ponsHook_;
        admin = admin_;
        emit AdminSet(admin_);
    }

    /// Whether a V4 pool may use `hook`: the HookList's answer.
    function allowedHook(address hook) external view returns (bool) {
        return hookList.allowedHook(hook);
    }

    function setAdmin(address admin_) external {
        if (msg.sender != admin) revert NotAdmin();
        admin = admin_;
        emit AdminSet(admin_);
    }

    function setTreasury(address payable treasury_) external {
        if (msg.sender != admin) revert NotAdmin();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function _authorizeWithdraw(address) internal view override {
        if (msg.sender != admin) revert NotAdmin();
    }

    function _authorizeHookListChange() internal view override {
        if (msg.sender != admin) revert NotAdmin();
    }

    function _withdrawTo() internal view override returns (address payable) {
        if (treasury == address(0)) revert NoTreasury();
        return treasury;
    }

    function plan(address account, bytes calldata params) external view returns (Call[] memory calls, Route memory route) {
        Params memory p = abi.decode(params, (Params));
        bytes memory swap = p.v4 ? _v4(p) : _v3(account, p);
        route = _isPonsPool(p)
            ? Route(p.token, Routes.PONS, true)
            : Route(p.token, Routes.uniswap(p.v4, p.fee, p.tickSpacing, p.hooks, p.via, p.viaFee, p.viaTickSpacing, p.viaHooks), false);
        if (p.buy) {
            calls = new Call[](1);
            calls[0] = Call(router, p.amountIn, swap);
            return (calls, route);
        }
        bool maxed = IERC20Approve(p.token).allowance(account, permit2) == type(uint256).max;
        calls = new Call[](maxed ? 3 : 5);
        uint256 i;
        if (!maxed) calls[i++] = Call(p.token, 0, abi.encodeCall(IERC20Approve.approve, (permit2, p.amountIn)));
        calls[i++] = Call(
            permit2, 0, abi.encodeCall(IPermit2.approve, (p.token, router, _uint160(p.amountIn), uint48(block.timestamp)))
        );
        calls[i++] = Call(router, 0, swap);
        calls[i++] = Call(permit2, 0, abi.encodeCall(IPermit2.approve, (p.token, router, 0, 0)));
        if (!maxed) calls[i] = Call(p.token, 0, abi.encodeCall(IERC20Approve.approve, (permit2, 0)));
    }

    function _v3(address account, Params memory p) private view returns (bytes memory) {
        bytes memory commands = new bytes(2);
        bytes[] memory inputs = new bytes[](2);
        if (p.buy) {
            bytes memory path = p.via == address(0)
                ? abi.encodePacked(weth, p.fee, p.token)
                : abi.encodePacked(weth, p.viaFee, p.via, p.fee, p.token);
            commands[0] = bytes1(WRAP_ETH);
            commands[1] = bytes1(V3_SWAP_EXACT_IN);
            inputs[0] = abi.encode(ADDRESS_THIS, p.amountIn);
            inputs[1] = abi.encode(account, p.amountIn, p.minOut, path, false, new uint256[](0));
        } else {
            bytes memory path = p.via == address(0)
                ? abi.encodePacked(p.token, p.fee, weth)
                : abi.encodePacked(p.token, p.fee, p.via, p.viaFee, weth);
            commands[0] = bytes1(V3_SWAP_EXACT_IN);
            commands[1] = bytes1(UNWRAP_WETH);
            inputs[0] = abi.encode(ADDRESS_THIS, p.amountIn, uint256(0), path, true, new uint256[](0));
            inputs[1] = abi.encode(account, p.minOut);
        }
        return abi.encodeCall(IUniversalRouter.execute, (commands, inputs, block.timestamp));
    }

    function _v4(Params memory p) private view returns (bytes memory) {
        _checkHook(p.hooks);
        if (p.via != address(0)) _checkHook(p.viaHooks);
        address tokenIn = p.buy ? address(0) : p.token;
        address tokenOut = p.buy ? p.token : address(0);

        PathKey[] memory path = new PathKey[](p.via == address(0) ? 1 : 2);
        if (p.via == address(0)) {
            path[0] = PathKey(tokenOut, p.fee, p.tickSpacing, p.hooks, "");
        } else if (p.buy) {
            path[0] = PathKey(p.via, p.viaFee, p.viaTickSpacing, p.viaHooks, "");
            path[1] = PathKey(p.token, p.fee, p.tickSpacing, p.hooks, "");
        } else {
            path[0] = PathKey(p.via, p.fee, p.tickSpacing, p.hooks, "");
            path[1] = PathKey(address(0), p.viaFee, p.viaTickSpacing, p.viaHooks, "");
        }

        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] =
            abi.encode(ExactInputParams(tokenIn, path, new uint256[](0), _uint128(p.amountIn), _uint128(p.minOut)));
        actionParams[1] = abi.encode(tokenIn, p.amountIn);
        actionParams[2] = abi.encode(tokenOut, p.minOut);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(SWAP_EXACT_IN, SETTLE_ALL, TAKE_ALL), actionParams);
        return abi.encodeCall(IUniversalRouter.execute, (abi.encodePacked(V4_SWAP), inputs, block.timestamp));
    }

    /// Whether the path is a graduated Pons token's own pool against native ETH.
    function _isPonsPool(Params memory p) private view returns (bool) {
        if (!p.v4 || p.via != address(0) || p.hooks != ponsHook || ponsHook == address(0)) return false;
        IPonsFactory.LaunchedToken memory t = ponsFactory.getLaunchedToken(p.token);
        return t.exists && t.token == p.token && t.pairToken == address(0) && t.poolFee == p.fee && t.tickSpacing == p.tickSpacing;
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
