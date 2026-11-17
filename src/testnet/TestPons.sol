// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @notice A token launched by TestPonsFactory; the whole supply starts in its curve. Burnable, like Pons V2 tokens.
contract TestPonsToken is ERC20Burnable {
    constructor(string memory name_, string memory symbol_, address curve, uint256 supply) ERC20(name_, symbol_) {
        _mint(curve, supply);
    }
}

/**
 * @title TestPonsCurve
 * @notice A constant-product bonding curve with virtual reserves and a 1% fee,
 * paired with native ETH, for test networks. Same interface and events as a
 * Pons V2 curve.
 */
contract TestPonsCurve {
    uint256 public constant FEE_BPS = 100;

    TestPonsToken public immutable token;
    uint256 private quoteReserve;
    uint256 private tokenReserve;

    event CurveBuy(address indexed buyer, address indexed recipient, uint256 quoteIn, uint256 tokensOut, uint256 fee, uint256 tax);
    event CurveSell(address indexed seller, address indexed recipient, uint256 tokensIn, uint256 quoteOut, uint256 fee, uint256 tax);

    error WrongValue();
    error Slippage();
    error PayoutFailed();

    constructor(string memory name_, string memory symbol_, uint256 supply, uint256 virtualQuote) {
        token = new TestPonsToken(name_, symbol_, address(this), supply);
        quoteReserve = virtualQuote;
        tokenReserve = supply;
    }

    function getReserves() external view returns (uint256, uint256) {
        return (quoteReserve, tokenReserve);
    }

    /// @notice Buys with `quoteIn` ETH (sent as value); the fee is taken from it.
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut) {
        if (msg.value != quoteIn) revert WrongValue();
        uint256 fee = (quoteIn * FEE_BPS) / 10_000;
        uint256 net = quoteIn - fee;
        tokensOut = (tokenReserve * net) / (quoteReserve + net);
        if (tokensOut < minTokensOut) revert Slippage();
        quoteReserve += net;
        tokenReserve -= tokensOut;
        token.transfer(recipient, tokensOut);
        emit CurveBuy(msg.sender, recipient, quoteIn, tokensOut, fee, 0);
    }

    /// @notice Sells `tokensIn` (approved to this curve); the fee is taken from the payout.
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256 quoteOut) {
        uint256 gross = (quoteReserve * tokensIn) / (tokenReserve + tokensIn);
        uint256 fee = (gross * FEE_BPS) / 10_000;
        quoteOut = gross - fee;
        if (quoteOut < minQuoteOut) revert Slippage();
        quoteReserve -= gross;
        tokenReserve += tokensIn;
        token.transferFrom(msg.sender, address(this), tokensIn);
        (bool ok,) = recipient.call{value: quoteOut}("");
        if (!ok) revert PayoutFailed();
        emit CurveSell(msg.sender, recipient, tokensIn, quoteOut, fee, 0);
    }
}

/**
 * @title TestPonsFactory
 * @notice Launches TestPonsCurve tokens, for test networks. Same launch event
 * and `getLaunchedToken` as the Pons V2 factory. Tokens never graduate.
 */
contract TestPonsFactory {
    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant VIRTUAL_QUOTE = 1.5 ether;

    mapping(address => LaunchedToken) private launched;

    event TokenLaunched(
        address indexed token,
        address indexed curve,
        address indexed deployer,
        address pairToken,
        uint256 launchConfigId,
        uint256 graduationThreshold
    );

    /// @notice Launches a token; ETH sent with the call buys from the new curve for the caller.
    function launch(string calldata name, string calldata symbol) external payable returns (address token, address curve) {
        TestPonsCurve c = new TestPonsCurve(name, symbol, SUPPLY, VIRTUAL_QUOTE);
        curve = address(c);
        token = address(c.token());
        launched[token] = LaunchedToken(
            token, curve, msg.sender, msg.sender, address(0), type(uint256).max, 0, 0, 0, false, 0, 0, 0, 0, true
        );
        emit TokenLaunched(token, curve, msg.sender, address(0), 0, type(uint256).max);
        if (msg.value > 0) c.buy{value: msg.value}(msg.value, 0, msg.sender);
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory) {
        return launched[token];
    }
}
