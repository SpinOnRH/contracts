// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SpinBotGuard, IERC6551Registry} from "../../src/bots/SpinBotGuard.sol";
import {UniswapAdapter} from "../../src/bots/adapters/UniswapAdapter.sol";
import {HookList} from "../../src/bots/HookList.sol";
import {IPonsFactory} from "../../src/bots/adapters/PonsAdapter.sol";
import {IVenueAdapter} from "../../src/bots/IVenueAdapter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {Spinners} from "../../src/collection/Spinners.sol";

interface ITokenboundPermissionsFixed {
    function setPermissions(address[] calldata callers, bool[] calldata permissions) external;
}

interface IRegistryCreateAccountFixed {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

interface IPermit2AllowanceFixed {
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/**
 * UniswapAdapter sells of a token that fixes Permit2's allowance at the maximum
 * (a Solady ERC-20: its approve of Permit2 reverts unless it is the maximum), on a
 * fork of Robinhood Chain: the plan leaves the token's approval out, and sets and
 * resets only Permit2's. A token with a normal approval keeps both.
 *
 *   RPC_URL=<archive rpc> npm run test
 */
contract UniswapAdapterFixedPermit2Fork is Test {
    IERC6551Registry constant REGISTRY = IERC6551Registry(0x000000006551c19487814612e58FE06813775758);
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    uint256 constant PINNED_BLOCK = 107732111;

    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    IPonsFactory constant PONS_FACTORY = IPonsFactory(0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e);

    /// HOOKR: Permit2's allowance fixed at the maximum; V4 against native ETH, 0.25%, no hook.
    address constant HOOKR_TOKEN = 0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c;
    /// STONKBROKER: a normal approval; V4 against native ETH, 1%, no hook.
    address constant STONKBROKER = 0xe934e36A439C94017B64a3FecE66AF12099aBF50;

    SpinBotGuard guard;
    UniswapAdapter uni;
    address account;
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address holder = makeAddr("holder");

    function setUp() public {
        string memory rpc = vm.envOr("RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // every test below skips
        vm.createSelectFork(rpc, PINNED_BLOCK);
        vm.etch(0x000000000000000000000000000000000000006C, "");

        Spinners spinners =
            new Spinners("Spinners", "SPIN", 7777, admin, payable(treasury), 500, "ipfs://art/", address(REGISTRY), ACCOUNT_V3);
        vm.prank(admin);
        spinners.setMintOpen(true);
        vm.startPrank(holder);
        spinners.mint(1);
        spinners.activate(1);
        vm.stopPrank();
        account = IRegistryCreateAccountFixed(address(REGISTRY)).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), 1);
        vm.deal(account, 1 ether);

        guard = new SpinBotGuard(REGISTRY, ACCOUNT_V3, address(spinners), admin, treasury, 50, 1 gwei, 0.001 ether, 110_000, 80_000);
        uni = new UniswapAdapter(UNIVERSAL_ROUTER, PERMIT2, WETH, PONS_FACTORY, PONS_HOOK, admin, new HookList(new address[](0)));
        vm.startPrank(admin);
        guard.setOperator(operator, true);
        guard.addVenue(address(uni));
        vm.stopPrank();

        vm.startPrank(holder);
        address[] memory callers = new address[](1);
        callers[0] = address(guard);
        bool[] memory perms = new bool[](1);
        perms[0] = true;
        ITokenboundPermissionsFixed(account).setPermissions(callers, perms);
        guard.configure(account, SpinBotGuard.Limits(0.2 ether, 1 ether, uint64(block.timestamp + 30 days)));
        vm.stopPrank();
    }

    modifier forked() {
        if (address(guard) == address(0)) {
            emit log("skipped: set RPC_URL to run the fork tests");
            return;
        }
        _;
    }

    function _v4(address token, uint24 fee, int24 tickSpacing) internal pure returns (UniswapAdapter.Params memory p) {
        p.v4 = true;
        p.token = token;
        p.fee = fee;
        p.tickSpacing = tickSpacing;
    }

    function _trade(UniswapAdapter.Params memory p, bool buy, uint256 amountIn) internal {
        p.buy = buy;
        p.amountIn = amountIn;
        p.minOut = 1;
        vm.prank(operator);
        guard.trade(account, uni, abi.encode(p));
    }

    function _sellPlan(UniswapAdapter.Params memory p, uint256 amountIn) internal view returns (IVenueAdapter.Call[] memory calls) {
        p.buy = false;
        p.amountIn = amountIn;
        (calls,) = uni.plan(account, abi.encode(p));
    }

    function test_aTokenWithPermit2FixedAtTheMaximumIsSold() public forked {
        UniswapAdapter.Params memory p = _v4(HOOKR_TOKEN, 2500, 25);
        assertEq(IERC20(HOOKR_TOKEN).allowance(account, PERMIT2), type(uint256).max, "the token fixes Permit2's allowance");
        _trade(p, true, 0.01 ether);
        uint256 tokens = IERC20(HOOKR_TOKEN).balanceOf(account);
        assertGt(tokens, 0, "bought");

        IVenueAdapter.Call[] memory calls = _sellPlan(p, tokens);
        assertEq(calls.length, 3, "Permit2's approval, the swap and its reset only");
        assertEq(calls[0].target, PERMIT2);

        uint256 ethBefore = account.balance;
        _trade(p, false, tokens);
        assertEq(IERC20(HOOKR_TOKEN).balanceOf(account), 0, "sold it all");
        assertGt(account.balance, ethBefore, "ETH back in the account");
        (uint160 left,,) = IPermit2AllowanceFixed(PERMIT2).allowance(account, HOOKR_TOKEN, UNIVERSAL_ROUTER);
        assertEq(left, 0, "Permit2 approval reset");
    }

    function test_aTokenWithANormalApprovalKeepsBothApprovals() public forked {
        UniswapAdapter.Params memory p = _v4(STONKBROKER, 10_000, 200);
        _trade(p, true, 0.01 ether);
        uint256 tokens = IERC20(STONKBROKER).balanceOf(account);

        IVenueAdapter.Call[] memory calls = _sellPlan(p, tokens);
        assertEq(calls.length, 5, "the token's approval and its reset too");
        assertEq(calls[0].target, STONKBROKER);
        assertEq(calls[4].target, STONKBROKER);

        _trade(p, false, tokens);
        assertEq(IERC20(STONKBROKER).balanceOf(account), 0, "sold it all");
        assertEq(IERC20(STONKBROKER).allowance(account, PERMIT2), 0, "token approval reset");
    }
}
