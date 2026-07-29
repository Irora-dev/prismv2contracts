// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

interface IH {
    function transfer(address, uint256) external returns (bool);
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

/// A contract holding PRISM that anyone can pull the excess back out of. This is not a contrivance: a
/// Uniswap V2 pair's `skim(to)` is permissionless and pays `balanceOf(this) - reserve` to any address,
/// and a V2 PRISM pool is the case the exclusion-set residual is explicitly documented against.
contract SkimmablePool {
    address immutable prism;
    uint256 public reserve;
    constructor(address p) { prism = p; }
    function sync() external { reserve = IH(prism).balanceOf(address(this)); }
    function skim(address to) external {
        uint256 excess = IH(prism).balanceOf(address(this)) - reserve;
        if (excess > 0) IH(prism).transfer(to, excess);
    }
}

/// What forcing a fee-share onto a third party ACTUALLY costs.
///
/// `_afterTokenTransfer`'s comment has now been wrong twice about this, so it is pinned here.
///
///  1. It first claimed forcing a share "requires actually moving a whole token, which is a gift". False:
///     the cost is the distance to the victim's NEXT whole-token boundary, so a victim sitting just under
///     one is pushed over for 1 wei.
///  2. The correction then claimed "every share after the first costs a full UNIT, so the amortised price
///     stays ~1 whole token per share and the attacker is strictly out of pocket". Also false, and this
///     test is why: against an UNDER-MIRRORED holder whose balance can be pulled back, the amortised cost
///     is ZERO PRISM. Only gas.
///
/// The asymmetry that makes it free: `_realignPair` computes `fromLoses = fromCur > fromTarget ? … : 0`.
/// While the victim is under-mirrored, `fromCur < fromTarget`, so pulling the balance back out burns
/// NOTHING — the boundary-crossing wei comes straight back and the minted share stays. Under-mirroring is
/// not exotic: `MAX_REALIGN = 128` guarantees it for any address receiving more than 128 whole tokens in
/// one transfer, and `syncNFTs` is caller-only, so for a contract that cannot call it the gap is permanent
/// and every forced share is permanent too.
///
/// What remains after that fix is NOT a bug, and the distinction matters because the obvious further
/// "fix" would be actively harmful. Each round mints exactly one share for one whole token that really did
/// arrive (200 tokens + 1 = 201 whole, so 129 shares from 128 is correct accounting), and the skim burns
/// nothing because the holder is still under-mirrored at 200 tokens against 129 shares. Both legs are
/// individually right. The attack therefore creates nothing — it only ACCELERATES a catch-up the holder
/// was always entitled to, and it stops dead at its own balance: 128 -> 200 and no further, asserted below.
///
/// The two paths are indistinguishable in code: "balance crossed a whole-token boundary, so mint a share"
/// is exactly what a normal buyer needs. Blocking fresh mints to under-mirrored contracts would strand
/// every genuine contract holder permanently, since `syncNFTs` is caller-only. So the controls here are the
/// exclusion set and not creating a non-claiming pool — NOT the cost of forcing a mint. No unbacked share
/// is ever created and the attacker gains nothing: this is dilution timing, not theft.
contract ForcedShareCost is Test {
    address constant V2 = address(0x2040);
    address constant OWNER = address(0xB0B);
    address constant ATTACKER = address(0xA77ACC);
    IH hook;
    SkimmablePool pool;

    function setUp() public {
        PMStub pm = new PMStub(); POSMStub posm = new POSMStub(); PStub p2 = new PStub();
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(address(pm), OWNER, address(posm), address(p2), address(0), uint256(0)), V2);
        hook = IH(V2);
        vm.store(V2, bytes32(uint256(0)), bytes32(uint256(1))); // seeded

        pool = new SkimmablePool(V2);
        // The pool receives 200 whole tokens in ONE transfer, so MAX_REALIGN leaves it under-mirrored at
        // 128 shares against a 200-token target. This is the ordinary consequence of a large transfer.
        vm.prank(V2); hook.transfer(address(pool), 200 ether);
        pool.sync();
        vm.prank(V2); hook.transfer(ATTACKER, 5 ether);
    }

    function test_ForcingSharesOntoAnUnderMirroredHolderCostsNoPrism() public {
        uint256 sharesBefore   = hook.nftBalanceOf(address(pool));
        uint256 attackerBefore = hook.balanceOf(ATTACKER);
        uint256 totalBefore    = hook.totalShares();
        assertEq(sharesBefore, 128, "under-mirrored by MAX_REALIGN, as any large transfer leaves it");

        // Push one whole token in (crossing a boundary, minting a share), then pull it straight back.
        // 30 rounds: 30*2 = 60 shares, which stays below the 72-share headroom to entitlement, so this
        // measures the RATE. The ceiling itself is asserted separately below.
        uint256 rounds = 30;
        for (uint256 i; i < rounds; ++i) {
            vm.prank(ATTACKER); hook.transfer(address(pool), 1 ether);
            pool.skim(ATTACKER);
        }

        uint256 sharesAfter   = hook.nftBalanceOf(address(pool));
        uint256 attackerAfter = hook.balanceOf(ATTACKER);

        console2.log("pool shares before / after :", sharesBefore, sharesAfter);
        console2.log("totalShares before / after :", totalBefore, hook.totalShares());
        console2.log("attacker PRISM before      :", attackerBefore);
        console2.log("attacker PRISM after       :", attackerAfter);
        console2.log("PRISM spent by the attacker:", attackerBefore - attackerAfter);

        // Two shares per round: the attacker's own share MOVES to the victim on the way in, and a
        // replacement is minted to the attacker on the way out (the victim is under-mirrored, so its
        // `fromLoses` is 0 and nothing burns). Both of those mints are of shares the recipient already
        // holds backing for, which is why no invariant breaks.
        //
        // I briefly "fixed" this by charging the mint against `mintBudget - transferable`, which halved
        // it to one per round — and froze the under-mirroring gap for every honest holder, costing an
        // unaware one 20% of each fee round permanently. Reverted; see `test/GapHealing.t.sol`. Asserting
        // the exact figure so that trade cannot be made again by accident.
        assertEq(sharesAfter - sharesBefore, rounds * 2,
                 "2 shares per round: one moved in, one minted back to the attacker");
        assertEq(attackerAfter, attackerBefore, "and it cost the attacker NOTHING in PRISM");

        // Still backed, so this is dilution and not an unbacked-share bug.
        assertLe(sharesAfter, hook.balanceOf(address(pool)) / 1 ether, "never over-mirrored");
    }

    /// The control that isolates the cause: a FULLY mirrored holder is immune, because the pull-back then
    /// burns exactly what the push minted.
    function test_FullyMirroredHolderIsImmune() public {
        vm.prank(address(pool)); hook.syncNFTs(0);
        vm.prank(address(pool)); hook.syncNFTs(0);   // close the gap completely
        uint256 target = hook.balanceOf(address(pool)) / 1 ether;
        assertEq(hook.nftBalanceOf(address(pool)), target, "fully mirrored");

        uint256 sharesBefore   = hook.nftBalanceOf(address(pool));
        uint256 attackerBefore = hook.balanceOf(ATTACKER);
        for (uint256 i; i < 10; ++i) {
            vm.prank(ATTACKER); hook.transfer(address(pool), 1 ether);
            pool.skim(ATTACKER);
        }
        console2.log("fully-mirrored: shares delta:", hook.nftBalanceOf(address(pool)) - sharesBefore);
        assertEq(hook.nftBalanceOf(address(pool)), sharesBefore, "no net shares forced");
        assertEq(hook.balanceOf(ATTACKER), attackerBefore, "attacker is whole either way");
    }

    /// The bound that makes this acceptable: forcing STOPS at the victim's own entitlement. An attacker
    /// cannot push a holder past `balanceOf / UNIT`, so the worst case is a non-claimer fully mirrored —
    /// which is exactly where ordinary trading would have taken it anyway.
    function test_ForcingCannotExceedTheVictimsOwnEntitlement() public {
        uint256 entitled = hook.balanceOf(address(pool)) / 1 ether;   // 200
        for (uint256 i; i < 120; ++i) {                                // far more rounds than the gap
            vm.prank(ATTACKER); hook.transfer(address(pool), 1 ether);
            pool.skim(ATTACKER);
        }
        uint256 shares = hook.nftBalanceOf(address(pool));
        console2.log("entitlement / shares reached:", entitled, shares);
        assertEq(shares, entitled, "forcing saturates at the victim's entitlement, never beyond");
        assertLe(shares, hook.balanceOf(address(pool)) / 1 ether, "never over-mirrored");
    }
}
