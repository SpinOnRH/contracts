// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Spinners} from "../../src/collection/Spinners.sol";

/// Limit Break's transfer validator, as far as these tests use it.
interface ICreatorTokenValidator {
    struct CollectionSecurityPolicy {
        uint8 rulesetId;
        uint48 listId;
        address customRuleset;
        uint8 globalOptions;
        uint16 rulesetOptions;
        uint16 tokenType;
    }

    function getCollectionSecurityPolicy(address collection) external view returns (CollectionSecurityPolicy memory);
    function getListAccounts(uint48 id, uint8 listType) external view returns (address[] memory);
    function validateTransfer(address caller, address from, address to, uint256 tokenId) external view;
    function setRulesetOfCollection(address collection, uint8 rulesetId, address customRuleset, uint8 globalOptions, uint16 rulesetOptions)
        external;
}

interface ITokenboundRegistry {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

interface ITokenboundLock {
    function lock(uint256 lockedUntil) external;
    function isLocked() external view returns (bool);
}

/// A marketplace that does not pay royalties: it moves tokens it is approved for.
contract PlainMarket {
    function take(Spinners collection, address from, address to, uint256 id) external {
        collection.transferFrom(from, to, id);
    }
}

/// A smart-contract wallet: its owner makes it call anything.
contract ContractWallet {
    address immutable owner = msg.sender;

    function execute(address to, bytes calldata data) external {
        require(msg.sender == owner);
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/**
 * Spinners as an ERC721-C token against Limit Break's live transfer validator on Robinhood Chain
 * (its default ruleset and list), on a fork:
 *
 *   RPC_URL=<archive rpc> npm run test
 */
contract SpinnersCreatorTokenFork is Test {
    ICreatorTokenValidator constant VALIDATOR = ICreatorTokenValidator(0x721C008fdff27BF06E7E123956E2Fe03B63342e3);
    /// Payment Processor v3: on the validator's default whitelist (list 0) on this chain.
    address constant PAYMENT_PROCESSOR = 0x9a1D00000000fC540e2000560054812452eB5366;
    uint8 constant LIST_TYPE_WHITELIST = 1;
    uint16 constant ALLOW_OTC_FOR_SMART_WALLETS = 1 << 2;
    uint256 constant PINNED_BLOCK = 102596000;
    /// Tokenbound's ERC-6551 registry and AccountV3: each Spinner's wallet.
    address constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;

    Spinners spinners;
    address owner = makeAddr("owner");
    address payable treasury = payable(makeAddr("treasury"));
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        string memory rpc = vm.envOr("RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // every test below skips
        vm.createSelectFork(rpc, PINNED_BLOCK);
        spinners = new Spinners("Spinners", "SPINNERS", 7777, owner, treasury, 777, "https://spin.trading/api/spinners/", REGISTRY, ACCOUNT_V3);
    }

    modifier forked() {
        if (address(spinners) == address(0)) {
            emit log("skipped: set RPC_URL to run the fork tests");
            return;
        }
        _;
    }

    function _reserve(address to) internal returns (uint256 id) {
        id = spinners.totalMinted() + 1;
        vm.prank(owner);
        spinners.reserve(to, 1);
    }

    function test_theCollectionRegistersWithTheLiveValidatorAndGetsItsDefaultPolicy() public forked {
        assertEq(spinners.getTransferValidator(), address(VALIDATOR));
        ICreatorTokenValidator.CollectionSecurityPolicy memory p = VALIDATOR.getCollectionSecurityPolicy(address(spinners));
        assertEq(p.tokenType, 721, "registered as an ERC-721 at deployment");
        assertEq(p.rulesetId, 0, "the default ruleset");
        assertEq(p.listId, 0, "Limit Break's default list");
        address[] memory whitelist = VALIDATOR.getListAccounts(0, LIST_TYPE_WHITELIST);
        bool listed;
        for (uint256 i; i < whitelist.length; i++) if (whitelist[i] == PAYMENT_PROCESSOR) listed = true;
        assertTrue(listed, "Payment Processor (it pays the royalty) is a listed operator");
    }

    function test_mintsAndAHoldersOwnTransferFromAPlainWalletWork() public forked {
        uint256 id = _reserve(alice);
        vm.prank(alice);
        spinners.transferFrom(alice, bob, id);
        assertEq(spinners.ownerOf(id), bob);
        // Payment Processor, as an operator, is allowed.
        vm.prank(address(spinners));
        VALIDATOR.validateTransfer(PAYMENT_PROCESSOR, bob, alice, id);
    }

    function test_aMarketplaceNotOnTheListCannotMoveTheTokens() public forked {
        uint256 id = _reserve(alice);
        PlainMarket market = new PlainMarket();
        vm.prank(alice);
        spinners.setApprovalForAll(address(market), true);
        vm.expectRevert();
        market.take(spinners, alice, bob, id);
        assertEq(spinners.ownerOf(id), alice);
    }

    function test_aSmartWalletsOwnTransferIsRefusedByDefault_untilTheOwnerAllowsIt() public forked {
        ContractWallet wallet = new ContractWallet();
        uint256 id = _reserve(address(wallet));
        bytes memory send = abi.encodeCall(spinners.transferFrom, (address(wallet), bob, id));
        vm.expectRevert();
        wallet.execute(address(spinners), send);
        assertEq(spinners.ownerOf(id), address(wallet));

        // Only the collection's owner sets its policy in the validator.
        vm.prank(alice);
        vm.expectRevert();
        VALIDATOR.setRulesetOfCollection(address(spinners), 0, address(0), 0, ALLOW_OTC_FOR_SMART_WALLETS);
        vm.prank(owner);
        VALIDATOR.setRulesetOfCollection(address(spinners), 0, address(0), 0, ALLOW_OTC_FOR_SMART_WALLETS);
        wallet.execute(address(spinners), send);
        assertEq(spinners.ownerOf(id), bob);
    }

    function test_aTransferStillMakesTheSpinnerInactive() public forked {
        uint256 id = _reserve(alice);
        vm.prank(alice);
        spinners.activate(id); // free: no fee is set
        assertTrue(spinners.isActive(id));
        vm.prank(alice);
        spinners.transferFrom(alice, bob, id);
        assertFalse(spinners.isActive(id));
    }

    function test_aSpinnerWhoseWalletIsLockedCannotChangeHandsUntilTheLockEnds() public forked {
        uint256 id = _reserve(alice);
        assertFalse(spinners.walletLocked(id), "no wallet yet: not locked");
        address wallet = ITokenboundRegistry(REGISTRY).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), id);
        vm.prank(alice);
        ITokenboundLock(wallet).lock(block.timestamp + 1 days);
        assertTrue(spinners.walletLocked(id));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Spinners.WalletLocked.selector, id));
        spinners.transferFrom(alice, bob, id);
        // Nor through an operator (a marketplace's sale).
        PlainMarket market = new PlainMarket();
        vm.prank(alice);
        spinners.setApprovalForAll(address(market), true);
        vm.expectRevert(abi.encodeWithSelector(Spinners.WalletLocked.selector, id));
        market.take(spinners, alice, bob, id);

        vm.warp(block.timestamp + 1 days + 1);
        assertFalse(spinners.walletLocked(id));
        vm.prank(alice);
        spinners.transferFrom(alice, bob, id);
        assertEq(spinners.ownerOf(id), bob);
    }
}

