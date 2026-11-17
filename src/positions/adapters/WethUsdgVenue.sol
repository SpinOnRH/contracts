// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC20} from "../../interfaces/IERC20.sol";
import {AdminWithdrawable} from "../../utils/Withdrawable.sol";

/// The swap of a Uniswap V3 pool, and of pools built like one (UP's concentrated pools).
interface ISwapPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

/**
 * @title WethUsdgVenue
 * @notice What the WETH/USDG liquidity venues share: the Chainlink price of ETH
 * in USDG (ETH/USD over USDG/USD), the check of a pool's price against it, and
 * swaps whose average price is checked against it. A price outside
 * `maxDeviationBps` of Chainlink, or a feed older than `maxFeedAge`, reverts.
 *
 * The admin (the deploying address, until it sets another) can withdraw any ETH or ERC-20
 * tokens sent to this contract, to the treasury it sets (`setTreasury`) only.
 */
abstract contract WethUsdgVenue is AdminWithdrawable {
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    uint256 internal constant WHOLE = 1e18;

    address public immutable weth;
    address public immutable usdg;
    IAggregatorV3 public immutable ethUsd;
    IAggregatorV3 public immutable usdgUsd;
    uint16 public immutable maxDeviationBps;
    uint32 public immutable maxFeedAge;

    uint256 private _locked = 1;

    error NotPool();
    error PriceOff();
    error StaleFeed();
    error Reentrant();
    error NotSelf();

    /// Returned to the position unsold, in the owner's full withdrawal, because it could not be sold at a checked price.
    event SentInKind(address indexed position, address indexed token, uint256 amount);

    /// Transient slots of `unsold`: an amount per token index, and their total value at this index.
    uint256 internal constant UNSOLD_VALUE = 3;
    bytes32 private constant UNSOLD_SEED = keccak256("WethUsdgVenue.unsold");

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrant();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address weth_, address usdg_, IAggregatorV3 ethUsd_, IAggregatorV3 usdgUsd_, uint16 maxDeviationBps_, uint32 maxFeedAge_) {
        weth = weth_;
        usdg = usdg_;
        ethUsd = ethUsd_;
        usdgUsd = usdgUsd_;
        maxDeviationBps = maxDeviationBps_;
        maxFeedAge = maxFeedAge_;
    }

    /// True for the pools this venue swaps in.
    function _isPool(address pool) internal view virtual returns (bool);

    /// Swaps all the WETH here for USDG in the venue's WETH/USDG pool, at a checked price.
    function _sellAllWeth(uint256 oracle) internal virtual;

    /// @notice Sells all the WETH here, checked as every sale is. Only this adapter calls it, in an owner's
    /// full exit, so that a sale that fails its check is undone alone.
    function sellWethHere(uint256 oracle) external {
        if (msg.sender != address(this)) revert NotSelf();
        _sellAllWeth(oracle);
    }

    /// In an owner's full exit: sells the WETH here if the sale passes its check, else keeps it unsold (index `i`).
    function _sellWethOrKeep(address position, uint256 i, uint256 oracle) internal {
        if (IERC20(weth).balanceOf(address(this)) > 0) try this.sellWethHere(oracle) {} catch {}
        _keepUnsold(position, i, weth, oracle, 1e30);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (!_isPool(msg.sender)) revert NotPool();
        if (amount0Delta > 0) IERC20(ISwapPool(msg.sender).token0()).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(ISwapPool(msg.sender).token1()).transfer(msg.sender, uint256(amount1Delta));
    }

    /// USDG per ETH, 18 decimals, from Chainlink.
    function _oraclePrice() internal view returns (uint256 price) {
        bool fresh;
        (price, fresh) = _tryOraclePrice();
        if (!fresh) revert StaleFeed();
    }

    /// The Chainlink price (the last one, however old; 0 if a feed has none or cannot be read), and whether
    /// both feeds are fresh.
    function _tryOraclePrice() internal view returns (uint256, bool) {
        return _feedPrice(ethUsd, maxFeedAge);
    }

    /// `feed` over the USDG/USD feed, 18 decimals, and whether both are fresh (`feed` within `maxAge`, USDG
    /// within `maxFeedAge`). A feed that reverts, or has no positive answer, reads as 0 and not fresh, so
    /// that the owner's full withdrawal still goes through.
    function _feedPrice(IAggregatorV3 feed, uint256 maxAge) internal view returns (uint256, bool) {
        (int256 tok, uint256 tokAt, uint8 tokDecimals, bool tokOk) = _readFeed(feed);
        (int256 usd, uint256 usdAt, uint8 usdDecimals, bool usdOk) = _readFeed(usdgUsd);
        if (!tokOk || !usdOk || tok <= 0 || usd <= 0) return (0, false);
        uint256 price = Math.mulDiv(uint256(tok), 1e18 * 10 ** usdDecimals, uint256(usd) * 10 ** tokDecimals);
        return (price, block.timestamp - tokAt <= maxAge && block.timestamp - usdAt <= maxFeedAge);
    }

    function _readFeed(IAggregatorV3 feed) internal view returns (int256 answer, uint256 updatedAt, uint8 decimals, bool ok) {
        try feed.latestRoundData() returns (uint80, int256 a, uint256, uint256 at, uint80) {
            (answer, updatedAt) = (a, at);
        } catch {
            return (0, 0, 0, false);
        }
        try feed.decimals() returns (uint8 d) {
            return (answer, updatedAt, d, updatedAt <= block.timestamp);
        } catch {
            return (0, 0, 0, false);
        }
    }

    /// USDG per ETH, 18 decimals, at a WETH/USDG pool's price.
    function _spotPrice(uint160 sqrtPriceX96, bool wethIsToken0) internal pure returns (uint256) {
        // token1 per token0 in base units, times 2^96.
        uint256 priceX96 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        // USDG has 6 decimals and WETH 18: 1e12 turns base units into whole tokens.
        if (wethIsToken0) return Math.mulDiv(priceX96, 1e30, 1 << 96);
        return Math.mulDiv(1 << 96, 1e30, priceX96);
    }

    function _within(uint256 price, uint256 oracle) internal view {
        if (!_isWithin(price, oracle)) revert PriceOff();
    }

    function _isWithin(uint256 price, uint256 oracle) internal view returns (bool) {
        uint256 band = (oracle * maxDeviationBps) / 10_000;
        return price + band >= oracle && price <= oracle + band;
    }

    /// Swaps all of `amountIn` WETH (`wethIn`) or USDG in a WETH/USDG `pool`, and checks its average price.
    function _swapWethUsdg(ISwapPool pool, bool wethIsToken0, bool wethIn, uint256 amountIn, uint256 oracle) internal {
        uint256 out = _swap(pool, wethIn == wethIsToken0, amountIn);
        // The average price, USDG per ETH with 18 decimals; it must sit in the band, on the side that hurts us.
        uint256 price = wethIn ? Math.mulDiv(out, 1e30, amountIn) : Math.mulDiv(amountIn, 1e30, out);
        uint256 band = (oracle * maxDeviationBps) / 10_000;
        if (wethIn ? price + band < oracle : price > oracle + band) revert PriceOff();
    }

    /// Swaps all of `amountIn`, token0 for token1 if `zeroForOne`; returns what came out.
    function _swap(ISwapPool pool, bool zeroForOne, uint256 amountIn) internal returns (uint256 out) {
        (int256 d0, int256 d1) = pool.swap(
            address(this), zeroForOne, int256(amountIn), zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1, ""
        );
        out = uint256(-(zeroForOne ? d1 : d0));
    }

    /// Records this contract's balance of `token` as unsold for `position`, at index `i`, worth `price`
    /// (USDG per whole token, 18 decimals) over `scale` each base unit. It goes back to the position with the rest.
    function _keepUnsold(address position, uint256 i, address token, uint256 price, uint256 scale) internal {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) return;
        _tstore(position, i, amount);
        _tstore(position, UNSOLD_VALUE, _tload(position, UNSOLD_VALUE) + Math.mulDiv(amount, price, scale));
        emit SentInKind(position, token, amount);
    }

    /// What this transaction's full exit of `position` left unsold, for its `tokens` (by index).
    function _unsold(address position, address[] memory tokens)
        internal
        view
        returns (address[] memory, uint256[] memory amounts, uint256 value)
    {
        amounts = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; i++) amounts[i] = _tload(position, i);
        return (tokens, amounts, _tload(position, UNSOLD_VALUE));
    }

    function _tstore(address position, uint256 i, uint256 v) private {
        bytes32 slot = keccak256(abi.encode(UNSOLD_SEED, position, i));
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }

    function _tload(address position, uint256 i) private view returns (uint256 v) {
        bytes32 slot = keccak256(abi.encode(UNSOLD_SEED, position, i));
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }

    /// Sends this contract's balance of `token` to `to`.
    function _return(address token, address to) internal {
        uint256 b = IERC20(token).balanceOf(address(this));
        if (b > 0) IERC20(token).transfer(to, b);
    }
}
