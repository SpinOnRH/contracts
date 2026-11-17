// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVenueAdapter} from "../IVenueAdapter.sol";
import {Routes} from "../Routes.sol";
import {AdminWithdrawable} from "../../utils/Withdrawable.sol";
import {SpinnerCreatorVaults, SpinnerCreatorVault} from "../SpinnerCreatorVaults.sol";

interface ITorchLaunchFactory {
    struct PositionSpec {
        int24 tickLower;
        int24 tickUpper;
        uint16 supplyBps;
    }

    struct Split {
        uint16 creatorBps;
        uint16 burnBps;
        uint16 holdersBps;
        uint16 liquidityBps;
    }

    struct LaunchParams {
        string name;
        string symbol;
        string contractURI;
        uint256 supply;
        uint256 buyTaxBps;
        uint24 lpFee;
        int24 startingTick;
        int24 tickSpacing;
        PositionSpec[] positions;
        uint256 devBuyAmount;
        uint256 antiSnipeSeconds;
        Split split;
        bytes32 salt;
        address quote;
    }

    function launch(LaunchParams calldata p) external payable returns (address token);
    function initCodeHash(LaunchParams calldata p) external view returns (bytes32);
    function tokenDeployer() external view returns (address);
    function feeRouter() external view returns (address);
}

interface ITorchCreatorHandover {
    function transferCreator(address token, address to) external;
}

/**
 * @title TorchLaunchAdapter
 * @notice Launches a Torch token against native ETH from the account.
 *
 * params = abi.encode(ITorchLaunchFactory.LaunchParams)
 *
 * The account launches (the factory registers its caller as the creator) and receives the dev
 * buy's tokens; the call's value is `devBuyAmount`, as the factory requires. In the same trade the
 * account hands the creator role to its SpinnerCreatorVault (deployed first if it is not yet),
 * which pays the creator fees to the account only, so they stay with the Spinner. The factory checks
 * the liquidity shape, the tax and the salt. The route is the token's own V4 pool against native
 * ETH, as `Routes.uniswap` names it, for the token's address: CREATE2 in the factory's token
 * deployer, salted with keccak(creator, salt), from the factory's init code hash of the launch.
 *
 * The admin (the deploying address, until it sets another) can withdraw any ETH or ERC-20
 * tokens sent to this contract, to the treasury it sets (`setTreasury`) only.
 */
contract TorchLaunchAdapter is IVenueAdapter, AdminWithdrawable {
    ITorchLaunchFactory public immutable factory;
    SpinnerCreatorVaults public immutable vaults;

    error NotEthPaired();

    constructor(ITorchLaunchFactory factory_, SpinnerCreatorVaults vaults_) {
        factory = factory_;
        vaults = vaults_;
    }

    function plan(address account, bytes calldata params) external view returns (Call[] memory calls, Route memory route) {
        ITorchLaunchFactory.LaunchParams memory p = abi.decode(params, (ITorchLaunchFactory.LaunchParams));
        if (p.quote != address(0)) revert NotEthPaired();
        address token = tokenOf(account, p);
        address vault = vaults.vaultOf(account);
        calls = new Call[](4);
        calls[0] = Call(address(vaults), 0, abi.encodeCall(SpinnerCreatorVaults.deploy, (account)));
        calls[1] = Call(address(factory), p.devBuyAmount, abi.encodeCall(ITorchLaunchFactory.launch, (p)));
        calls[2] = Call(factory.feeRouter(), 0, abi.encodeCall(ITorchCreatorHandover.transferCreator, (token, vault)));
        calls[3] = Call(vault, 0, abi.encodeCall(SpinnerCreatorVault.acceptTorch, (token)));
        route = Route(token, Routes.uniswap(true, p.lpFee, p.tickSpacing, address(0), address(0), 0, 0, address(0)), false);
    }

    /// @notice The address `creator`'s launch with `p` deploys its token at.
    function tokenOf(address creator, ITorchLaunchFactory.LaunchParams memory p) public view returns (address) {
        bytes32 salt = p.salt;
        // The init code hash is of the launch without its salt.
        p.salt = bytes32(0);
        bytes32 initCodeHash = factory.initCodeHash(p);
        p.salt = salt;
        bytes32 salted = keccak256(abi.encode(creator, salt));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory.tokenDeployer(), salted, initCodeHash)))));
    }
}
