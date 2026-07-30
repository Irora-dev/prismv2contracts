// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

/// The whole-token boundary itself (`_afterTokenTransfer`'s
/// balance-delta mint budget, PrismHookV2.sol:506-514), MAX_REALIGN meeting the transient anti-JIT
/// quarantine inside a single transfer that both mints AND moves, and the fee-debt arithmetic across
/// `totalShares` transitions 0 -> 1 -> 0 -> 1.
///
/// TWO-TRANSACTION STRUCTURE. The quarantine is transient-storage keyed and a whole test body is ONE
/// transaction, so `setUp()` is used as transaction #1 (holders arrive, fee round 1 lands) and each
/// body is transaction #2. Anything that must ACCRUE is minted in setUp; anything that must be
/// QUARANTINED is minted in the body. `vm.prank` is also consumed by an inlined view, so every
/// balance read is hoisted above its prank.

interface IHook {
    function mirror() external view returns (address);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function nftBalanceOf(address) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function ownedTokensOf(address) external view returns (uint256[] memory);
    function pokeFees() external;
    function claim(uint256) external;
    function claimMany(uint256[] calldata) external;
    function withdrawPending() external;
    function syncNFTs(uint256) external;
    function pendingETH(address) external view returns (uint256);
    function pendingPRISM(address) external view returns (uint256);
    function pendingFees(uint256) external view returns (uint256, uint256);
    function accFeesPerShareETH() external view returns (uint256);
    function forfeitNextCollection() external view returns (bool);
}

contract Permit2Stub { function approve(address,address,uint160,uint48) external {} }
contract PMStub { function exttload(bytes32) external pure returns (bytes32) { return bytes32(0); } }

/// One-shot ETH payer with a ghost of every wei delivered.
contract EthPOSM {
    uint256 public feeEth;
    uint256 public totalPaid;
    receive() external payable {}
    function arm(uint256 e) external { feeEth = e; }
    function modifyLiquidities(bytes calldata, uint256) external {
        uint256 e = feeEth; feeEth = 0;
        if (e > 0) { (bool ok,) = msg.sender.call{value: e}(""); require(ok); totalPaid += e; }
    }
    function nextTokenId() external pure returns (uint256) { return 1; }
    function multicall(bytes[] calldata) external {}
}

/// Runs a transfer, a poke and a claim inside ONE call frame so the anti-JIT marker is shared.
contract AtomicRunner {
    function buyPokeClaim(IHook hook, address src, uint256 amount, EthPOSM posm, uint256 fee)
        external returns (uint256 credited)
    {
        posm.arm(fee);
        hook.transferFrom(src, address(this), amount); // mints fresh shares, sets the tx marker
        hook.pokeFees();                                // advances the accumulator
        hook.claimMany(hook.ownedTokensOf(address(this)));
        credited = hook.pendingETH(address(this));
    }
    /// Receive fresh shares, poke, then SELL back — burning the fresh shares in the same tx.
    function buyPokeSell(IHook hook, address src, uint256 amount, EthPOSM posm, uint256 fee)
        external returns (uint256 credited)
    {
        posm.arm(fee);
        hook.transferFrom(src, address(this), amount);
        hook.pokeFees();
        hook.transfer(src, amount);
        credited = hook.pendingETH(address(this));
    }
    receive() external payable {}
}

contract WholeTokenBoundary is Test {
    address constant HOOKA = address(0x2040);
    address constant OWNER = address(0xB0B);
    uint256 constant UNIT  = 1 ether;
    uint256 constant ACC   = 1e12;

    IHook hook;
    PMStub pm;
    EthPOSM posm;
    Permit2Stub p2;

    // Pristine in setUp — used by the pure share-arithmetic tests.
    address alice = address(0xA1);
    address bob   = address(0xB1);
    address carol = address(0xC1);
    // Populated in setUp (transaction #1) so their accrual is live in a body.
    address old1  = address(0x0D1);
    address old2  = address(0x0D2);
    address late  = address(0x0D3);
    AtomicRunner preRunner;
    uint256 accRound1;

    function setUp() public {
        pm = new PMStub(); posm = new EthPOSM(); p2 = new Permit2Stub();
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(address(pm), OWNER, address(posm), address(p2), address(0), uint256(0)), HOOKA);
        hook = IHook(HOOKA);
        vm.store(HOOKA, bytes32(uint256(0)), bytes32(uint256(1))); // seeded (forfeit flag stays false)
        vm.deal(address(posm), 1_000_000 ether);

        vm.prank(HOOKA); hook.transfer(old1, 10 ether);
        vm.prank(HOOKA); hook.transfer(old2, 6 ether);

        // FEE ROUND 1 with 16 shares live, then two LATER arrivals. All still transaction #1.
        posm.arm(9 ether);
        hook.pokeFees();
        accRound1 = hook.accFeesPerShareETH();
        assertGt(accRound1, 0);

        vm.prank(HOOKA); hook.transfer(late, 4 ether);
        preRunner = new AtomicRunner();
        vm.prank(HOOKA); hook.approve(address(preRunner), type(uint256).max);
        vm.prank(HOOKA); hook.transfer(address(preRunner), 5 ether);
    }

    /// Balance read BEFORE the prank: vm.prank is consumed by the next call, view or not.
    function _exitAll(address who) internal {
        uint256 bal = hook.balanceOf(who);
        vm.prank(who); hook.transfer(HOOKA, bal);
    }
    function _roster() internal view returns (address[7] memory) {
        return [alice, bob, carol, old1, old2, late, address(preRunner)];
    }
    function _mirrored(address a) internal view {
        assertLe(hook.nftBalanceOf(a), hook.balanceOf(a) / UNIT, "unbacked share");
    }
    function _sumShares() internal view returns (uint256 s) {
        address[7] memory w = _roster();
        for (uint256 i; i < 7; ++i) s += hook.nftBalanceOf(w[i]);
    }
    /// Everything the fee layer owes or has already paid in ETH, realized + unrealized + withdrawn.
    function _obligation() internal view returns (uint256 t) {
        address[7] memory w = _roster();
        for (uint256 i; i < 7; ++i) {
            t += hook.pendingETH(w[i]) + w[i].balance;
            uint256[] memory ids = hook.ownedTokensOf(w[i]);
            for (uint256 j; j < ids.length; ++j) { (uint256 e,) = hook.pendingFees(ids[j]); t += e; }
        }
    }
    function _solvent() internal view {
        assertLe(_obligation(), posm.totalPaid(), "ETH promised beyond what the POSM delivered");
        assertLe(_obligation(), HOOKA.balance + _paidOut(), "hook cannot cover its promises");
    }
    function _paidOut() internal view returns (uint256 t) {
        address[7] memory w = _roster();
        for (uint256 i; i < 7; ++i) t += w[i].balance;
    }

    /*──────────────── the boundary itself ────────────────*/

    /// Every whole-token boundary case in one deterministic sweep. The mint budget is a BALANCE DELTA,
    /// so what matters is which boundaries the recipient crossed — not how much was sent.
    function test_boundaryExactCases() public {
        // 0 -> just under 1: crosses nothing.
        vm.prank(HOOKA); hook.transfer(alice, UNIT - 1);
        assertEq(hook.nftBalanceOf(alice), 0, "sub-unit balance minted a share");

        // ...then 1 wei tips it to exactly 1: crosses exactly one boundary.
        vm.prank(HOOKA); hook.transfer(alice, 1);
        assertEq(hook.balanceOf(alice), UNIT);
        assertEq(hook.nftBalanceOf(alice), 1, "1e18-1 -> 1e18 did not mint");

        // exactly-on-boundary -> exactly-on-boundary: one whole token, one share.
        vm.prank(HOOKA); hook.transfer(alice, UNIT);
        assertEq(hook.nftBalanceOf(alice), 2);

        // A large sub-unit top-up that reaches no boundary mints nothing, then 1 wei mints one.
        vm.prank(HOOKA); hook.transfer(alice, UNIT - 1);          // 2.999...
        assertEq(hook.nftBalanceOf(alice), 2, "minted for a boundary it did not reach");
        vm.prank(HOOKA); hook.transfer(alice, 1);                  // 3.0
        assertEq(hook.nftBalanceOf(alice), 3);

        // Sending 1 wei OUT of an exact multiple burns exactly one share (entitlement really fell).
        uint256 sharesBefore = hook.nftBalanceOf(alice);
        vm.prank(alice); hook.transfer(bob, 1);
        assertEq(hook.nftBalanceOf(alice), sharesBefore - 1, "outflow below a boundary kept a share");
        assertEq(hook.nftBalanceOf(bob), 0);

        // Self-transfer moves nothing, so it crosses nothing and mints nothing — at any size.
        uint256 s = hook.nftBalanceOf(alice);
        uint256 whole = hook.balanceOf(alice);
        vm.prank(alice); hook.transfer(alice, whole);
        assertEq(hook.nftBalanceOf(alice), s, "self-transfer changed the share count");
        assertEq(hook.balanceOf(alice), whole, "self-transfer changed the balance");
        vm.prank(alice); hook.transfer(alice, 0);
        assertEq(hook.nftBalanceOf(alice), s);
        vm.prank(alice); hook.transfer(alice, 1);
        assertEq(hook.nftBalanceOf(alice), s);

        // Zero-value transfer to a third party: no crossing, no mint, however many times repeated.
        for (uint256 i; i < 12; ++i) { vm.prank(alice); hook.transfer(carol, 0); }
        assertEq(hook.nftBalanceOf(carol), 0, "free share forced by zero-value transfers");

        _mirrored(alice); _mirrored(bob); _mirrored(carol);
        assertEq(hook.totalShares(), _sumShares());
        _solvent();
    }

    /// Arbitrary residues on both sides of a transfer: shares equal floor(balance/UNIT) exactly, on
    /// both sender and recipient, for every offset the fuzzer can reach below the MAX_REALIGN cap.
    function testFuzz_neverUnbackedAcrossAnyResidue(uint96 a, uint96 b, uint96 c) public {
        uint256 x = uint256(a) % (12 * UNIT);
        uint256 y = uint256(b) % (12 * UNIT);
        uint256 z = uint256(c) % (12 * UNIT);
        vm.prank(HOOKA); hook.transfer(alice, x);
        vm.prank(HOOKA); hook.transfer(bob, y);
        assertEq(hook.nftBalanceOf(alice), x / UNIT, "alice mis-mirrored on arrival");
        assertEq(hook.nftBalanceOf(bob),   y / UNIT, "bob mis-mirrored on arrival");

        uint256 send = z > x ? x : z;
        vm.prank(alice); hook.transfer(bob, send);
        assertEq(hook.nftBalanceOf(alice), hook.balanceOf(alice) / UNIT, "alice off after transfer");
        assertEq(hook.nftBalanceOf(bob),   hook.balanceOf(bob)   / UNIT, "bob off after transfer");
        assertEq(hook.totalShares(), _sumShares());
    }

    /// Round-tripping value through the hook (an excluded endpoint — the sell/buy path) leaves exactly
    /// the shares the balance backs, with no ratchet in either direction.
    function testFuzz_excludedRoundTripNoRatchet(uint96 amt, uint8 rounds) public {
        uint256 a = uint256(amt) % (60 * UNIT) + 1;
        vm.prank(HOOKA); hook.transfer(alice, a);
        for (uint256 i; i < uint256(rounds) % 6 + 1; ++i) {
            uint256 bal = hook.balanceOf(alice);
            vm.prank(alice); hook.transfer(HOOKA, bal / 3);
            assertEq(hook.nftBalanceOf(alice), hook.balanceOf(alice) / UNIT, "gap opened on sell");
            vm.prank(HOOKA); hook.transfer(alice, bal / 3);
            assertEq(hook.nftBalanceOf(alice), hook.balanceOf(alice) / UNIT, "gap opened on buy");
        }
        assertEq(hook.nftBalanceOf(alice), hook.balanceOf(alice) / UNIT);
    }

    /*──────────────── MAX_REALIGN meets the quarantine ────────────────*/

    /// A single transfer that BOTH moves and mints, with exact expected numbers.
    function test_singleTransferThatBothMintsAndMoves() public {
        vm.prank(HOOKA); hook.transfer(alice, 400 ether);
        assertEq(hook.nftBalanceOf(alice), 128, "MAX_REALIGN is not 128");
        uint256 total0 = hook.totalShares();

        // Pure mint path: alice keeps 200 tokens so she sheds nothing; bob's 200 mints cap at 128.
        vm.prank(alice); hook.transfer(bob, 200 ether);
        assertEq(hook.nftBalanceOf(bob), 128, "recipient mint not capped at MAX_REALIGN");
        assertEq(hook.nftBalanceOf(alice), 128, "sender lost shares it still backs");
        assertEq(hook.totalShares(), total0 + 128);

        // Combined path: alice falls to 50 tokens holding 128 shares, so 78 MOVE and 72 are MINTED
        // (mintBudget 150 and MAX_REALIGN 128 both leave room), landing carol on exactly 150.
        vm.prank(alice); hook.transfer(carol, 150 ether);
        assertEq(hook.balanceOf(alice), 50 ether);
        assertEq(hook.nftBalanceOf(alice), 50, "sender did not shed down to entitlement");
        assertEq(hook.nftBalanceOf(carol), 150, "move+mint arithmetic wrong");
        assertEq(hook.totalShares(), total0 + 128 + 72, "share ledger desynced across mint+move");
        _mirrored(alice); _mirrored(bob); _mirrored(carol);

        // bob's residual gap closes via syncNFTs and never overshoots entitlement.
        vm.prank(bob); hook.syncNFTs(0);
        assertEq(hook.nftBalanceOf(bob), 200, "syncNFTs did not converge");
        vm.prank(bob); hook.syncNFTs(0);
        assertEq(hook.nftBalanceOf(bob), 200, "syncNFTs overshot entitlement");
        assertEq(hook.totalShares(), _sumShares());
        _solvent();
    }

    /// THE SECURITY HALF of the quarantine: `_mintedThisTx` is `tokenId >= lo` where `lo` is the
    /// FIRST id minted this transaction. Because ids are monotonic, `lo` is always above every
    /// pre-existing id, so no third party can ever cause someone else's older shares to be
    /// quarantined and have their accrued fees zeroed by `_claimOne`. Proved side by side in ONE
    /// transaction: fresh shares get nothing from the round they diluted, older shares get all of it.
    function test_quarantineCannotReachAnOlderShare() public {
        AtomicRunner r = new AtomicRunner();
        vm.prank(HOOKA); hook.approve(address(r), type(uint256).max);

        uint256 sharesBefore = hook.totalShares();
        assertEq(sharesBefore, 25, "setUp roster changed"); // 10 + 6 + 4 + 5

        // Fresh in-tx shares: 20 minted, then a 30 ETH round, then claimed. Must credit zero.
        uint256 credited = r.buyPokeClaim(hook, HOOKA, 20 ether, posm, 30 ether);
        assertEq(credited, 0, "fresh in-tx share captured same-tx fees");
        assertEq(hook.nftBalanceOf(address(r)), 20);

        // The SAME round, same transaction: every setUp-minted share is fully paid.
        uint256 accNow = hook.accFeesPerShareETH();
        uint256 round2PerShare = (accNow - accRound1) / ACC;
        assertGt(round2PerShare, 0, "no round to claim: this test would prove nothing");

        uint256[] memory a = hook.ownedTokensOf(old1);
        for (uint256 i; i < a.length; ++i) hook.claim(a[i]);
        assertEq(hook.pendingETH(old1), 10 * (accRound1 / ACC) + 10 * round2PerShare,
            "older shares were wrongly quarantined, or mis-paid");

        // `late` arrived after round 1 (still in setUp), so it gets round 2 only — never round 1.
        uint256[] memory l = hook.ownedTokensOf(late);
        for (uint256 i; i < l.length; ++i) hook.claim(l[i]);
        assertEq(hook.pendingETH(late), 4 * round2PerShare, "late arrival back-claimed a closed round");

        _solvent();
    }

    /// The quarantine does not persist across transactions: shares minted in setUp's transaction are
    /// fully paid by a round collected in the body. (This is the discriminating half — if the marker
    /// leaked, `preRunner` would be credited zero here.)
    function test_quarantineDoesNotPersistAcrossTransactions() public {
        posm.arm(12 ether);
        hook.pokeFees();
        uint256 perShare = (hook.accFeesPerShareETH() - accRound1) / ACC;
        assertGt(perShare, 0);

        uint256[] memory ids = hook.ownedTokensOf(address(preRunner));
        assertEq(ids.length, 5);
        hook.claimMany(ids);
        assertEq(hook.pendingETH(address(preRunner)), 5 * perShare,
            "a share minted in an earlier transaction was still quarantined");
        _solvent();
    }

    /// Selling in the same tx as the buy burns the FRESH (tail) shares first, so the burn path cannot
    /// launder a quarantined slice into `pendingETH`, and the holder's older shares are untouched.
    function test_sameTxBuyPokeSellCapturesNothing() public {
        AtomicRunner r = new AtomicRunner();
        vm.prank(HOOKA); hook.approve(address(r), type(uint256).max);
        uint256 credited = r.buyPokeSell(hook, HOOKA, 15 ether, posm, 25 ether);
        assertEq(credited, 0, "burn path laundered a same-tx slice into pending");
        assertEq(hook.nftBalanceOf(address(r)), 0);
        _solvent();
    }

    /*──────────────── totalShares 0 -> 1 -> 0 -> 1 ────────────────*/

    /// Walk the share count to zero and back three times across separate fee rounds. What must hold
    /// is that no shareholder is ever paid ETH the fee layer did not receive, that the withheld
    /// backlog stays IN the hook rather than becoming claimable by whoever appears next, and that the
    /// flag is one-shot rather than sticky (a sticky flag would silently destroy every future round).
    function test_zeroShareCyclesNeverOverPromiseAndNeverPayTheNextArrival() public {
        _exitAll(old1); _exitAll(old2); _exitAll(late); _exitAll(address(preRunner));
        assertEq(hook.totalShares(), 0);
        assertTrue(hook.forfeitNextCollection(), "flag not armed when shares hit zero");

        uint256 forfeited;
        for (uint256 cycle; cycle < 3; ++cycle) {
            // Fees accrue while NOBODY holds a share.
            posm.arm(4 ether);

            // A holder appears. The realign poke sees totalShares == 0 and does nothing.
            vm.prank(HOOKA); hook.transfer(alice, 2 ether);
            assertEq(hook.nftBalanceOf(alice), 2);
            assertTrue(hook.forfeitNextCollection(), "flag cleared without a collection");

            // First collection after the zero-share window: forfeited, and it stays in the hook.
            uint256 accBefore  = hook.accFeesPerShareETH();
            uint256 hookBefore = HOOKA.balance;
            hook.pokeFees();
            assertEq(hook.accFeesPerShareETH(), accBefore, "forfeited round still credited holders");
            assertEq(HOOKA.balance - hookBefore, 4 ether, "forfeited ETH left the hook");
            assertFalse(hook.forfeitNextCollection(), "flag not consumed");
            forfeited += 4 ether;

            // A NORMAL round now distributes, so the flag is one-shot rather than sticky.
            posm.arm(1 ether);
            hook.pokeFees();
            assertGt(hook.accFeesPerShareETH(), accBefore, "flag stuck: no round ever distributes");

            _exitAll(alice);
            assertEq(hook.totalShares(), 0);
            assertTrue(hook.forfeitNextCollection(), "flag not re-armed");
        }

        // The withheld backlog is still sitting in the hook, and nobody was over-paid.
        assertGe(HOOKA.balance, forfeited, "forfeited ETH is not still in the hook");
        _solvent();
    }

    /// A holder whose share count falls to zero keeps every wei it accrued while it held: the burn
    /// captures into `pendingETH` before the share is destroyed, and the withdrawal pays it out.
    function test_exitKeepsAccruedAndLosesNothing() public {
        uint256 owedBefore;
        uint256[] memory ids = hook.ownedTokensOf(old2);
        for (uint256 i; i < ids.length; ++i) { (uint256 e,) = hook.pendingFees(ids[i]); owedBefore += e; }
        assertEq(owedBefore, 6 * (accRound1 / ACC));
        assertGt(owedBefore, 0, "nothing accrued: this test would prove nothing");

        _exitAll(old2);                                   // 6 shares burn, each capturing first
        assertEq(hook.nftBalanceOf(old2), 0);
        assertEq(hook.pendingETH(old2), owedBefore, "exiting holder lost its accrued ETH");

        uint256 before = old2.balance;
        vm.prank(old2); hook.withdrawPending();
        assertEq(old2.balance - before, owedBefore, "exiting holder could not withdraw");
        _solvent();
    }

    /// A holder that arrives strictly between two rounds is paid the second and never the first, and
    /// the two rounds use the correct (different) denominators.
    function test_denominatorsAcrossArrivalAreExact() public {
        uint256 shares1 = 25;                               // 10 + 6 + 4 + 5 after setUp
        assertEq(hook.totalShares(), shares1);
        assertEq(accRound1, 9 ether * ACC / 16, "round 1 used the wrong denominator");

        posm.arm(10 ether); hook.pokeFees();
        uint256 acc2 = hook.accFeesPerShareETH();
        assertEq(acc2 - accRound1, 10 ether * ACC / shares1, "round 2 used the wrong denominator");

        uint256[] memory l = hook.ownedTokensOf(late);
        for (uint256 i; i < l.length; ++i) hook.claim(l[i]);
        assertEq(hook.pendingETH(late), 4 * ((acc2 - accRound1) / ACC));

        uint256[] memory o = hook.ownedTokensOf(old1);
        for (uint256 i; i < o.length; ++i) hook.claim(o[i]);
        assertEq(hook.pendingETH(old1), 10 * (accRound1 / ACC) + 10 * ((acc2 - accRound1) / ACC));
        _solvent();
    }
}
