// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @notice Builds the calls for one action on a yield venue. A SpinPosition runs
 * them from itself. Adapters hold no funds. Everything an action produces goes
 * to the position; approvals are exact and reset to zero.
 */
interface IPositionAdapter {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @param position The SpinPosition; it is `msg.sender` of every call.
    /// @param harvest True for a harvest: the adapter plans only actions that collect income and remove
    /// no principal, and refuses any other.
    /// @param params The adapter's encoding of one action (see each adapter).
    function plan(address position, bool harvest, bytes calldata params) external view returns (Call[] memory calls);

    /// @notice The calls that take `fraction` (of 1e18) of everything `position` holds in this venue
    /// back to USDG. 1e18 is a full exit. `params` carries only the caller's limits (e.g. minimums).
    function exitPlan(address position, uint256 fraction, bytes calldata params) external view returns (Call[] memory calls);

    /// @notice True while `position` still holds anything in this venue.
    function holds(address position) external view returns (bool);

    /// @notice What this transaction's full exit through `exitPlan` returned to `position` unsold, because
    /// a price check failed: the tokens, their amounts, and their value in USDG at the venue's reference
    /// prices. Empty when everything was sold.
    function unsold(address position)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts, uint256 value);
}
