// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AdminWithdrawable} from "../utils/Withdrawable.sol";

/**
 * @title FeeSplitter
 * @notice Collects the protocol's fees (ETH and ERC-20 tokens) and splits them between the burn
 * wallet and the treasury. It does nothing when fees arrive: anyone can call `distribute(token)`,
 * which pays `burnBps` of its whole balance of that token (zero: ETH) to the burn wallet and the
 * rest to the treasury.
 *
 * The admin (the deploying address, until it sets another) sets the burn wallet, its share and the
 * treasury, and can withdraw any ETH or ERC-20 tokens held here, to the treasury only.
 */
contract FeeSplitter is AdminWithdrawable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// Receives `burnBps` of each distribution.
    address payable public burnWallet;
    /// The burn wallet's share of each distribution, in basis points.
    uint16 public burnBps;

    event BurnWalletSet(address burnWallet);
    event BurnShareSet(uint16 burnBps);
    event Distributed(address indexed token, uint256 toBurnWallet, uint256 toTreasury);

    error BadShare();
    error NoBurnWallet();
    error PaymentFailed();

    constructor(address payable treasury_, address payable burnWallet_, uint16 burnBps_) {
        if (burnBps_ > 10_000) revert BadShare();
        treasury = treasury_;
        burnWallet = burnWallet_;
        burnBps = burnBps_;
        emit TreasurySet(treasury_);
        emit BurnWalletSet(burnWallet_);
        emit BurnShareSet(burnBps_);
    }

    receive() external payable {}

    function setBurnWallet(address payable burnWallet_) external {
        if (msg.sender != admin) revert NotAdmin();
        burnWallet = burnWallet_;
        emit BurnWalletSet(burnWallet_);
    }

    function setBurnShare(uint16 burnBps_) external {
        if (msg.sender != admin) revert NotAdmin();
        if (burnBps_ > 10_000) revert BadShare();
        burnBps = burnBps_;
        emit BurnShareSet(burnBps_);
    }

    /// @notice Splits this contract's whole balance of `token` (zero: ETH) between the burn wallet and the treasury.
    function distribute(address token) external nonReentrant {
        if (treasury == address(0)) revert NoTreasury();
        if (burnWallet == address(0)) revert NoBurnWallet();
        uint256 amount = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        if (amount == 0) return;
        uint256 toBurnWallet = (amount * burnBps) / 10_000;
        uint256 toTreasury = amount - toBurnWallet;
        if (token == address(0)) {
            _sendEth(burnWallet, toBurnWallet);
            _sendEth(treasury, toTreasury);
        } else {
            if (toBurnWallet != 0) IERC20(token).safeTransfer(burnWallet, toBurnWallet);
            if (toTreasury != 0) IERC20(token).safeTransfer(treasury, toTreasury);
        }
        emit Distributed(token, toBurnWallet, toTreasury);
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }
}
