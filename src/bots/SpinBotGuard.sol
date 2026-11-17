// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVenueAdapter} from "./IVenueAdapter.sol";
import {Withdrawable} from "../utils/Withdrawable.sol";

interface IERC6551Account {
    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);
}

interface IERC6551Executable {
    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory);
}

interface IERC6551Registry {
    function account(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        view
        returns (address);
}

interface ISpinners {
    function ownerOf(uint256 tokenId) external view returns (address);
    function isActive(uint256 tokenId) external view returns (bool);
}

/**
 * @title SpinBotGuard
 * @notice Executes trades for a Spinners token-bound account (ERC-6551) through
 * approved venue adapters.
 *
 * The NFT owner enables it per account: `setPermissions([guard], [true])` on the
 * account, then `configure` with an ETH limit per trade, an ETH limit per day
 * and an expiry. Both are keyed by the current owner. Revoking either disables it.
 * The Spinner must also be active (`Spinners.isActive`); a transfer deactivates it.
 *
 * For each trade the guard runs the adapter's calls from the account, measures
 * the ETH that leaves the account against the owner's limits (fee and gas
 * refund included), rejects calls to the account or to the guard, sends the
 * fee (at most 100% of the trade's ETH) to the treasury, and refunds the calling
 * operator's gas from the account. Limits and fees are measured in ETH.
 * Zero limits stop every trade that does not bring ETH in: sells still run.
 *
 * The guard also measures the trade's token (`IVenueAdapter.Route`). Tokens a
 * trade brings in are credited to the account for that route; tokens can leave
 * through a route only as far as its credit goes, unless the route is open (a
 * launchpad's own curve or pool). So a sell goes through the pools its tokens
 * were bought in. If such a pool can no longer take a sale, the NFT owner can
 * move the credit to another route (`moveCredit`).
 * The admin can withdraw any ETH or ERC-20 tokens sent to the guard itself, to the treasury only.
 *
 * The gas refund is the gas the trade used, plus `gasOverhead` for the parts
 * a contract cannot measure, at the transaction's gas price capped at
 * `maxGasPrice`, plus any parent-chain data fee, and never more than
 * `maxGasRefund`. On buys it counts against the owner's limits. A trade whose
 * account cannot pay its fee and refund reverts. In a `tradeMany`, a trade
 * that reverts still pays its own gas when it can (`FailedTradeCharged`).
 */
contract SpinBotGuard is Withdrawable {
    struct Limits {
        uint128 maxTradeWei;
        uint128 maxDailyWei;
        uint64 expiresAt;
    }

    struct Spend {
        uint64 day;
        uint192 spentWei;
    }

    /// The fee is a share of the trade's ETH: at most all of it, so that a sale can always pay it.
    uint16 public constant MAX_FEE_BPS = 10_000;
    /// Gas a failed trade's charge adds in a `tradeMany`: its TradeFailed event, the charge call and its event.
    uint256 public constant FAILED_TRADE_GAS = 15_000;
    /// The most of a failed trade's revert data that `TradeFailed` carries.
    uint256 public constant MAX_REASON_BYTES = 256;
    /// ArbGasInfo: the current transaction's parent-chain data fee, on Arbitrum chains.
    address internal constant ARB_GAS_INFO = 0x000000000000000000000000000000000000006C;

    IERC6551Registry public immutable registry;
    /// The ERC-6551 implementation spinner accounts are created with (salt 0).
    address public immutable accountImplementation;
    /// The spinner NFT collection (the admin can change it: `setCollection`).
    address public collection;

    address public admin;
    address public treasury;
    uint16 public feeBps;
    /// Gas per trade outside the measured part: the transaction's base cost and calldata, the limit update and the refund transfer.
    uint32 public gasOverhead;
    /// The same for each trade of a `tradeMany`: its share of the transaction's base cost, its own calldata and call, the limit update and its refund.
    uint32 public batchGasOverhead;
    /// The highest gas price a refund pays.
    uint256 public maxGasPrice;
    /// The most one trade refunds, in wei.
    uint256 public maxGasRefund;
    /// The most gas one trade of a `tradeMany` may use, so that one bad trade cannot use up the batch's gas.
    uint256 public tradeGasLimit = 10_000_000;
    bool public paused;
    mapping(address => bool) public isOperator;
    mapping(address => bool) public isVenue;

    /// account => NFT owner who set them => limits.
    mapping(address => mapping(address => Limits)) public limits;
    mapping(address => Spend) public spend;
    /// account => token => route id => tokens the account may still sell through that route.
    mapping(address => mapping(address => mapping(bytes32 => uint256))) public credit;

    uint256 private _locked = 1;

    event Configured(address indexed account, address indexed owner, Limits limits);
    event Traded(address indexed account, address indexed venue, int256 ethDelta, uint256 fee, uint256 gasRefund);
    event VenueAdded(address indexed venue);
    event VenueRemoved(address indexed venue);
    event OperatorSet(address indexed operator, bool enabled);
    event AdminSet(address admin);
    event TreasurySet(address treasury);
    event CollectionSet(address collection);
    event FeeSet(uint16 feeBps);
    event PausedSet(bool paused);
    event GasOverheadSet(uint32 gasOverhead, uint32 batchGasOverhead);
    event TradeFailed(address indexed account, uint256 index, bytes reason);
    event FailedTradeCharged(address indexed account, uint256 gasRefund);

    struct Trade {
        address account;
        IVenueAdapter venue;
        bytes params;
    }
    event GasCapsSet(uint256 maxGasPrice, uint256 maxGasRefund);
    event TradeGasLimitSet(uint256 tradeGasLimit);
    event CreditMoved(address indexed account, address indexed token, bytes32 from, bytes32 to, uint256 amount);

    error NotAdmin();
    error ZeroCollection();
    error NotOperator();
    error NotOwner();
    error NotSpinBot();
    error NotEnabled();
    error NotActive();
    error NotVenue();
    error ForbiddenTarget();
    error Paused();
    error OverTradeLimit();
    error OverDailyLimit();
    error FeeTooHigh();
    error NotSelf();
    error CannotPayGas();
    error Reentrant();
    error NoCredit();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// Operator calls: not paused, one at a time.
    modifier operatorCall() {
        if (!isOperator[msg.sender]) revert NotOperator();
        if (paused) revert Paused();
        if (_locked != 1) revert Reentrant();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(
        IERC6551Registry registry_,
        address accountImplementation_,
        address collection_,
        address admin_,
        address treasury_,
        uint16 feeBps_,
        uint256 maxGasPrice_,
        uint256 maxGasRefund_,
        uint32 gasOverhead_,
        uint32 batchGasOverhead_
    ) {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        registry = registry_;
        accountImplementation = accountImplementation_;
        collection = collection_;
        admin = admin_;
        treasury = treasury_;
        feeBps = feeBps_;
        maxGasPrice = maxGasPrice_;
        maxGasRefund = maxGasRefund_;
        gasOverhead = gasOverhead_;
        batchGasOverhead = batchGasOverhead_;
    }

    // ── Owner ───────────────────────────────────────────────────────────

    /// @notice Sets the bot's caps. Called by the NFT owner. A past expiry switches it off; zero caps
    /// stop buys and launches, and sells still run.
    function configure(address account, Limits calldata l) external {
        (address owner,) = _spinner(account);
        if (owner != msg.sender) revert NotOwner();
        limits[account][msg.sender] = l;
        emit Configured(account, msg.sender, l);
    }

    /// @notice Moves `amount` of the account's credit for `token` from route `from` to route `to`, so the bot
    /// can sell those tokens through `to`. Called by the NFT owner.
    function moveCredit(address account, address token, bytes32 from, bytes32 to, uint256 amount) external {
        (address owner,) = _spinner(account);
        if (owner != msg.sender) revert NotOwner();
        uint256 left = credit[account][token][from];
        if (amount > left) revert NoCredit();
        credit[account][token][from] = left - amount;
        credit[account][token][to] += amount;
        emit CreditMoved(account, token, from, to, amount);
    }

    // ── Operator ────────────────────────────────────────────────────────

    /// @notice One trade on `venue`, for `account`. `params` is the venue's own encoding.
    /// @return ethDelta The change in the account's ETH before the fee and gas refund (negative = spent).
    function trade(address account, IVenueAdapter venue, bytes calldata params)
        external
        operatorCall
        returns (int256 ethDelta)
    {
        uint256 gasAtStart = gasleft();
        return _trade(account, venue, params, msg.sender, gasAtStart, gasOverhead, _parentChainFee());
    }

    /// @notice Several trades in one transaction, for different accounts. Each runs on its own: one that
    /// reverts is skipped (`TradeFailed`, with its reason) and the others go through. Each account refunds
    /// its own trade's gas, plus `batchGasOverhead` and its share of the parent-chain fee. A trade that
    /// reverts still pays its own gas, as a failed transaction would (`FailedTradeCharged`), within the
    /// owner's limits and if the account can pay; otherwise that charge is skipped.
    /// @return ok Which trades went through.
    function tradeMany(Trade[] calldata trades) external operatorCall returns (bool[] memory ok) {
        ok = new bool[](trades.length);
        uint256 feeShare = trades.length == 0 ? 0 : _parentChainFee() / trades.length;
        // A batch of one bears the whole transaction's fixed cost alone, as a single trade does.
        uint256 overhead = trades.length == 1 ? gasOverhead : batchGasOverhead;
        for (uint256 i = 0; i < trades.length; i++) {
            Trade calldata t = trades[i];
            uint256 gasBefore = gasleft();
            bytes memory reason;
            (ok[i], reason) = _callSelf(
                abi.encodeCall(this.tradeFor, (t.account, t.venue, t.params, msg.sender, feeShare, overhead)), tradeGasLimit
            );
            if (!ok[i]) {
                emit TradeFailed(t.account, i, reason);
                // Measured in this frame: an inner call sees less gas left (63/64), so it cannot measure the failed call itself.
                try this.chargeFor(t.account, gasBefore - gasleft(), msg.sender, feeShare, overhead + FAILED_TRADE_GAS) {} catch {}
            }
        }
    }

    /// @notice A failed trade's gas, charged to its account (`tradeMany`). Only the guard itself calls it.
    function chargeFor(address account, uint256 gasUsed, address operator, uint256 parentFeeShare, uint256 overhead) external {
        uint256 gasAtStart = gasleft() + gasUsed;
        if (msg.sender != address(this)) revert NotSelf();
        Limits memory l = _enabledLimits(account);
        uint256 refund = _gasRefund(gasAtStart, overhead, parentFeeShare);
        _charge(account, l, refund);
        if (account.balance < refund) revert CannotPayGas();
        _exec(account, operator, refund, "");
        emit FailedTradeCharged(account, refund);
    }

    /// @notice One trade of a `tradeMany`. Only the guard itself calls it, so that each trade reverts alone.
    function tradeFor(
        address account,
        IVenueAdapter venue,
        bytes calldata params,
        address operator,
        uint256 parentFeeShare,
        uint256 overhead
    ) external returns (int256 ethDelta) {
        uint256 gasAtStart = gasleft();
        if (msg.sender != address(this)) revert NotSelf();
        return _trade(account, venue, params, operator, gasAtStart, overhead, parentFeeShare);
    }

    function _trade(
        address account,
        IVenueAdapter venue,
        bytes calldata params,
        address operator,
        uint256 gasAtStart,
        uint256 overhead,
        uint256 parentFee
    ) internal returns (int256 ethDelta) {
        Limits memory l = _enabledLimits(account);
        if (!isVenue[address(venue)]) revert NotVenue();
        (IVenueAdapter.Call[] memory calls, IVenueAdapter.Route memory route) = venue.plan(account, params);

        uint256 tokensBefore = _tokenBalance(route.token, account);
        uint256 before = account.balance;
        for (uint256 i = 0; i < calls.length; i++) {
            IVenueAdapter.Call memory c = calls[i];
            if (c.target == account || c.target == address(this)) revert ForbiddenTarget();
            _exec(account, c.target, c.value, c.data);
        }
        uint256 afterTrade = account.balance;
        if ((l.maxTradeWei == 0 || l.maxDailyWei == 0) && afterTrade <= before) revert NotEnabled();
        _settleTokens(account, route, tokensBefore);

        uint256 spent = afterTrade < before ? before - afterTrade : 0;
        uint256 fee = ((spent > 0 ? spent : afterTrade - before) * feeBps) / 10_000;
        if (afterTrade < fee) revert CannotPayGas();
        if (fee > 0) _exec(account, treasury, fee, "");
        // Measured after the fee transfer, so the overhead covers only what follows and the transaction's base cost.
        uint256 refund = _gasRefund(gasAtStart, overhead, parentFee);
        // Buys count against the owner's limits; a sell always goes through, so an exit is never stuck on a limit.
        if (spent > 0) _charge(account, l, spent + fee + refund);
        if (account.balance < refund) revert CannotPayGas();
        if (refund > 0) _exec(account, operator, refund, "");
        ethDelta = int256(afterTrade) - int256(before);
        emit Traded(account, address(venue), ethDelta, fee, refund);
    }

    // ── Venues ──────────────────────────────────────────────────────────

    function addVenue(address venue) external onlyAdmin {
        isVenue[venue] = true;
        emit VenueAdded(venue);
    }

    function removeVenue(address venue) external onlyAdmin {
        isVenue[venue] = false;
        emit VenueRemoved(venue);
    }

    // ── Admin ───────────────────────────────────────────────────────────

    function setOperator(address operator, bool enabled) external onlyAdmin {
        isOperator[operator] = enabled;
        emit OperatorSet(operator, enabled);
    }

    function setPaused(bool p) external onlyAdmin {
        paused = p;
        emit PausedSet(p);
    }

    function setFee(uint16 feeBps_) external onlyAdmin {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeSet(feeBps_);
    }

    /// @notice Sets the Spinner collection whose accounts the guard trades for. Accounts of the
    /// previous collection stop trading at once; their settings stay unused.
    function setCollection(address collection_) external onlyAdmin {
        if (collection_ == address(0)) revert ZeroCollection();
        collection = collection_;
        emit CollectionSet(collection_);
    }

    function setTreasury(address treasury_) external onlyAdmin {
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setGasCaps(uint256 maxGasPrice_, uint256 maxGasRefund_) external onlyAdmin {
        maxGasPrice = maxGasPrice_;
        maxGasRefund = maxGasRefund_;
        emit GasCapsSet(maxGasPrice_, maxGasRefund_);
    }

    function setGasOverhead(uint32 gasOverhead_, uint32 batchGasOverhead_) external onlyAdmin {
        gasOverhead = gasOverhead_;
        batchGasOverhead = batchGasOverhead_;
        emit GasOverheadSet(gasOverhead_, batchGasOverhead_);
    }

    function setTradeGasLimit(uint256 tradeGasLimit_) external onlyAdmin {
        tradeGasLimit = tradeGasLimit_;
        emit TradeGasLimitSet(tradeGasLimit_);
    }

    function setAdmin(address admin_) external onlyAdmin {
        admin = admin_;
        emit AdminSet(admin_);
    }

    function _authorizeWithdraw(address) internal view override {
        if (msg.sender != admin) revert NotAdmin();
    }

    /// Withdrawals go to the treasury that takes the fees.
    function _withdrawTo() internal view override returns (address payable) {
        return payable(treasury);
    }

    // ── Internal ────────────────────────────────────────────────────────

    /// The NFT owner of a genuine spinner account; reverts for any other address.
    /// The Spinner behind `account`: its holder and token id.
    function _spinner(address account) internal view returns (address owner, uint256 tokenId) {
        if (account.code.length == 0) revert NotSpinBot();
        uint256 chainId;
        address tokenContract;
        (chainId, tokenContract, tokenId) = IERC6551Account(account).token();
        // `token()` is the account's claim; the registry address check makes it true.
        if (chainId != block.chainid || tokenContract != collection) revert NotSpinBot();
        if (registry.account(accountImplementation, bytes32(0), chainId, tokenContract, tokenId) != account) {
            revert NotSpinBot();
        }
        owner = ISpinners(collection).ownerOf(tokenId);
    }

    /// The limits the current NFT owner set, if the bot is on.
    function _enabledLimits(address account) internal view returns (Limits memory l) {
        (address owner, uint256 tokenId) = _spinner(account);
        if (!ISpinners(collection).isActive(tokenId)) revert NotActive();
        l = limits[account][owner];
        if (block.timestamp >= l.expiresAt) revert NotEnabled();
    }

    /// The operator's gas so far plus `overhead`, at the capped gas price, plus `parentFee`; at most `maxGasRefund`.
    function _gasRefund(uint256 gasAtStart, uint256 overhead, uint256 parentFee) internal view returns (uint256 refund) {
        uint256 price = tx.gasprice < maxGasPrice ? tx.gasprice : maxGasPrice;
        refund = (gasAtStart - gasleft() + overhead) * price + parentFee;
        if (refund > maxGasRefund) refund = maxGasRefund;
    }

    /// The parent-chain data fee of this transaction on an Arbitrum chain; zero elsewhere. The call's gas is capped:
    /// where the precompile is not native, its address holds an invalid opcode, which uses all the gas it is given.
    function _parentChainFee() internal view returns (uint256) {
        (bool ok, bytes memory data) =
            ARB_GAS_INFO.staticcall{gas: 30_000}(abi.encodeWithSignature("getCurrentTxL1GasFees()"));
        return ok && data.length == 32 ? abi.decode(data, (uint256)) : 0;
    }

    /// Counts ETH that left the account (fee and gas refund included) against the caps.
    function _charge(address account, Limits memory l, uint256 outWei) internal {
        if (outWei > l.maxTradeWei) revert OverTradeLimit();
        uint64 today = uint64(block.timestamp / 1 days);
        Spend memory s = spend[account];
        uint256 spent = (s.day == today ? s.spentWei : 0) + outWei;
        if (spent > l.maxDailyWei) revert OverDailyLimit();
        spend[account] = Spend(today, uint192(spent));
    }

    /// Calls this contract with at most `gasLimit` gas; returns whether it went through and at most
    /// MAX_REASON_BYTES of its revert data (a longer one would cost the batch its memory).
    function _callSelf(bytes memory data, uint256 gasLimit) internal returns (bool ok, bytes memory reason) {
        uint256 max = MAX_REASON_BYTES;
        assembly ("memory-safe") {
            ok := call(gasLimit, address(), 0, add(data, 32), mload(data), 0, 0)
            let n := returndatasize()
            if gt(n, max) { n := max }
            reason := mload(0x40)
            mstore(reason, n)
            returndatacopy(add(reason, 32), 0, n)
            mstore(0x40, add(add(reason, 32), and(add(n, 31), not(31))))
        }
        if (ok) reason = "";
    }

    /// Credits the tokens that came in to the route, or takes the tokens that left from its credit.
    function _settleTokens(address account, IVenueAdapter.Route memory route, uint256 tokensBefore) internal {
        if (route.token == address(0)) return;
        uint256 tokensAfter = _tokenBalance(route.token, account);
        if (tokensAfter > tokensBefore) {
            credit[account][route.token][route.id] += tokensAfter - tokensBefore;
        } else if (tokensAfter < tokensBefore && !route.open) {
            uint256 used = tokensBefore - tokensAfter;
            uint256 left = credit[account][route.token][route.id];
            if (used > left) revert NoCredit();
            credit[account][route.token][route.id] = left - used;
        }
    }

    /// `account`'s balance of `token`; zero for no token, or a token that is not deployed yet (a launch's).
    function _tokenBalance(address token, address account) internal view returns (uint256) {
        if (token == address(0) || token.code.length == 0) return 0;
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        return ok && data.length >= 32 ? abi.decode(data, (uint256)) : 0;
    }

    function _exec(address account, address to, uint256 value, bytes memory data) internal {
        IERC6551Executable(account).execute(to, value, data, 0);
    }
}
