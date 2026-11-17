// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Routes
 * @notice The route ids venue adapters give SpinBotGuard: one id per way a token can be traded.
 * A buy and a sell through the same pools have the same id. Each id names every pool of its path,
 * so two routes that differ in any pool have different ids.
 */
library Routes {
    /// A Pons token's own curve and, after graduation, its own V4 pool.
    bytes32 internal constant PONS = keccak256("spin.route.pons");

    /// A Torch token's own V4 pool (the Torch factory names its quote token; every Torch pool has the same fee and tick spacing).
    bytes32 internal constant TORCH = keccak256("spin.route.torch");

    /// A Long.xyz token's own V4 pool against native ETH (Doppler names the pool and its pair token).
    bytes32 internal constant LONG = keccak256("spin.route.long");

    /// A fobo.fun token's own V4 pool against native ETH (FoboHook records the pool it made for the token).
    bytes32 internal constant FOBO = keccak256("spin.route.fobo");

    /// A Uniswap V3 or V4 path between native ETH and a token, through `via` when it is not zero
    /// (the fields as in UniswapAdapter.Params).
    function uniswap(
        bool v4,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        address via,
        uint24 viaFee,
        int24 viaTickSpacing,
        address viaHooks
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode("spin.route.uniswap", v4, fee, tickSpacing, hooks, via, viaFee, viaTickSpacing, viaHooks));
    }

    /// A Pons, Torch, Long or fobo token paired with another token: its launchpad (`PONS`, `TORCH`, `LONG`, `FOBO`) and the
    /// Uniswap path between native ETH and the pair token (`hop`, as `uniswap` names it).
    function pair(bytes32 launchpad, bytes32 hop) internal pure returns (bytes32) {
        return keccak256(abi.encode("spin.route.pair", launchpad, hop));
    }

    /// An UP path between native ETH and a token (the fields as in UpAdapter.Params).
    function up(bool concentrated, bool stable, int24 tickSpacing, address via, bool viaStable, int24 viaTickSpacing)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("spin.route.up", concentrated, stable, tickSpacing, via, viaStable, viaTickSpacing));
    }
}
