// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SpinBotGuard, IERC6551Registry} from "../../src/bots/SpinBotGuard.sol";
import {UniswapAdapter} from "../../src/bots/adapters/UniswapAdapter.sol";
import {HookList} from "../../src/bots/HookList.sol";
import {IPonsFactory} from "../../src/bots/adapters/PonsAdapter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {Spinners} from "../../src/collection/Spinners.sol";

interface ITokenboundPermissionsReview {
    function setPermissions(address[] calldata callers, bool[] calldata permissions) external;
}

interface IRegistryCreateAccountReview {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

/**
 * The hooks reviewed on 2026-11-16, on a fork of Robinhood Chain: a buy of 0.05 ETH and a sale of
 * all of it through the guard and UniswapAdapter, in one pool behind each hook, with the hook on
 * the HookList. Each round trip must bring back at least 88% of the ETH (the hooks' own fees are
 * 0 to 3% a side, with the pool's fee and our 0.5% a side).
 *
 *   RPC_URL=<archive rpc> forge test --match-contract HookReviewFork -vv
 */
contract HookReviewFork is Test {
    IERC6551Registry constant REGISTRY = IERC6551Registry(0x000000006551c19487814612e58FE06813775758);
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    uint256 constant PINNED_BLOCK = 115890000;

    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint24 constant DYNAMIC_FEE = 0x800000;
    /// The V4 ETH / USDG pool the adapter goes through for a USDG pool (Fables, tick spacing 10).
    address constant FABLES_ETH_USDG = 0x06a889870C8f83640D6816319f72e2aA579b6080;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    IPonsFactory constant PONS_FACTORY = IPonsFactory(0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e);

    /// The hooks under review.
    address constant PONS_HOOK_EARLIER = 0x332F85E7e323214B2D55286414B059ebB1F2A044;
    address constant RYFT_HOOK = 0x56B6f9D5aFE2335DcBB974777357088E38e620Cc;
    address constant UMIA_HOOK = 0xbEA11B032BfB6D7E20b9FD975C0211ad81A03A80;
    address constant LAUNCH_FEE_HOOK = 0x720e649549F7BC2118aCBA9F4C9ae6fCC7586080;
    address constant INCOME_HOOK = 0x4adbFa936020fb330587EE1862478316Da5ba0CC;
    address constant ORYNTH_HOOK = 0x953391a2DDf7E8437FeB878FDF2C6f325Fbf00CC;
    address constant PRL_HOOK = 0x1a6675Bb1B8D878c51A98baAd0dBC97487972044;

    /// One token behind each.
    address constant BRODIE = 0x737054bd706cba68eaF4661411FeDE5F6C2952e5;
    address constant RYFT = 0xb0007D59fE4050A1636c2fa19038973d16481337;
    address constant SLOP = 0xfeb4E36FA4a2A494FF25ae4a63491e4c584A67AE;
    address constant V4TOKEN = 0xC60bA256B44334A0Cd2C7242E98B88f031abB006;
    address constant INCOME = 0x29E56F7809f387C6FCEdc7E634054840C4b04C4C;
    address constant GLOAM = 0xDcD885F5c60b3aD49F6D58718696417314e8724d;
    address constant PEARL = 0xA17383e0dAd8c6Ac68F0ed65891eeb27a182f2aF;

    SpinBotGuard guard;
    UniswapAdapter uni;
    Spinners spinners;
    address account;
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address holder = makeAddr("holder");

    function setUp() public {
        string memory rpc = vm.envOr("RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // every test below skips
        vm.createSelectFork(rpc, PINNED_BLOCK);
        // A fork does not run Arbitrum's precompiles; empty code there reads as no parent-chain fee.
        vm.etch(0x000000000000000000000000000000000000006C, "");

        spinners = new Spinners("Spinners", "SPIN", 7777, admin, payable(treasury), 500, "ipfs://art/", address(REGISTRY), ACCOUNT_V3);
        vm.prank(admin);
        spinners.setMintOpen(true);
        vm.startPrank(holder);
        spinners.mint(1);
        spinners.activate(1);
        vm.stopPrank();
        account = IRegistryCreateAccountReview(address(REGISTRY)).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), 1);
        vm.deal(account, 1 ether);

        guard = new SpinBotGuard(REGISTRY, ACCOUNT_V3, address(spinners), admin, treasury, 50, 1 gwei, 0.001 ether, 110_000, 80_000);
        address[] memory hooks = new address[](8);
        hooks[0] = FABLES_ETH_USDG;
        hooks[1] = PONS_HOOK_EARLIER;
        hooks[2] = RYFT_HOOK;
        hooks[3] = UMIA_HOOK;
        hooks[4] = LAUNCH_FEE_HOOK;
        hooks[5] = INCOME_HOOK;
        hooks[6] = ORYNTH_HOOK;
        hooks[7] = PRL_HOOK;
        vm.prank(admin);
        HookList hookList = new HookList(hooks);
        uni = new UniswapAdapter(UNIVERSAL_ROUTER, PERMIT2, WETH, PONS_FACTORY, PONS_HOOK, admin, hookList);
        vm.startPrank(admin);
        guard.setOperator(operator, true);
        guard.addVenue(address(uni));
        vm.stopPrank();

        vm.startPrank(holder);
        address[] memory callers = new address[](1);
        callers[0] = address(guard);
        bool[] memory perms = new bool[](1);
        perms[0] = true;
        ITokenboundPermissionsReview(account).setPermissions(callers, perms);
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

    function _v4(address token, uint24 fee, int24 tickSpacing, address hooks) internal pure returns (UniswapAdapter.Params memory p) {
        p.v4 = true;
        p.token = token;
        p.fee = fee;
        p.tickSpacing = tickSpacing;
        p.hooks = hooks;
    }

    function _viaUsdg(UniswapAdapter.Params memory p) internal pure returns (UniswapAdapter.Params memory) {
        p.via = USDG;
        p.viaFee = DYNAMIC_FEE;
        p.viaTickSpacing = 10;
        p.viaHooks = FABLES_ETH_USDG;
        return p;
    }

    function _trade(UniswapAdapter.Params memory p, bool buy, uint256 amountIn) internal {
        p.buy = buy;
        p.amountIn = amountIn;
        p.minOut = 1;
        vm.prank(operator);
        guard.trade(account, uni, abi.encode(p));
    }

    /// Buys 0.05 ETH of the token, sells all of it, and says what share of the ETH came back.
    function _roundTrip(string memory name, UniswapAdapter.Params memory p) internal {
        uint256 ethBefore = account.balance;
        _trade(p, true, 0.05 ether);
        uint256 tokens = IERC20(p.token).balanceOf(account);
        assertGt(tokens, 0, "bought the token into the account");
        uint256 spent = ethBefore - account.balance;

        // A later block, as a bot's sale is: a hook must not need the buy's own block.
        vm.roll(block.number + 5);
        vm.warp(block.timestamp + 60);
        _trade(p, false, tokens);
        assertEq(IERC20(p.token).balanceOf(account), 0, "sold it all");
        assertEq(IERC20(USDG).balanceOf(account), 0, "no USDG left behind");
        uint256 back = account.balance - (ethBefore - spent);
        emit log_named_decimal_uint(string.concat(name, ": ETH back, % of what was spent"), back * 10_000 / spent, 2);
        assertGt(back * 100, spent * 88, "at least 88% of the ETH comes back");
    }

    function test_ponsEarlierHook() public forked {
        _roundTrip("BRODIE (Pons hook of the earlier factory)", _v4(BRODIE, 10_000, 200, PONS_HOOK_EARLIER));
    }

    function test_ryftHook() public forked {
        _roundTrip("RYFT (RyftPoolHook)", _v4(RYFT, 0, 60, RYFT_HOOK));
    }

    function test_umiaHook() public forked {
        _roundTrip("SLOP (UmiaHookV2, through USDG)", _viaUsdg(_v4(SLOP, 10_000, 60, UMIA_HOOK)));
    }

    function test_launchFeeHook() public forked {
        _roundTrip("V4 (ProgrammableLaunchFeeHook)", _v4(V4TOKEN, DYNAMIC_FEE, 60, LAUNCH_FEE_HOOK));
    }

    function test_incomeHook() public forked {
        _roundTrip("INCOME (IncomeMarketHook1000, through USDG)", _viaUsdg(_v4(INCOME, 0, 200, INCOME_HOOK)));
    }

    function test_orynthHook() public forked {
        _roundTrip("GLOAM (OrynthEthFeeHook)", _v4(GLOAM, 0, 200, ORYNTH_HOOK));
    }

    function test_prlHook() public forked {
        _roundTrip("PEARL (PrlUsdgFeeHook, through USDG)", _viaUsdg(_v4(PEARL, 10_000, 200, PRL_HOOK)));
    }
}
