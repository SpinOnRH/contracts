// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVenueAdapter} from "../IVenueAdapter.sol";
import {AdminWithdrawable} from "../../utils/Withdrawable.sol";
import {SpinnerCreatorVaults} from "../SpinnerCreatorVaults.sol";

interface IPonsLaunchFactory {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address creatorFeeRecipient;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        bytes32 expectedEconomics;
        bytes32 salt;
    }

    function launchToken(TokenParams calldata params, uint256 launchConfigId, address pairToken)
        external
        payable
        returns (address token, address curve);
    function launchFee() external view returns (uint256);
    function launchForwarder() external view returns (address);
}

interface IPonsLaunchAndBuy {
    function launchAndBuy(
        IPonsLaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        uint256 quoteIn,
        uint256 minTokensOut,
        address recipient,
        address[] calldata snipeTaxExemptions
    ) external payable;
}

/**
 * @title PonsLaunchAdapter
 * @notice Launches an ETH-paired Pons V2 token from the account, with an optional first buy.
 *
 * params = abi.encode(Params)
 *   devBuy == 0: the factory's launchToken, paying its launch fee.
 *   devBuy > 0:  the factory's launch forwarder (launch and buy in one call), paying the launch
 *                fee plus `devBuy`; at least `minTokensOut` tokens go to the account.
 *
 * The account is the launch's deployer and receives any tokens bought; its creator fee recipient
 * is the account's SpinnerCreatorVault, which pays them to the account only, so they stay with
 * the Spinner. The launch is always against native ETH. The fee and the forwarder are read from
 * the factory.
 * The route names no token: the first buy is on the token's own curve, an open route.
 *
 * The admin (the deploying address, until it sets another) can withdraw any ETH or ERC-20
 * tokens sent to this contract, to the treasury it sets (`setTreasury`) only.
 */
contract PonsLaunchAdapter is IVenueAdapter, AdminWithdrawable {
    struct Params {
        string name;
        string symbol;
        string logo;
        string description;
        IPonsLaunchFactory.Socials socials;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        bytes32 expectedEconomics;
        bytes32 salt;
        uint256 launchConfigId;
        uint256 devBuy;
        uint256 minTokensOut;
    }

    IPonsLaunchFactory public immutable factory;
    SpinnerCreatorVaults public immutable vaults;

    constructor(IPonsLaunchFactory factory_, SpinnerCreatorVaults vaults_) {
        factory = factory_;
        vaults = vaults_;
    }

    function plan(address account, bytes calldata params) external view returns (Call[] memory calls, Route memory route) {
        Params memory p = abi.decode(params, (Params));
        IPonsLaunchFactory.TokenParams memory t = IPonsLaunchFactory.TokenParams({
            name: p.name,
            symbol: p.symbol,
            logo: p.logo,
            description: p.description,
            socials: p.socials,
            // Pons keeps the fees for an address until it claims them: the vault need not exist yet.
            creatorFeeRecipient: vaults.vaultOf(account),
            creatorTaxBps: p.creatorTaxBps,
            buybackEnabled: p.buybackEnabled,
            expectedEconomics: p.expectedEconomics,
            salt: p.salt
        });
        uint256 fee = factory.launchFee();
        route = Route(address(0), bytes32(0), false);
        calls = new Call[](1);
        if (p.devBuy == 0) {
            calls[0] = Call(address(factory), fee, abi.encodeCall(IPonsLaunchFactory.launchToken, (t, p.launchConfigId, address(0))));
        } else {
            calls[0] = Call(
                factory.launchForwarder(),
                fee + p.devBuy,
                abi.encodeCall(
                    IPonsLaunchAndBuy.launchAndBuy,
                    (t, p.launchConfigId, address(0), p.devBuy, p.minTokensOut, account, new address[](0))
                )
            );
        }
    }
}
