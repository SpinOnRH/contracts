// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Spinners} from "../src/collection/Spinners.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ICreatorToken} from "@limitbreak/creator-token-standards/interfaces/ICreatorToken.sol";
import {CreatorTokenBase} from "@limitbreak/creator-token-standards/utils/CreatorTokenBase.sol";

/// Stands in for an ERC-6551 registry: every token's wallet is the one wallet it is given.
contract MockWalletRegistry {
    address public wallet;

    function setWallet(address w) external {
        wallet = w;
    }

    function account(address, bytes32, uint256, address, uint256) external view returns (address) {
        return wallet;
    }
}

/// Stands in for a token-bound account that its holder can lock.
contract MockLockableWallet {
    bool public isLocked;

    function setLocked(bool on) external {
        isLocked = on;
    }
}

/**
 * Stands in for Limit Break's transfer validator at its default address (a plain test chain has
 * none): it records the token type a collection registers, and refuses transfers by the callers it
 * is told to (or all of them).
 */
contract MockTransferValidator {
    mapping(address => uint16) public tokenTypeOf;
    mapping(address => bool) public blocked;
    bool public blockAll;

    error Blocked(address caller);

    function setTokenTypeOfCollection(address collection, uint16 tokenType) external {
        tokenTypeOf[collection] = tokenType;
    }

    function setBlocked(address caller, bool on) external {
        blocked[caller] = on;
    }

    function setBlockAll(bool on) external {
        blockAll = on;
    }

    /// Read-only, as the real one: the collection calls it with a static call.
    function validateTransfer(address caller, address, address, uint256) external view {
        if (blockAll || blocked[caller]) revert Blocked(caller);
    }
}

contract TestUSD is ERC20 {
    constructor() ERC20("Test USD", "TUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Stands in for $SPIN: a Torch token is a plain ERC-20, with no `burn`.
contract TestSpin is ERC20 {
    constructor() ERC20("Spin", "SPIN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SpinnersTest is Test {
    Spinners spinners;
    address owner = makeAddr("owner");
    address payable treasury = payable(makeAddr("treasury"));
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 constant SUPPLY = 50;

    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    /// Limit Break's default transfer validator (CreatorTokenBase.DEFAULT_TRANSFER_VALIDATOR).
    address constant VALIDATOR = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;
    MockTransferValidator validator = MockTransferValidator(VALIDATOR);

    function setUp() public {
        vm.etch(VALIDATOR, address(new MockTransferValidator()).code);
        spinners = new Spinners("Spinners", "SPIN", SUPPLY, owner, treasury, 500, "ipfs://placeholder/", address(0), address(0));
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _open(uint256 price) internal {
        vm.startPrank(owner);
        spinners.setPrice(address(0), price, price);
        spinners.setMintOpen(true);
        vm.stopPrank();
    }

    // ── Deployed closed; the owner opens it ────────────────────────────

    function test_deploysWithTheMintClosed() public {
        assertFalse(spinners.mintOpen());
        vm.prank(alice);
        vm.expectRevert(Spinners.MintClosed.selector);
        spinners.mint(1);
    }

    function test_onlyTheOwnerOpensAndCloses() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        spinners.setMintOpen(true);

        _open(0.01 ether);
        assertTrue(spinners.mintOpen());
        vm.prank(owner);
        spinners.setMintOpen(false);
        vm.prank(alice);
        vm.expectRevert(Spinners.MintClosed.selector);
        spinners.mint{value: 0.01 ether}(1);
    }

    function test_mintPaysThePriceAndStartsAtTokenOne() public {
        _open(0.01 ether);
        vm.prank(alice);
        vm.expectRevert(Spinners.WrongPayment.selector);
        spinners.mint{value: 0.01 ether}(2);

        vm.prank(alice);
        spinners.mint{value: 0.02 ether}(2);
        assertEq(spinners.ownerOf(1), alice);
        assertEq(spinners.ownerOf(2), alice);
        assertEq(spinners.totalMinted(), 2);
        assertEq(address(spinners).balance, 0.02 ether);
    }

    function test_limitsPerTxPerWalletAndSupply() public {
        vm.prank(owner);
        spinners.setLimits(3, 4);
        _open(0);
        vm.startPrank(alice);
        vm.expectRevert(Spinners.BadQuantity.selector);
        spinners.mint(4);
        vm.expectRevert(Spinners.BadQuantity.selector);
        spinners.mint(0);
        spinners.mint(3);
        vm.expectRevert(Spinners.WalletLimit.selector);
        spinners.mint(2);
        spinners.mint(1);
        vm.stopPrank();

        // The supply is a hard cap, for the owner too.
        vm.startPrank(owner);
        for (uint256 i = 0; i < 2; i++) spinners.reserve(owner, 20);
        vm.expectRevert(Spinners.SoldOut.selector);
        spinners.reserve(owner, 7);
        spinners.reserve(owner, 6);
        vm.stopPrank();
        assertEq(spinners.totalMinted(), SUPPLY);
        vm.prank(bob);
        vm.expectRevert(Spinners.SoldOut.selector);
        spinners.mint(1);
    }

    function test_priceAndLimitsAreFixedWhileOpen() public {
        _open(0.01 ether);
        vm.startPrank(owner);
        vm.expectRevert(Spinners.MintIsOpen.selector);
        spinners.setPrice(address(0), 1 ether, 1 ether);
        vm.expectRevert(Spinners.MintIsOpen.selector);
        spinners.setLimits(1, 1);
        spinners.setMintOpen(false); // closing is always allowed
        spinners.setPrice(address(0), 0.02 ether, 0.02 ether);
        vm.stopPrank();
        assertEq(spinners.price(), 0.02 ether);
    }

    function test_theOwnerSetsAnyPerTxLimit() public {
        vm.startPrank(owner);
        vm.expectRevert(Spinners.BadQuantity.selector);
        spinners.setLimits(0, 0);
        spinners.setLimits(SUPPLY, 0);
        assertEq(spinners.maxPerTx(), SUPPLY);
        spinners.reserve(owner, SUPPLY);
        vm.stopPrank();
        assertEq(spinners.totalMinted(), SUPPLY);
    }

    function test_theOwnerWithdrawsAnyEthOrTokensToTheTreasuryOnly() public {
        TestSpin spin = new TestSpin();
        spin.mint(address(spinners), 100e18);
        vm.deal(address(spinners), 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        spinners.withdrawToken(address(spin), 100e18);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        spinners.withdrawEth(1 ether);
        vm.stopPrank();
        uint256 treasuryEth = treasury.balance;
        vm.startPrank(owner);
        spinners.withdrawToken(address(spin), 60e18);
        spinners.withdrawEth(0.4 ether);
        vm.stopPrank();
        assertEq(spin.balanceOf(treasury), 60e18);
        assertEq(treasury.balance, treasuryEth + 0.4 ether);
        assertEq(spin.balanceOf(owner), 0, "never to the owner, only to the treasury");
        assertEq(address(spinners).balance, 0.6 ether);

        // A mint paid in ETH stays in the contract until the owner withdraws it.
        _open(0.01 ether);
        vm.prank(alice);
        spinners.mint{value: 0.03 ether}(3);
        vm.prank(owner);
        spinners.withdrawEth(address(spinners).balance);
        assertEq(address(spinners).balance, 0);
        assertEq(treasury.balance, treasuryEth + 1.03 ether);
    }

    function test_theOwnerSetsAnyRoyaltyUpTo100Percent() public {
        (address receiver, uint256 amount) = spinners.royaltyInfo(1, 1 ether);
        assertEq(receiver, treasury);
        assertEq(amount, 0.05 ether);
        vm.startPrank(owner);
        spinners.setRoyalty(treasury, 2_500);
        (, amount) = spinners.royaltyInfo(1, 1 ether);
        assertEq(amount, 0.25 ether);
        vm.expectRevert(); // ERC-2981: more than the whole price
        spinners.setRoyalty(treasury, 10_001);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        spinners.setRoyalty(alice, 100);
        assertTrue(spinners.supportsInterface(0x2a55205a)); // ERC-2981
        assertTrue(spinners.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(spinners.supportsInterface(0x49064906)); // ERC-4906
    }

    function test_ownershipMovesInTwoSteps() public {
        vm.prank(owner);
        spinners.transferOwnership(bob);
        assertEq(spinners.owner(), owner, "not until bob accepts");
        vm.prank(bob);
        spinners.acceptOwnership();
        assertEq(spinners.owner(), bob);
    }

    // ── Metadata ────────────────────────────────────────────────────────

    function test_theOwnerSetsTheMetadataLocation() public {
        _open(0);
        vm.prank(alice);
        spinners.mint(2);
        assertEq(spinners.tokenURI(2), "ipfs://placeholder/2");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        spinners.setBaseURI("ipfs://evil/");

        vm.prank(owner);
        vm.expectEmit(address(spinners));
        emit BatchMetadataUpdate(1, SUPPLY);
        spinners.setBaseURI("ipfs://art/");
        assertEq(spinners.tokenURI(1), "ipfs://art/1");
        vm.expectRevert();
        spinners.tokenURI(3); // not minted
    }

    function test_theOwnerAnnouncesAReveal() public {
        vm.startPrank(owner);
        vm.expectEmit(address(spinners));
        emit MetadataUpdate(7);
        spinners.refreshMetadata(7, 7);

        vm.expectEmit(address(spinners));
        emit BatchMetadataUpdate(1, 100);
        spinners.refreshMetadata(1, 100);

        vm.expectRevert(Spinners.BadRange.selector);
        spinners.refreshMetadata(5, 4);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        spinners.refreshMetadata(1, 1);
    }

    // ── ERC-20 price ────────────────────────────────────────────────────

    function test_priceInAnErc20GoesToTheTreasury() public {
        TestUSD usd = new TestUSD();
        usd.mint(alice, 1000e18);
        vm.startPrank(owner);
        spinners.setPrice(address(usd), 25e18, 20e18);
        spinners.setMintOpen(true);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(); // no allowance
        spinners.mint(2);
        usd.approve(address(spinners), 50e18);
        vm.expectRevert(Spinners.WrongPayment.selector); // no ETH with a token price
        spinners.mint{value: 1}(2);
        spinners.mint(2);
        vm.stopPrank();
        assertEq(usd.balanceOf(treasury), 50e18);
        assertEq(usd.balanceOf(address(spinners)), 0);
        assertEq(spinners.ownerOf(2), alice);
    }

    function test_priceAndTokenAreFixedWhileEitherMintIsOpen() public {
        vm.startPrank(owner);
        spinners.setWhitelistMintOpen(true);
        vm.expectRevert(Spinners.MintIsOpen.selector);
        spinners.setPrice(address(0), 1 ether, 1 ether);
        vm.expectRevert(Spinners.MintIsOpen.selector);
        spinners.setLimits(1, 1);
        vm.expectRevert(Spinners.MintIsOpen.selector);
        spinners.setWhitelistSupply(10);
        vm.stopPrank();
    }

    // ── Whitelist ───────────────────────────────────────────────────────

    uint256 constant SIGNER_KEY = 0xA11CE;

    function _sign(uint256 key, address minter, uint256 allowance) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, spinners.whitelistDigest(minter, allowance));
        return abi.encodePacked(r, s, v);
    }

    function _openWhitelist(uint256 supply, uint256 price) internal {
        vm.startPrank(owner);
        spinners.setWhitelistSigner(vm.addr(SIGNER_KEY));
        spinners.setWhitelistSupply(supply);
        spinners.setPrice(address(0), price, price);
        spinners.setWhitelistMintOpen(true);
        vm.stopPrank();
    }

    function test_whitelistMintNeedsTheSignersSignatureForTheCaller() public {
        _openWhitelist(10, 0.01 ether);
        bytes memory sig = _sign(SIGNER_KEY, alice, 2);

        vm.prank(alice);
        spinners.whitelistMint{value: 0.02 ether}(2, 2, sig);
        assertEq(spinners.ownerOf(2), alice);
        assertEq(spinners.whitelistMinted(), 2);

        // Alice's signature does not work for Bob, nor with a larger allowance.
        vm.prank(bob);
        vm.expectRevert(Spinners.NotWhitelisted.selector);
        spinners.whitelistMint{value: 0.01 ether}(1, 2, sig);
        vm.prank(alice);
        vm.expectRevert(Spinners.NotWhitelisted.selector);
        spinners.whitelistMint{value: 0.01 ether}(1, 5, sig);

        // A signature from any other key is refused.
        bytes memory forged = _sign(0xB0B, bob, 1);
        vm.prank(bob);
        vm.expectRevert(Spinners.NotWhitelisted.selector);
        spinners.whitelistMint{value: 0.01 ether}(1, 1, forged);
    }

    function test_whitelistAllowanceHoldsAcrossMints() public {
        _openWhitelist(10, 0);
        bytes memory sig = _sign(SIGNER_KEY, alice, 3);
        vm.startPrank(alice);
        spinners.whitelistMint(2, 3, sig);
        vm.expectRevert(Spinners.OverAllowance.selector);
        spinners.whitelistMint(2, 3, sig);
        spinners.whitelistMint(1, 3, sig);
        vm.stopPrank();
        assertEq(spinners.whitelistMintedBy(alice), 3);
    }

    function test_whitelistSupplyIsCapped() public {
        _openWhitelist(3, 0);
        bytes memory aliceSig = _sign(SIGNER_KEY, alice, 5);
        bytes memory bobSig = _sign(SIGNER_KEY, bob, 5);
        vm.prank(alice);
        spinners.whitelistMint(2, 5, aliceSig);
        // Bob asks for 2 with 1 left: he gets 1.
        vm.prank(bob);
        assertEq(spinners.whitelistMint(2, 5, bobSig), 1);
        assertEq(spinners.whitelistMinted(), 3);
        vm.prank(bob);
        vm.expectRevert(Spinners.WhitelistSoldOut.selector);
        spinners.whitelistMint(1, 5, bobSig);
    }

    function test_whitelistIsClosedUntilOpenedAndSeparateFromPublic() public {
        vm.prank(owner);
        spinners.setWhitelistSigner(vm.addr(SIGNER_KEY));
        bytes memory sig = _sign(SIGNER_KEY, alice, 2);
        vm.prank(alice);
        vm.expectRevert(Spinners.MintClosed.selector);
        spinners.whitelistMint(1, 2, sig);

        _open(0); // public open, whitelist still closed
        vm.prank(alice);
        vm.expectRevert(Spinners.MintClosed.selector);
        spinners.whitelistMint(1, 2, sig);
    }

    function test_aNewSignerCancelsOldSignatures() public {
        _openWhitelist(10, 0);
        bytes memory sig = _sign(SIGNER_KEY, alice, 2);
        vm.prank(owner);
        spinners.setWhitelistSigner(vm.addr(0xC0FFEE));
        vm.prank(alice);
        vm.expectRevert(Spinners.NotWhitelisted.selector);
        spinners.whitelistMint(1, 2, sig);
    }

    function test_publicWalletLimitCountsOnlyPublicMints() public {
        _openWhitelist(10, 0);
        bytes memory sig = _sign(SIGNER_KEY, alice, 3);
        vm.prank(alice);
        spinners.whitelistMint(3, 3, sig);
        vm.startPrank(owner);
        spinners.setWhitelistMintOpen(false);
        spinners.setLimits(5, 2);
        spinners.setMintOpen(true);
        vm.stopPrank();
        vm.startPrank(alice);
        spinners.mint(2);
        vm.expectRevert(Spinners.WalletLimit.selector);
        spinners.mint(1);
        vm.stopPrank();
        assertEq(spinners.numberMinted(alice), 5);
    }

    function test_whitelistSignatureIsBoundToThisContract() public {
        // The same signer and minter on another deployment: the digest differs.
        Spinners other = new Spinners("Spinners", "SPIN", SUPPLY, owner, treasury, 500, "", address(0), address(0));
        assertTrue(other.whitelistDigest(alice, 2) != spinners.whitelistDigest(alice, 2));
    }

    // ── Whitelist price and partial mints ──────────────────────────────

    function test_whitelistHasItsOwnPrice() public {
        vm.startPrank(owner);
        spinners.setWhitelistSigner(vm.addr(SIGNER_KEY));
        spinners.setWhitelistSupply(10);
        spinners.setPrice(address(0), 0.02 ether, 0.01 ether);
        spinners.setWhitelistMintOpen(true);
        spinners.setMintOpen(true);
        vm.stopPrank();
        bytes memory sig = _sign(SIGNER_KEY, alice, 2);
        vm.startPrank(alice);
        vm.expectRevert(Spinners.WrongPayment.selector);
        spinners.whitelistMint{value: 0.04 ether}(2, 2, sig); // the public price
        spinners.whitelistMint{value: 0.02 ether}(2, 2, sig);
        vm.expectRevert(Spinners.WrongPayment.selector);
        spinners.mint{value: 0.01 ether}(1); // the whitelist price
        spinners.mint{value: 0.02 ether}(1);
        vm.stopPrank();
        assertEq(address(spinners).balance, 0.04 ether);
    }

    function test_aPublicMintNearTheEndGetsWhatIsLeftAndARefund() public {
        _open(0.01 ether);
        vm.startPrank(owner);
        for (uint256 i = 0; i < 2; i++) spinners.reserve(owner, 20);
        spinners.reserve(owner, 8); // 2 left of 50
        vm.stopPrank();
        uint256 before = alice.balance;
        vm.prank(alice);
        assertEq(spinners.mint{value: 0.05 ether}(5), 2);
        assertEq(spinners.totalMinted(), SUPPLY);
        assertEq(alice.balance, before - 0.02 ether, "paid for 2, refunded 3");
        assertEq(address(spinners).balance, 0.02 ether);
        assertEq(spinners.publicMintedBy(alice), 2);
        vm.prank(bob);
        vm.expectRevert(Spinners.SoldOut.selector);
        spinners.mint{value: 0.01 ether}(1);
    }

    function test_aPartialMintInAnErc20ChargesOnlyWhatWasMinted() public {
        TestUSD usd = new TestUSD();
        usd.mint(alice, 1000e18);
        vm.startPrank(owner);
        spinners.setPrice(address(usd), 25e18, 25e18);
        spinners.setMintOpen(true);
        for (uint256 i = 0; i < 2; i++) spinners.reserve(owner, 20);
        spinners.reserve(owner, 9); // 1 left
        vm.stopPrank();
        vm.startPrank(alice);
        usd.approve(address(spinners), 125e18);
        assertEq(spinners.mint(5), 1);
        vm.stopPrank();
        assertEq(usd.balanceOf(treasury), 25e18);
        assertEq(usd.balanceOf(alice), 975e18);
    }

    function test_aWhitelistMintIsAlsoCappedByTheTotalSupply() public {
        _openWhitelist(SUPPLY, 0);
        vm.startPrank(owner);
        for (uint256 i = 0; i < 2; i++) spinners.reserve(owner, 20);
        spinners.reserve(owner, 9); // 1 left in total, 50 in the whitelist
        vm.stopPrank();
        bytes memory sig = _sign(SIGNER_KEY, alice, 5);
        vm.prank(alice);
        assertEq(spinners.whitelistMint(3, 5, sig), 1);
        assertEq(spinners.whitelistMintedBy(alice), 1, "only what was minted counts against the allowance");
    }

    // ── Activation ──────────────────────────────────────────────────────

    event Activated(uint256 indexed tokenId, address indexed holder, uint256 fee, uint256 burned);
    event Deactivated(uint256 indexed tokenId);

    function _withSpin() internal returns (TestSpin spin) {
        spin = new TestSpin();
        spin.mint(alice, 20_000e18);
        spin.mint(bob, 20_000e18);
        vm.prank(owner);
        spinners.setActivation(address(spin), 5_000e18, 7_000);
        _open(0);
        vm.prank(alice);
        spinners.mint(2);
    }

    function test_activationBurns70PercentAndPaysTheRestToTheTreasury() public {
        TestSpin spin = _withSpin();
        address burn = spinners.BURN_ADDRESS();
        assertFalse(spinners.isActive(1), "minted inactive");

        vm.startPrank(alice);
        spin.approve(address(spinners), 5_000e18);
        vm.expectEmit(address(spinners));
        emit Activated(1, alice, 5_000e18, 3_500e18);
        spinners.activate(1);
        vm.stopPrank();

        assertTrue(spinners.isActive(1));
        assertFalse(spinners.isActive(2), "only the token activated");
        assertEq(spin.balanceOf(alice), 15_000e18);
        assertEq(spin.balanceOf(burn), 3_500e18, "3,500 burned: sent to the burn address");
        assertEq(spin.balanceOf(treasury), 1_500e18);
        assertEq(spin.balanceOf(address(spinners)), 0, "nothing left in the collection");
    }

    function test_onlyTheHolderActivatesAndOnlyOnce() public {
        TestSpin spin = _withSpin();
        vm.startPrank(bob);
        spin.approve(address(spinners), 5_000e18);
        vm.expectRevert(Spinners.NotTokenHolder.selector);
        spinners.activate(1);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(); // no allowance: nothing changes
        spinners.activate(1);
        assertFalse(spinners.isActive(1));
        spin.approve(address(spinners), 10_000e18);
        spinners.activate(1);
        vm.expectRevert(Spinners.AlreadyActive.selector);
        spinners.activate(1);
        vm.stopPrank();
        assertEq(spin.balanceOf(alice), 15_000e18, "charged once");
    }

    function test_everyTransferDeactivatesAndTheNewHolderPaysAgain() public {
        TestSpin spin = _withSpin();
        vm.startPrank(alice);
        spin.approve(address(spinners), 10_000e18);
        spinners.activate(1);
        spinners.activate(2);
        vm.expectEmit(address(spinners));
        emit Deactivated(1);
        spinners.transferFrom(alice, bob, 1);
        vm.stopPrank();

        assertFalse(spinners.isActive(1), "sold: inactive");
        assertTrue(spinners.isActive(2), "the other token is untouched");

        vm.startPrank(bob);
        spin.approve(address(spinners), 5_000e18);
        spinners.activate(1);
        assertTrue(spinners.isActive(1));
        // A safe transfer, even to yourself on another wallet, counts as a transfer.
        spinners.safeTransferFrom(bob, alice, 1);
        vm.stopPrank();
        assertFalse(spinners.isActive(1));
        assertEq(spin.balanceOf(treasury), 4_500e18, "three activations");
    }

    function test_approvedOperatorTransfersAlsoDeactivate() public {
        TestSpin spin = _withSpin();
        vm.startPrank(alice);
        spin.approve(address(spinners), 5_000e18);
        spinners.activate(1);
        spinners.setApprovalForAll(bob, true); // a marketplace's approval
        vm.stopPrank();
        assertTrue(spinners.isActive(1), "an approval alone changes nothing");
        vm.prank(bob);
        spinners.transferFrom(alice, bob, 1);
        assertFalse(spinners.isActive(1));
    }

    function test_activationIsFreeUntilAFeeIsSet() public {
        _open(0);
        vm.startPrank(alice);
        spinners.mint(1);
        spinners.activate(1);
        vm.stopPrank();
        assertTrue(spinners.isActive(1));
    }

    function test_onlyTheOwnerSetsActivationAndTheSettingsAreChecked() public {
        TestSpin spin = new TestSpin();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        spinners.setActivation(address(spin), 5_000e18, 7_000);

        vm.startPrank(owner);
        vm.expectRevert(Spinners.BadActivation.selector);
        spinners.setActivation(address(spin), 5_000e18, 10_001);
        vm.expectRevert(Spinners.BadActivation.selector);
        spinners.setActivation(address(0), 5_000e18, 7_000);
        spinners.setActivation(address(spin), 5_000e18, 7_000);
        vm.stopPrank();
        assertEq(spinners.activationToken(), address(spin));
        assertEq(spinners.activationFee(), 5_000e18);
        assertEq(spinners.activationBurnBps(), 7_000);
    }

    // ── ERC721-C: transfers go through the transfer validator ───────────

    function _mintTo(address to) internal returns (uint256 id) {
        id = spinners.totalMinted() + 1;
        vm.prank(owner);
        spinners.reserve(to, 1);
    }

    function test_theDefaultValidatorIsSetAndTheCollectionRegisteredAsAnErc721() public view {
        assertEq(spinners.getTransferValidator(), VALIDATOR);
        assertEq(spinners.DEFAULT_TRANSFER_VALIDATOR(), VALIDATOR);
        assertEq(validator.tokenTypeOf(address(spinners)), 721, "registered at deployment");
        (bytes4 fn, bool isView) = spinners.getTransferValidationFunction();
        assertEq(fn, bytes4(keccak256("validateTransfer(address,address,address,uint256)")));
        assertTrue(isView);
    }

    function test_everyTransferIsCheckedByTheValidator_andMintsAreNot() public {
        // Mints are not transfers: with the validator refusing everything, both mints still work.
        validator.setBlockAll(true);
        uint256 id = _mintTo(alice);
        _open(0);
        vm.prank(bob);
        spinners.mint(1);
        assertEq(spinners.balanceOf(bob), 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockTransferValidator.Blocked.selector, alice));
        spinners.transferFrom(alice, bob, id);
        validator.setBlockAll(false);
        vm.expectCall(VALIDATOR, abi.encodeCall(MockTransferValidator.validateTransfer, (alice, alice, bob, id)));
        vm.prank(alice);
        spinners.transferFrom(alice, bob, id);
        assertEq(spinners.ownerOf(id), bob);
    }

    function test_theValidatorRefusesAnOperatorItBlocks_andTheTokenStaysActive() public {
        TestSpin spin = _withSpin();
        address market = makeAddr("market");
        vm.startPrank(alice);
        spin.approve(address(spinners), 5_000e18);
        spinners.activate(1);
        spinners.setApprovalForAll(market, true);
        vm.stopPrank();
        validator.setBlocked(market, true);
        vm.prank(market);
        vm.expectRevert(abi.encodeWithSelector(MockTransferValidator.Blocked.selector, market));
        spinners.transferFrom(alice, bob, 1);
        assertEq(spinners.ownerOf(1), alice);
        assertTrue(spinners.isActive(1), "a refused transfer changes nothing");
    }

    function test_onlyTheOwnerSetsTheValidator_andNoValidatorMeansNoChecks() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        spinners.setTransferValidator(address(0));
        vm.prank(owner);
        vm.expectRevert(CreatorTokenBase.CreatorTokenBase__InvalidTransferValidatorContract.selector);
        spinners.setTransferValidator(makeAddr("no code"));

        // Another validator: it is used, and the collection registers with it.
        address other = makeAddr("other validator");
        vm.etch(other, address(new MockTransferValidator()).code);
        vm.prank(owner);
        spinners.setTransferValidator(other);
        assertEq(spinners.getTransferValidator(), other);
        assertEq(MockTransferValidator(other).tokenTypeOf(address(spinners)), 721);

        // None: transfers are not checked at all.
        vm.prank(owner);
        spinners.setTransferValidator(address(0));
        assertEq(spinners.getTransferValidator(), address(0));
        validator.setBlockAll(true);
        uint256 id = _mintTo(alice);
        vm.prank(alice);
        spinners.transferFrom(alice, bob, id);
        assertEq(spinners.ownerOf(id), bob);
    }

    function test_onlyTheOwnerLetsTheValidatorMoveTokens_andItsOwnTransfersAreNotRechecked() public {
        uint256 id = _mintTo(alice);
        assertFalse(spinners.isApprovedForAll(alice, VALIDATOR));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        spinners.setAutomaticApprovalOfTransfersFromValidator(true);
        vm.prank(owner);
        spinners.setAutomaticApprovalOfTransfersFromValidator(true);
        assertTrue(spinners.autoApproveTransfersFromValidator());
        assertTrue(spinners.isApprovedForAll(alice, VALIDATOR), "the validator is approved for every holder");
        // A transfer the validator makes itself is not sent back to it.
        validator.setBlockAll(true);
        vm.prank(VALIDATOR);
        spinners.transferFrom(alice, bob, id);
        assertEq(spinners.ownerOf(id), bob);
    }

    function test_interfaces_creatorTokenRoyaltiesMetadataUpdates() public view {
        assertTrue(spinners.supportsInterface(type(ICreatorToken).interfaceId), "ERC721-C");
        assertTrue(spinners.supportsInterface(0x2a55205a), "ERC-2981");
        assertTrue(spinners.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(spinners.supportsInterface(0x49064906), "ERC-4906");
        (address receiver, uint256 royalty) = spinners.royaltyInfo(1, 10_000);
        assertEq(receiver, treasury);
        assertEq(royalty, 500);
    }

    // ── No approval survives a change of owner ─────────────────────────

    function test_noApprovalSurvivesAChangeOfOwner() public {
        uint256 id = _mintTo(alice);
        address spender = makeAddr("spender");
        address operator = makeAddr("operator");
        vm.startPrank(alice);
        spinners.approve(spender, id);
        spinners.setApprovalForAll(operator, true);
        spinners.transferFrom(alice, bob, id); // the sale
        vm.stopPrank();
        assertEq(spinners.getApproved(id), address(0), "the token's approval is cleared");
        assertFalse(spinners.isApprovedForAll(bob, operator), "an operator approval is the old owner's only");
        vm.prank(spender);
        vm.expectRevert();
        spinners.transferFrom(bob, spender, id);
        vm.prank(operator);
        vm.expectRevert();
        spinners.transferFrom(bob, operator, id);
        assertEq(spinners.ownerOf(id), bob);
        // An approved spender's own transfer clears it too.
        vm.prank(bob);
        spinners.approve(spender, id);
        vm.prank(spender);
        spinners.transferFrom(bob, alice, id);
        assertEq(spinners.getApproved(id), address(0));
    }

    // ── A locked wallet does not change hands ───────────────────────────

    function _withWallets() internal returns (Spinners c, MockWalletRegistry registry, MockLockableWallet wallet) {
        registry = new MockWalletRegistry();
        wallet = new MockLockableWallet();
        registry.setWallet(address(wallet));
        c = new Spinners("Spinners", "SPIN", SUPPLY, owner, treasury, 500, "", address(registry), makeAddr("implementation"));
        vm.prank(owner);
        c.reserve(alice, 2);
    }

    function test_aTokenWhoseWalletIsLockedIsNotTransferred_andAMintIsNotChecked() public {
        (Spinners c,, MockLockableWallet wallet) = _withWallets();
        wallet.setLocked(true);
        vm.prank(owner);
        c.reserve(bob, 1); // a mint, though every wallet reads as locked
        assertTrue(c.walletLocked(1));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Spinners.WalletLocked.selector, 1));
        c.transferFrom(alice, bob, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Spinners.WalletLocked.selector, 2));
        c.safeTransferFrom(alice, bob, 2);
        wallet.setLocked(false);
        vm.prank(alice);
        c.transferFrom(alice, bob, 1);
        assertEq(c.ownerOf(1), bob);
    }

    function test_aWalletThatIsNotDeployedOrHasNoLockIsNotLocked_andNoRegistryMeansNoCheck() public {
        (Spinners c, MockWalletRegistry registry,) = _withWallets();
        registry.setWallet(makeAddr("not deployed"));
        assertFalse(c.walletLocked(1), "no code: no lock");
        registry.setWallet(address(new TestUSD())); // code with no isLocked()
        assertFalse(c.walletLocked(1));
        vm.prank(alice);
        c.transferFrom(alice, bob, 1);
        assertEq(spinners.walletRegistry(), address(0));
        assertFalse(spinners.walletLocked(1), "the suite's collection has no registry");
        assertEq(c.walletRegistry(), address(registry));
        assertEq(c.walletImplementation(), makeAddr("implementation"));
    }
}

