// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../../interfaces/IERC20.sol";
import {IPositionAdapter} from "../IPositionAdapter.sol";
import {WethUsdgVenue, ISwapPool, IAggregatorV3} from "./WethUsdgVenue.sol";

interface IUniswapV3PoolLp is ISwapPool {
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function mint(MintParams calldata params) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function increaseLiquidity(IncreaseLiquidityParams calldata params) external payable returns (uint128, uint256, uint256);
    function decreaseLiquidity(DecreaseLiquidityParams calldata params) external payable returns (uint256, uint256);
    function collect(CollectParams calldata params) external payable returns (uint256, uint256);
    function burn(uint256 tokenId) external payable;
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function approve(address to, uint256 tokenId) external;
}

/**
 * @title UniswapV3LpAdapter
 * @notice One Uniswap V3 WETH/USDG pool as a SpinPosition venue: a single
 * concentrated position (an NFT of the pool's position manager) held by the
 * SpinPosition, opened from USDG and closed back to USDG.
 *
 * The position's calls approve this adapter and call it; the adapter does the
 * swaps and the position-manager calls, then returns everything to the
 * position in the same call, holding nothing afterwards.
 *
 * Swaps go through `swapPool`, a WETH/USDG pool that may be another one (the
 * deepest). Every price the adapter acts on is checked against Chainlink
 * (WethUsdgVenue): the pool's price before it adds or removes liquidity, and
 * the average price of each swap.
 *
 * `params` = abi.encode(Action action, bytes data):
 * - `In`: data = abi.encode(uint256 amount, uint256 swapAmount, int24 tickLower, int24 tickUpper).
 *   Takes `amount` USDG, swaps `swapAmount` of it to WETH, and adds both as
 *   liquidity: a new position in [tickLower, tickUpper], or more liquidity in
 *   the position's existing one (its range; the ticks are then ignored).
 *   What is not used goes back to the position.
 * - `Out`: the whole position back to USDG (data unused).
 * - `Harvest`: the position's fees, as USDG (data unused).
 * A harvest job may only plan `Harvest`, and `Harvest` only a harvest job.
 * `exitPlan` takes a fraction of the position's liquidity, all its fees, and
 * the same fraction of any WETH the position holds, back to USDG. In a full
 * exit through `exitPlan` (the owner's full withdrawal), a price check that
 * fails (a stale feed, or the pool's price away from Chainlink) does not stop
 * the exit: the WETH goes back to the position unsold (`unsold`), valued at
 * Chainlink's last price.
 *
 * The adapter records the NFT it minted for each position and acts only on
 * that one; other NFTs sent to the position are ignored.
 */
contract UniswapV3LpAdapter is IPositionAdapter, WethUsdgVenue {
    enum Action {
        In,
        Out,
        Harvest
    }

    IUniswapV3PoolLp public immutable pool;
    INonfungiblePositionManager public immutable positionManager;
    ISwapPool public immutable swapPool;
    bool public immutable wethIsToken0;
    bool public immutable swapWethIsToken0;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
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

    constructor(
        IUniswapV3PoolLp pool_,
        INonfungiblePositionManager positionManager_,
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
        address t0 = pool_.token0();
        address t1 = pool_.token1();
        if (!((t0 == weth_ && t1 == usdg_) || (t0 == usdg_ && t1 == weth_))) revert WrongPool();
        address s0 = swapPool_.token0();
        address s1 = swapPool_.token1();
        if (!((s0 == weth_ && s1 == usdg_) || (s0 == usdg_ && s1 == weth_))) revert WrongPool();
        pool = pool_;
        positionManager = positionManager_;
        swapPool = swapPool_;
        wethIsToken0 = t0 == weth_;
        swapWethIsToken0 = s0 == weth_;
        fee = pool_.fee();
        tickSpacing = pool_.tickSpacing();
        minWidth = minWidth_;
        maxWidth = maxWidth_;
    }

    // ── Plans (run from the position) ───────────────────────────────────

    function plan(address position, bool harvest, bytes calldata params) external view returns (Call[] memory calls) {
        (Action action, bytes memory data) = abi.decode(params, (Action, bytes));
        if (harvest != (action == Action.Harvest)) revert WrongKind();
        if (action == Action.In) {
            (uint256 amount, uint256 swapAmount, int24 tickLower, int24 tickUpper) = abi.decode(data, (uint256, uint256, int24, int24));
            if (amount == 0 || swapAmount > amount) revert NothingToDo();
            calls = new Call[](3);
            calls[0] = Call(usdg, 0, abi.encodeCall(IERC20.approve, (address(this), amount)));
            calls[1] = Call(address(this), 0, abi.encodeCall(this.enter, (amount, swapAmount, tickLower, tickUpper)));
            calls[2] = Call(usdg, 0, abi.encodeCall(IERC20.approve, (address(this), 0)));
        } else if (action == Action.Out) {
            calls = _exitCalls(position, WHOLE, false);
        } else {
            uint256 tokenId = _tokenOf(position);
            calls = new Call[](3);
            calls[0] = Call(address(positionManager), 0, abi.encodeCall(INonfungiblePositionManager.approve, (address(this), tokenId)));
            calls[1] = Call(address(this), 0, abi.encodeCall(this.harvestFor, (tokenId)));
            calls[2] = Call(address(positionManager), 0, abi.encodeCall(INonfungiblePositionManager.approve, (address(0), tokenId)));
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
        calls[0] = Call(address(positionManager), 0, abi.encodeCall(INonfungiblePositionManager.approve, (address(this), tokenId)));
        calls[1] = Call(weth, 0, abi.encodeCall(IERC20.approve, (address(this), wethHeld)));
        calls[2] = Call(address(this), 0, abi.encodeCall(this.exitFor, (tokenId, fraction, wethHeld, byOwner)));
        calls[3] = Call(weth, 0, abi.encodeCall(IERC20.approve, (address(this), 0)));
        if (!whole) calls[4] = Call(address(positionManager), 0, abi.encodeCall(INonfungiblePositionManager.approve, (address(0), tokenId)));
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
        if (swapAmount > 0) _swap(false, swapAmount, oracle);
        // Our own swap moved the pool: the liquidity goes in at a price that is still fair.
        _checkSpot(oracle);

        uint256 wethIn = IERC20(weth).balanceOf(address(this));
        uint256 usdgIn = IERC20(usdg).balanceOf(address(this));
        IERC20(weth).approve(address(positionManager), wethIn);
        IERC20(usdg).approve(address(positionManager), usdgIn);
        (uint256 a0, uint256 a1) = wethIsToken0 ? (wethIn, usdgIn) : (usdgIn, wethIn);
        uint256 tokenId = _held(position);
        if (tokenId != 0) {
            positionManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(tokenId, a0, a1, 0, 0, block.timestamp)
            );
        } else {
            int24 width = tickUpper - tickLower;
            if (tickLower % tickSpacing != 0 || tickUpper % tickSpacing != 0 || width < minWidth || width > maxWidth) revert BadRange();
            (tokenId,,,) = positionManager.mint(
                INonfungiblePositionManager.MintParams(
                    pool.token0(), pool.token1(), fee, tickLower, tickUpper, a0, a1, 0, 0, position, block.timestamp
                )
            );
            tokenOf[position] = tokenId;
        }
        IERC20(weth).approve(address(positionManager), 0);
        IERC20(usdg).approve(address(positionManager), 0);
        _returnAll(position);
    }

    /// @notice Takes `fraction` of the caller's liquidity, all its fees and `wethHeld` of its WETH back to USDG.
    /// `byOwner` marks the owner's withdrawal: in a full one, WETH that cannot be sold at a checked price goes
    /// back to the position unsold.
    function exitFor(uint256 tokenId, uint256 fraction, uint256 wethHeld, bool byOwner) external nonReentrant {
        address position = msg.sender;
        if (tokenId == 0 || _held(position) != tokenId) revert NotOwnerOfPosition();
        bool inKind = byOwner && fraction >= WHOLE;
        (uint256 oracle, bool sell) = _exitPrice(inKind);
        (,,,,,,, uint128 liquidity,,,,) = positionManager.positions(tokenId);
        uint128 out = fraction >= WHOLE ? liquidity : uint128((uint256(liquidity) * fraction) / WHOLE);
        if (out > 0) {
            positionManager.decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams(tokenId, out, 0, 0, block.timestamp));
        }
        positionManager.collect(INonfungiblePositionManager.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max));
        if (fraction >= WHOLE) {
            positionManager.burn(tokenId);
            delete tokenOf[position];
        }
        if (wethHeld > 0) IERC20(weth).transferFrom(position, address(this), wethHeld);
        uint256 wethOut = IERC20(weth).balanceOf(address(this));
        if (!sell) _keepUnsold(position, 0, weth, oracle, 1e30);
        else if (inKind) _sellWethOrKeep(position, 0, oracle);
        else if (wethOut > 0) _swap(true, wethOut, oracle);
        _returnAll(position);
    }

    /// The Chainlink price, and whether WETH may be sold: in the owner's full withdrawal (`inKind`) a failed
    /// check means no sale; otherwise it reverts.
    function _exitPrice(bool inKind) internal view returns (uint256 oracle, bool sell) {
        if (!inKind) {
            oracle = _oraclePrice();
            _checkSpot(oracle);
            return (oracle, true);
        }
        bool fresh;
        (oracle, fresh) = _tryOraclePrice();
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        sell = fresh && _isWithin(_spotPrice(sqrtPriceX96, wethIsToken0), oracle);
    }

    /// @notice Collects the caller's fees and returns them as USDG.
    function harvestFor(uint256 tokenId) external nonReentrant {
        address position = msg.sender;
        if (tokenId == 0 || _held(position) != tokenId) revert NotOwnerOfPosition();
        uint256 oracle = _oraclePrice();
        positionManager.collect(INonfungiblePositionManager.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max));
        uint256 wethOut = IERC20(weth).balanceOf(address(this));
        if (wethOut > 0) _swap(true, wethOut, oracle);
        _returnAll(position);
    }

    function _isPool(address p) internal view override returns (bool) {
        return p == address(swapPool);
    }

    function _checkSpot(uint256 oracle) internal view {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        _within(_spotPrice(sqrtPriceX96, wethIsToken0), oracle);
    }

    function _swap(bool wethIn, uint256 amountIn, uint256 oracle) internal {
        _swapWethUsdg(swapPool, swapWethIsToken0, wethIn, amountIn, oracle);
    }

    function _sellAllWeth(uint256 oracle) internal override {
        uint256 amount = IERC20(weth).balanceOf(address(this));
        if (amount > 0) _swap(true, amount, oracle);
    }

    function _returnAll(address position) internal {
        _return(weth, position);
        _return(usdg, position);
    }
}
