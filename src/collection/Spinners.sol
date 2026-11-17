// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721A} from "erc721a/ERC721A.sol";
import {ERC721AC} from "@limitbreak/creator-token-standards/erc721c/ERC721AC.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// The ERC-6551 registry, as far as Spinners reads it: each token's own account (wallet).
interface ISpinnerWalletRegistry {
    function account(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        view
        returns (address);
}


/**
 * @title Spinners
 * @notice The Spinners collection. Both mints are closed at deployment; the
 * owner opens and closes them.
 *
 * Whitelist mint: open while `whitelistMintOpen`, up to `whitelistSupply` tokens
 * in total. Each call carries an EIP-712 signature from `whitelistSigner` over
 * (minter, allowance); a minter mints at most `allowance` tokens this way.
 *
 * Public mint: open while `mintOpen`, up to `maxPerWallet` public mints per
 * wallet (0 = no limit).
 *
 * The whitelist mint costs `whitelistPrice` per token and the public mint
 * `price`, both in `paymentToken` (the zero address means native ETH). ERC-20
 * payments go directly to the treasury; fee-on-transfer tokens are not
 * supported. Prices, payment token and limits cannot change while a mint is open.
 *
 * When fewer tokens remain (in the whitelist supply or the total supply) than
 * a mint asks for, it mints what remains and charges only for that; excess ETH
 * is refunded. Token URIs are `baseURI + tokenId`, set by the owner.
 * Metadata changes are announced with the ERC-4906 events: `setBaseURI` covers
 * every token, and `refreshMetadata` covers a range whose metadata changed
 * without a new base URI.
 *
 * Activation: a token's holder activates it by paying `activationFee` in
 * `activationToken`; `activationBurnBps` of the fee goes to BURN_ADDRESS, from
 * which no key can move it, and the rest goes to the treasury. Tokens are minted
 * inactive, and every transfer makes a token inactive again.
 *
 * The owner can withdraw any ETH or ERC-20 tokens held by the contract, to the treasury only.
 *
 * Transfers: an ERC721-C creator token (Limit Break's creator-token-standards). Every transfer
 * (not a mint) is checked by the transfer validator (`getTransferValidator`, the library's default
 * until the owner sets another), under the security policy the owner sets for this collection in
 * that validator. Royalties are ERC-2981, to the treasury.
 *
 * Each token has its own wallet, its ERC-6551 account (salt 0) from `walletRegistry` and
 * `walletImplementation`. A token whose wallet is locked (`isLocked()`, as Tokenbound accounts
 * have) cannot be transferred until the lock ends, so a locked wallet never changes hands. With no
 * registry set, this check is off.
 */
contract Spinners is ERC721AC, ERC2981, EIP712, Ownable2Step {
    using SafeERC20 for IERC20;

    /// Where the burned share of each activation fee goes.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    bytes32 public constant WHITELIST_TYPEHASH = keccak256("WhitelistMint(address minter,uint256 allowance)");

    uint256 public immutable maxSupply;
    /// The ERC-6551 registry and account implementation of each token's wallet (zero: no lock check).
    address public immutable walletRegistry;
    address public immutable walletImplementation;

    bool public mintOpen;
    bool public whitelistMintOpen;
    /// The zero address means native ETH.
    address public paymentToken;
    uint256 public price;
    uint256 public whitelistPrice;
    uint256 public maxPerTx;
    /// Public mints per wallet; 0 = no limit.
    uint256 public maxPerWallet;
    address payable public treasury;

    address public whitelistSigner;
    uint256 public whitelistSupply;
    uint256 public whitelistMinted;
    mapping(address => uint256) public whitelistMintedBy;
    mapping(address => uint256) public publicMintedBy;

    string private _baseTokenURI;

    /// The ERC-20 the activation fee is paid in; unset while the fee is zero.
    address public activationToken;
    uint256 public activationFee;
    /// Share of the activation fee sent to BURN_ADDRESS, in basis points; the rest goes to the treasury.
    uint16 public activationBurnBps;
    mapping(uint256 => bool) private _active;

    event MintOpenSet(bool open);
    event WhitelistMintOpenSet(bool open);
    event PriceSet(address paymentToken, uint256 price, uint256 whitelistPrice);
    event LimitsSet(uint256 maxPerTx, uint256 maxPerWallet);
    event WhitelistSignerSet(address signer);
    event WhitelistSupplySet(uint256 supply);
    event TreasurySet(address treasury);
    /// `token` is the zero address for ETH.
    event BalanceWithdrawn(address indexed token, address indexed to, uint256 amount);
    event BaseURISet(string baseURI);
    /// ERC-4906.
    event MetadataUpdate(uint256 _tokenId);
    /// ERC-4906.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    event ActivationSet(address token, uint256 fee, uint16 burnBps);
    event Activated(uint256 indexed tokenId, address indexed holder, uint256 fee, uint256 burned);
    event Deactivated(uint256 indexed tokenId);

    error MintClosed();
    error MintIsOpen();
    error BadQuantity();
    error SoldOut();
    error WalletLimit();
    error WrongPayment();
    error NotWhitelisted();
    error OverAllowance();
    error WhitelistSoldOut();
    error ZeroAddress();
    error WithdrawFailed();
    error RefundFailed();
    error NotTokenHolder();
    error AlreadyActive();
    error BadActivation();
    error BadRange();
    error WalletLocked(uint256 tokenId);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        address owner_,
        address payable treasury_,
        uint96 royaltyBps_,
        string memory baseURI_,
        address walletRegistry_,
        address walletImplementation_
    ) ERC721AC(name_, symbol_) EIP712(name_, "1") Ownable(owner_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        maxSupply = maxSupply_;
        treasury = treasury_;
        maxPerTx = 5;
        _baseTokenURI = baseURI_;
        walletRegistry = walletRegistry_;
        walletImplementation = walletImplementation_;
        _setDefaultRoyalty(treasury_, royaltyBps_);
    }

    // ── Mint ────────────────────────────────────────────────────────────

    /// @notice Public mint. Pays for `quantity` at `price`; returns how many were minted.
    function mint(uint256 quantity) external payable returns (uint256 minted) {
        if (!mintOpen) revert MintClosed();
        if (quantity == 0 || quantity > maxPerTx) revert BadQuantity();
        uint256 byWallet = publicMintedBy[msg.sender] + quantity;
        if (maxPerWallet != 0 && byWallet > maxPerWallet) revert WalletLimit();
        minted = _available(quantity, type(uint256).max);
        publicMintedBy[msg.sender] = publicMintedBy[msg.sender] + minted;
        _mint(msg.sender, minted);
        _pay(quantity, minted, price);
    }

    /// @notice Whitelist mint. `signature` is `whitelistSigner`'s EIP-712 signature over
    /// (msg.sender, allowance). Pays for `quantity` at `whitelistPrice`; returns how many were minted.
    function whitelistMint(uint256 quantity, uint256 allowance, bytes calldata signature)
        external
        payable
        returns (uint256 minted)
    {
        if (!whitelistMintOpen) revert MintClosed();
        if (ECDSA.recover(whitelistDigest(msg.sender, allowance), signature) != whitelistSigner) revert NotWhitelisted();
        if (quantity == 0 || quantity > maxPerTx) revert BadQuantity();
        if (whitelistMintedBy[msg.sender] + quantity > allowance) revert OverAllowance();
        if (whitelistMinted >= whitelistSupply) revert WhitelistSoldOut();
        minted = _available(quantity, whitelistSupply - whitelistMinted);
        whitelistMintedBy[msg.sender] += minted;
        whitelistMinted += minted;
        _mint(msg.sender, minted);
        _pay(quantity, minted, whitelistPrice);
    }

    /// @notice The EIP-712 digest `whitelistSigner` signs for `minter`.
    function whitelistDigest(address minter, uint256 allowance) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(WHITELIST_TYPEHASH, minter, allowance)));
    }

    /// @notice Mints `quantity` tokens to `to`, within the supply. Owner only.
    function reserve(address to, uint256 quantity) external onlyOwner {
        if (quantity == 0) revert BadQuantity();
        if (_totalMinted() + quantity > maxSupply) revert SoldOut();
        _mint(to, quantity);
    }

    function totalMinted() external view returns (uint256) {
        return _totalMinted();
    }

    function numberMinted(address wallet) external view returns (uint256) {
        return _numberMinted(wallet);
    }

    /// The smaller of `quantity`, `phaseLeft` and what remains of the total supply; reverts if none remains.
    function _available(uint256 quantity, uint256 phaseLeft) internal view returns (uint256) {
        uint256 left = maxSupply - _totalMinted();
        if (left == 0) revert SoldOut();
        if (phaseLeft < left) left = phaseLeft;
        return quantity < left ? quantity : left;
    }

    /// Takes payment for `minted` tokens. ETH must cover `requested`; the difference is refunded.
    function _pay(uint256 requested, uint256 minted, uint256 unitPrice) internal {
        uint256 cost = unitPrice * minted;
        if (paymentToken == address(0)) {
            if (msg.value != unitPrice * requested) revert WrongPayment();
            uint256 refund = msg.value - cost;
            if (refund != 0) {
                (bool ok,) = payable(msg.sender).call{value: refund}("");
                if (!ok) revert RefundFailed();
            }
        } else {
            if (msg.value != 0) revert WrongPayment();
            if (cost != 0) IERC20(paymentToken).safeTransferFrom(msg.sender, treasury, cost);
        }
    }

    // ── Activation ──────────────────────────────────────────────────────

    /// @notice Activates `tokenId`. Called by its holder, who pays `activationFee` in `activationToken`
    /// (approve it to this contract first).
    function activate(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenHolder();
        if (_active[tokenId]) revert AlreadyActive();
        _active[tokenId] = true;

        uint256 fee = activationFee;
        uint256 burned;
        if (fee != 0) {
            IERC20 token = IERC20(activationToken);
            token.safeTransferFrom(msg.sender, address(this), fee);
            burned = (fee * activationBurnBps) / 10_000;
            if (burned != 0) token.safeTransfer(BURN_ADDRESS, burned);
            if (fee > burned) token.safeTransfer(treasury, fee - burned);
        }
        emit Activated(tokenId, msg.sender, fee, burned);
    }

    function isActive(uint256 tokenId) external view returns (bool) {
        return _active[tokenId];
    }

    /// A transfer (not a mint) of a token whose wallet is locked is refused; then the transfer validator checks it.
    function _beforeTokenTransfers(address from, address to, uint256 startTokenId, uint256 quantity) internal override {
        if (from != address(0) && walletRegistry != address(0)) {
            for (uint256 id = startTokenId; id < startTokenId + quantity; id++) {
                if (walletLocked(id)) revert WalletLocked(id);
            }
        }
        super._beforeTokenTransfers(from, to, startTokenId, quantity);
    }

    /// @notice Whether `tokenId`'s wallet exists and is locked (`isLocked()`): it cannot be transferred until the lock ends.
    function walletLocked(uint256 tokenId) public view returns (bool) {
        if (walletRegistry == address(0)) return false;
        address wallet =
            ISpinnerWalletRegistry(walletRegistry).account(walletImplementation, bytes32(0), block.chainid, address(this), tokenId);
        if (wallet.code.length == 0) return false;
        (bool ok, bytes memory data) = wallet.staticcall(abi.encodeWithSignature("isLocked()"));
        return ok && data.length >= 32 && abi.decode(data, (bool));
    }

    /// Every transfer (not a mint) makes the token inactive, after the transfer validator's own hook.
    function _afterTokenTransfers(address from, address to, uint256 startTokenId, uint256 quantity) internal override {
        super._afterTokenTransfers(from, to, startTokenId, quantity);
        if (from == address(0)) return;
        for (uint256 id = startTokenId; id < startTokenId + quantity; id++) {
            if (_active[id]) {
                delete _active[id];
                emit Deactivated(id);
            }
        }
    }

    /// @notice Sets the activation fee, the ERC-20 it is paid in, and the share burned.
    /// A zero fee makes activation free. Applies to activations from now on.
    function setActivation(address token, uint256 fee, uint16 burnBps) external onlyOwner {
        if (burnBps > 10_000 || (fee != 0 && token == address(0))) revert BadActivation();
        activationToken = token;
        activationFee = fee;
        activationBurnBps = burnBps;
        emit ActivationSet(token, fee, burnBps);
    }

    // ── Owner: mint settings ────────────────────────────────────────────

    modifier mintsClosed() {
        if (mintOpen || whitelistMintOpen) revert MintIsOpen();
        _;
    }

    function setMintOpen(bool open) external onlyOwner {
        mintOpen = open;
        emit MintOpenSet(open);
    }

    function setWhitelistMintOpen(bool open) external onlyOwner {
        whitelistMintOpen = open;
        emit WhitelistMintOpenSet(open);
    }

    /// @notice Sets the public and whitelist prices per token, in `paymentToken_` (the zero address means native ETH).
    function setPrice(address paymentToken_, uint256 price_, uint256 whitelistPrice_) external onlyOwner mintsClosed {
        paymentToken = paymentToken_;
        price = price_;
        whitelistPrice = whitelistPrice_;
        emit PriceSet(paymentToken_, price_, whitelistPrice_);
    }

    function setLimits(uint256 maxPerTx_, uint256 maxPerWallet_) external onlyOwner mintsClosed {
        if (maxPerTx_ == 0) revert BadQuantity();
        maxPerTx = maxPerTx_;
        maxPerWallet = maxPerWallet_;
        emit LimitsSet(maxPerTx_, maxPerWallet_);
    }

    /// @notice Sets the whitelist signer. Signatures from a previous signer stop being valid.
    function setWhitelistSigner(address signer) external onlyOwner {
        whitelistSigner = signer;
        emit WhitelistSignerSet(signer);
    }

    function setWhitelistSupply(uint256 supply) external onlyOwner {
        if (whitelistMintOpen) revert MintIsOpen();
        if (supply > maxSupply) revert BadQuantity();
        whitelistSupply = supply;
        emit WhitelistSupplySet(supply);
    }

    function setTreasury(address payable treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        _setDefaultRoyalty(receiver, bps);
    }

    /// @notice Sends `amount` of this contract's ETH to the treasury.
    function withdrawEth(uint256 amount) external onlyOwner {
        (bool ok,) = treasury.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
        emit BalanceWithdrawn(address(0), treasury, amount);
    }

    /// @notice Sends `amount` of the ERC-20 `token` held by this contract to the treasury.
    function withdrawToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(treasury, amount);
        emit BalanceWithdrawn(token, treasury, amount);
    }

    // ── Metadata ────────────────────────────────────────────────────────

    function setBaseURI(string calldata baseURI) external onlyOwner {
        _baseTokenURI = baseURI;
        emit BaseURISet(baseURI);
        emit BatchMetadataUpdate(_startTokenId(), _startTokenId() + maxSupply - 1);
    }

    /// @notice Announces that the metadata of tokens `fromTokenId` to `toTokenId`
    /// (inclusive) changed at the same base URI.
    function refreshMetadata(uint256 fromTokenId, uint256 toTokenId) external onlyOwner {
        if (fromTokenId > toTokenId) revert BadRange();
        if (fromTokenId == toTokenId) emit MetadataUpdate(fromTokenId);
        else emit BatchMetadataUpdate(fromTokenId, toTokenId);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    // ── ERC721A / ERC165 ────────────────────────────────────────────────

    function _startTokenId() internal pure override returns (uint256) {
        return 1;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721AC, ERC2981) returns (bool) {
        return interfaceId == 0x49064906 // ERC-4906
            || ERC721AC.supportsInterface(interfaceId) || ERC2981.supportsInterface(interfaceId);
    }

    // ── ERC721-C ────────────────────────────────────────────────────────

    /// The owner sets the transfer validator, and its automatic approval (`setTransferValidator`,
    /// `setAutomaticApprovalOfTransfersFromValidator`).
    function _requireCallerIsContractOwner() internal view override {
        _checkOwner();
    }
}
