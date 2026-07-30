// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

interface IHook {
    function mirror() external view returns (address);
    function POSM() external view returns (address);
    function PERMIT2() external view returns (address);
    function poolManager() external view returns (address);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function nftBalanceOf(address) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function ownedTokensOf(address) external view returns (uint256[] memory);
    function pokeFees() external;
    function claim(uint256) external;
    function claimMany(uint256[] calldata) external;
    function syncNFTs(uint256) external;
    function withdrawPending() external;
    function withdrawPendingTo(address recipient) external;
    function pendingETH(address) external view returns (uint256);
    function pendingPRISM(address) external view returns (uint256);
    function pendingFees(uint256) external view returns (uint256, uint256);
    function accFeesPerShareETH() external view returns (uint256);
    function accFeesPerSharePRISM() external view returns (uint256);
    function forfeitNextCollection() external view returns (bool);
}

interface IPrismMin { function transfer(address, uint256) external returns (bool); }

/// One-shot fee payer, same shape as test/FeeLegUnit.t.sol's mock: a collect drains what
/// accrued and the position has nothing further to give until `set` is called again.
contract FeePOSM {
    uint256 public feeEth;
    uint256 public feePrism;
    address public prism;
    uint256 public firings;
    receive() external payable {}
    function set(address p, uint256 e, uint256 pr) external { prism = p; feeEth = e; feePrism = pr; }
    function modifyLiquidities(bytes calldata, uint256) external {
        uint256 e = feeEth; uint256 pr = feePrism;
        feeEth = 0; feePrism = 0;
        if (e > 0)  { (bool ok,) = msg.sender.call{value: e}(""); require(ok, "eth send"); }
        if (pr > 0) { IPrismMin(prism).transfer(msg.sender, pr); }
        if (e > 0 || pr > 0) firings++;
    }
    function nextTokenId() external pure returns (uint256) { return 1; }
    function multicall(bytes[] calldata) external {}
}

contract Permit2Stub { function approve(address,address,uint160,uint48) external {} }
contract PMStub { function exttload(bytes32) external pure returns (bytes32) { return bytes32(0); } }

/// Recipient that re-enters every guarded entry point during the ETH send and records the result.
contract Reenterer {
    IHook public hook;
    uint256 public tokenId;
    bool public claimReverted;
    bool public withdrawReverted;
    bool public syncReverted;
    bool public pokeReverted;
    bool public armed = true;
    uint256 public ethSeen;

    constructor(IHook h) { hook = h; }
    function setToken(uint256 id) external { tokenId = id; }

    receive() external payable {
        ethSeen += msg.value;
        if (!armed) return;
        armed = false;
        try hook.claim(tokenId)        { claimReverted = false; } catch { claimReverted = true; }
        try hook.withdrawPending()     { withdrawReverted = false; } catch { withdrawReverted = true; }
        try hook.syncNFTs(0)           { syncReverted = false; } catch { syncReverted = true; }
        try hook.pokeFees()            { pokeReverted = false; } catch { pokeReverted = true; }
    }
}

/// Recipient that consumes the ETH, does work, then FAILS — probing the restore-overwrite branch.
contract FailAfterWork {
    IHook public hook;
    address public victim;
    uint256 public pullAmount;
    constructor(IHook h) { hook = h; }
    function arm(address v, uint256 amt) external { victim = v; pullAmount = amt; }
    receive() external payable {
        // Move the victim's PRISM out using an allowance the victim granted us. That burns
        // the victim's shares and credits pendingETH[victim] mid-flight.
        if (pullAmount > 0) hook.transferFrom(victim, address(this), pullAmount);
        revert("nope");
    }
}

/// Plain contract with no receive(): the ETH leg must fail cleanly and restore the credit.
contract NoReceive {
    IHook public hook;
    constructor(IHook h) { hook = h; }
    function withdraw() external { hook.withdrawPending(); }
    function withdrawTo(address to) external { hook.withdrawPendingTo(to); }
}

/// Fee-layer probes: conservation, credit routing, reentrancy, exclusion.
contract PendingCreditUnit is Test {
    // Low 14 bits must equal the hook permission flags (beforeInitialize | afterSwap = 0x2040).
    address constant HOOK  = address(0xAB2040);
    address constant OWNER = address(0xB0B0);
    address constant BURN  = 0x000000000000000000000000000000000000dEaD;
    uint256 constant ACC_SCALE = 1e12;

    IHook hook;
    FeePOSM posm;
    PMStub  pm;
    Permit2Stub p2;

    address alice = address(0xA1);
    address bob   = address(0xB1);
    address carol = address(0xC1);
    address dave  = address(0xD1);

    function setUp() public {
        pm   = new PMStub();
        posm = new FeePOSM();
        p2   = new Permit2Stub();
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(address(pm), OWNER, address(posm), address(p2), address(0), uint256(0)), HOOK);
        hook = IHook(HOOK);
        vm.store(HOOK, bytes32(uint256(0)), bytes32(uint256(1))); // seeded = true, forfeit = false
        vm.deal(address(posm), 10_000 ether);

        // All MINTS happen here, in setUp's own transaction, so the transient anti-JIT
        // quarantine never swallows a claim in a test body.
        vm.startPrank(HOOK);
        hook.transfer(alice, 10 ether);   // 10 shares
        hook.transfer(bob,    5 ether);   //  5 shares
        hook.transfer(carol,  1 ether);   //  1 share
        hook.transfer(address(posm), 500 ether); // so the mock can pay PRISM fees in
        vm.stopPrank();
    }

    /* ── helpers ─────────────────────────────────────────────────────────────── */

    function _claimAll(address who) internal {
        uint256[] memory ids = hook.ownedTokensOf(who);
        if (ids.length > 0) hook.claimMany(ids);
    }

    function _excluded() internal view returns (address[] memory a) {
        a = new address[](8);
        a[0] = address(0);
        a[1] = hook.poolManager();
        a[2] = HOOK;
        a[3] = address(0);            // MIGRATION_VAULT is 0 in this fixture
        a[4] = BURN;
        a[5] = hook.POSM();
        a[6] = hook.PERMIT2();
        a[7] = hook.mirror();
    }

    /* ── 1. conservation across a churning multi-round life ──────────────────── */

    /// The core solvency question, asked with shares MOVING and BURNING between rounds (the
    /// orderings that carry fee debt around) rather than a static holder set. No mint happens
    /// in this body, so the quarantine plays no part and the arithmetic is exact.
    function test_Refuted_PromisedNeverExceedsReceivedUnderChurn() public {
        uint256 recvEth;
        uint256 recvPrism;

        posm.set(HOOK, 2 ether, 30 ether); hook.pokeFees(); recvEth += 2 ether;   recvPrism += 30 ether;

        // 4 whole tokens alice -> bob: shares MOVE (toMint == 0), alice is credited her accrual.
        vm.prank(alice); hook.transfer(bob, 4 ether);
        assertEq(hook.totalShares(), 16, "a move must not change the share count");

        posm.set(HOOK, 1 ether, 10 ether); hook.pokeFees(); recvEth += 1 ether;   recvPrism += 10 ether;

        // alice sells 6 whole tokens into the (excluded) hook: 6 shares BURN, alice credited.
        vm.prank(alice); hook.transfer(HOOK, 6 ether);
        assertEq(hook.totalShares(), 10, "six shares must burn");

        posm.set(HOOK, 0.5 ether, 5 ether); hook.pokeFees(); recvEth += 0.5 ether; recvPrism += 5 ether;

        _claimAll(alice); _claimAll(bob); _claimAll(carol);

        uint256 promisedEth   = hook.pendingETH(alice)   + hook.pendingETH(bob)   + hook.pendingETH(carol);
        uint256 promisedPrism = hook.pendingPRISM(alice) + hook.pendingPRISM(bob) + hook.pendingPRISM(carol);
        uint256 burned        = hook.balanceOf(BURN);

        assertEq(burned, recvPrism * 2000 / 10_000, "burn leg is exactly 20% of every round");
        assertLe(promisedEth,          recvEth,   "ETH promised exceeds ETH received");
        assertLe(promisedPrism + burned, recvPrism, "PRISM promised+burned exceeds PRISM received");

        // Nothing is left unaccounted beyond sub-wei accumulator flooring.
        assertGe(promisedEth + 32,           recvEth,   "more than dust of ETH went missing");
        assertGe(promisedPrism + burned + 32, recvPrism, "more than dust of PRISM went missing");

        // Solvency: the hook can actually pay every promise, and does.
        assertGe(address(HOOK).balance, promisedEth, "hook ETH cannot cover its promises");
        uint256 e0 = alice.balance + bob.balance + carol.balance;
        vm.prank(alice); hook.withdrawPending();
        vm.prank(bob);   hook.withdrawPending();
        vm.prank(carol); hook.withdrawPending();
        assertEq(alice.balance + bob.balance + carol.balance - e0, promisedEth, "every wei paid out");
        assertEq(hook.pendingETH(alice) + hook.pendingETH(bob) + hook.pendingETH(carol), 0);
        assertEq(hook.pendingPRISM(alice) + hook.pendingPRISM(bob) + hook.pendingPRISM(carol), 0);
    }

    /// Not one wei of credit may ever land on an address that could never spend it.
    function test_Refuted_NoExcludedAddressEverAccruesPending() public {
        posm.set(HOOK, 2 ether, 30 ether); hook.pokeFees();
        vm.prank(alice); hook.transfer(bob, 4 ether);
        vm.prank(bob);   hook.transfer(HOOK, 2 ether);       // sell
        vm.prank(carol); hook.transfer(BURN, 1 ether);       // "burn" your own PRISM
        posm.set(HOOK, 1 ether, 10 ether); hook.pokeFees();
        _claimAll(alice); _claimAll(bob);

        address[] memory ex = _excluded();
        for (uint256 i; i < ex.length; ++i) {
            assertEq(hook.pendingETH(ex[i]),   0, "excluded address accrued ETH credit");
            assertEq(hook.pendingPRISM(ex[i]), 0, "excluded address accrued PRISM credit");
            assertEq(hook.nftBalanceOf(ex[i]), 0, "excluded address holds a fee-share");
        }
        // and the burn sink really is inert: it holds PRISM but zero shares
        assertGt(hook.balanceOf(BURN), 0);
        assertEq(hook.nftBalanceOf(BURN), 0);
    }

    /// Claiming, then moving, then claiming again must never pay the same accrual twice.
    function test_Refuted_NoDoubleCreditAcrossClaimThenMove() public {
        posm.set(HOOK, 3 ether, 0); hook.pokeFees();

        // Settle EVERY holder first, so any later credit can only be new accrual.
        _claimAll(alice); _claimAll(bob); _claimAll(carol);
        uint256 aliceSettled = hook.pendingETH(alice);
        uint256 bobSettled   = hook.pendingETH(bob);
        assertEq(aliceSettled, 3 ether * 10 / 16, "alice settled at her exact share");
        assertEq(bobSettled,   3 ether *  5 / 16, "bob settled at his exact share");

        // Move 3 shares to bob. Their accrual is already claimed, so this credits nothing more.
        vm.prank(alice); hook.transfer(bob, 3 ether);
        assertEq(hook.pendingETH(alice), aliceSettled, "a move re-credited an already-claimed accrual");
        assertEq(hook.pendingETH(bob),   bobSettled,   "bob was credited the seller's history");

        // A second claim on the same ids adds nothing.
        _claimAll(alice); _claimAll(bob);
        assertEq(hook.pendingETH(alice), aliceSettled, "re-claim paid twice");
        assertEq(hook.pendingETH(bob),   bobSettled,   "re-claim paid twice");

        // Fresh accrual after the move belongs to the new owner, in proportion.
        posm.set(HOOK, 1.6 ether, 0); hook.pokeFees();
        _claimAll(alice); _claimAll(bob);
        // 16 shares live; bob now holds 5+3 = 8, alice 7, carol 1.
        assertEq(hook.pendingETH(bob) - bobSettled, 1.6 ether * 8 / 16,
                 "post-move accrual must follow the share");
        assertEq(hook.pendingETH(alice) - aliceSettled, 1.6 ether * 7 / 16,
                 "seller keeps only what her remaining shares earn");
    }

    /* ── 2. credit routing / withdrawal ──────────────────────────────────────── */

    function test_Refuted_WithdrawPendingToRejectsEveryExcludedSink() public {
        posm.set(HOOK, 2 ether, 30 ether); hook.pokeFees();
        _claimAll(alice);
        assertGt(hook.pendingETH(alice), 0);

        address[] memory ex = _excluded();
        for (uint256 i; i < ex.length; ++i) {
            vm.prank(alice);
            vm.expectRevert();                     // TransferToZero or ExcludedRecipient
            hook.withdrawPendingTo(ex[i]);
        }
        // still intact and payable to a real address
        vm.prank(alice); hook.withdrawPendingTo(dave);
        assertGt(dave.balance, 0);
    }

    /// A holder that cannot receive ETH must not lose the credit, and must not have the PRISM
    /// leg blocked by the ETH leg.
    function test_Refuted_EthRejectingHolderKeepsCreditAndGetsPrism() public {
        NoReceive nr = new NoReceive(hook);
        // give it 2 whole tokens in this body: it mints shares, which are quarantined for the
        // rest of this transaction — so give it pending via a MOVE from alice instead.
        vm.prank(alice); hook.transfer(address(nr), 2 ether);   // 2 shares MOVE to nr

        posm.set(HOOK, 2 ether, 30 ether); hook.pokeFees();
        uint256[] memory ids = hook.ownedTokensOf(address(nr));
        hook.claimMany(ids);                                    // permissionless: credits the owner
        uint256 owedEth   = hook.pendingETH(address(nr));
        uint256 owedPrism = hook.pendingPRISM(address(nr));
        assertGt(owedEth, 0); assertGt(owedPrism, 0);

        nr.withdraw();                                          // ETH leg fails, PRISM leg must not
        assertEq(hook.pendingETH(address(nr)), owedEth, "credit was destroyed by a failed ETH send");
        assertEq(hook.pendingPRISM(address(nr)), 0,      "PRISM leg was blocked by the ETH leg");
        assertGe(hook.balanceOf(address(nr)), owedPrism, "PRISM did not arrive");

        // and it can still route the ETH elsewhere
        nr.withdrawTo(dave);
        assertEq(dave.balance, owedEth, "ETH not recoverable via withdrawPendingTo");
        assertEq(hook.pendingETH(address(nr)), 0);
    }

    /* ── 3. reentrancy ───────────────────────────────────────────────────────── */

    /// The ETH send hands full gas to an arbitrary recipient. Every guarded entry point must be
    /// closed to it, and the un-guarded `pokeFees` must not be able to manufacture value.
    function test_Refuted_ReentrancyDuringEthSendIsClosed() public {
        Reenterer r = new Reenterer(hook);
        vm.prank(alice); hook.transfer(address(r), 3 ether);  // 3 shares MOVE to r (no mint)
        uint256[] memory ids = hook.ownedTokensOf(address(r));
        r.setToken(ids[0]);

        posm.set(HOOK, 3 ether, 30 ether); hook.pokeFees();
        hook.claimMany(ids);
        uint256 owedEth = hook.pendingETH(address(r));
        assertGt(owedEth, 0);

        // Arm a second fee round so a reentrant pokeFees would have something to collect.
        posm.set(HOOK, 1 ether, 0);

        uint256 hookEthBefore = address(HOOK).balance;
        vm.prank(address(r));
        hook.withdrawPending();

        assertTrue(r.claimReverted(),    "claim() was reachable re-entrantly");
        assertTrue(r.withdrawReverted(), "withdrawPending() was reachable re-entrantly");
        assertTrue(r.syncReverted(),     "syncNFTs() was reachable re-entrantly");
        assertFalse(r.pokeReverted(),    "pokeFees is deliberately open; it should not revert");
        assertEq(r.ethSeen(), owedEth,   "recipient received exactly its credit, once");

        // The reentrant poke collected 1 ETH into the hook. Nothing was double-paid.
        assertEq(address(HOOK).balance, hookEthBefore - owedEth + 1 ether, "hook ETH accounting drifted");
        assertEq(hook.pendingETH(address(r)), 0, "credit not cleared after a successful send");

        // Everyone can still be paid in full afterwards.
        _claimAll(alice); _claimAll(bob); _claimAll(carol);
        uint256 promised = hook.pendingETH(alice) + hook.pendingETH(bob) + hook.pendingETH(carol)
                         + hook.pendingETH(address(r));
        assertGe(address(HOOK).balance, promised, "hook became insolvent in ETH");
    }

    /// WHY `=` AND `+=` ARE INDISTINGUISHABLE IN `_withdrawPendingTo`'s RESTORE. Read as written, the
    /// assignment looks like it clobbers credit a hostile recipient creates mid-flight — by pulling the
    /// caller's PRISM on an allowance, which burns shares and credits the sender. It does not, and the
    /// reason is structural: the restore runs only when the send returned failure, which means the
    /// recipient's frame reverted, which rolls back every state change it made INCLUDING that credit. To
    /// keep the credit the recipient must return successfully, and then the restore never runs.
    ///
    /// Do not settle this with a test that asserts `pendingETH == aliceCredit`: that is true both if
    /// credit was created-then-clobbered AND if none was ever created, so it cannot tell the two apart.
    /// The assertions below can: the accrual is real (`wouldBeCredited > 0`), it is genuinely rolled back
    /// rather than merely equal, and it is still there to be claimed afterwards.
    function test_FailedSendRestoresExactlyAndTheHostilePullLeavesNoTrace() public {
        FailAfterWork f = new FailAfterWork(hook);
        vm.prank(alice); hook.transfer(address(f), 1 ether);     // 1 share moves, gives it standing

        posm.set(HOOK, 3 ether, 0); hook.pokeFees();
        _claimAll(alice);
        uint256 aliceCredit = hook.pendingETH(alice);
        assertGt(aliceCredit, 0);

        // alice grants the hostile contract an allowance, then a second fee round accrues on her
        // remaining shares so that pulling her balance would credit her mid-flight.
        vm.prank(alice); hook.approve(address(f), 9 ether);
        posm.set(HOOK, 1.6 ether, 0); hook.pokeFees();
        f.arm(alice, 9 ether);

        uint256 wouldBeCredited;
        {
            uint256[] memory ids = hook.ownedTokensOf(alice);
            for (uint256 i; i < ids.length; ++i) {
                (uint256 e,) = hook.pendingFees(ids[i]);
                wouldBeCredited += e;
            }
        }
        assertGt(wouldBeCredited, 0, "need a live accrual for this probe to mean anything");

        vm.prank(alice);
        hook.withdrawPendingTo(address(f));   // f pulls alice's PRISM (crediting her), then reverts

        uint256 aliceShares = hook.ownedTokensOf(alice).length;
        uint256 alicePrism  = hook.balanceOf(alice);

        vm.prank(alice);
        hook.withdrawPendingTo(address(f));   // f pulls alice's PRISM, then reverts

        // Restored to exactly the pre-send value — no credit lost, and none gained.
        assertEq(hook.pendingETH(alice), aliceCredit, "restore is not exact");

        // The hostile pull left NO trace: the revert rolled back the transferFrom too, so alice still
        // holds her PRISM and her shares. This is what proves nothing was clobbered rather than merely
        // that the arithmetic happened to match.
        assertEq(hook.balanceOf(alice), alicePrism, "the reverted pull moved PRISM anyway");
        assertEq(hook.ownedTokensOf(alice).length, aliceShares, "the reverted pull moved shares anyway");
        assertEq(hook.balanceOf(address(f)), 1 ether, "the hostile contract kept something");

        // And the accrual it would have converted is still pending on her tokens, still claimable.
        uint256 stillPending;
        {
            uint256[] memory ids = hook.ownedTokensOf(alice);
            for (uint256 i; i < ids.length; ++i) {
                (uint256 e,) = hook.pendingFees(ids[i]);
                stillPending += e;
            }
        }
        assertEq(stillPending, wouldBeCredited, "the accrual was consumed by the failed send");

        // Finally, the restored credit really pays out to a recipient that accepts ETH.
        vm.prank(alice);
        hook.withdrawPendingTo(bob);
        assertEq(hook.pendingETH(alice), 0, "credit not cleared after a successful withdrawal");
        assertGe(bob.balance, aliceCredit, "the restored credit was not paid out");
    }

    /* ── 4. syncNFTs ordering and gating ─────────────────────────────────────── */

    /// `syncNFTs` must collect BEFORE it mints, otherwise a holder could sit on an
    /// un-mirrored gap and mint into an uncollected backlog.
    function test_Refuted_SyncNFTsCollectsBeforeItMints() public {
        // Push dave over MAX_REALIGN so he keeps a permanent gap.
        vm.prank(HOOK); hook.transfer(dave, 200 ether);
        assertEq(hook.nftBalanceOf(dave), 128, "MAX_REALIGN should cap the mint at 128");

        posm.set(HOOK, 5 ether, 0);
        uint256 firingsBefore = posm.firings();
        uint256 accBefore     = hook.accFeesPerShareETH();

        vm.prank(dave); hook.syncNFTs(0);

        assertEq(posm.firings(), firingsBefore + 1, "syncNFTs did not collect before minting");
        assertGt(hook.accFeesPerShareETH(), accBefore, "accumulator did not advance before the mint");
        assertEq(hook.nftBalanceOf(dave), 200, "the 72-share gap should have healed to his full backing");

        // The freshly minted ids owe nothing: their debt was set to the POST-collect accumulator.
        uint256[] memory ids = hook.ownedTokensOf(dave);
        (uint256 owedNew,) = hook.pendingFees(ids[ids.length - 1]);
        assertEq(owedNew, 0, "a share minted after the collect must be owed nothing from it");
    }

    function test_Refuted_SyncNFTsIsSelfOnlyAndRejectsExcluded() public {
        vm.prank(HOOK); hook.transfer(dave, 200 ether);
        uint256 before_ = hook.nftBalanceOf(dave);
        // A third party syncing "for" dave can only sync itself, and it holds nothing.
        vm.prank(bob); hook.syncNFTs(0);
        assertEq(hook.nftBalanceOf(dave), before_, "a third party moved dave's share count");

        address[] memory ex = _excluded();
        for (uint256 i; i < ex.length; ++i) {
            if (ex[i] == address(0)) continue;      // cannot prank address(0) meaningfully
            vm.prank(ex[i]);
            vm.expectRevert();
            hook.syncNFTs(0);
        }
    }

    /* ── 5. accumulator / rounding direction ─────────────────────────────────── */

    /// Rounding must always favour the contract, never the claimant: with an awkward
    /// share count and a prime-ish fee, the sum of every claim stays strictly under the take.
    function test_Refuted_RoundingAlwaysFavoursTheContract() public {
        // 16 shares live; use fee amounts that do not divide evenly.
        uint256 fee = 1 ether + 7;   // 1000000000000000007 wei over 16 shares
        posm.set(HOOK, fee, 0);
        hook.pokeFees();
        _claimAll(alice); _claimAll(bob); _claimAll(carol);
        uint256 promised = hook.pendingETH(alice) + hook.pendingETH(bob) + hook.pendingETH(carol);
        assertLe(promised, fee, "rounding leaked value to claimants");
        assertGe(promised + 16, fee, "rounding lost more than one wei per share");
        console2.log("residue retained by the hook (wei):", fee - promised);
    }

    /// A one-wei fee round credits nobody yet is not destroyed: the accumulator keeps the
    /// fraction, so it becomes claimable once enough rounds have stacked.
    function test_Refuted_SubWeiRoundsAreRetainedNotDestroyed() public {
        for (uint256 i; i < 16; ++i) { posm.set(HOOK, 1, 0); hook.pokeFees(); }
        _claimAll(alice); _claimAll(bob); _claimAll(carol);
        uint256 promised = hook.pendingETH(alice) + hook.pendingETH(bob) + hook.pendingETH(carol);
        assertEq(promised, 16, "sixteen one-wei rounds over sixteen shares must all become claimable");
    }
}
