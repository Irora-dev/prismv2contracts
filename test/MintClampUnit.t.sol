// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test, console2} from "forge-std/Test.sol";

interface IH {
    function transfer(address,uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function nftBalanceOf(address) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function syncNFTs(uint256) external;
}
contract PStub { function approve(address,address,uint160,uint48) external {} }
contract PMStub { function exttload(bytes32) external pure returns (bytes32) { return bytes32(0); } }
contract POSMStub {
    receive() external payable {}
    function modifyLiquidities(bytes calldata, uint256) external {}
    function nextTokenId() external pure returns (uint256) { return 1; }
    function multicall(bytes[] calldata) external {}
}

/// Quantifies what the mint clamp actually changes: how much a stranger can force-mint onto a third
/// party, and whether ordinary fractional accumulation still mirrors.
contract MintClampUnit is Test {
    address constant V2 = address(0x2040);
    address constant OWNER = address(0xB0B);
    address constant VICTIM = address(0x0171C);
    address constant ATTACKER = address(0xA77ACC);
    IH hook;

    function setUp() public {
        PMStub pm = new PMStub(); POSMStub posm = new POSMStub(); PStub p2 = new PStub();
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(address(pm), OWNER, address(posm), address(p2), address(0), uint256(0)), V2);
        hook = IH(V2);
        vm.store(V2, bytes32(uint256(0)), bytes32(uint256(1))); // seeded
        // give the victim a large lump in ONE transfer -> under-mirrored by MAX_REALIGN
        vm.prank(V2); hook.transfer(VICTIM, 400 ether);
    }

    function test_ForceSyncBudgetPerZeroValueTransfer() public {
        uint256 before_ = hook.nftBalanceOf(VICTIM);
        assertEq(before_, 128, "under-mirrored as expected");
        vm.prank(ATTACKER);
        hook.transfer(VICTIM, 0);                       // attacker holds nothing
        uint256 after_ = hook.nftBalanceOf(VICTIM);
        console2.log("victim shares before  :", before_);
        console2.log("victim shares after   :", after_);
        console2.log("forced per zero-value transfer:", after_ - before_);
        console2.log("  (pre-clamp this was 128)");
        assertEq(after_, before_, "a zero-value transfer must force nothing at all");
    }

    /// The bound must hold per TRANSACTION, not per call. An `amount / UNIT + 1` budget was recomputed
    /// on every `_afterTokenTransfer` with nothing carried across the transaction, so this loop
    /// restored the whole attack at 1.20x the pre-clamp cost per share — and run inside a
    /// `PoolManager.unlock` callback `_maybePoke` early-returns, so even that premium disappeared.
    function test_ZeroValueLoopForcesNothingAcrossOneTransaction() public {
        uint256 before_ = hook.nftBalanceOf(VICTIM);
        vm.startPrank(ATTACKER);
        for (uint256 i; i < 250; ++i) hook.transfer(VICTIM, 0);
        vm.stopPrank();
        console2.log("forced by 250 zero-value transfers in ONE tx:", hook.nftBalanceOf(VICTIM) - before_);
        assertEq(hook.nftBalanceOf(VICTIM), before_, "repeating the call must not accumulate shares");
    }

    function test_DustTransferAlsoBounded() public {
        uint256 before_ = hook.nftBalanceOf(VICTIM);
        vm.prank(V2); hook.transfer(ATTACKER, 1000);     // dust, far below one whole token
        vm.startPrank(ATTACKER);
        for (uint256 i; i < 250; ++i) hook.transfer(VICTIM, 1);
        vm.stopPrank();
        console2.log("forced per 1-wei transfer x250:", hook.nftBalanceOf(VICTIM) - before_);
        assertEq(hook.nftBalanceOf(VICTIM), before_, "dust must cross no whole-token boundary");
    }

    /// A self-transfer moves no value, so it must mirror nothing. The `to != from` guard in
    /// `_afterTokenTransfer` is the ONLY thing enforcing that, so it needs a test that fails when the
    /// guard is removed — and this is that test.
    ///
    /// Removing it is not harmless. `_realignPair` does NOT independently neutralise a self-transfer —
    /// with `from == to` it computes `fromLoses = 0` but `toGains = target - current`, so the whole
    /// backlog is eligible and only `MAX_REALIGN` bounds it. Without the guard, a self-transfer of 200
    /// whole tokens takes an under-mirrored holder from 128 shares to 256: a free self-sync that bypasses
    /// the mint budget entirely.
    ///
    /// The effect is bounded (a holder can only ever sync their own backlog, which `syncNFTs` already
    /// permits) so this is a correctness and consistency issue rather than a theft vector — but it means
    /// the guard carries the property alone, so it needs a test of its own.
    function test_SelfTransferMirrorsNothing() public {
        uint256 before_ = hook.nftBalanceOf(VICTIM);
        uint256 bal     = hook.balanceOf(VICTIM);
        vm.prank(VICTIM); hook.transfer(VICTIM, 200 ether);   // under-mirrored holder, moving to itself
        assertEq(hook.balanceOf(VICTIM), bal, "a self-transfer must not change the balance");
        assertEq(hook.nftBalanceOf(VICTIM), before_, "a self-transfer must not mint a share");
    }

    /// Forcing shares now costs real value, which is what makes it a gift rather than griefing: the
    /// gain is bounded by the whole tokens actually moved, not free and unbounded as it was before.
    ///
    /// The victim gains TWO shares per whole token here, not one — the attacker's own share moves
    /// across with the token (`transferable`) and the mint budget is spent on top. That is sound:
    /// `toMint` is `toGains - transferable`, so the two together can never carry the victim past
    /// `balanceOf / UNIT`, which is asserted below. Under-mirrored recipients are the only ones this
    /// helps, and they could already catch themselves up with `syncNFTs`.
    function test_ForcingSharesCostsWholeTokens() public {
        uint256 before_ = hook.nftBalanceOf(VICTIM);
        vm.prank(V2); hook.transfer(ATTACKER, 3 ether);
        vm.prank(ATTACKER); hook.transfer(VICTIM, 3 ether);

        uint256 gained = hook.nftBalanceOf(VICTIM) - before_;
        console2.log("shares forced by moving 3 whole tokens:", gained);
        assertLe(gained, 6, "gain must stay bounded by the value moved");
        assertGt(gained, 0, "a real transfer must still mirror");
        assertEq(hook.balanceOf(ATTACKER), 0, "the attacker paid for it in full");
        assertLe(hook.nftBalanceOf(VICTIM), hook.balanceOf(VICTIM) / 1 ether, "over-mirrored");
    }

    /// The UX case the clamp must NOT break: accumulating fractions until a whole token is crossed.
    function test_FractionalAccumulationStillMirrors() public {
        address small = address(0x5A11);
        vm.prank(V2); hook.transfer(small, 0.5 ether);
        assertEq(hook.nftBalanceOf(small), 0, "half a token mirrors nothing");
        vm.prank(V2); hook.transfer(small, 0.6 ether);   // crosses 1.0 with a sub-1 amount
        assertEq(hook.balanceOf(small), 1.1 ether);
        assertEq(hook.nftBalanceOf(small), 1, "boundary crossing still mirrors without syncNFTs");
        console2.log("fractional crossing mirrored:", hook.nftBalanceOf(small));
    }

    /// And the holder can still catch up their own backlog themselves, unbounded by the clamp.
    function test_SelfSyncStillCatchesUpFully() public {
        for (uint256 i; i < 4 && hook.nftBalanceOf(VICTIM) < 400; ++i) {
            vm.prank(VICTIM); hook.syncNFTs(0);
        }
        assertEq(hook.nftBalanceOf(VICTIM), 400, "syncNFTs is unaffected by the clamp");
        console2.log("victim self-synced to:", hook.nftBalanceOf(VICTIM));
    }
}
