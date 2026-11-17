// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVenueAdapter} from "../IVenueAdapter.sol";
import {Routes} from "../Routes.sol";
import {AdminWithdrawable} from "../../utils/Withdrawable.sol";
import {IPonsCurve} from "../../interfaces/IPonsCurve.sol";

interface IPonsFactory {
    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
}

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @title PonsAdapter
 * @notice Buys and sells ETH-paired Pons V2 tokens on their bonding curve.
 *
 * params = abi.encode(bool buy, address token, uint256 amount, uint256 minOut)
 *   buy:  `amount` ETH in, at least `minOut` tokens out
 *   sell: `amount` tokens in, at least `minOut` ETH out
 *
 * The curve is the one the Pons factory names for the token, never the
 * caller's; the recipient is always the account. Near graduation the curve
 * refunds what it cannot take to the caller, which is the account. The route
 * is open (`Routes.PONS`): the factory names the curve.
 *
 * The admin (the deploying address, until it sets another) can withdraw any ETH or ERC-20
 * tokens sent to this contract, to the treasury it sets (`setTreasury`) only.
 */
contract PonsAdapter is IVenueAdapter, AdminWithdrawable {
    IPonsFactory public immutable factory;

    error NotPonsEthToken();

    constructor(IPonsFactory factory_) {
        factory = factory_;
    }

    function plan(address account, bytes calldata params) external view returns (Call[] memory calls, Route memory route) {
        (bool buy, address token, uint256 amount, uint256 minOut) =
            abi.decode(params, (bool, address, uint256, uint256));
        address curve = _curve(token);
        route = Route(token, Routes.PONS, true);
        if (buy) {
            calls = new Call[](1);
            calls[0] = Call(curve, amount, abi.encodeCall(IPonsCurve.buy, (amount, minOut, account)));
        } else {
            calls = new Call[](3);
            calls[0] = Call(token, 0, abi.encodeCall(IERC20Approve.approve, (curve, amount)));
            calls[1] = Call(curve, 0, abi.encodeCall(IPonsCurve.sell, (amount, minOut, account)));
            calls[2] = Call(token, 0, abi.encodeCall(IERC20Approve.approve, (curve, 0)));
        }
    }

    function _curve(address token) internal view returns (address) {
        IPonsFactory.LaunchedToken memory t = factory.getLaunchedToken(token);
        if (!t.exists || t.pairToken != address(0) || t.curve == address(0) || t.token != token) {
            revert NotPonsEthToken();
        }
        return t.curve;
    }
}
