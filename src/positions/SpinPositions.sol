// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {SpinPosition} from "./SpinPosition.sol";
import {Withdrawable} from "../utils/Withdrawable.sol";

interface IERC6551RegistryView {
    function account(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        view
        returns (address);
}

/**
 * @title SpinPositions
 * @notice Creates one SpinPosition per Spinner and holds the settings they share:
 * the operators, the listed venues and their risk classes, the fee on realised
 * gains, the treasury and the gas refund caps.
 *
 * A position is a minimal clone of one implementation, at an address fixed by
 * the Spinner's token id and its generation. Its owner is the Spinner's
 * token-bound account (ERC-6551, salt 0). A position that escapes retires
 * itself, and the Spinner's next position is a new clone (the next
 * generation): calls made from a position during an escape (an approval, for
 * one) never reach the position a later holder uses. Operators act on positions only through `run`, which
 * checks the operator and the pause; each position checks everything else.
 * The admin can withdraw any ETH or ERC-20 tokens sent to this contract itself
 * (never a position's), to the treasury only.
 */
contract SpinPositions is Withdrawable {
    struct Job {
        uint256 tokenId;
        SpinPosition.Kind kind;
        address adapter;
        bytes params;
    }

    /// The fee is a share of each realised gain: at most all of it, so that it never takes the principal.
    uint16 public constant MAX_FEE_BPS = 10_000;
    /// Gas a failed job's charge adds: its JobFailed event, the charge call and its event.
    uint256 public constant FAILED_JOB_GAS = 15_000;
    /// ArbGasInfo: the current transaction's parent-chain data fee, on Arbitrum chains.
    address internal constant ARB_GAS_INFO = 0x000000000000000000000000000000000000006C;

    IERC6551RegistryView public immutable registry;
    /// The ERC-6551 implementation Spinner accounts are created with (salt 0).
    address public immutable accountImplementation;
    /// The Spinner NFT collection (the admin can change it: `setCollection`).
    address public collection;
    /// The position's balance token.
    address public immutable usdg;
    /// The SpinPosition every position is a clone of.
    address public immutable implementation;

    address public admin;
    address public treasury;
    uint16 public feeBps;
    bool public paused;
    uint256 public maxGasPrice;
    uint256 public maxGasRefund;
    /// Gas per job outside the part a position measures, for a run of one job and for each job of a longer run.
    uint32 public gasOverhead;
    uint32 public batchGasOverhead;
    mapping(address => bool) public isOperator;
    /// adapter => risk class (1 to 255); 0 = not listed. A position allows a set of classes.
    mapping(address => uint8) public classOf;
    /// tokenId => how many of its positions have retired; `positionOf` is the next one.
    mapping(uint256 => uint256) public generation;

    event PositionCreated(uint256 indexed tokenId, address position);
    event PositionRetired(uint256 indexed tokenId, address position, uint256 nextGeneration);
    event JobFailed(uint256 indexed tokenId, uint256 index, bytes reason);
    event VenueSet(address indexed adapter, uint8 riskClass);
    event OperatorSet(address indexed operator, bool enabled);
    event AdminSet(address admin);
    event TreasurySet(address treasury);
    event CollectionSet(address collection);
    event FeeSet(uint16 feeBps);
    event PausedSet(bool paused);
    event GasCapsSet(uint256 maxGasPrice, uint256 maxGasRefund);
    event GasOverheadSet(uint32 gasOverhead, uint32 batchGasOverhead);

    error NotAdmin();
    error ZeroCollection();
    error NotOperator();
    error Paused();
    error FeeTooHigh();
    error NotPosition();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(
        IERC6551RegistryView registry_,
        address accountImplementation_,
        address collection_,
        address usdg_,
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
        usdg = usdg_;
        implementation = address(new SpinPosition());
        admin = admin_;
        treasury = treasury_;
        feeBps = feeBps_;
        maxGasPrice = maxGasPrice_;
        maxGasRefund = maxGasRefund_;
        gasOverhead = gasOverhead_;
        batchGasOverhead = batchGasOverhead_;
    }

    // ── Positions ───────────────────────────────────────────────────────

    /// @notice Creates the Spinner's position. Anyone may call it; there is one per token id and generation.
    function create(uint256 tokenId) external returns (SpinPosition position) {
        position = SpinPosition(payable(Clones.cloneDeterministic(implementation, _salt(tokenId, generation[tokenId]))));
        position.initialize(tokenId);
        emit PositionCreated(tokenId, address(position));
    }

    /// @notice Called by the Spinner's position when it escapes: the Spinner's next position is a new one.
    function retire(uint256 tokenId) external {
        if (msg.sender != positionOf(tokenId)) revert NotPosition();
        uint256 next = ++generation[tokenId];
        emit PositionRetired(tokenId, msg.sender, next);
    }

    /// @notice The Spinner's position address, created or not.
    function positionOf(uint256 tokenId) public view returns (address) {
        return positionAt(tokenId, generation[tokenId]);
    }

    /// @notice The Spinner's position of generation `gen` (0 first), created or not; earlier ones are retired.
    function positionAt(uint256 tokenId, uint256 gen) public view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _salt(tokenId, gen));
    }

    /// @notice The Spinner's token-bound account: the owner of its position.
    function accountOf(uint256 tokenId) external view returns (address) {
        return registry.account(accountImplementation, bytes32(0), block.chainid, collection, tokenId);
    }

    // ── Operator ────────────────────────────────────────────────────────

    /// @notice Runs jobs on positions. Each runs on its own: one that reverts is skipped
    /// (`JobFailed`, with its reason) and the others go through. Each position refunds its own gas,
    /// a failed job's too (`SpinPosition.chargeFailed`) while the position is enabled and can pay.
    /// @return ok Which jobs went through.
    function run(Job[] calldata jobs) external returns (bool[] memory ok) {
        if (!isOperator[msg.sender]) revert NotOperator();
        if (paused) revert Paused();
        ok = new bool[](jobs.length);
        uint256 feeShare = jobs.length == 0 ? 0 : _parentChainFee() / jobs.length;
        uint256 overhead = jobs.length == 1 ? gasOverhead : batchGasOverhead;
        for (uint256 i = 0; i < jobs.length; i++) {
            Job calldata j = jobs[i];
            SpinPosition position = SpinPosition(payable(positionOf(j.tokenId)));
            // Not created yet (or retired a moment ago): nothing to run, and nothing to charge.
            if (address(position).code.length == 0) {
                emit JobFailed(j.tokenId, i, "");
                continue;
            }
            uint256 gasBefore = gasleft();
            try position.operate(j.kind, j.adapter, j.params, msg.sender, overhead, feeShare) {
                ok[i] = true;
            } catch (bytes memory reason) {
                emit JobFailed(j.tokenId, i, reason);
                // Measured in this frame: the position cannot measure a call of its own that reverted.
                try position.chargeFailed(j.kind, gasBefore - gasleft(), msg.sender, overhead + FAILED_JOB_GAS, feeShare) {} catch {}
            }
        }
    }

    // ── Admin ───────────────────────────────────────────────────────────

    /// @notice Lists a venue adapter in a risk class, or removes it (class 0). Positions already in a
    /// removed venue can still leave it.
    function setVenue(address adapter, uint8 riskClass) external onlyAdmin {
        classOf[adapter] = riskClass;
        emit VenueSet(adapter, riskClass);
    }

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

    /// @notice Sets the Spinner collection whose token ids the positions belong to. Positions made
    /// for the previous collection keep their accounts.
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

    /// The first generation's salt is the token id, as before generations; later ones hash it with the generation.
    function _salt(uint256 tokenId, uint256 gen) internal pure returns (bytes32) {
        return gen == 0 ? bytes32(tokenId) : keccak256(abi.encode(tokenId, gen));
    }

    /// The parent-chain data fee of this transaction on an Arbitrum chain; zero elsewhere. The call's gas is capped:
    /// where the precompile is not native, its address holds an invalid opcode, which uses all the gas it is given.
    function _parentChainFee() internal view returns (uint256) {
        (bool ok, bytes memory data) =
            ARB_GAS_INFO.staticcall{gas: 30_000}(abi.encodeWithSignature("getCurrentTxL1GasFees()"));
        return ok && data.length == 32 ? abi.decode(data, (uint256)) : 0;
    }
}
