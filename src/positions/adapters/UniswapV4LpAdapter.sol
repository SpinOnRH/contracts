// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../../interfaces/IERC20.sol";
import {IPositionAdapter} from "../IPositionAdapter.sol";
import {WethUsdgVenue, ISwapPool, IAggregatorV3} from "./WethUsdgVenue.sol";

/// A Uniswap V4 pool's key. Currencies are addresses; native ETH is address(0).
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IPositionManagerV4 {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256 info);
    function ownerOf(uint256 tokenId) external view returns (address);
    function approve(address spender, uint256 tokenId) external;
    function poolManager() external view returns (address);
}

interface IStateView {
    function getSlot0(bytes32 poolId) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/**
 * @title UniswapV4LpAdapter
 * @notice One Uniswap V4 ETH/USDG pool (native ETH as currency0) as a
 * SpinPosition venue: a single concentrated position (an NFT of V4's
 * PositionManager) held by the SpinPosition, opened from USDG and closed back
 * to USDG.
 *
 * The position's calls approve this adapter and call it; the adapter does the
 * swaps and the PositionManager calls, then returns everything to the position
 * in the same call, holding no funds afterwards. It pays the PositionManager
 * directly (USDG sent ahead and settled from the PositionManager's balance,
 * ETH as call value), so it needs no Permit2 allowance.
 *
 * WETH/USDG swaps go through `swapPool`, a Uniswap V3 pool (the deepest one).
 * Every price the adapter acts on is checked against Chainlink
 * (WethUsdgVenue): the V4 pool's price before liquidity is added or removed,
 * and the average price of each swap.
 *
 * The adapter records the NFT it minted for each position and acts only on
 * that one; other NFTs sent to the position are ignored.
 *
 * `params` = abi.encode(Action action, bytes data):
 * - `In`: data = abi.encode(uint256 amount, uint256 swapAmount, int24 tickLower, int24 tickUpper).
 *   Takes `amount` USDG, swaps `swapAmount` of it to ETH, and adds both as
 *   liquidity: a new position in [tickLower, tickUpper], or more liquidity in
 *   the position's existing one (its range; the ticks are then ignored).
 *   What is not used goes back to the position (ETH as WETH).
 * - `Out`: the whole position back to USDG (data unused).
 * - `Harvest`: the position's fees, as USDG (data unused).
 * A harvest job may only plan `Harvest`, and `Harvest` only a harvest job.
 * `exitPlan` takes a fraction of the position's liquidity, all its fees, and
 * the same fraction of any WETH the position holds, back to USDG. In a full
 * exit through `exitPlan` (the owner's full withdrawal), a price check that
 * fails (a stale feed, or the pool's price away from Chainlink) does not stop
 * the exit: the ETH goes back to the position unsold, as WETH (`unsold`),
 * valued at Chainlink's last price.
 */
contract UniswapV4LpAdapter is IPositionAdapter, WethUsdgVenue {
    enum Action {
        In,
        Out,
        Harvest
    }

    // V4 PositionManager actions (v4-periphery Actions.sol).
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant BURN_POSITION = 0x03;
    uint8 internal constant INCREASE_LIQUIDITY_FROM_DELTAS = 0x04;
    uint8 internal constant MINT_POSITION_FROM_DELTAS = 0x05;
    uint8 internal constant SETTLE = 0x0b;
    uint8 internal constant TAKE_PAIR = 0x11;

    IPositionManagerV4 public immutable positionManager;
    address public immutable poolManager;
    IStateView public immutable stateView;
    ISwapPool public immutable swapPool;
    bool public immutable swapWethIsToken0;
    bytes32 public immutable poolId;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    address public immutable hooks;
    /// The narrowest and widest new range, in ticks.
    int24 public immutable minWidth;
    int24 public immutable maxWidth;

    /// The NFT this adapter minted for each position (0: none).
    mapping(address position => uint256 tokenId) public tokenOf;

    error NotOwnerOfPosition();
    error WrongPool();
    error BadRange();
    error NothingToDo();
    error WrongKind();
    error UnexpectedEth();

    constructor(
        PoolKey memory key,
        IPositionManagerV4 positionManager_,
        IStateView stateView_,
        ISwapPool swapPool_,
        address weth_,
        address usdg_,
        IAggregatorV3 ethUsd_,
        IAggregatorV3 usdgUsd_,
        uint16 maxDeviationBps_,
        uint32 maxFeedAge_,
        int24 minWidth_,
        int24 maxWidth_
    ) WethUsdgVenue(weth_, usdg_, ethUsd_, usdgUsd_, maxDeviationBps_, maxFeedAge_) {
        if (key.currency0 != address(0) || key.currency1 != usdg_) revert WrongPool();
        address s0 = swapPool_.token0();
        address s1 = swapPool_.token1();
        if (!((s0 == weth_ && s1 == usdg_) || (s0 == usdg_ && s1 == weth_))) revert WrongPool();
        positionManager = positionManager_;
        poolManager = positionManager_.poolManager();
        stateView = stateView_;
        swapPool = swapPool_;
        swapWethIsToken0 = s0 == weth_;
        poolId = keccak256(abi.encode(key));
        fee = key.fee;
        tickSpacing = key.tickSpacing;
        hooks = key.hooks;
        minWidth = minWidth_;
        maxWidth = maxWidth_;
    }

    /// ETH comes only from WETH (unwrapping) and the PoolManager (taking).
    receive() external payable {
        if (msg.sender != weth && msg.sender != poolManager) revert UnexpectedEth();
    }

    // ── Plans (run from the position) ───────────────────────────────────

    function plan(address position, bool harvest, bytes calldata params) external view returns (Call[] memory calls) {
        (Action action, bytes memory data) = abi.decode(params, (Action, bytes));
        if (harvest != (action == Action.Harvest)) revert WrongKind();
        if (action == Action.In) {
            (uint256 amount, uint256 swapAmount, int24 tickLower, int24 tickUpper) = abi.decode(data, (uint256, uint256, int24, int24));
            if (amount == 0 || swapAmount > amount) revert NothingToDo();
            uint256 tokenId = _held(position);
            bytes memory enterCall = abi.encodeCall(this.enter, (amount, swapAmount, tickLower, tickUpper));
            if (tokenId == 0) {
                calls = new Call[](3);
                calls[0] = Call(usdg, 0, abi.encodeCall(IERC20.approve, (address(this), amount)));
                calls[1] = Call(address(this), 0, enterCall);
                calls[2] = Call(usdg, 0, abi.encodeCall(IERC20.approve, (address(this), 0)));
            } else {
                // Adding to the existing range: the adapter must be approved for the NFT.
                calls = new Call[](5);
                calls[0] = Call(address(positionManager), 0, abi.encodeCall(IPositionManagerV4.approve, (address(this), tokenId)));
                calls[1] = Call(usdg, 0, abi.encodeCall(IERC20.approve, (address(this), amount)));
                calls[2] = Call(address(this), 0, enterCall);
                calls[3] = Call(usdg, 0, abi.encodeCall(IERC20.approve, (address(this), 0)));
                calls[4] = Call(address(positionManager), 0, abi.encodeCall(IPositionManagerV4.approve, (address(0), tokenId)));
            }
        } else if (action == Action.Out) {
            calls = _exitCalls(position, WHOLE, false);
        } else {
            uint256 tokenId = _tokenOf(position);
            calls = new Call[](3);
            calls[0] = Call(address(positionManager), 0, abi.encodeCall(IPositionManagerV4.approve, (address(this), tokenId)));
            calls[1] = Call(address(this), 0, abi.encodeCall(this.harvestFor, ()));
            calls[2] = Call(address(positionManager), 0, abi.encodeCall(IPositionManagerV4.approve, (address(0), tokenId)));
        }
    }

    function exitPlan(address position, uint256 fraction, bytes calldata) external view returns (Call[] memory) {
        return _exitCalls(position, fraction, true);
    }

    function holds(address position) external view returns (bool) {
        return _held(position) != 0;
    }

    function unsold(address position) external view returns (address[] memory tokens, uint256[] memory, uint256) {
        tokens = new address[](1);
        tokens[0] = weth;
        return _unsold(position, tokens);
    }

    function _exitCalls(address position, uint256 fraction, bool byOwner) internal view returns (Call[] memory calls) {
        uint256 tokenId = _tokenOf(position);
        uint256 wethHeld = (IERC20(weth).balanceOf(position) * fraction) / WHOLE;
        bool whole = fraction >= WHOLE;
        // A whole exit burns the NFT, which clears its approval.
        calls = new Call[](whole ? 4 : 5);
        calls[0] = Call(address(positionManager), 0, abi.encodeCall(IPositionManagerV4.approve, (address(this), tokenId)));
        calls[1] = Call(weth, 0, abi.encodeCall(IERC20.approve, (address(this), wethHeld)));
        calls[2] = Call(address(this), 0, abi.encodeCall(this.exitFor, (fraction, wethHeld, byOwner)));
        calls[3] = Call(weth, 0, abi.encodeCall(IERC20.approve, (address(this), 0)));
        if (!whole) calls[4] = Call(address(positionManager), 0, abi.encodeCall(IPositionManagerV4.approve, (address(0), tokenId)));
    }

    /// The NFT this adapter minted for `position`, while the position still owns it (0 otherwise).
    function _held(address position) internal view returns (uint256 tokenId) {
        tokenId = tokenOf[position];
        if (tokenId == 0) return 0;
        try positionManager.ownerOf(tokenId) returns (address owner) {
            if (owner != position) return 0;
        } catch {
            return 0; // burned
        }
    }

    function _tokenOf(address position) internal view returns (uint256 tokenId) {
        tokenId = _held(position);
        if (tokenId == 0) revert NothingToDo();
    }

    // ── Execution (called by the position, within its plan) ─────────────

    /// @notice Takes `amount` USDG from the caller and adds it as liquidity for the caller.
    function enter(uint256 amount, uint256 swapAmount, int24 tickLower, int24 tickUpper) external nonReentrant {
        address position = msg.sender;
        uint256 oracle = _oraclePrice();
        _checkSpot(oracle);
        IERC20(usdg).transferFrom(position, address(this), amount);
        if (swapAmount > 0) {
            _swap(false, swapAmount, oracle);
            IWETH9(weth).withdraw(IERC20(weth).balanceOf(address(this)));
        }

        uint256 ethIn = address(this).balance;
        uint256 usdgIn = IERC20(usdg).balanceOf(address(this));
        // Paid ahead: the PositionManager settles USDG from its own balance and ETH from the call value.
        IERC20(usdg).transfer(address(positionManager), usdgIn);
        uint256 tokenId = _held(position);
        bytes memory actions;
        bytes[] memory p = new bytes[](4);
        p[0] = abi.encode(address(0), ethIn, false);
        p[1] = abi.encode(usdg, usdgIn, false);
        if (tokenId != 0) {
            actions = abi.encodePacked(SETTLE, SETTLE, INCREASE_LIQUIDITY_FROM_DELTAS, TAKE_PAIR);
            p[2] = abi.encode(tokenId, uint128(ethIn), uint128(usdgIn), bytes(""));
        } else {
            int24 width = tickUpper - tickLower;
            if (tickLower % tickSpacing != 0 || tickUpper % tickSpacing != 0 || width < minWidth || width > maxWidth) revert BadRange();
            tokenId = positionManager.nextTokenId();
            actions = abi.encodePacked(SETTLE, SETTLE, MINT_POSITION_FROM_DELTAS, TAKE_PAIR);
            p[2] = abi.encode(_key(), tickLower, tickUpper, uint128(ethIn), uint128(usdgIn), position, bytes(""));
            tokenOf[position] = tokenId;
        }
        // What the liquidity did not use comes back here.
        p[3] = abi.encode(address(0), usdg, address(this));
        positionManager.modifyLiquidities{value: ethIn}(abi.encode(actions, p), block.timestamp);
        if (positionManager.ownerOf(tokenId) != position) revert NotOwnerOfPosition();
        _returnAll(position);
    }

    /// @notice Takes `fraction` of the caller's liquidity, all its fees and `wethHeld` of its WETH back to USDG.
    /// `byOwner` marks the owner's withdrawal: in a full one, ETH that cannot be sold at a checked price goes
    /// back to the position unsold, as WETH.
    function exitFor(uint256 fraction, uint256 wethHeld, bool byOwner) external nonReentrant {
        address position = msg.sender;
        uint256 tokenId = _held(position);
        if (tokenId == 0) revert NotOwnerOfPosition();
        bool inKind = byOwner && fraction >= WHOLE;
        (uint256 oracle, bool sell) = _exitPrice(inKind);
        bytes[] memory p = new bytes[](2);
        p[1] = abi.encode(address(0), usdg, address(this));
        bytes memory actions;
        if (fraction >= WHOLE) {
            actions = abi.encodePacked(BURN_POSITION, TAKE_PAIR);
            p[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
            delete tokenOf[position];
        } else {
            uint256 out = (uint256(positionManager.getPositionLiquidity(tokenId)) * fraction) / WHOLE;
            actions = abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR);
            p[0] = abi.encode(tokenId, out, uint128(0), uint128(0), bytes(""));
        }
        positionManager.modifyLiquidities(abi.encode(actions, p), block.timestamp);
        if (wethHeld > 0) IERC20(weth).transferFrom(position, address(this), wethHeld);
        if (sell && !inKind) {
            _sellEth(oracle);
        } else {
            if (address(this).balance > 0) IWETH9(weth).deposit{value: address(this).balance}();
            if (sell) _sellWethOrKeep(position, 0, oracle);
            else _keepUnsold(position, 0, weth, oracle, 1e30);
        }
        _returnAll(position);
    }

    /// The Chainlink price, and whether ETH may be sold: in the owner's full withdrawal (`inKind`) a failed
    /// check means no sale; otherwise it reverts.
    function _exitPrice(bool inKind) internal view returns (uint256 oracle, bool sell) {
        if (!inKind) {
            oracle = _oraclePrice();
            _checkSpot(oracle);
            return (oracle, true);
        }
        bool fresh;
        (oracle, fresh) = _tryOraclePrice();
        (uint160 sqrtPriceX96,,,) = stateView.getSlot0(poolId);
        sell = fresh && _isWithin(_spotPrice(sqrtPriceX96, true), oracle);
    }

    /// @notice Collects the caller's fees and returns them as USDG.
    function harvestFor() external nonReentrant {
        address position = msg.sender;
        uint256 tokenId = _held(position);
        if (tokenId == 0) revert NotOwnerOfPosition();
        uint256 oracle = _oraclePrice();
        // A decrease of zero liquidity collects the fees.
        bytes[] memory p = new bytes[](2);
        p[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        p[1] = abi.encode(address(0), usdg, address(this));
        positionManager.modifyLiquidities(abi.encode(abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR), p), block.timestamp);
        _sellEth(oracle);
        _returnAll(position);
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey(address(0), usdg, fee, tickSpacing, hooks);
    }

    function _isPool(address p) internal view override returns (bool) {
        return p == address(swapPool);
    }

    function _checkSpot(uint256 oracle) internal view {
        (uint160 sqrtPriceX96,,,) = stateView.getSlot0(poolId);
        _within(_spotPrice(sqrtPriceX96, true), oracle);
    }

    function _swap(bool wethIn, uint256 amountIn, uint256 oracle) internal {
        _swapWethUsdg(swapPool, swapWethIsToken0, wethIn, amountIn, oracle);
    }

    function _sellAllWeth(uint256 oracle) internal override {
        _sellEth(oracle);
    }

    /// Wraps any ETH here and swaps all WETH here to USDG.
    function _sellEth(uint256 oracle) internal {
        if (address(this).balance > 0) IWETH9(weth).deposit{value: address(this).balance}();
        uint256 wethOut = IERC20(weth).balanceOf(address(this));
        if (wethOut > 0) _swap(true, wethOut, oracle);
    }

    /// Returns what is left to the position: ETH as WETH, and USDG.
    function _returnAll(address position) internal {
        if (address(this).balance > 0) IWETH9(weth).deposit{value: address(this).balance}();
        _return(weth, position);
        _return(usdg, position);
    }
}
