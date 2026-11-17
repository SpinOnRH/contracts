// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC6551Registry, IERC6551Executable} from "../../src/bots/SpinBotGuard.sol";
import {Spinners} from "../../src/collection/Spinners.sol";

interface IRegistryCreate {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

/// The ERC-8004 identity registry, as deployed (v2.0.0).
interface IIdentityRegistry {
    struct MetadataEntry {
        string metadataKey;
        bytes metadataValue;
    }

    function register(string memory agentURI, MetadataEntry[] memory metadata) external returns (uint256 agentId);
    function ownerOf(uint256 agentId) external view returns (address);
    function tokenURI(uint256 agentId) external view returns (string memory);
    function getMetadata(uint256 agentId, string memory metadataKey) external view returns (bytes memory);
    function setAgentURI(uint256 agentId, string calldata newURI) external;
}

/**
 * A Spinner's agent identity on a fork of Robinhood Chain: the Spinner's
 * Tokenbound account registers itself with the deployed ERC-8004 identity
 * registry, in a call its holder signs, so the identity belongs to the
 * account and moves with the Spinner.
 *
 *   RPC_URL=<archive rpc> npm run test
 */
contract AgentIdentityFork is Test {
    IERC6551Registry constant REGISTRY = IERC6551Registry(0x000000006551c19487814612e58FE06813775758);
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    IIdentityRegistry constant IDENTITY = IIdentityRegistry(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
    uint256 constant PINNED_BLOCK = 88_300_000;

    Spinners spinners;
    address account;
    address admin = makeAddr("admin");
    address holder = makeAddr("holder");
    address buyer = makeAddr("buyer");
    string constant URI = "https://spin.trading/api/agents/1";

    function setUp() public {
        string memory rpc = vm.envOr("RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // every test below skips
        vm.createSelectFork(rpc, PINNED_BLOCK);
        require(address(IDENTITY).code.length > 0, "no identity registry at the pinned block");

        spinners = new Spinners("Spinners", "SPIN", 7777, admin, payable(admin), 500, "ipfs://art/", address(REGISTRY), ACCOUNT_V3);
        vm.prank(admin);
        spinners.setMintOpen(true);
        vm.prank(holder);
        spinners.mint(1);
        account = IRegistryCreate(address(REGISTRY)).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), 1);
    }

    modifier forked() {
        if (address(spinners) == address(0)) {
            emit log("skipped: set RPC_URL to run the fork tests");
            return;
        }
        _;
    }

    function _spinnerId() internal view returns (bytes memory) {
        return bytes(string.concat("eip155:4663/erc721:", vm.toString(address(spinners)), "/1"));
    }

    /// What the app asks the holder to sign: the account calls `register`.
    function _register(address as_) internal returns (uint256) {
        IIdentityRegistry.MetadataEntry[] memory meta = new IIdentityRegistry.MetadataEntry[](1);
        meta[0] = IIdentityRegistry.MetadataEntry("spinner", _spinnerId());
        bytes memory call = abi.encodeCall(IIdentityRegistry.register, (URI, meta));
        vm.prank(as_);
        return abi.decode(IERC6551Executable(account).execute(address(IDENTITY), 0, call, 0), (uint256));
    }

    function test_theSpinnerAccountOwnsItsAgent() public forked {
        uint256 agentId = _register(holder);
        assertEq(IDENTITY.ownerOf(agentId), account, "the account owns the identity");
        assertEq(IDENTITY.tokenURI(agentId), URI);
        assertEq(IDENTITY.getMetadata(agentId, "agentWallet"), abi.encodePacked(account), "its agent wallet is the account");
        assertEq(IDENTITY.getMetadata(agentId, "spinner"), _spinnerId(), "it names the Spinner");
    }

    function test_onlyTheHolderCanRegister() public forked {
        address stranger = makeAddr("stranger");
        IIdentityRegistry.MetadataEntry[] memory none;
        bytes memory call = abi.encodeCall(IIdentityRegistry.register, (URI, none));
        vm.prank(stranger);
        vm.expectRevert();
        IERC6551Executable(account).execute(address(IDENTITY), 0, call, 0);
    }

    function test_theAgentMovesWithTheSpinner() public forked {
        uint256 agentId = _register(holder);
        vm.prank(holder);
        spinners.transferFrom(holder, buyer, 1);

        bytes memory update = abi.encodeCall(IIdentityRegistry.setAgentURI, (agentId, "https://spin.trading/api/agents/1?v=2"));
        vm.prank(holder);
        vm.expectRevert();
        IERC6551Executable(account).execute(address(IDENTITY), 0, update, 0);

        vm.prank(buyer);
        IERC6551Executable(account).execute(address(IDENTITY), 0, update, 0);
        assertEq(IDENTITY.ownerOf(agentId), account, "still the account's");
        assertEq(IDENTITY.getMetadata(agentId, "agentWallet"), abi.encodePacked(account), "no transfer, so the agent wallet stays");
    }
}
