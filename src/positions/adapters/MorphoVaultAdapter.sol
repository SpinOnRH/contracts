// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPositionAdapter} from "../IPositionAdapter.sol";
import {AdminWithdrawable} from "../../utils/Withdrawable.sol";

interface IERC4626Vault {
    function asset() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

interface IApprove {
    function approve(address spender, uint256 value) external returns (bool);
}

interface IDeployed {
    function deployed() external view returns (uint256);
}

/**
 * @title MorphoVaultAdapter
 * @notice One ERC-4626 vault (a Morpho vault) as a SpinPosition venue.
 *
 * `params` = abi.encode(Action action, uint256 amount):
 * - `In`: deposits `amount` of the vault's asset.
 * - `Out`: redeems every share the position holds (`amount` unused).
 * - `Harvest`: withdraws the interest only: what the position's shares would
 *   redeem for, less the position's `deployed` (`amount` unused).
 * A harvest job may only plan `Harvest`, and `Harvest` only a harvest job.
 * `exitPlan` redeems the fraction of the position's shares (`params` unused).
 *
 * The admin (the deploying address, until it sets another) can withdraw any ETH or ERC-20
 * tokens sent to this contract, to the treasury it sets (`setTreasury`) only.
 */
contract MorphoVaultAdapter is IPositionAdapter, AdminWithdrawable {
    enum Action {
        In,
        Out,
        Harvest
    }

    IERC4626Vault public immutable vault;
    address public immutable asset;

    error NothingToDo();
    error WrongKind();

    constructor(IERC4626Vault vault_) {
        vault = vault_;
        asset = vault_.asset();
    }

    function plan(address position, bool harvest, bytes calldata params) external view returns (Call[] memory calls) {
        (Action action, uint256 amount) = abi.decode(params, (Action, uint256));
        if (harvest != (action == Action.Harvest)) revert WrongKind();
        if (action == Action.In) {
            if (amount == 0) revert NothingToDo();
            calls = new Call[](3);
            calls[0] = Call(asset, 0, abi.encodeCall(IApprove.approve, (address(vault), amount)));
            calls[1] = Call(address(vault), 0, abi.encodeCall(IERC4626Vault.deposit, (amount, position)));
            calls[2] = Call(asset, 0, abi.encodeCall(IApprove.approve, (address(vault), 0)));
        } else if (action == Action.Out) {
            uint256 shares = vault.balanceOf(position);
            if (shares == 0) revert NothingToDo();
            calls = new Call[](1);
            calls[0] = Call(address(vault), 0, abi.encodeCall(IERC4626Vault.redeem, (shares, position, position)));
        } else {
            uint256 value = vault.previewRedeem(vault.balanceOf(position));
            uint256 cost = IDeployed(position).deployed();
            if (value <= cost) revert NothingToDo();
            calls = new Call[](1);
            calls[0] = Call(address(vault), 0, abi.encodeCall(IERC4626Vault.withdraw, (value - cost, position, position)));
        }
    }

    function exitPlan(address position, uint256 fraction, bytes calldata) external view returns (Call[] memory calls) {
        uint256 shares = vault.balanceOf(position);
        if (fraction < 1e18) shares = (shares * fraction) / 1e18;
        if (shares == 0) revert NothingToDo();
        calls = new Call[](1);
        calls[0] = Call(address(vault), 0, abi.encodeCall(IERC4626Vault.redeem, (shares, position, position)));
    }

    function holds(address position) external view returns (bool) {
        return vault.balanceOf(position) > 0;
    }

    /// A vault's exit always pays out in USDG: nothing is left unsold.
    function unsold(address) external pure returns (address[] memory, uint256[] memory, uint256) {}
}
