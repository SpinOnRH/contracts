// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// Every contract the USDG positions deploy fits the limit on deployed code (EIP-170), as built
/// for the deploy (the artifacts script/positions.ts reads). Forge's own tests do not enforce it.
contract CodeSizeTest is Test {
    uint256 constant LIMIT = 24_576;

    function test_everyDeployedContractFits() public view {
        string[10] memory contracts = [
            "SpinPositions.sol:SpinPositions",
            "SpinPosition.sol:SpinPosition",
            "MorphoVaultAdapter.sol:MorphoVaultAdapter",
            "UniswapV3LpAdapter.sol:UniswapV3LpAdapter",
            "UniswapV4LpAdapter.sol:UniswapV4LpAdapter",
            "UpGaugeAdapter.sol:UpGaugeAdapter",
            "UpFeedGaugeAdapter.sol:UpFeedGaugeAdapter",
            "UpStableGaugeAdapter.sol:UpStableGaugeAdapter",
            "SpinBotGuard.sol:SpinBotGuard",
            "Spinners.sol:Spinners"
        ];
        for (uint256 i; i < contracts.length; i++) {
            uint256 size = vm.getDeployedCode(contracts[i]).length;
            assertLe(size, LIMIT, contracts[i]);
        }
    }
}
