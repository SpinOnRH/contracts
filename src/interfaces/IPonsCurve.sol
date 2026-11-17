// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Pons V2 bonding curve trade surface (docs.ponsfamily.com/v2).
/// For a native-quote launch, `buy` takes the quote as msg.value; for a
/// custom-pair launch the curve pulls the quote ERC-20 via allowance.
interface IPonsCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient)
        external
        payable
        returns (uint256 tokensOut);

    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient)
        external
        returns (uint256 quoteOut);
}
