// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC20} from "../../interfaces/IERC20.sol";
import {IPositionAdapter} from "../IPositionAdapter.sol";
import {TickPrice} from "./TickPrice.sol";
import {WethUsdgVenue, ISwapPool, IAggregatorV3} from "./WethUsdgVenue.sol";

interface IUpClPool is ISwapPool {
    function tickSpacing() external view returns (int24);
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, bool);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

interface IUpPositionManager {
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
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
            int24 tickSpacing,
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

interface IUpGauge {
    function deposit(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
    function getReward(uint256 tokenId) external;
    function earned(address account, uint256 tokenId) external view returns (uint256);
    function stakedValues(address depositor) external view returns (uint256[] memory);
    function stakedLength(address depositor) external view returns (uint256);
}

/**
 * @title UpGaugeVenue
 * @notice What the UP gauge venues share: one UP concentrated pool of USDG and
 * one other token (`other`), and its gauge. The position holds a single
 * position (an NFT of UP's position manager), staked in the gauge for UP
 * emissions (a staked position's swap fees go to UP's voters); the emissions
 * are sold for USDG.
 *
 * The position's calls approve this adapter and call it, and call the gauge
 * themselves (the gauge stakes for its caller). The adapter does the swaps and
 * the position-manager calls, then returns everything to the position in the
 * same call, holding nothing afterwards.
 *
 * Each venue sets how the pool's price is checked and how `other` is bought
 * and sold. UP has no Chainlink feed, so a sale of UP is checked against its
 * own pool (UP/WETH): the pool's tick must be within `maxUpTickDeviation` of
 * its average over `twapWindow`, before and after the sale. The WETH from it
 * is sold in `swapPool` (WETH/USDG), at an average price checked against
 * Chainlink.
 *
 * The adapter records the NFT it minted for each position and acts only on
 * that one (or on what the position itself staked); other NFTs sent to the
 * position are ignored.
 *
 * `params` = abi.encode(Action action, bytes data):
 * - `In` (manage): data = abi.encode(uint256 amount, uint256 swapAmount, int24 tickLower, int24 tickUpper).
 *   Takes `amount` USDG, swaps `swapAmount` of it to `other` and adds both as
 *   liquidity: a new position in [tickLower, tickUpper] (staked by a `Stake`
 *   job after it), or more liquidity in the existing one (unstaked, increased
 *   and staked again in the same job). Rewards claimed on the way are kept as
 *   UP and sold by the next harvest.
 * - `Out` (manage): everything back to USDG, rewards included (data unused).
 * - `Harvest` (harvest): the rewards, sold for USDG (data unused).
 * - `Stake` (harvest): stakes the position's unstaked NFT (data unused).
 * `exitPlan` takes a fraction of the liquidity, the same fraction of any
 * `other` the position holds, and all its rewards back to USDG; a range that
 * stays is staked again. In a full exit through `exitPlan` (the owner's full
 * withdrawal), a price check that fails does not stop the exit: what cannot
 * be sold at a checked price (`other`, UP or WETH) goes back to the position
 * unsold (`unsold`), valued at the last reference prices (UP at its pool's
 * average price over `twapWindow`).
 */
abstract contract UpGaugeVenue is IPositionAdapter, WethUsdgVenue {
    enum Action {
        In,
        Out,
        Harvest,
        Stake
    }

    struct Config {
        IUpClPool pool;
        IUpGauge gauge;
        IUpPositionManager positionManager;
        address weth;
        address usdg;
        address up;
        /// The UP/WETH pool UP is sold in.
        IUpClPool upPool;
        /// A WETH/USDG pool for the WETH from UP sales (and the swaps of a WETH venue).
        ISwapPool swapPool;
        IAggregatorV3 ethUsd;
        IAggregatorV3 usdgUsd;
        uint16 maxDeviationBps;
        uint32 maxFeedAge;
        int24 minWidth;
        int24 maxWidth;
        uint32 twapWindow;
        int24 maxUpTickDeviation;
    }

    IUpClPool public immutable pool;
    IUpGauge public immutable gauge;
    IUpPositionManager public immutable positionManager;
    address public immutable up;
    IUpClPool public immutable upPool;
    ISwapPool public immutable swapPool;
    /// The pool's token that is not USDG.
    address public immutable other;
    bool public immutable otherIsToken0;
    bool public immutable upIsToken0;
    bool public immutable swapWethIsToken0;
    int24 public immutable tickSpacing;
    int24 public immutable minWidth;
    int24 public immutable maxWidth;
    uint32 public immutable twapWindow;
    int24 public immutable maxUpTickDeviation;

    /// The NFT this adapter minted for each position (0: none).
    mapping(address position => uint256 tokenId) public tokenOf;

    error NotOwnerOfPosition();
    error WrongPool();
    error BadRange();
    error NothingToDo();
    error WrongKind();

    constructor(Config memory c) WethUsdgVenue(c.weth, c.usdg, c.ethUsd, c.usdgUsd, c.maxDeviationBps, c.maxFeedAge) {
        address t0 = c.pool.token0();
        address t1 = c.pool.token1();
        if (t0 != c.usdg && t1 != c.usdg) revert WrongPool();
        address u0 = c.upPool.token0();
        address u1 = c.upPool.token1();
        if (!((u0 == c.up && u1 == c.weth) || (u0 == c.weth && u1 == c.up))) revert WrongPool();
        address s0 = c.swapPool.token0();
        address s1 = c.swapPool.token1();
        if (!((s0 == c.weth && s1 == c.usdg) || (s0 == c.usdg && s1 == c.weth))) revert WrongPool();
        pool = c.pool;
        gauge = c.gauge;
        positionManager = c.positionManager;
        up = c.up;
        upPool = c.upPool;
        swapPool = c.swapPool;
        other = t0 == c.usdg ? t1 : t0;
        otherIsToken0 = t0 != c.usdg;
        upIsToken0 = u0 == c.up;
        swapWethIsToken0 = s0 == c.weth;
        tickSpacing = c.pool.tickSpacing();
        minWidth = c.minWidth;
        maxWidth = c.maxWidth;
        twapWindow = c.twapWindow;
        maxUpTickDeviation = c.maxUpTickDeviation;
    }

    // ── What each venue sets ────────────────────────────────────────────

    /// Reverts unless the pool's price can be acted on (`oracle`: the Chainlink ETH price).
    function _checkSpot(uint256 oracle) internal view virtual;

    /// Whether the pool's price can be acted on and `other` sold (`fresh`: whether `oracle` is).
    function _spotOk(uint256 oracle, bool fresh) internal view virtual returns (bool);

    /// Swaps `usdgIn` USDG to `other`, at a checked price.
    function _buyOther(uint256 usdgIn, uint256 oracle) internal virtual;

    /// Swaps `amount` of `other` to USDG, at a checked price. A venue may sell only part of it; the rest stays here.
    function _sellOther(uint256 amount, uint256 oracle) internal virtual;

    /// `other`'s last reference price, in USDG per whole token (18 decimals), and the scale of one base unit.
    function _otherPrice(uint256 oracle) internal view virtual returns (uint256 price, uint256 scale);

    // ── Plans (run from the position) ───────────────────────────────────

    function plan(address position, bool harvest, bytes calldata params) external view returns (Call[] memory calls) {
        (Action action, bytes memory data) = abi.decode(params, (Action, bytes));
        if (harvest != (action == Action.Harvest || action == Action.Stake)) revert WrongKind();
        if (action == Action.In) {
            (uint256 amount, uint256 swapAmount, int24 tickLower, int24 tickUpper) = abi.decode(data, (uint256, uint256, int24, int24));
            if (amount == 0 || swapAmount > amount) revert NothingToDo();
            bool staked = gauge.stakedLength(position) > 0;
            uint256 tokenId = staked ? gauge.stakedValues(position)[0] : 0;
            calls = new Call[](staked ? 6 : 3);
            uint256 n;
            if (staked) calls[n++] = Call(address(gauge), 0, abi.encodeCall(IUpGauge.withdraw, (tokenId)));
            calls[n++] = Call(usdg, 0, abi.encodeCall(IERC20.approve, (address(this), amount)));
            calls[n++] = Call(address(this), 0, abi.encodeCall(this.enter, (amount, swapAmount, tickLower, tickUpper)));
            calls[n++] = Call(usdg, 0, abi.encodeCall(IERC20.approve, (address(this), 0)));
            if (staked) {
                calls[n++] = Call(address(positionManager), 0, abi.encodeCall(IUpPositionManager.approve, (address(gauge), tokenId)));
                calls[n++] = Call(address(gauge), 0, abi.encodeCall(IUpGauge.deposit, (tokenId)));
            }
        } else if (action == Action.Out) {
            calls = _exitCalls(position, WHOLE, false);
        } else if (action == Action.Harvest) {
            uint256 tokenId = _stakedOf(position);
            uint256 amount = gauge.earned(position, tokenId) + IERC20(up).balanceOf(position);
            if (amount == 0) revert NothingToDo();
            calls = new Call[](4);
            calls[0] = Call(address(gauge), 0, abi.encodeCall(IUpGauge.getReward, (tokenId)));
            calls[1] = Call(up, 0, abi.encodeCall(IERC20.approve, (address(this), amount)));
            calls[2] = Call(address(this), 0, abi.encodeCall(this.sellRewards, (amount)));
            calls[3] = Call(up, 0, abi.encodeCall(IERC20.approve, (address(this), 0)));
        } else {
            uint256 tokenId = _tokenOf(position);
            calls = new Call[](2);
            calls[0] = Call(address(positionManager), 0, abi.encodeCall(IUpPositionManager.approve, (address(gauge), tokenId)));
            calls[1] = Call(address(gauge), 0, abi.encodeCall(IUpGauge.deposit, (tokenId)));
        }
    }

    function exitPlan(address position, uint256 fraction, bytes calldata) external view returns (Call[] memory) {
        return _exitCalls(position, fraction, true);
    }

    function holds(address position) external view returns (bool) {
        return gauge.stakedLength(position) > 0 || _held(position) != 0;
    }

    function unsold(address position) external view returns (address[] memory tokens, uint256[] memory, uint256) {
        tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (other, up, weth);
        return _unsold(position, tokens);
    }

    function _exitCalls(address position, uint256 fraction, bool byOwner) internal view returns (Call[] memory calls) {
        bool staked = gauge.stakedLength(position) > 0;
        uint256 tokenId;
        uint256 rewards = IERC20(up).balanceOf(position);
        if (staked) {
            tokenId = _stakedOf(position);
            rewards += gauge.earned(position, tokenId);
        } else {
            tokenId = _tokenOf(position);
        }
        uint256 otherHeld = (IERC20(other).balanceOf(position) * fraction) / WHOLE;
        bool whole = fraction >= WHOLE;
        calls = new Call[]((staked ? 1 : 0) + 6 + (whole ? 0 : (staked ? 2 : 1)));
        uint256 n;
        if (staked) calls[n++] = Call(address(gauge), 0, abi.encodeCall(IUpGauge.withdraw, (tokenId)));
        calls[n++] = Call(address(positionManager), 0, abi.encodeCall(IUpPositionManager.approve, (address(this), tokenId)));
        calls[n++] = Call(other, 0, abi.encodeCall(IERC20.approve, (address(this), otherHeld)));
        calls[n++] = Call(up, 0, abi.encodeCall(IERC20.approve, (address(this), rewards)));
        calls[n++] = Call(address(this), 0, abi.encodeCall(this.exitFor, (tokenId, fraction, otherHeld, rewards, byOwner)));
        calls[n++] = Call(other, 0, abi.encodeCall(IERC20.approve, (address(this), 0)));
        calls[n++] = Call(up, 0, abi.encodeCall(IERC20.approve, (address(this), 0)));
        // A whole exit burns the NFT, which clears its approval; a range that stays is staked again (or its approval cleared).
        if (!whole && staked) {
            calls[n++] = Call(address(positionManager), 0, abi.encodeCall(IUpPositionManager.approve, (address(gauge), tokenId)));
            calls[n++] = Call(address(gauge), 0, abi.encodeCall(IUpGauge.deposit, (tokenId)));
        } else if (!whole) {
            calls[n++] = Call(address(positionManager), 0, abi.encodeCall(IUpPositionManager.approve, (address(0), tokenId)));
        }
    }

    function _stakedOf(address position) internal view returns (uint256) {
        uint256[] memory staked = gauge.stakedValues(position);
        if (staked.length == 0) revert NothingToDo();
        return staked[0];
    }

    /// The NFT this adapter minted for `position`, while the position holds it unstaked (0 otherwise).
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

    /// @notice Takes `amount` USDG from the caller and adds it as liquidity for the caller (unstaked).
    function enter(uint256 amount, uint256 swapAmount, int24 tickLower, int24 tickUpper) external nonReentrant {
        address position = msg.sender;
        uint256 oracle = _oraclePrice();
        _checkSpot(oracle);
        IERC20(usdg).transferFrom(position, address(this), amount);
        if (swapAmount > 0) _buyOther(swapAmount, oracle);
        _checkSpot(oracle);

        uint256 otherIn = IERC20(other).balanceOf(address(this));
        uint256 usdgIn = IERC20(usdg).balanceOf(address(this));
        IERC20(other).approve(address(positionManager), otherIn);
        IERC20(usdg).approve(address(positionManager), usdgIn);
        (uint256 a0, uint256 a1) = otherIsToken0 ? (otherIn, usdgIn) : (usdgIn, otherIn);
        uint256 tokenId = _held(position);
        if (tokenId != 0) {
            positionManager.increaseLiquidity(IUpPositionManager.IncreaseLiquidityParams(tokenId, a0, a1, 0, 0, block.timestamp));
        } else {
            int24 width = tickUpper - tickLower;
            if (tickLower % tickSpacing != 0 || tickUpper % tickSpacing != 0 || width < minWidth || width > maxWidth) revert BadRange();
            (tokenId,,,) = positionManager.mint(
                IUpPositionManager.MintParams(
                    pool.token0(), pool.token1(), tickSpacing, tickLower, tickUpper, a0, a1, 0, 0, position, block.timestamp, 0
                )
            );
            tokenOf[position] = tokenId;
        }
        IERC20(other).approve(address(positionManager), 0);
        IERC20(usdg).approve(address(positionManager), 0);
        _returnAll(position);
    }

    /// @notice Takes `fraction` of the caller's liquidity, its fees, `otherHeld` of its `other` and `rewards`
    /// of its UP back to USDG. `byOwner` marks the owner's withdrawal: in a full one, what cannot be sold at a
    /// checked price goes back to the position unsold.
    function exitFor(uint256 tokenId, uint256 fraction, uint256 otherHeld, uint256 rewards, bool byOwner) external nonReentrant {
        address position = msg.sender;
        if (tokenId == 0 || _held(position) != tokenId) revert NotOwnerOfPosition();
        bool whole = fraction >= WHOLE;
        bool inKind = byOwner && whole;
        uint256 oracle;
        bool fresh = true;
        bool sellOther = true;
        if (inKind) {
            (oracle, fresh) = _tryOraclePrice();
            sellOther = _spotOk(oracle, fresh);
        } else {
            oracle = _oraclePrice();
            _checkSpot(oracle);
        }

        (,,,,,,, uint128 liquidity,,,,) = positionManager.positions(tokenId);
        uint128 out = whole ? liquidity : uint128((uint256(liquidity) * fraction) / WHOLE);
        if (out > 0) {
            positionManager.decreaseLiquidity(IUpPositionManager.DecreaseLiquidityParams(tokenId, out, 0, 0, block.timestamp));
        }
        positionManager.collect(IUpPositionManager.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max));
        if (whole) {
            positionManager.burn(tokenId);
            delete tokenOf[position];
        }
        if (otherHeld > 0) IERC20(other).transferFrom(position, address(this), otherHeld);
        if (rewards > 0) {
            IERC20(up).transferFrom(position, address(this), rewards);
            if (!inKind) _sellUp(rewards);
            // A sale that fails its check (or a pool with no average yet) leaves the UP here, unsold.
            else if (fresh) try this.sellUpHere(rewards) {} catch {}
        }
        if (sellOther) {
            uint256 otherOut = IERC20(other).balanceOf(address(this));
            // In the owner's full withdrawal a sale that fails its check leaves `other` here, unsold.
            if (otherOut > 0 && inKind) try this.sellOtherHere(otherOut, oracle) {} catch {}
            else if (otherOut > 0) _sellOther(otherOut, oracle);
        }
        if (fresh && other != weth) {
            if (inKind) try this.sellWethHere(oracle) {} catch {}
            else _sellWeth(oracle);
        }
        if (inKind) {
            // The owner's full withdrawal: what could not be sold at a checked price goes back unsold, valued.
            (uint256 otherPrice, uint256 otherScale) = _otherPrice(oracle);
            _keepUnsold(position, 0, other, otherPrice, otherScale);
            _keepUnsold(position, 1, up, _upPrice(oracle), 1e30);
            if (other != weth) _keepUnsold(position, 2, weth, oracle, 1e30);
        } else if (IERC20(other).balanceOf(address(this)) > 0) {
            revert PriceOff();
        }
        _returnAll(position);
    }

    /// @notice Sells `amount` of `other` here, checked as `_sellOther`. Only this adapter calls it, during an
    /// owner's full exit, so that a sale that fails its check is undone alone.
    function sellOtherHere(uint256 amount, uint256 oracle) external {
        if (msg.sender != address(this)) revert NotSelf();
        _sellOther(amount, oracle);
    }

    /// @notice Sells `amount` of the UP here, checked as `_sellUp`. Only this adapter calls it, during an
    /// owner's full exit, so that a sale that fails its check is undone alone.
    function sellUpHere(uint256 amount) external {
        if (msg.sender != address(this)) revert NotSelf();
        _sellUp(amount);
    }

    /// @notice Takes `amount` UP from the caller and returns it as USDG.
    function sellRewards(uint256 amount) external nonReentrant {
        address position = msg.sender;
        uint256 oracle = _oraclePrice();
        IERC20(up).transferFrom(position, address(this), amount);
        _sellUp(amount);
        _sellWeth(oracle);
        _returnAll(position);
    }

    // ── Prices and swaps ────────────────────────────────────────────────

    function _isPool(address p) internal view virtual override returns (bool) {
        return p == address(swapPool) || p == address(upPool);
    }

    /// Sells `amount` UP for WETH in its pool, within `maxUpTickDeviation` of the pool's average tick before and after.
    function _sellUp(uint256 amount) internal {
        int24 average = _averageTick();
        if (!_upTickOk(average)) revert PriceOff();
        _swap(upPool, upIsToken0, amount);
        if (!_upTickOk(average)) revert PriceOff();
    }

    function _sellAllWeth(uint256 oracle) internal override {
        _sellWeth(oracle);
    }

    /// Sells all WETH here for USDG in `swapPool`.
    function _sellWeth(uint256 oracle) internal {
        uint256 amount = IERC20(weth).balanceOf(address(this));
        if (amount > 0) _swapWethUsdg(swapPool, swapWethIsToken0, true, amount, oracle);
    }

    function _averageTick() internal view returns (int24) {
        (int56[] memory cumulatives,) = upPool.observe(_twapAgo());
        return _averageOf(cumulatives);
    }

    /// USDG per whole UP (18 decimals), at the UP pool's average price and `oracle` for ETH; 0 if the pool has no average.
    function _upPrice(uint256 oracle) internal view returns (uint256) {
        try upPool.observe(_twapAgo()) returns (int56[] memory cumulatives, uint160[] memory) {
            // WETH per UP, 18 decimals (both have 18): the tick's price is token1 per token0.
            uint256 p = TickPrice.at(_averageOf(cumulatives));
            return Math.mulDiv(upIsToken0 ? p : 1e36 / p, oracle, 1e18);
        } catch {
            return 0;
        }
    }

    function _twapAgo() internal view returns (uint32[] memory ago) {
        ago = new uint32[](2);
        ago[0] = twapWindow;
    }

    function _averageOf(int56[] memory cumulatives) internal view returns (int24) {
        int56 delta = cumulatives[1] - cumulatives[0];
        int56 average = delta / int56(uint56(twapWindow));
        // Round towards negative infinity, as Uniswap's oracle library does.
        if (delta < 0 && delta % int56(uint56(twapWindow)) != 0) average--;
        return int24(average);
    }

    function _upTickOk(int24 average) internal view returns (bool) {
        (, int24 tick,,,,) = upPool.slot0();
        int24 diff = tick > average ? tick - average : average - tick;
        return diff <= maxUpTickDeviation;
    }

    function _returnAll(address position) internal {
        _return(other, position);
        if (other != weth) _return(weth, position);
        _return(usdg, position);
        _return(up, position);
    }
}
