// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Swapper} from "./SwapFork.t.sol";
import {PrismMigration} from "../src/PrismMigration.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

interface IHookL {
    function seed(uint160, int24, int24, uint128) external returns (uint256);
    function renounceOwnership() external;
    function pokeFees() external;
    function accFeesPerShareETH() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function nftBalanceOf(address) external view returns (uint256);
    function pendingETH(address) external view returns (uint256);
    function pendingPRISM(address) external view returns (uint256);
    function claimMany(uint256[] calldata) external;
    function nftOwnerOf(uint256) external view returns (address);
}

/// The launch sequence actually planned: seed the pool, let it TRADE for a while so the protocol's
/// position converts PRISM into permanently-locked ETH, and only then wire the airdrop so holders can
/// claim. That ordering builds the bid before sellers arrive — but it means thousands of fee-shares
/// mint LATE, against an accumulator that is already nonzero. Nothing else in the suite covers that.
///
/// Two notes on why this is structured the way it is, both of which cost me time:
///  - `seed()` arms `forfeitNextCollection`, so the FIRST collection after seeding is deliberately
///    destroyed (it stops a first shareholder sweeping a pre-existing backlog). Measuring before
///    burning that off shows a zero accumulator and looks like a bug.
///  - the anti-JIT quarantine is keyed on TRANSIENT storage, and a whole forge test body is one
///    transaction — so shares minted inside the test body are quarantined and credit nothing. The
///    trading window therefore has to happen in `setUp`, which is a separate transaction.
contract LaunchSequenceFork is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSM         = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2      = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant OWNER        = address(0xB0B);
    address constant HOOK         = address(0x2040);
    address constant EARLY        = address(0xEA711);
    uint256 constant FORK_BLOCK   = 25604624;

    uint256 constant A_AMT = 6 ether;
    uint256 constant B_AMT = 4 ether;
    uint256 constant C_AMT = 3 ether;
    uint256 constant D_AMT = 2 ether;
    address constant HA = address(0xA1);
    address constant HB = address(0xB1);
    address constant HC = address(0xC1);
    address constant HD = address(0xD1);

    IHookL hook;
    PrismMigration migration;
    Swapper swapper;
    bytes32[4] leaves;

    // recorded at the end of the trading window, before the airdrop opens
    uint256 sharesAfterWindow;
    uint256 earlyBookedETH;
    uint256 earlyBookedPRISM;
    uint256 hookEthAfterWindow;

    function _leaf(address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, amt))));
    }
    function _pair(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x <= y ? keccak256(abi.encodePacked(x, y)) : keccak256(abi.encodePacked(y, x));
    }
    function _key() internal pure returns (PoolKey memory) {
        return PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(HOOK),
                        fee: 10_000, tickSpacing: 200, hooks: IHooks(HOOK)});
    }
    function _proof(uint256 i) internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = leaves[i ^ 1];
        p[1] = i < 2 ? _pair(leaves[2], leaves[3]) : _pair(leaves[0], leaves[1]);
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);

        leaves[0] = _leaf(HA, A_AMT); leaves[1] = _leaf(HB, B_AMT);
        leaves[2] = _leaf(HC, C_AMT); leaves[3] = _leaf(HD, D_AMT);
        bytes32 root = _pair(_pair(leaves[0], leaves[1]), _pair(leaves[2], leaves[3]));
        uint256 reserve = A_AMT + B_AMT + C_AMT + D_AMT;

        migration = new PrismMigration(root, address(this));
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(POOL_MANAGER, OWNER, POSM, PERMIT2, address(migration), reserve), HOOK);
        hook = IHookL(HOOK);

        // setToken is deliberately NOT called — that gate is the whole point of the sequence.
        vm.prank(OWNER);
        hook.seed(3648751508805509367250261525102, -887200, 76600, 80e18);
        vm.prank(OWNER);
        hook.renounceOwnership();

        swapper = new Swapper(POOL_MANAGER);
        vm.deal(address(swapper), 500 ether);

        // ── the trading window, all inside setUp so these shares pre-exist the test body ──────
        swapper.buy(_key(), 5 ether, EARLY);
        hook.pokeFees();                       // burn off the seed's forfeited first collection
        for (uint256 i; i < 3; ++i) {
            swapper.buy(_key(), 20 ether, address(swapper));
            swapper.sell(_key(), hook.balanceOf(address(swapper)) / 2, address(swapper));
        }
        hook.pokeFees();

        sharesAfterWindow  = hook.totalShares();
        hookEthAfterWindow = HOOK.balance;
    }

    /// Book the early buyer's window earnings into `pending`. Must be called from a TEST BODY, not
    /// setUp: the mint happened in setUp, and the anti-JIT quarantine keys on transient storage, so a
    /// claim in the same transaction as the mint credits nothing.
    function _bookEarlyFees() internal {
        uint256[] memory ids = _idsOf(EARLY, hook.nftBalanceOf(EARLY));
        vm.prank(EARLY);
        hook.claimMany(ids);
        earlyBookedETH   = hook.pendingETH(EARLY);
        earlyBookedPRISM = hook.pendingPRISM(EARLY);
    }

    /// The gate the sequence depends on: nothing is claimable until the deployer wires the token.
    function test_AirdropIsGatedUntilSetToken() public {
        vm.expectRevert(PrismMigration.TokenNotSet.selector);
        migration.claim(HA, A_AMT, _proof(0));
        assertEq(hook.balanceOf(HA), 0, "nobody was paid");
    }

    /// The window really does what it is for: fees accrue and an early buyer books real earnings
    /// while the airdrop is still closed.
    function test_WindowAccruesFeesToEarlyBuyersOnly() public {
        _bookEarlyFees();
        assertGt(sharesAfterWindow, 0, "the early buyer holds shares");
        assertGt(hook.accFeesPerShareETH(), 0, "fees accrued during the window");
        assertGt(earlyBookedETH + earlyBookedPRISM, 0, "early buyer booked real fees");
        assertEq(hook.nftBalanceOf(HA), 0, "no airdrop shares exist yet");
        console2.log("window shares:", sharesAfterWindow);
        console2.log("early buyer booked ETH:", earlyBookedETH, " PRISM:", earlyBookedPRISM);
    }

    /// The property that matters for the sequence: opening the airdrop mints a large number of new
    /// shares against a nonzero accumulator, and that must NOT claw back fees an early buyer has
    /// already booked. Dilution applies to FUTURE fees only.
    function test_LateAirdropDoesNotClawBackBookedFees() public {
        _bookEarlyFees();
        assertGt(earlyBookedETH + earlyBookedPRISM, 0, "there is something to claw back");
        migration.setToken(HOOK);
        migration.claim(HA, A_AMT, _proof(0));
        migration.claim(HB, B_AMT, _proof(1));
        migration.claim(HC, C_AMT, _proof(2));
        migration.claim(HD, D_AMT, _proof(3));

        uint256 sharesAfter = hook.totalShares();
        assertGt(sharesAfter, sharesAfterWindow, "the airdrop minted new shares");

        assertEq(hook.pendingETH(EARLY),   earlyBookedETH,   "booked ETH not clawed back");
        assertEq(hook.pendingPRISM(EARLY), earlyBookedPRISM, "booked PRISM not clawed back");

        // every claimant actually received their allocation and got mirrored
        assertEq(hook.balanceOf(HA), A_AMT, "HA paid");
        assertEq(hook.nftBalanceOf(HA), A_AMT / 1 ether, "HA mirrored");

        console2.log("shares before/after airdrop:", sharesAfterWindow, sharesAfter);
        console2.log("early buyer booked ETH unchanged at:", hook.pendingETH(EARLY));
    }

    /// Solvency must survive the transition: the hook still holds enough ETH for every promise made
    /// during the window, after thousands of new shares appear.
    function test_SolventAcrossTheTransition() public {
        _bookEarlyFees();
        migration.setToken(HOOK);
        migration.claim(HA, A_AMT, _proof(0));
        migration.claim(HB, B_AMT, _proof(1));
        migration.claim(HC, C_AMT, _proof(2));
        migration.claim(HD, D_AMT, _proof(3));

        uint256 owed = hook.pendingETH(EARLY) + hook.pendingETH(HA) + hook.pendingETH(HB)
                     + hook.pendingETH(HC) + hook.pendingETH(HD);
        assertGe(HOOK.balance, owed, "hook solvent for all booked ETH");
        assertGe(hookEthAfterWindow, owed, "and was already solvent before the airdrop");
        console2.log("hook ETH:", HOOK.balance, " total booked owed:", owed);
    }

    function _idsOf(address who, uint256 n) internal view returns (uint256[] memory out) {
        out = new uint256[](n);
        uint256 found;
        for (uint256 id = 1; id < 6000 && found < n; ++id) {
            (bool ok, bytes memory ret) = HOOK.staticcall(
                abi.encodeWithSignature("nftOwnerOf(uint256)", id));
            if (ok && ret.length >= 32 && abi.decode(ret, (address)) == who) out[found++] = id;
        }
        require(found == n, "ids not found");
    }
}
