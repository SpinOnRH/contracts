// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AdminWithdrawable} from "../utils/Withdrawable.sol";

interface IHookList {
    function allowedHook(address hook) external view returns (bool);
}

/**
 * @title HookList
 * @notice The Uniswap V4 hooks that the venue adapters may trade through. A pool with no hook
 * needs no entry. The admin (the deploying address, until it sets another) keeps the list.
 *
 * The admin can withdraw any ETH or ERC-20 tokens sent to this contract, to the treasury it
 * sets (`setTreasury`) only.
 */
contract HookList is IHookList, AdminWithdrawable {
    mapping(address hook => bool) public allowedHook;

    event HookSet(address indexed hook, bool allowed);

    constructor(address[] memory hooks) {
        for (uint256 i; i < hooks.length; i++) {
            allowedHook[hooks[i]] = true;
            emit HookSet(hooks[i], true);
        }
    }

    function setHook(address hook, bool allowed) external {
        if (msg.sender != admin) revert NotAdmin();
        allowedHook[hook] = allowed;
        emit HookSet(hook, allowed);
    }
}

/**
 * @title HookListUser
 * @notice A contract that checks V4 hooks against a HookList. Its admin can point it at
 * another list (`setHookList`).
 */
abstract contract HookListUser {
    IHookList public hookList;

    event HookListSet(address hookList);

    error HookNotAllowed(address hook);
    error NoHookList();

    constructor(IHookList hookList_) {
        _setHookList(hookList_);
    }

    function setHookList(IHookList hookList_) external {
        _authorizeHookListChange();
        _setHookList(hookList_);
    }

    /// Reverts unless the caller may change the list.
    function _authorizeHookListChange() internal view virtual;

    /// Reverts unless `hook` is none or on the list.
    function _checkHook(address hook) internal view {
        if (hook != address(0) && !hookList.allowedHook(hook)) revert HookNotAllowed(hook);
    }

    function _setHookList(IHookList hookList_) private {
        if (address(hookList_) == address(0)) revert NoHookList();
        hookList = hookList_;
        emit HookListSet(address(hookList_));
    }
}
