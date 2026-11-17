// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {SpinBotGuard, IERC6551Registry} from "../../src/bots/SpinBotGuard.sol";
import {UniswapAdapter} from "../../src/bots/adapters/UniswapAdapter.sol";
import {HookList} from "../../src/bots/HookList.sol";
import {IPonsFactory} from "../../src/bots/adapters/PonsAdapter.sol";
import {Routes} from "../../src/bots/Routes.sol";
import {PonsLaunchAdapter, IPonsLaunchFactory} from "../../src/bots/adapters/PonsLaunchAdapter.sol";
import {TorchLaunchAdapter, ITorchLaunchFactory} from "../../src/bots/adapters/TorchLaunchAdapter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {Spinners} from "../../src/collection/Spinners.sol";
import {IPonsCurve} from "../../src/interfaces/IPonsCurve.sol";
import {FeeSplitter} from "../../src/fees/FeeSplitter.sol";
import {
    SpinnerCreatorVaults,
    SpinnerCreatorVault,
    ITorchCreatorRouter,
    ITorchCreatorFactory,
    IPonsCreatorEscrow
} from "../../src/bots/SpinnerCreatorVaults.sol";

interface ITokenboundPermissions {
    function setPermissions(address[] calldata callers, bool[] calldata permissions) external;
}

interface IAccountExecute {
    function execute(address to, uint256 value, bytes calldata data, uint8 operation) external payable returns (bytes memory);
}

interface IVenueAdapterView {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    struct Route {
        address token;
        bytes32 id;
        bool open;
    }

    function plan(address account, bytes calldata params) external view returns (Call[] memory calls, Route memory route);
}

interface IPonsCurveState {
    function readyToGraduate() external view returns (bool);
}

interface ITorchFeeRouter {
    function creatorOf(address token) external view returns (address);
    function claim(address token) external;
    function transferCreator(address token, address to) external;
    function setPayoutWallet(address token, address wallet) external;
}

interface IRegistryCreateAccount {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

/// The parts of TorchFactory (Sourcify, exact match) that a launch needs.
interface ITorchFactory {
    struct PositionSpec {
        int24 tickLower;
        int24 tickUpper;
        uint16 supplyBps;
    }

    struct Split {
        uint16 creatorBps;
        uint16 burnBps;
        uint16 holdersBps;
        uint16 liquidityBps;
    }

    struct LaunchParams {
        string name;
        string symbol;
        string contractURI;
        uint256 supply;
        uint256 buyTaxBps;
        uint24 lpFee;
        int24 startingTick;
        int24 tickSpacing;
        PositionSpec[] positions;
        uint256 devBuyAmount;
        uint256 antiSnipeSeconds;
        Split split;
        bytes32 salt;
        address quote;
    }

    function launch(LaunchParams calldata p) external payable returns (address token);
    function initCodeHash(LaunchParams calldata p) external view returns (bytes32);
    function tokenDeployer() external view returns (address);
    function feeRouter() external view returns (address);
}

interface IPonsFactoryView {
    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
    function launchFee() external view returns (uint256);
    function feeEscrow() external view returns (address);
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
    function graduate(address token) external;
    function createGraduatedPool(address token) external returns (uint256 positionId);
}

/**
 * Launchpads on a fork of Robinhood Chain. Torch: a Torch pool is a hookless
 * Uniswap V4 pool against native ETH, so the guard trades it through
 * UniswapAdapter as it is; the token's buy tax is taken as the tokens leave
 * the pool, after the router has checked its minimum; sells are not taxed.
 * Launches: the guard launches on Pons and Torch from a Spinner's account,
 * which is the creator, with its ETH counted against the holder's limits.
 *
 *   RPC_URL=<archive rpc> npm run test
 */
contract LaunchpadsFork is Test {
    IERC6551Registry constant REGISTRY = IERC6551Registry(0x000000006551c19487814612e58FE06813775758);
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    uint256 constant PINNED_BLOCK = 93330000;

    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    ITorchFactory constant FACTORY = ITorchFactory(0x7891eA889899928aFE637e4Cca8106188427776a);
    /// $TORCH, launched on Torch: 2% buy tax.
    address constant TORCH = 0x000050E18ffa3F8F7aD170Eb9CeF160eb3Ed1111;
    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;
    bytes32 constant BUY_TAX_PAID = keccak256("BuyTaxPaid(address,address,uint256,uint256)");

    IPonsFactoryView constant PONS = IPonsFactoryView(0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e);
    bytes32 constant PONS_LAUNCHED = keccak256("TokenLaunched(address,address,address,address,uint256,uint256)");
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;

    SpinBotGuard guard;
    UniswapAdapter uni;
    PonsLaunchAdapter ponsLaunch;
    TorchLaunchAdapter torchLaunch;
    SpinnerCreatorVaults vaults;
    address account;
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address holder = makeAddr("holder");
    address creator = makeAddr("creator");

    function setUp() public {
        string memory rpc = vm.envOr("RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // every test below skips
        vm.createSelectFork(rpc, PINNED_BLOCK);
        vm.etch(0x000000000000000000000000000000000000006C, "");

        Spinners spinners = new Spinners("Spinners", "SPIN", 7777, admin, payable(treasury), 500, "ipfs://art/", address(REGISTRY), ACCOUNT_V3);
        vm.prank(admin);
        spinners.setMintOpen(true);
        vm.startPrank(holder);
        spinners.mint(1);
        spinners.activate(1);
        vm.stopPrank();
        account = IRegistryCreateAccount(address(REGISTRY)).createAccount(ACCOUNT_V3, bytes32(0), block.chainid, address(spinners), 1);
        vm.deal(account, 1 ether);

        guard = new SpinBotGuard(REGISTRY, ACCOUNT_V3, address(spinners), admin, treasury, 50, 1 gwei, 0.001 ether, 110_000, 80_000);
        uni = new UniswapAdapter(UNIVERSAL_ROUTER, PERMIT2, WETH, IPonsFactory(address(PONS)), PONS_HOOK, admin, new HookList(new address[](0)));
        vaults = new SpinnerCreatorVaults(payable(treasury), 50);
        vaults.setImplementation(
            address(
                new SpinnerCreatorVault(
                    vaults,
                    ITorchCreatorRouter(FACTORY.feeRouter()),
                    ITorchCreatorFactory(address(FACTORY)),
                    IPonsFactory(address(PONS)),
                    IPonsCreatorEscrow(PONS.feeEscrow())
                )
            )
        );
        ponsLaunch = new PonsLaunchAdapter(IPonsLaunchFactory(address(PONS)), vaults);
        torchLaunch = new TorchLaunchAdapter(ITorchLaunchFactory(address(FACTORY)), vaults);
        vm.startPrank(admin);
        guard.setOperator(operator, true);
        guard.addVenue(address(uni));
        guard.addVenue(address(ponsLaunch));
        guard.addVenue(address(torchLaunch));
        vm.stopPrank();

        vm.startPrank(holder);
        address[] memory callers = new address[](1);
        callers[0] = address(guard);
        bool[] memory perms = new bool[](1);
        perms[0] = true;
        ITokenboundPermissions(account).setPermissions(callers, perms);
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

    function _params(address token, bool buy, uint256 amountIn, uint256 minOut) internal pure returns (bytes memory) {
        UniswapAdapter.Params memory p;
        p.v4 = true;
        p.buy = buy;
        p.token = token;
        p.fee = FEE;
        p.tickSpacing = SPACING;
        p.amountIn = amountIn;
        p.minOut = minOut;
        return abi.encode(p);
    }

    /// Buys `eth` of `token` for the account; returns the tokens received and the tax taken from the pool's output.
    function _buy(address token, uint256 eth, uint256 minOut) internal returns (uint256 received, uint256 tax) {
        uint256 before = IERC20(token).balanceOf(account);
        vm.recordLogs();
        vm.prank(operator);
        guard.trade(account, uni, _params(token, true, eth, minOut));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == token && logs[i].topics[0] == BUY_TAX_PAID) {
                (uint256 creatorCut, uint256 torchCut) = abi.decode(logs[i].data, (uint256, uint256));
                tax += creatorCut + torchCut;
            }
        }
        received = IERC20(token).balanceOf(account) - before;
    }

    /// A Degen launch (1 ETH starting market cap) as Torch's app sends it: a 2% tax, 30 s of anti-snipe.
    function _launch() internal returns (address token) {
        ITorchFactory.LaunchParams memory p = _preset(-207240, -184200, -161160, 30);
        p.salt = _mine(p, creator);
        vm.prank(creator);
        token = FACTORY.launch(p);
        assertEq(uint16(uint160(token)), 0x1111);
    }

    /// Torch's three-range shape from a starting tick: 45 / 30 / 25% of the supply, the last range to the ceiling.
    function _preset(int24 start, int24 second, int24 third, uint256 antiSnipe) internal pure returns (ITorchFactory.LaunchParams memory p) {
        p.name = "Fork Test";
        p.symbol = "FORK";
        p.contractURI = "ipfs://fork-test";
        p.supply = 1e27;
        p.buyTaxBps = 200;
        p.lpFee = FEE;
        p.startingTick = start;
        p.tickSpacing = SPACING;
        p.positions = new ITorchFactory.PositionSpec[](3);
        p.positions[0] = ITorchFactory.PositionSpec(start, second, 4500);
        p.positions[1] = ITorchFactory.PositionSpec(second, third, 3000);
        p.positions[2] = ITorchFactory.PositionSpec(third, -78240, 2500);
        p.antiSnipeSeconds = antiSnipe;
        p.split = ITorchFactory.Split(10_000, 0, 0, 0);
    }

    /// The token's address must end in 1111: CREATE2 in the token deployer, salted with (launcher, salt).
    function _mine(ITorchFactory.LaunchParams memory p, address launcher) internal view returns (bytes32) {
        bytes32 code = FACTORY.initCodeHash(p);
        address deployer = FACTORY.tokenDeployer();
        uint256 free;
        assembly {
            free := mload(0x40)
        }
        for (uint256 s;; s++) {
            bytes32 salted = keccak256(abi.encode(launcher, bytes32(s)));
            address at = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salted, code)))));
            if (uint16(uint160(at)) == 0x1111) return bytes32(s);
            // Each try's encodings are scratch: reuse their memory, or 65,536 tries grow it past the gas limit.
            assembly {
                mstore(0x40, free)
            }
        }
    }

    function test_aSpinnersWalletLaunchesWithEachPresetAndIsTheCreator() public forked {
        ITorchFactory.LaunchParams[3] memory presets = [
            _preset(-207240, -184200, -161160, 30), // Degen
            _preset(-198060, -175080, -152040, 15), // Launch
            _preset(-191160, -168120, -145080, 15) // Steady
        ];
        ITorchFeeRouter router = ITorchFeeRouter(FACTORY.feeRouter());
        for (uint256 i; i < presets.length; i++) {
            ITorchFactory.LaunchParams memory p = presets[i];
            // The token's address depends on its parameters: two launches alike would land at one address.
            p.name = string.concat("Fork Test ", vm.toString(i));
            p.devBuyAmount = 0.01 ether;
            p.salt = _mine(p, account);
            uint256 ethBefore = account.balance;
            vm.prank(holder);
            bytes memory ret = IAccountExecute(account).execute(address(FACTORY), p.devBuyAmount, abi.encodeCall(ITorchFactory.launch, (p)), 0);
            address token = abi.decode(ret, (address));
            assertEq(uint16(uint160(token)), 0x1111);
            assertEq(router.creatorOf(token), account, "the Spinner is the creator");
            assertEq(account.balance, ethBefore - 0.01 ether, "the dev buy came from the Spinner's wallet");
            assertGt(IERC20(token).balanceOf(account), 0, "and its tokens are there, untaxed");

            // Someone buys; the creator's claim goes through from the account (the fees arrive as the keepers convert them).
            _buy(token, 0.02 ether, 1);
            vm.prank(holder);
            IAccountExecute(account).execute(address(router), 0, abi.encodeCall(ITorchFeeRouter.claim, (token)), 0);
        }
    }

    function test_aTorchTokenTradesThroughTheUniswapAdapter() public forked {
        uint256 ethBefore = account.balance;
        (uint256 received, uint256 tax) = _buy(TORCH, 0.05 ether, 1);
        assertGt(received, 0, "bought TORCH into the account");
        assertApproxEqRel(tax * 10_000 / (received + tax), 200, 0.01e18, "a 2% buy tax, taken from the pool's output");
        assertEq(account.balance, ethBefore - 0.05 ether - 0.00025 ether, "spent the buy plus the 0.5% fee");

        address router = FACTORY.feeRouter();
        uint256 routerBefore = IERC20(TORCH).balanceOf(router);
        vm.prank(operator);
        guard.trade(account, uni, _params(TORCH, false, received, 1));
        assertEq(IERC20(TORCH).balanceOf(account), 0, "sold it all");
        assertEq(IERC20(TORCH).balanceOf(router), routerBefore, "no tax on the sale");
        // The 2% tax, 0.3% each way in the pool, 0.5% each way to the treasury, and the spread.
        assertGt(account.balance, ethBefore - 0.0025 ether, "ETH back, less the tax and fees");
        assertEq(address(uni).balance, 0, "the adapter holds nothing");
    }

    function test_aBuyDuringAntiSnipePays80PercentAndTheMinimumIsBeforeTheTax() public forked {
        address token = _launch();
        uint256 snap = vm.snapshotState();
        (uint256 received, uint256 tax) = _buy(token, 0.01 ether, 1);
        uint256 poolOut = received + tax;
        assertApproxEqRel(tax * 10_000 / poolOut, 8_000, 0.001e18, "80% at launch");

        // The router checks its minimum against the pool's output, before the tax: the whole of it passes.
        vm.revertToState(snap);
        (uint256 again,) = _buy(token, 0.01 ether, poolOut);
        assertEq(again, received, "a minimum of the pre-tax output is met");
        vm.revertToState(snap);
        vm.prank(operator);
        vm.expectRevert();
        guard.trade(account, uni, _params(token, true, 0.01 ether, poolOut + 1));

        // Half-way through the 30 s, then after it: the tax falls to the token's own 2%.
        vm.revertToState(snap);
        uint256 launchedAt = block.timestamp;
        vm.warp(launchedAt + 15);
        (received, tax) = _buy(token, 0.01 ether, 1);
        assertApproxEqRel(tax * 10_000 / (received + tax), 4_100, 0.001e18, "8000 - 7800 * 15 / 30");
        vm.warp(launchedAt + 30);
        (received, tax) = _buy(token, 0.01 ether, 1);
        assertApproxEqRel(tax * 10_000 / (received + tax), 200, 0.01e18, "the token's own rate");
    }

    // ── Launches by the bot ─────────────────────────────────────────────

    function _ponsParams(uint256 devBuy) internal view returns (PonsLaunchAdapter.Params memory p) {
        p.name = "Bot Launch";
        p.symbol = "BOTL";
        p.logo = "ipfs://bafkreiec6gnqaqjw7o5rd5sh4xkaysfy3v3l6ybreaavbr6ulfflsicvfu";
        p.description = "Launched by a Spinner's bot.";
        p.socials.website = "https://spin.trading";
        p.creatorTaxBps = 200;
        p.salt = keccak256(abi.encode("pons", block.timestamp, devBuy));
        p.devBuy = devBuy;
        p.minTokensOut = 1;
    }

    /// The token a launch made, from the launchpad's TokenLaunched (the token is its first topic).
    function _launched(address launchpad, bytes32 topic) internal returns (address) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == launchpad && logs[i].topics[0] == topic) return address(uint160(uint256(logs[i].topics[1])));
        }
        revert("no launch");
    }

    function test_theBotLaunchesOnPonsAsTheSpinner() public forked {
        uint256 fee = PONS.launchFee();
        for (uint256 devBuy; devBuy <= 0.01 ether; devBuy += 0.01 ether) {
            uint256 ethBefore = account.balance;
            vm.recordLogs();
            vm.prank(operator);
            guard.trade(account, ponsLaunch, abi.encode(_ponsParams(devBuy)));
            address token = _launched(address(PONS), PONS_LAUNCHED);
            IPonsFactoryView.LaunchedToken memory t = PONS.getLaunchedToken(token);
            assertEq(t.deployer, account, "the Spinner launched it");
            assertEq(t.creatorFeeRecipient, vaults.vaultOf(account), "its creator fees go to the Spinner's vault");
            assertEq(t.pairToken, address(0), "against ETH");
            assertEq(t.creatorTaxBps, 200);
            uint256 spent = fee + devBuy;
            assertEq(account.balance, ethBefore - spent - spent * 50 / 10_000, "the launch fee and the dev buy, and our 0.5%");
            if (devBuy > 0) assertGt(IERC20(token).balanceOf(account), 0, "the dev buy's tokens are the Spinner's");
            else assertEq(IERC20(token).balanceOf(account), 0);
        }
    }

    function test_aPonsLaunchCannotSendTheCreatorFeesElsewhere() public forked {
        // The adapter's params have no recipient: whatever the operator sends, the account is the recipient.
        PonsLaunchAdapter.Params memory p = _ponsParams(0.01 ether);
        (IVenueAdapterView.Call[] memory calls,) = IVenueAdapterView(address(ponsLaunch)).plan(account, abi.encode(p));
        assertEq(calls.length, 1);
        assertEq(calls[0].value, PONS.launchFee() + 0.01 ether);
        (IPonsLaunchFactory.TokenParams memory t, address recipient) = this.launchAndBuyArgs(calls[0].data);
        assertEq(t.creatorFeeRecipient, vaults.vaultOf(account), "the creator fees go to the account's vault");
        assertEq(recipient, account, "and so do the dev buy's tokens");
    }

    /// The launch-and-buy call's token params and recipient.
    function launchAndBuyArgs(bytes calldata data) external pure returns (IPonsLaunchFactory.TokenParams memory t, address recipient) {
        (t,,,,, recipient,) = abi.decode(data[4:], (IPonsLaunchFactory.TokenParams, uint256, address, uint256, uint256, address, address[]));
    }

    function test_theBotLaunchesOnTorchAsTheSpinner() public forked {
        ITorchFactory.LaunchParams memory p = _preset(-198060, -175080, -152040, 15);
        p.name = "Bot Torch";
        p.devBuyAmount = 0.02 ether;
        p.salt = _mine(p, account);
        uint256 ethBefore = account.balance;
        vm.recordLogs();
        vm.prank(operator);
        guard.trade(account, torchLaunch, abi.encode(p));
        address token = _launched(address(FACTORY), keccak256("TokenLaunched(address,address,bytes32,uint256,uint24,uint256,(uint16,uint16,uint16,uint16),string,address)"));
        assertEq(ITorchFeeRouter(FACTORY.feeRouter()).creatorOf(token), vaults.vaultOf(account), "the Spinner's vault is the creator, from the launch");
        assertGt(IERC20(token).balanceOf(account), 0, "the dev buy's tokens are the Spinner's");
        assertEq(account.balance, ethBefore - 0.02 ether - 0.0001 ether, "the dev buy and our 0.5%");

        // The dev buy is credited to the token's own pool, so the bot can sell it there.
        uint256 tokens = IERC20(token).balanceOf(account);
        assertEq(torchLaunch.tokenOf(account, abi.decode(abi.encode(p), (ITorchLaunchFactory.LaunchParams))), token, "the adapter knew the token's address");
        bytes32 route = Routes.uniswap(true, FEE, SPACING, address(0), address(0), 0, 0, address(0));
        assertEq(guard.credit(account, token, route), tokens, "the dev buy is credited");
        vm.warp(block.timestamp + 1 hours);
        UniswapAdapter.Params memory s;
        s.v4 = true;
        s.token = token;
        s.fee = FEE;
        s.tickSpacing = SPACING;
        s.amountIn = tokens;
        s.minOut = 1;
        vm.prank(operator);
        guard.trade(account, uni, abi.encode(s));
        assertEq(IERC20(token).balanceOf(account), 0, "sold in its own pool");
    }

    /// A Torch launch by the bot, and a crowd's buys after it (their tax is the creator's fees); returns the token.
    function _torchLaunchWithTrades() internal returns (address token) {
        ITorchFactory.LaunchParams memory p = _preset(-198060, -175080, -152040, 15);
        p.name = "Vault Torch";
        p.salt = _mine(p, account);
        vm.recordLogs();
        vm.prank(operator);
        guard.trade(account, torchLaunch, abi.encode(p));
        token = _launched(address(FACTORY), keccak256("TokenLaunched(address,address,bytes32,uint256,uint24,uint256,(uint16,uint16,uint16,uint16),string,address)"));
        vm.warp(block.timestamp + 1 hours);
        for (uint256 i; i < 3; i++) _buy(token, 0.05 ether, 1);
    }

    function test_aTorchTokensCreatorFeesAlwaysReachTheSpinnerLessOurHalfPercent() public forked {
        address token = _torchLaunchWithTrades();
        ITorchFeeRouter router = ITorchFeeRouter(FACTORY.feeRouter());
        SpinnerCreatorVault vault = SpinnerCreatorVault(payable(vaults.vaultOf(account)));

        // The holder cannot move the creator role or where its fees are paid: the vault holds it.
        vm.startPrank(holder);
        vm.expectRevert();
        IAccountExecute(account).execute(address(router), 0, abi.encodeCall(ITorchFeeRouter.transferCreator, (token, holder)), 0);
        vm.expectRevert();
        IAccountExecute(account).execute(address(router), 0, abi.encodeCall(ITorchFeeRouter.setPayoutWallet, (token, holder)), 0);
        vm.stopPrank();

        // Anyone can claim; the fees (here the creator's share in kind) go to the Spinner, 0.5% to the treasury.
        uint256 before = IERC20(token).balanceOf(account);
        vm.prank(makeAddr("anyone"));
        vault.claimTorchTokens(token);
        uint256 toAccount = IERC20(token).balanceOf(account) - before;
        uint256 toTreasury = IERC20(token).balanceOf(treasury);
        assertGt(toAccount, 0, "the creator's fees reached the Spinner");
        assertEq(toTreasury, (toAccount + toTreasury) * 50 / 10_000, "0.5% to the treasury");
        assertEq(IERC20(token).balanceOf(address(vault)), 0, "nothing stays in the vault");
        vault.claimTorch(token); // the ETH share (none until keepers convert it): no revert

        // The links are the holder's to change, through the Spinner's account.
        vm.prank(holder);
        IAccountExecute(account).execute(address(vault), 0, abi.encodeCall(SpinnerCreatorVault.setTorchMetadata, (token, "ipfs://new-links")), 0);
        vm.expectRevert(SpinnerCreatorVault.NotAccount.selector);
        vault.setTorchMetadata(token, "ipfs://not-yours");
    }

    function test_tradingFeesAndCreatorFeeSharesReachTheSplitterWhichSplitsThem70To30() public forked {
        address burnWallet = makeAddr("burnWallet");
        FeeSplitter splitter = new FeeSplitter(payable(treasury), payable(burnWallet), 7_000);
        vm.prank(admin);
        guard.setTreasury(address(splitter));
        vaults.setTreasury(payable(address(splitter)));

        // A launch through the guard: its 0.5% trading fee goes to the splitter.
        vm.recordLogs();
        vm.prank(operator);
        guard.trade(account, ponsLaunch, abi.encode(_ponsParams(0)));
        address token = _launched(address(PONS), PONS_LAUNCHED);
        uint256 tradingFee = address(splitter).balance;
        assertGt(tradingFee, 0, "the trading fee reached the splitter");

        // A claim of the launch's creator fees: the protocol's 0.5% share goes to the splitter too.
        address crowd = makeAddr("crowd");
        vm.deal(crowd, 1 ether);
        vm.startPrank(crowd);
        for (uint256 i; i < 3; i++) IPonsCurve(PONS.getLaunchedToken(token).curve).buy{value: 0.1 ether}(0.1 ether, 1, crowd);
        vm.stopPrank();
        SpinnerCreatorVault vault = SpinnerCreatorVault(payable(vaults.deploy(account)));
        vault.sweepPons(token);
        vault.claimPons();
        uint256 collected = address(splitter).balance;
        assertGt(collected, tradingFee, "the creator fee share reached the splitter");
        assertEq(treasury.balance, 0, "nothing went past it");

        // Anyone distributes: 70% to the burn wallet, 30% to the treasury.
        vm.prank(makeAddr("anyone"));
        splitter.distribute(address(0));
        assertEq(burnWallet.balance, collected * 7_000 / 10_000);
        assertEq(treasury.balance, collected - burnWallet.balance);
    }

    function test_aPonsTokensCreatorFeesAlwaysReachTheSpinnerLessOurHalfPercent() public forked {
        vm.recordLogs();
        vm.prank(operator);
        guard.trade(account, ponsLaunch, abi.encode(_ponsParams(0)));
        address token = _launched(address(PONS), PONS_LAUNCHED);
        address vault = vaults.vaultOf(account);
        IPonsFactoryView.LaunchedToken memory t = PONS.getLaunchedToken(token);

        // The holder is the launch's deployer, not its fee recipient: it cannot move the fees.
        vm.prank(holder);
        vm.expectRevert();
        IAccountExecute(account).execute(address(PONS), 0, abi.encodeCall(IPonsFactoryView.transferCreatorFeeRecipient, (token, holder)), 0);

        // A crowd buys on the curve: its 2% creator tax is the vault's, which Pons holds until it is claimed.
        address crowd = makeAddr("crowd");
        vm.deal(crowd, 1 ether);
        vm.startPrank(crowd);
        for (uint256 i; i < 3; i++) IPonsCurve(t.curve).buy{value: 0.1 ether}(0.1 ether, 1, crowd);
        vm.stopPrank();
        // Pons keeps them in the curve until a sweep (its operator's, or the vault's for anyone).
        vaults.deploy(account);
        SpinnerCreatorVault(payable(vault)).sweepPons(token);
        uint256 owed = IPonsCreatorEscrow(PONS.feeEscrow()).balanceOf(vault);
        assertGt(owed, 0, "creator fees owed to the vault");

        // Anyone deploys the vault and claims: 0.5% to the treasury, the rest to the Spinner's account.
        uint256 accountBefore = account.balance;
        uint256 treasuryBefore = treasury.balance;
        vm.startPrank(makeAddr("anyone"));
        SpinnerCreatorVault(payable(vault)).claimPons();
        vm.stopPrank();
        assertEq(treasury.balance - treasuryBefore, owed * 50 / 10_000);
        assertEq(account.balance - accountBefore, owed - owed * 50 / 10_000);
        assertEq(vault.balance, 0);
    }

    function test_aGraduatedPonsTokenKeepsTheVaultAsItsCreatorAndItsPoolCanBeSwept() public forked {
        vm.recordLogs();
        vm.prank(operator);
        guard.trade(account, ponsLaunch, abi.encode(_ponsParams(0)));
        address token = _launched(address(PONS), PONS_LAUNCHED);
        IPonsFactoryView.LaunchedToken memory t = PONS.getLaunchedToken(token);
        address crowd = makeAddr("crowd");
        vm.deal(crowd, 200 ether);
        vm.warp(block.timestamp + 1 hours); // past the launch's anti-snipe tax
        vm.startPrank(crowd);
        // Buys fill the curve (a buy past its end is refunded); then anyone moves it to its pool.
        // The buy that sells the curve out moves it on (or leaves it ready to): then anyone completes the move.
        for (uint256 i; i < 100 && PONS.getLaunchedToken(token).phase == 0 && !IPonsCurveState(t.curve).readyToGraduate(); i++) {
            IPonsCurve(t.curve).buy{value: 1 ether}(1 ether, 1, crowd);
        }
        vm.stopPrank();
        if (PONS.getLaunchedToken(token).phase == 0) PONS.graduate(token);
        if (PONS.getLaunchedToken(token).phase == 1) PONS.createGraduatedPool(token);
        t = PONS.getLaunchedToken(token);
        assertEq(t.phase, 2, "graduated");
        assertEq(t.creatorFeeRecipient, vaults.vaultOf(account), "the vault is still the creator in its pool");
        SpinnerCreatorVault vault = SpinnerCreatorVault(payable(vaults.deploy(account)));
        vault.sweepPons(token); // a sweep Pons leaves to its operator does not revert
        uint256 owed = IPonsCreatorEscrow(PONS.feeEscrow()).balanceOf(address(vault));
        uint256 before = account.balance;
        vault.claimPons();
        assertEq(account.balance - before, owed - owed * 50 / 10_000, "whatever it was owed reached the Spinner, less 0.5%");
    }

    function test_launchesCountAgainstTheHoldersLimits() public forked {
        // A trade at most 0.2 ETH (setUp): a dev buy above it is refused, as a buy would be.
        vm.prank(operator);
        vm.expectRevert();
        guard.trade(account, ponsLaunch, abi.encode(_ponsParams(0.3 ether)));

        ITorchFactory.LaunchParams memory p = _preset(-207240, -184200, -161160, 30);
        p.quote = TORCH;
        vm.expectRevert(TorchLaunchAdapter.NotEthPaired.selector);
        torchLaunch.plan(account, abi.encode(p));
    }
}
