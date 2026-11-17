// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVenueAdapter} from "../IVenueAdapter.sol";
import {Routes} from "../Routes.sol";
import {AdminWithdrawable} from "../../utils/Withdrawable.sol";

interface IUpRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactETHForTokens(uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IUpClRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
    function unwrapWETH9(uint256 amountMinimum, address recipient) external payable;
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @title UpAdapter
 * @notice An exact-input swap between native ETH and a token on UP: its v2-style
 * pools (volatile or stable) through its router, or its concentrated-liquidity
 * pools through its CL swap router. A token paired with another token (`via`,
 * such as a dollar token) is reached through that token's pool with wrapped
 * ETH, in the same swap.
 *
 * params = abi.encode(Params)
 *
 * `stable` and `viaStable` apply to v2-style pools; `tickSpacing` and
 * `viaTickSpacing` to concentrated ones. `via` is zero for a direct pool.
 * Buys send `amountIn` of ETH as value. Sells approve exactly `amountIn` of the
 * token and reset the approval to zero in the same plan. The output goes to
 * the account; a concentrated sell takes wrapped ETH to the router and
 * unwraps it to the account in one multicall. The route (`Routes.up`) is the
 * whole path.
 *
 * The admin (the deploying address, until it sets another) can withdraw any ETH or ERC-20
 * tokens sent to this contract, to the treasury it sets (`setTreasury`) only.
 */
contract UpAdapter is IVenueAdapter, AdminWithdrawable {
    struct Params {
        bool concentrated;
        bool buy;
        address token;
        bool stable;
        int24 tickSpacing;
        address via;
        bool viaStable;
        int24 viaTickSpacing;
        uint256 amountIn;
        uint256 minOut;
    }

    address public immutable router;
    address public immutable poolFactory;
    address public immutable clRouter;
    address public immutable weth;

    constructor(address router_, address poolFactory_, address clRouter_, address weth_) {
        router = router_;
        poolFactory = poolFactory_;
        clRouter = clRouter_;
        weth = weth_;
    }

    function plan(address account, bytes calldata params) external view returns (Call[] memory calls, Route memory route) {
        Params memory p = abi.decode(params, (Params));
        calls = p.concentrated ? _concentrated(account, p) : _v2(account, p);
        route = Route(p.token, Routes.up(p.concentrated, p.stable, p.tickSpacing, p.via, p.viaStable, p.viaTickSpacing), false);
    }

    function _v2(address account, Params memory p) private view returns (Call[] memory calls) {
        IUpRouter.Route[] memory routes = new IUpRouter.Route[](p.via == address(0) ? 1 : 2);
        if (p.buy) {
            if (p.via == address(0)) {
                routes[0] = IUpRouter.Route(weth, p.token, p.stable, poolFactory);
            } else {
                routes[0] = IUpRouter.Route(weth, p.via, p.viaStable, poolFactory);
                routes[1] = IUpRouter.Route(p.via, p.token, p.stable, poolFactory);
            }
            calls = new Call[](1);
            calls[0] = Call(
                router,
                p.amountIn,
                abi.encodeCall(IUpRouter.swapExactETHForTokens, (p.minOut, routes, account, block.timestamp))
            );
            return calls;
        }
        if (p.via == address(0)) {
            routes[0] = IUpRouter.Route(p.token, weth, p.stable, poolFactory);
        } else {
            routes[0] = IUpRouter.Route(p.token, p.via, p.stable, poolFactory);
            routes[1] = IUpRouter.Route(p.via, weth, p.viaStable, poolFactory);
        }
        calls = new Call[](3);
        calls[0] = Call(p.token, 0, abi.encodeCall(IERC20Approve.approve, (router, p.amountIn)));
        calls[1] = Call(
            router,
            0,
            abi.encodeCall(IUpRouter.swapExactTokensForETH, (p.amountIn, p.minOut, routes, account, block.timestamp))
        );
        calls[2] = Call(p.token, 0, abi.encodeCall(IERC20Approve.approve, (router, 0)));
    }

    function _concentrated(address account, Params memory p) private view returns (Call[] memory calls) {
        if (p.buy) {
            bytes memory path = p.via == address(0)
                ? abi.encodePacked(weth, p.tickSpacing, p.token)
                : abi.encodePacked(weth, p.viaTickSpacing, p.via, p.tickSpacing, p.token);
            calls = new Call[](1);
            calls[0] = Call(
                clRouter,
                p.amountIn,
                abi.encodeCall(
                    IUpClRouter.exactInput, (IUpClRouter.ExactInputParams(path, account, block.timestamp, p.amountIn, p.minOut))
                )
            );
            return calls;
        }
        bytes memory sellPath = p.via == address(0)
            ? abi.encodePacked(p.token, p.tickSpacing, weth)
            : abi.encodePacked(p.token, p.tickSpacing, p.via, p.viaTickSpacing, weth);
        bytes[] memory steps = new bytes[](2);
        steps[0] = abi.encodeCall(
            IUpClRouter.exactInput, (IUpClRouter.ExactInputParams(sellPath, clRouter, block.timestamp, p.amountIn, p.minOut))
        );
        steps[1] = abi.encodeCall(IUpClRouter.unwrapWETH9, (p.minOut, account));
        calls = new Call[](3);
        calls[0] = Call(p.token, 0, abi.encodeCall(IERC20Approve.approve, (clRouter, p.amountIn)));
        calls[1] = Call(clRouter, 0, abi.encodeCall(IUpClRouter.multicall, (steps)));
        calls[2] = Call(p.token, 0, abi.encodeCall(IERC20Approve.approve, (clRouter, 0)));
    }
}
