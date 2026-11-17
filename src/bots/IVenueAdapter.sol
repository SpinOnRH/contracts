// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @notice Builds the calls for one trade on a venue. SpinBotGuard executes them
 * from the account. Adapters hold no state or funds. Everything a trade
 * produces goes to `account`; approvals are exact and reset to zero.
 */
interface IVenueAdapter {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @notice The token a trade moves and the route it moves through (see `Routes`).
    /// The guard credits the tokens a trade brings in to its route, and lets a trade take tokens out
    /// only through a route that holds a credit for them, unless the route is `open`: a launchpad's
    /// own curve or pool, as its contracts name it. `token` is zero for a trade whose token the guard
    /// does not count.
    struct Route {
        address token;
        bytes32 id;
        bool open;
    }

    /// @param account The bot's token-bound account; it is `msg.sender` of every call.
    /// @param params The venue's encoding of one trade (see each adapter).
    function plan(address account, bytes calldata params)
        external
        view
        returns (Call[] memory calls, Route memory route);
}
