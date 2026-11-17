// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20 as OZIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC20} from "../interfaces/IERC20.sol";
import {IPositionAdapter} from "./IPositionAdapter.sol";
import {Withdrawable} from "../utils/Withdrawable.sol";

interface ISpinPositions {
    function collection() external view returns (address);
    function usdg() external view returns (address);
    function accountOf(uint256 tokenId) external view returns (address);
    function classOf(address adapter) external view returns (uint8);
    function feeBps() external view returns (uint16);
    function treasury() external view returns (address);
    function maxGasPrice() external view returns (uint256);
    function maxGasRefund() external view returns (uint256);
    function retire(uint256 tokenId) external;
    function positionOf(uint256 tokenId) external view returns (address);
}

interface ISpinnersView {
    function ownerOf(uint256 tokenId) external view returns (address);
    function isActive(uint256 tokenId) external view returns (bool);
}

/**
 * @title SpinPosition
 * @notice One Spinner's USDG position: a single balance, held in one listed
 * venue at a time, or idle. The owner is the Spinner's token-bound account.
 *
 * The owner sets the risk classes operators may use and an expiry
 * (`configure`). Operators, through the SpinPositions contract, put USDG into
 * a venue whose class is allowed,
 * take it out, and collect income (`harvest`). The position measures its own
 * USDG around every action:
 * - USDG out of the position is added to `deployed`.
 * - USDG back from a venue is a full exit: the venue must hold nothing for
 *   the position afterwards. What came back above `deployed` is a realised
 *   gain; what fell short is added to `lossCarry`.
 * - Harvested USDG is a realised gain. The adapter is told it is a harvest and
 *   plans only actions that collect income.
 * A realised gain first reduces `lossCarry`; the fee (`feeBps` of the rest)
 * goes to the treasury.
 *
 * The owner can withdraw all or part of the position at any time. A fraction
 * of everything in the venue is taken back to USDG through its adapter and
 * settled against the same fraction of `deployed`; the USDG it returned, less
 * the fee, and the same fraction of any idle USDG go to the owner. A full
 * withdrawal also sends the ETH float and closes the book: `lossCarry` is
 * cleared, as by an escape. In a full withdrawal, what the venue could not
 * sell at a checked price comes back unsold (`IPositionAdapter.unsold`) and
 * counts at its value: the fee is paid in USDG and, where the USDG is not
 * enough, in those tokens, and the rest of them go to the owner.
 *
 * If an exit cannot run, the owner can `requestEscape` and, after
 * ESCAPE_DELAY, make any call from the position. While an escape is
 * requested, operators can still take the balance out of its venue to USDG,
 * even when the owner has switched them off, and put nothing in. A request
 * from a venue needs a float of at least `maxGasRefund`, and the float stays
 * in the position until the escape is used, so that exit can pay its gas.
 * An escape retires the position: operators can no longer act on it, and the
 * Spinner's next position is a new one (SpinPositions). The owner keeps every
 * way out of a retired position.
 * The owner can also withdraw any ETH and any idle USDG at any time, and any
 * other ERC-20 token while the position is idle (`withdrawEth`, `withdrawToken`),
 * always to itself (the Spinner's wallet).
 *
 * Every action keeps the position's ETH (its gas float) at least where it
 * was, before the operator's gas refund. The refund follows the same rules as
 * SpinBotGuard: measured gas plus an overhead, at a capped gas price, plus any
 * parent-chain fee, never more than a cap. A job that reverts pays its gas the
 * same way (`chargeFailed`), while the position is enabled and its float can.
 */
contract SpinPosition is Withdrawable {
    enum Kind {
        Manage,
        Harvest
    }

    uint64 public constant ESCAPE_DELAY = 7 days;
    /// A whole position, as a fraction.
    uint256 public constant WHOLE = 1e18;

    ISpinPositions public factory;
    uint256 public tokenId;

    /// Bit n set: venues of risk class n are allowed (bit 0 is never set: class 0 means not listed).
    uint256 public allowedClasses;
    uint64 public expiresAt;
    /// The NFT owner who set the classes and expiry; a new owner must configure again.
    address public configuredBy;

    /// The adapter the balance is in; zero while idle.
    address public venue;
    /// USDG put into `venue` and not yet back.
    uint256 public deployed;
    /// Realised losses not yet won back.
    uint256 public lossCarry;
    /// When `escape` opens; zero if not requested.
    uint64 public escapeAt;
    /// Set by `escape`: operators can no longer act on this position.
    bool public retired;

    uint256 private _locked;

    event Configured(uint256 allowedClasses, uint64 expiresAt, address indexed by);
    event Entered(address indexed adapter, uint256 amount);
    event Exited(address indexed adapter, uint256 back, int256 result);
    event Harvested(address indexed adapter, uint256 amount);
    event FeePaid(uint256 amount);
    event FeePaidInKind(address indexed token, uint256 amount);
    event GasRefunded(address indexed operator, uint256 amount);
    event FailedJobCharged(address indexed operator, uint256 amount);
    event Withdrawn(uint256 fraction, uint256 usdg, uint256 eth);
    event EscapeRequested(uint64 at);
    event Escaped(address indexed target, uint256 value, bytes data);

    error AlreadyInitialized();
    error NotFactory();
    error NotOwner();
    error NotEnabled();
    error NotActive();
    error NotListed();
    error ClassNotAllowed();
    error OtherVenue();
    error NotVenue();
    error StillHeld();
    error UsdgSpent();
    error EthSpent();
    error ForbiddenTarget();
    error CannotPayGas();
    error EscapeNotOpen();
    error Reentrant();
    error BadClasses();
    error TransferFailed();
    error BadFraction();
    error NotIdle();
    error EscapePending();
    error FloatTooLow();
    error Retired();

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrant();
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner()) revert NotOwner();
        _;
    }

    /// @notice Called once by SpinPositions when it creates the clone.
    function initialize(uint256 tokenId_) external {
        if (address(factory) != address(0)) revert AlreadyInitialized();
        factory = ISpinPositions(msg.sender);
        tokenId = tokenId_;
        _locked = 1;
    }

    receive() external payable {}

    /// @notice Accepts position NFTs (LP positions) sent with `safeTransferFrom`.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @notice Accepts ERC-1155 position tokens.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    /// @notice The Spinner's token-bound account.
    function owner() public view returns (address) {
        return factory.accountOf(tokenId);
    }

    // ── Owner ───────────────────────────────────────────────────────────

    /// @notice Sets the risk classes operators may use (bit n for class n) and when their access ends.
    /// No classes or a past expiry switches operators off; the owner can still withdraw.
    function configure(uint256 allowedClasses_, uint64 expiresAt_) external onlyOwner {
        if (allowedClasses_ & 1 != 0) revert BadClasses();
        allowedClasses = allowedClasses_;
        expiresAt = expiresAt_;
        configuredBy = ISpinnersView(factory.collection()).ownerOf(tokenId);
        emit Configured(allowedClasses_, expiresAt_, configuredBy);
    }

    /// @notice Takes `fraction` (of WHOLE) of the position to the owner. The venue (if any) is exited by
    /// that fraction through its adapter, with the owner's limits in `params`, and the result is settled.
    function withdraw(address adapter, uint256 fraction, bytes calldata params) external onlyOwner nonReentrant {
        if (fraction == 0 || fraction > WHOLE) revert BadFraction();
        IERC20 usdg = IERC20(factory.usdg());
        uint256 idle = usdg.balanceOf(address(this));
        uint256 back;
        uint256 fee;
        if (venue != address(0)) {
            if (adapter != venue) revert NotVenue();
            uint256 ethBefore = address(this).balance;
            IPositionAdapter.Call[] memory calls = IPositionAdapter(adapter).exitPlan(address(this), fraction, params);
            _run(calls);
            if (address(this).balance < ethBefore) revert EthSpent();
            uint256 afterExit = usdg.balanceOf(address(this));
            back = afterExit > idle ? afterExit - idle : 0;
            if (fraction == WHOLE) {
                (address[] memory kept, uint256[] memory amounts, uint256 keptValue) =
                    IPositionAdapter(adapter).unsold(address(this));
                fee = _exit(adapter, back, keptValue, kept, amounts);
                for (uint256 i; i < kept.length; i++) {
                    if (amounts[i] > 0) SafeERC20.safeTransfer(OZIERC20(kept[i]), msg.sender, amounts[i]);
                }
            } else {
                uint256 cost = (deployed * fraction) / WHOLE;
                deployed -= cost;
                emit Exited(adapter, back, int256(back) - int256(cost));
                if (back >= cost) fee = _realise(back - cost);
                else lossCarry += cost - back;
            }
        }
        if (fraction == WHOLE) {
            lossCarry = 0;
            escapeAt = 0;
        }
        address to = msg.sender;
        uint256 usdgOut = fraction == WHOLE ? usdg.balanceOf(address(this)) : back - fee + (idle * fraction) / WHOLE;
        uint256 ethOut = fraction == WHOLE ? address(this).balance : 0;
        if (usdgOut > 0 && !usdg.transfer(to, usdgOut)) revert TransferFailed();
        if (ethOut > 0) {
            (bool ok,) = to.call{value: ethOut}("");
            if (!ok) revert TransferFailed();
        }
        emit Withdrawn(fraction, usdgOut, ethOut);
    }

    /// The owner, outside an action. USDG here is idle, so it leaves at any time; other ERC-20 tokens only
    /// while idle, so that a venue's tokens leave through `withdraw`.
    /// The holder's own funds: a withdrawal goes to the owner (the Spinner's wallet), never elsewhere.
    function _withdrawTo() internal view override returns (address payable) {
        return payable(owner());
    }

    function _authorizeWithdraw(address token) internal view override {
        if (msg.sender != owner()) revert NotOwner();
        if (_locked != 1) revert Reentrant();
        if (token != address(0) && token != factory.usdg() && venue != address(0)) revert NotIdle();
        // The float pays for the exit an escape request lets operators make.
        if (token == address(0) && escapeAt != 0 && venue != address(0)) revert EscapePending();
    }

    /// @notice Starts the escape delay. Until `escape`, operators can take the balance out of its venue to
    /// USDG and put nothing in, and the float stays here to pay for that exit.
    function requestEscape() external onlyOwner {
        if (venue != address(0) && address(this).balance < factory.maxGasRefund()) revert FloatTooLow();
        escapeAt = uint64(block.timestamp) + ESCAPE_DELAY;
        emit EscapeRequested(escapeAt);
    }

    /// @notice After the escape delay, any call from the position. It retires the position.
    function escape(address target, uint256 value, bytes calldata data) external onlyOwner nonReentrant returns (bytes memory) {
        if (escapeAt == 0 || block.timestamp < escapeAt) revert EscapeNotOpen();
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) _bubble(ret);
        // Funds that leave this way are not settled, so the book starts again from nothing.
        venue = address(0);
        deployed = 0;
        lossCarry = 0;
        escapeAt = 0;
        if (!retired) {
            retired = true;
            if (factory.positionOf(tokenId) == address(this)) factory.retire(tokenId);
        }
        emit Escaped(target, value, data);
        return ret;
    }

    // ── Operator (through SpinPositions) ───────────────────────────────

    /// @notice One operator action. Only SpinPositions calls it, after checking the operator.
    /// `Manage` puts USDG into `adapter` or takes it all out; `Harvest` collects income from the venue
    /// (or does upkeep that removes no principal, such as staking).
    function operate(Kind kind, address adapter, bytes calldata params, address operator, uint256 overhead, uint256 parentFee)
        external
        nonReentrant
    {
        uint256 gasAtStart = gasleft();
        if (msg.sender != address(factory)) revert NotFactory();
        if (retired) revert Retired();
        // While an escape is requested, an exit runs even when the owner has switched operators off.
        bool escaping = escapeAt != 0 && kind == Kind.Manage && venue != address(0);
        if (!escaping) _requireEnabled();

        // While the balance is in a venue, only that venue's adapter runs.
        if (venue != address(0) && adapter != venue) revert OtherVenue();
        if (kind == Kind.Harvest && venue == address(0)) revert NotVenue();

        IERC20 usdg = IERC20(factory.usdg());
        uint256 before = usdg.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        _execute(adapter, kind == Kind.Harvest, params);
        if (address(this).balance < ethBefore) revert EthSpent();
        uint256 afterAction = usdg.balanceOf(address(this));

        if (kind == Kind.Harvest) {
            // Income only: the adapter plans no other action for a harvest. Some (staking a new
            // range) bring in no USDG at all.
            if (afterAction < before) revert UsdgSpent();
            emit Harvested(adapter, afterAction - before);
            _realise(afterAction - before);
        } else if (afterAction < before) {
            if (escapeAt != 0) revert EscapePending();
            uint8 riskClass = factory.classOf(adapter);
            if (riskClass == 0) revert NotListed();
            if ((allowedClasses >> riskClass) & 1 == 0) revert ClassNotAllowed();
            venue = adapter;
            deployed += before - afterAction;
            emit Entered(adapter, before - afterAction);
        } else {
            if (venue == address(0)) revert NotVenue();
            _exit(adapter, afterAction - before, 0, new address[](0), new uint256[](0));
        }

        uint256 refund = _refund(gasAtStart - gasleft() + overhead, operator, parentFee);
        if (refund > 0) emit GasRefunded(operator, refund);
    }

    /// @notice A job of `kind` that reverted still pays its own gas, as a failed transaction would: measured
    /// by SpinPositions around the job, refunded to its operator under the same price and cap. Only
    /// SpinPositions calls it, only for a position its holder has enabled; it reverts (and the charge
    /// is skipped) when the float cannot pay.
    function chargeFailed(Kind kind, uint256 gasUsed, address operator, uint256 overhead, uint256 parentFee)
        external
        nonReentrant
    {
        if (msg.sender != address(factory)) revert NotFactory();
        if (retired) revert Retired();
        // While an escape is requested, only a failed exit pays its gas without the holder's switch:
        // the float waits for that exit.
        if (escapeAt == 0 || venue == address(0) || kind != Kind.Manage) _requireEnabled();
        uint256 refund = _refund(gasUsed + overhead, operator, parentFee);
        if (refund > 0) emit FailedJobCharged(operator, refund);
    }

    // ── Internal ────────────────────────────────────────────────────────

    /// Pays the operator for `gas` at the transaction's gas price (at most SpinPositions'
    /// `maxGasPrice`), plus `parentFee`, at most `maxGasRefund`, from the float.
    function _refund(uint256 gas, address operator, uint256 parentFee) internal returns (uint256 refund) {
        uint256 price = tx.gasprice < factory.maxGasPrice() ? tx.gasprice : factory.maxGasPrice();
        refund = gas * price + parentFee;
        uint256 cap = factory.maxGasRefund();
        if (refund > cap) refund = cap;
        if (refund == 0) return 0;
        if (address(this).balance < refund) revert CannotPayGas();
        (bool ok,) = operator.call{value: refund}("");
        if (!ok) revert TransferFailed();
    }

    function _requireEnabled() internal view {
        if (allowedClasses == 0 || block.timestamp >= expiresAt) revert NotEnabled();
        ISpinnersView spinners = ISpinnersView(factory.collection());
        if (spinners.ownerOf(tokenId) != configuredBy) revert NotEnabled();
        if (!spinners.isActive(tokenId)) revert NotActive();
    }

    /// A full exit of `adapter` that returned `back` USDG and, in the owner's withdrawal, `kept` tokens
    /// worth `keptValue` USDG unsold: settles both against `deployed`. The part of the fee that the USDG
    /// here cannot pay is taken from `amounts`, in proportion to their value.
    function _exit(address adapter, uint256 back, uint256 keptValue, address[] memory kept, uint256[] memory amounts)
        internal
        returns (uint256 fee)
    {
        if (IPositionAdapter(adapter).holds(address(this))) revert StillHeld();
        uint256 cost = deployed;
        deployed = 0;
        venue = address(0);
        uint256 total = back + keptValue;
        emit Exited(adapter, total, int256(total) - int256(cost));
        if (total < cost) {
            lossCarry += cost - total;
            return 0;
        }
        uint256 owed = _feeOn(total - cost);
        uint256 usdgHere = IERC20(factory.usdg()).balanceOf(address(this));
        fee = owed < usdgHere ? owed : usdgHere;
        _payFee(fee);
        // Only when the fee is more than the USDG here, so `keptValue` is not zero.
        uint256 rest = owed - fee;
        if (rest == 0) return fee;
        address treasury = factory.treasury();
        for (uint256 i; i < kept.length; i++) {
            uint256 part = (amounts[i] * rest) / keptValue;
            if (part == 0) continue;
            amounts[i] -= part;
            SafeERC20.safeTransfer(OZIERC20(kept[i]), treasury, part);
            emit FeePaidInKind(kept[i], part);
        }
    }

    /// A realised gain: it first reduces `lossCarry`; returns the fee on the rest.
    function _feeOn(uint256 gain) internal returns (uint256) {
        if (gain <= lossCarry) {
            lossCarry -= gain;
            return 0;
        }
        uint256 net = gain - lossCarry;
        lossCarry = 0;
        return (net * factory.feeBps()) / 10_000;
    }

    /// A realised gain in USDG: the fee on it is paid in USDG.
    function _realise(uint256 gain) internal returns (uint256 fee) {
        fee = _feeOn(gain);
        _payFee(fee);
    }

    function _payFee(uint256 fee) internal {
        if (fee == 0) return;
        if (!IERC20(factory.usdg()).transfer(factory.treasury(), fee)) revert TransferFailed();
        emit FeePaid(fee);
    }

    function _execute(address adapter, bool harvest, bytes calldata params) internal {
        _run(IPositionAdapter(adapter).plan(address(this), harvest, params));
    }

    function _run(IPositionAdapter.Call[] memory calls) internal {
        for (uint256 i = 0; i < calls.length; i++) {
            IPositionAdapter.Call memory c = calls[i];
            if (c.target == address(this) || c.target == address(factory)) revert ForbiddenTarget();
            (bool ok, bytes memory ret) = c.target.call{value: c.value}(c.data);
            if (!ok) _bubble(ret);
        }
    }

    function _bubble(bytes memory ret) internal pure {
        assembly {
            revert(add(ret, 32), mload(ret))
        }
    }
}
