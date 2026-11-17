// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {AdminWithdrawable} from "../utils/Withdrawable.sol";
import {IPonsFactory} from "./adapters/PonsAdapter.sol";

interface ITorchCreatorRouter {
    function acceptCreator(address token) external;
    function claim(address token) external;
    function claimTokens(address token) external;
}

interface ITorchCreatorFactory {
    function quoteOf(address token) external view returns (address);
    function setMetadata(address token, string calldata uri) external;
}

interface IPonsCreatorFactory {
    function memeHook() external view returns (address);
}

interface IPonsCreatorCurve {
    function sweepFees(uint256 minBuybackTokensOut) external;
}

interface IPonsCreatorHook {
    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
}

interface IPonsCreatorEscrow {
    function claim() external returns (uint256);
    function claimToken(address token) external returns (uint256);
    function balanceOf(address recipient) external view returns (uint256);
    function balanceOfToken(address recipient, address token) external view returns (uint256);
}

/**
 * @title SpinnerCreatorVault
 * @notice Holds the creator role of the tokens a Spinner's account launches on Pons and Torch, and
 * pays their creator fees to that account only. Each account's vault is a beacon proxy made by
 * SpinnerCreatorVaults, which names this implementation (its admin sets a new one to add a
 * launchpad). The launchpads' addresses are this implementation's own. A later implementation
 * keeps `account` as its first storage slot (inheriting this contract does).
 *
 * This implementation has no function that hands the creator role or the fee recipient to another
 * address. Anyone can claim a token's creator fees through it: what arrives is paid on at once, the
 * protocol's fee (`SpinnerCreatorVaults.feeOf`) to the protocol's treasury and the rest to the
 * account. The account is a Spinner's token-bound account, so the fees go to whoever holds the
 * Spinner. Only the account can change a Torch token's links (its metadata).
 */
contract SpinnerCreatorVault is Initializable {
    using SafeERC20 for IERC20;

    SpinnerCreatorVaults public immutable vaults;
    ITorchCreatorRouter public immutable torchRouter;
    ITorchCreatorFactory public immutable torchFactory;
    IPonsFactory public immutable ponsFactory;
    IPonsCreatorEscrow public immutable ponsEscrow;

    /// The Spinner's token-bound account: every claim is paid to it. The first storage slot, in every implementation.
    address public account;

    event Paid(address indexed token, uint256 amount, uint256 fee);

    error NotAccount();

    constructor(
        SpinnerCreatorVaults vaults_,
        ITorchCreatorRouter torchRouter_,
        ITorchCreatorFactory torchFactory_,
        IPonsFactory ponsFactory_,
        IPonsCreatorEscrow ponsEscrow_
    ) {
        vaults = vaults_;
        torchRouter = torchRouter_;
        torchFactory = torchFactory_;
        ponsFactory = ponsFactory_;
        ponsEscrow = ponsEscrow_;
        _disableInitializers();
    }

    /// @notice Sets the vault's account, once, as SpinnerCreatorVaults deploys it.
    function initialize(address account_) external initializer {
        account = account_;
    }

    receive() external payable {}

    // ── Torch ───────────────────────────────────────────────────────────

    /// @notice Takes the creator role of `token`, once its creator has proposed this vault (`transferCreator`).
    function acceptTorch(address token) external {
        torchRouter.acceptCreator(token);
    }

    /// @notice Claims `token`'s creator fees (in its quote: ETH or the pair token) and pays them on.
    function claimTorch(address token) external {
        torchRouter.claim(token);
        _pay(torchFactory.quoteOf(token));
    }

    /// @notice Takes `token`'s unconverted creator share in kind and pays it on.
    function claimTorchTokens(address token) external {
        torchRouter.claimTokens(token);
        _pay(token);
    }

    /// @notice Sets a Torch token's metadata (its links). Only the account.
    function setTorchMetadata(address token, string calldata uri) external {
        if (msg.sender != account) revert NotAccount();
        torchFactory.setMetadata(token, uri);
    }

    // ── Pons ────────────────────────────────────────────────────────────

    /// The factory's phase of a token in its own V4 pool.
    uint8 private constant PONS_GRADUATED = 2;

    /// @notice Moves `token`'s creator fees from its curve (or, once graduated, its pool) to Pons'
    /// escrow, for this vault; Pons' own operator does this too. A sweep Pons refuses (one that would
    /// need its operator's swap) is left to that operator: nothing reverts.
    function sweepPons(address token) external {
        IPonsFactory factory = ponsFactory;
        IPonsFactory.LaunchedToken memory t = factory.getLaunchedToken(token);
        if (!t.exists || t.creatorFeeRecipient != address(this)) return;
        if (t.phase == PONS_GRADUATED) {
            address hook = IPonsCreatorFactory(address(factory)).memeHook();
            (address c0, address c1) = t.pairToken < token ? (t.pairToken, token) : (token, t.pairToken);
            bytes32 poolId = keccak256(abi.encode(c0, c1, t.poolFee, t.tickSpacing, hook));
            try IPonsCreatorHook(hook).sweepPoolFees(poolId, 0, 0) {} catch {}
        } else if (t.curve != address(0)) {
            try IPonsCreatorCurve(t.curve).sweepFees(0) {} catch {}
        }
    }

    /// @notice Claims the ETH creator fees Pons holds for this vault and pays them on.
    function claimPons() external {
        IPonsCreatorEscrow escrow = ponsEscrow;
        if (escrow.balanceOf(address(this)) != 0) escrow.claim();
        _pay(address(0));
    }

    /// @notice Claims the creator fees Pons holds for this vault in the ERC-20 `token` (a pair token) and pays them on.
    function claimPonsToken(address token) external {
        IPonsCreatorEscrow escrow = ponsEscrow;
        if (escrow.balanceOfToken(address(this), token) != 0) escrow.claimToken(token);
        _pay(token);
    }

    // ── Paying on ───────────────────────────────────────────────────────

    /// @notice Pays on everything this vault holds of `token` (zero: ETH), as a claim does.
    function pay(address token) external {
        _pay(token);
    }

    function _pay(address token) internal {
        uint256 amount = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        if (amount == 0) return;
        (uint256 feeBps, address treasury) = vaults.feeOf();
        uint256 fee = (amount * feeBps) / 10_000;
        if (token == address(0)) {
            if (fee != 0) _sendEth(treasury, fee);
            _sendEth(account, amount - fee);
        } else {
            if (fee != 0) IERC20(token).safeTransfer(treasury, fee);
            IERC20(token).safeTransfer(account, amount - fee);
        }
        emit Paid(token, amount, fee);
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert SpinnerCreatorVaults.PaymentFailed();
    }
}

/**
 * @title SpinnerCreatorVaults
 * @notice Makes each Spinner account's SpinnerCreatorVault, a beacon proxy at a fixed address
 * (CREATE2, salted with the account), and is their beacon: every vault runs the implementation set
 * here. It also holds the protocol's fee on creator fees and the treasury it goes to. Anyone can
 * deploy an account's vault, once an implementation is set.
 *
 * The admin (the deploying address, until it sets another) sets the implementation, the fee and the
 * treasury, and can withdraw any ETH or ERC-20 tokens sent to this contract, to the treasury only.
 */
contract SpinnerCreatorVaults is AdminWithdrawable, IBeacon, IERC1967 {
    /// The code every vault runs.
    address public implementation;
    /// The protocol's share of each creator fee a vault pays on, in basis points.
    uint16 public feeBps;

    event VaultDeployed(address indexed account, address vault);
    event FeeSet(uint16 feeBps);

    error BadFee();
    error BadImplementation();
    error PaymentFailed();

    constructor(address payable treasury_, uint16 feeBps_) {
        if (feeBps_ > 10_000) revert BadFee();
        treasury = treasury_;
        feeBps = feeBps_;
        emit TreasurySet(treasury_);
        emit FeeSet(feeBps_);
    }

    /// @notice Sets the code every vault runs, from their next call: a SpinnerCreatorVault made for this contract.
    function setImplementation(address implementation_) external {
        if (msg.sender != admin) revert NotAdmin();
        if (implementation_.code.length == 0) revert BadImplementation();
        try SpinnerCreatorVault(payable(implementation_)).vaults() returns (SpinnerCreatorVaults v) {
            if (address(v) != address(this)) revert BadImplementation();
        } catch {
            revert BadImplementation();
        }
        implementation = implementation_;
        emit Upgraded(implementation_);
    }

    function setFee(uint16 feeBps_) external {
        if (msg.sender != admin) revert NotAdmin();
        if (feeBps_ > 10_000) revert BadFee();
        feeBps = feeBps_;
        emit FeeSet(feeBps_);
    }

    /// @notice The fee a vault takes, and where it goes; no fee while no treasury is set.
    function feeOf() external view returns (uint256 bps, address to) {
        if (treasury == address(0)) return (0, address(0));
        return (feeBps, treasury);
    }

    /// @notice `account`'s vault, deployed or not.
    function vaultOf(address account) public view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(address(this), _init(account))));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(account), hash)))));
    }

    /// @notice Deploys `account`'s vault, if it is not yet; returns it.
    function deploy(address account) external returns (address vault) {
        vault = vaultOf(account);
        if (vault.code.length != 0) return vault;
        new BeaconProxy{salt: _salt(account)}(address(this), _init(account));
        emit VaultDeployed(account, vault);
    }

    function _init(address account) internal pure returns (bytes memory) {
        return abi.encodeCall(SpinnerCreatorVault.initialize, (account));
    }

    function _salt(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }
}
