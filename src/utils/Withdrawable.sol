// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Withdrawable
 * @notice Withdrawal of ETH and ERC-20 tokens held by this contract, by the address that
 * `_authorizeWithdraw` allows, always to the one address `_withdrawTo` names: the protocol's
 * treasury (a holder's own contract: its owner). No withdrawal goes to an address the caller picks.
 */
abstract contract Withdrawable {
    /// `token` is the zero address for ETH.
    event BalanceWithdrawn(address indexed token, address indexed to, uint256 amount);

    error EthWithdrawFailed();

    /// @notice Sends `amount` of this contract's ETH to its withdrawal address.
    function withdrawEth(uint256 amount) external {
        _authorizeWithdraw(address(0));
        address payable to = _withdrawTo();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthWithdrawFailed();
        emit BalanceWithdrawn(address(0), to, amount);
    }

    /// @notice Sends `amount` of the ERC-20 `token` held by this contract to its withdrawal address.
    function withdrawToken(address token, uint256 amount) external {
        _authorizeWithdraw(token);
        address to = _withdrawTo();
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit BalanceWithdrawn(token, to, amount);
    }

    /// Reverts unless the caller may withdraw `token` (zero: ETH).
    function _authorizeWithdraw(address token) internal view virtual;

    /// Where every withdrawal goes.
    function _withdrawTo() internal view virtual returns (address payable);
}

/**
 * @title AdminWithdrawable
 * @notice Withdrawable by an admin (the deploying address, until it sets another), to the
 * treasury the admin sets. Until a treasury is set, a withdrawal reverts and nothing moves.
 */
abstract contract AdminWithdrawable is Withdrawable {
    address public admin;
    address payable public treasury;

    event AdminSet(address admin);
    event TreasurySet(address treasury);

    error NotAdmin();
    error NoTreasury();

    constructor() {
        admin = msg.sender;
        emit AdminSet(msg.sender);
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

    function _withdrawTo() internal view override returns (address payable) {
        if (treasury == address(0)) revert NoTreasury();
        return treasury;
    }
}
