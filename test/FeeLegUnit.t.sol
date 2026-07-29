// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

interface IHook {
    function mirror() external view returns (address);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function nftBalanceOf(address) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function ownedTokensOf(address) external view returns (uint256[] memory);
    function pokeFees() external;
    function claim(uint256) external;
    function withdrawPending() external;
    function withdrawPendingTo(address recipient) external;
    function pendingETH(address) external view returns (uint256);
    function pendingPRISM(address) external view returns (uint256);
    function accFeesPerShareETH() external view returns (uint256);
    function accFeesPerSharePRISM() external view returns (uint256);
    function forfeitNextCollection() external view returns (bool);
}

interface IPrismMin { function transfer(address, uint256) external returns (bool); }

/// A POSM whose collect always reverts — a pause, a migration, a deadline change.
contract FailingPOSM {
    receive() external payable {}
    function modifyLiquidities(bytes calldata, uint256) external pure { revert("POSM down"); }
    function nextTokenId() external pure returns (uint256) { return 1; }
    function multicall(bytes[] calldata) external {}
}

contract Permit2Stub { function approve(address,address,uint160,uint48) external {} }
contract PMStub { function exttload(bytes32) external pure returns (bytes32) { return bytes32(0); } }

/// A POSM that pays exactly what it is told, ONCE per `set`, and records it.
///
/// One-shot is what makes the arithmetic checkable, and it is also what a real collect does: it drains
/// the fees that have accrued and the position then has nothing further to give until more trading
/// happens. A mock that re-pays on every collect compounds silently — `claim()` calls `_maybePoke()`, so
/// claiming ten shares triggers ten more collects, and the expected values drift by a factor that looks
/// like a contract bug. Measured while writing this: a 50-PRISM fee produced 80 PRISM of promises, and a
/// 5-ETH fee produced 32.5 ETH.
contract FeePOSM {
    uint256 public feeEth;
    uint256 public feePrism;
    address public prism;
    uint256 public firings;
    receive() external payable {}
    function set(address p, uint256 e, uint256 pr) external { prism = p; feeEth = e; feePrism = pr; }
    function modifyLiquidities(bytes calldata, uint256) external {
        uint256 e = feeEth;
        uint256 pr = feePrism;
        feeEth = 0; feePrism = 0;                 // one-shot: a collect drains what accrued
        if (e > 0)  { (bool ok,) = msg.sender.call{value: e}(""); require(ok, "eth send"); }
        if (pr > 0) { IPrismMin(prism).transfer(msg.sender, pr); }
        if (e > 0 || pr > 0) firings++;
    }
    function nextTokenId() external pure returns (uint256) { return 1; }
    function multicall(bytes[] calldata) external {}
}

/// DETERMINISTIC proof that both fee legs run and split correctly.
///
/// This exists because the invariant campaign cannot provide that guarantee. `afterInvariant` fires
/// after each run, not once per campaign, and at 500 runs x depth 60 a sequence draws `poke` only a
/// handful of times — measured, some sequences never call it at all. A coverage assertion there is
/// flaky by construction, and a coverage assertion is exactly what the PRISM leg needed: for a long
/// while the mock POSM paid ETH only, so the 80/20 split, the burn and PRISM solvency went completely
/// unexercised across 30,000 calls while the suite reported zero reverts.
///
/// Fixed inputs, exact expected values, no bounds and no fuzzing.
contract FeeLegUnit is Test {
    address constant HOOK  = address(0x2040);
    address constant OWNER = address(0xB0B);
    address constant BURN  = 0x000000000000000000000000000000000000dEaD;
    uint256 constant ACC_SCALE = 1e12;

    IHook hook;
    FeePOSM posm;
    address alice = address(0xA1);

    function setUp() public {
        PMStub pm = new PMStub();
        posm = new FeePOSM();
        Permit2Stub p2 = new Permit2Stub();
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(address(pm), OWNER, address(posm), address(p2), address(0), uint256(0)), HOOK);
        hook = IHook(HOOK);
        vm.store(HOOK, bytes32(uint256(0)), bytes32(uint256(1))); // seeded = true
        vm.deal(address(posm), 1000 ether);

        // 10 whole tokens to alice => 10 shares. Minted in setUp, which is its own transaction, so the
        // transient-storage anti-JIT quarantine does not swallow the claim in the test body.
        vm.prank(HOOK); hook.transfer(alice, 10 ether);
        // Fund the mock so it can pay PRISM fees in.
        vm.prank(HOOK); hook.transfer(address(posm), 100 ether);
    }

    /// The PRISM leg: 80% to holders via the accumulator, 20% burned to 0xdEaD, exactly.
    function test_PrismFeeSplitsEightyTwentyExactly() public {
        assertEq(hook.totalShares(), 10, "10 whole tokens => 10 shares");
        uint256 burnBefore = hook.balanceOf(BURN);
        uint256 accBefore  = hook.accFeesPerSharePRISM();

        posm.set(HOOK, 0, 50 ether);
        hook.pokeFees();

        assertEq(posm.firings(), 1, "the fee leg must actually have run");
        // 20% of 50 = 10 burned; 40 to holders across 10 shares = 4 per share, scaled.
        assertEq(hook.balanceOf(BURN) - burnBefore, 10 ether, "burn must be exactly 20%");
        assertEq(hook.accFeesPerSharePRISM() - accBefore, 40 ether * ACC_SCALE / 10,
                 "holders must be credited exactly 80%");
    }

    /// And the credited amount is really claimable, to the wei.
    function test_HolderClaimsExactlyTheirEightyPercentShare() public {
        posm.set(HOOK, 0, 50 ether);
        hook.pokeFees();

        uint256[] memory ids = hook.ownedTokensOf(alice);
        assertEq(ids.length, 10, "alice holds 10 shares");
        for (uint256 i; i < ids.length; ++i) hook.claim(ids[i]);

        // 40 PRISM to holders, alice holds all 10 shares, so she is owed all of it.
        assertEq(hook.pendingPRISM(alice), 40 ether, "alice is owed the whole 80% slice");

        uint256 before_ = hook.balanceOf(alice);
        vm.prank(alice); hook.withdrawPending();
        assertEq(hook.balanceOf(alice) - before_, 40 ether, "and receives it exactly");
        assertEq(hook.pendingPRISM(alice), 0, "pending is cleared");
    }

    /// The ETH leg: 100% to holders, no burn.
    function test_EthFeeGoesEntirelyToHolders() public {
        uint256 accBefore = hook.accFeesPerShareETH();
        posm.set(HOOK, 5 ether, 0);
        hook.pokeFees();

        assertEq(posm.firings(), 1, "the fee leg must actually have run");
        assertEq(hook.accFeesPerShareETH() - accBefore, 5 ether * ACC_SCALE / 10,
                 "ETH is credited 100% to holders");

        uint256[] memory ids = hook.ownedTokensOf(alice);
        for (uint256 i; i < ids.length; ++i) hook.claim(ids[i]);
        assertEq(hook.pendingETH(alice), 5 ether, "alice is owed the whole ETH fee");

        uint256 before_ = alice.balance;
        vm.prank(alice); hook.withdrawPending();
        assertEq(alice.balance - before_, 5 ether, "and receives it exactly");
    }

    /// Both legs in one collect, which is the real shape of a two-sided fee round.
    function test_BothLegsInOneCollect() public {
        posm.set(HOOK, 2 ether, 30 ether);
        uint256 burnBefore = hook.balanceOf(BURN);
        hook.pokeFees();

        assertEq(hook.balanceOf(BURN) - burnBefore, 6 ether, "20% of 30 PRISM burned");
        assertEq(hook.accFeesPerShareETH(),   2 ether * ACC_SCALE / 10, "ETH credited");
        assertEq(hook.accFeesPerSharePRISM(), 24 ether * ACC_SCALE / 10, "80% of PRISM credited");
    }

    /// Conservation, stated the way the invariant states it: what the fee layer promises plus what it
    /// burned can never exceed what it actually received.
    function test_FeeLayerNeverPromisesMoreThanItReceived() public {
        posm.set(HOOK, 0, 50 ether);
        hook.pokeFees();
        posm.set(HOOK, 0, 25 ether);
        hook.pokeFees();

        uint256 received = 75 ether;
        uint256 burned   = hook.balanceOf(BURN);
        uint256[] memory ids = hook.ownedTokensOf(alice);
        for (uint256 i; i < ids.length; ++i) hook.claim(ids[i]);
        uint256 owed = hook.pendingPRISM(alice);

        assertEq(burned, 15 ether, "20% of 75");
        assertEq(owed,   60 ether, "80% of 75");
        assertLe(burned + owed, received, "fee layer promised more than it received");
    }

    /// A collect while `totalShares == 0` must credit nobody rather than reverting or stranding a
    /// promise — the zero-share forfeit. Documented behaviour, pinned here so it cannot drift silently.
    function test_CollectWithNoSharesCreditsNobody() public {
        // Move alice's whole balance back to the hook (excluded) so every share burns.
        vm.prank(alice); hook.transfer(HOOK, 10 ether);
        assertEq(hook.totalShares(), 0, "no shares outstanding");

        uint256 accBefore = hook.accFeesPerSharePRISM();
        posm.set(HOOK, 1 ether, 10 ether);
        hook.pokeFees();   // must not revert
        assertEq(hook.accFeesPerSharePRISM(), accBefore, "nothing credited with no shares");
    }

    /// Burning the LAST share must arm the forfeit, and the next collect must be destroyed rather than
    /// handed to whoever happens to arrive next.
    ///
    /// This pins the causal link at `_burnNFT`: `if (totalShares == 0) forfeitNextCollection = true;`.
    /// Nothing else in the suite does. The test above passes purely because of the `totalShares == 0`
    /// early return, so the flag is never load-bearing in it; `HardeningUnit` arms the flag with
    /// `vm.store` and so bypasses `_burnNFT` entirely. Deleting that line would leave both green.
    ///
    /// The property matters because it is the anti-skim guarantee: fees that accrued while nobody held
    /// a share belong to nobody, and must not become a windfall for the first shareholder to appear.
    function test_BurningTheLastShareArmsTheForfeitAndDestroysTheBacklog() public {
        // Accrue a real pot while alice holds every share, but do NOT let her claim it.
        posm.set(HOOK, 3 ether, 0);
        hook.pokeFees();
        assertGt(hook.accFeesPerShareETH(), 0, "a pot exists");

        // Alice exits completely -> the last share burns -> the forfeit must arm.
        vm.prank(alice); hook.transfer(HOOK, 10 ether);
        assertEq(hook.totalShares(), 0, "every share burned");
        assertTrue(hook.forfeitNextCollection(), "burning the last share must arm the forfeit");

        // A newcomer arrives and a fee round lands. The newcomer must NOT inherit the zero-share
        // backlog: the first collection after the gap is destroyed.
        address bob = address(0xB0B0);
        vm.prank(HOOK); hook.transfer(bob, 4 ether);
        assertEq(hook.totalShares(), 4, "newcomer holds shares");

        uint256 accAtArrival = hook.accFeesPerShareETH();
        posm.set(HOOK, 2 ether, 0);
        hook.pokeFees();
        assertEq(hook.accFeesPerShareETH(), accAtArrival, "the first collect after a gap is forfeited");
        assertFalse(hook.forfeitNextCollection(), "and the flag disarms after being consumed");

        // The round after that credits normally, so the forfeit is one-shot rather than permanent.
        posm.set(HOOK, 2 ether, 0);
        hook.pokeFees();
        assertGt(hook.accFeesPerShareETH(), accAtArrival, "subsequent collects credit normally");
    }

}

/// A contract that holds PRISM and has NO code path that calls `withdrawPending` /
/// `withdrawPendingTo` — the unavoidable real case being an ordinary Uniswap V2/V3 pool holding PRISM.
///
/// The inertness is the point: both withdrawal functions pay `msg.sender`'s own credit, so a holder that
/// cannot originate that call can never take delivery, and no third party can do it on its behalf.
/// Note it is deliberately NOT a contract that rejects ETH — solady's forced-transfer would deliver to
/// one of those anyway, so rejecting ETH is not what makes fees unreachable.
contract NonClaimer {
    receive() external payable {}
}

/// PRISM parked on a contract that cannot retrieve its fees still mints shares, and the fees routed to
/// those shares are unrecoverable — every other holder is diluted by exactly that weight.
///
/// `README.md` documents this as a known property ("an ordinary Uniswap V2/V3 pool is the common case")
/// and nothing else in the suite exercised it. Pinned so the documented behaviour and the actual
/// behaviour cannot drift, and so the dilution is quantified rather than asserted.
///
/// Its own contract, with the sink funded in `setUp`, because the anti-JIT quarantine is transient-storage
/// keyed and a whole test body is ONE transaction: shares minted in the body are quarantined and credit
/// nothing, which reads exactly like a contract bug. Measured while writing this — the sink was credited
/// 0 instead of its 50%.
contract FeeLegNonClaimer is Test {
    address constant HOOK = address(0x2040);
    address constant OWNER = address(0xB0B);
    IHook hook;
    FeePOSM posm;
    NonClaimer sink;
    address alice = address(0xA1);

    function setUp() public {
        PMStub pm = new PMStub();
        posm = new FeePOSM();
        Permit2Stub p2 = new Permit2Stub();
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(address(pm), OWNER, address(posm), address(p2), address(0), uint256(0)), HOOK);
        hook = IHook(HOOK);
        vm.store(HOOK, bytes32(uint256(0)), bytes32(uint256(1))); // seeded = true
        vm.deal(address(posm), 1000 ether);

        sink = new NonClaimer();
        vm.prank(HOOK); hook.transfer(alice, 10 ether);
        vm.prank(HOOK); hook.transfer(address(sink), 10 ether);   // minted here, not in the test body
    }

    function test_SharesOnANonClaimingContractDiluteEveryoneElse() public {
        assertEq(hook.nftBalanceOf(address(sink)), 10, "a non-claiming contract still mints shares");
        assertEq(hook.totalShares(), 20, "alice 10 + sink 10");

        posm.set(HOOK, 10 ether, 0);
        hook.pokeFees();

        // Alice gets half of what she would have had the sink not existed.
        uint256[] memory ids = hook.ownedTokensOf(alice);
        for (uint256 i; i < ids.length; ++i) hook.claim(ids[i]);
        assertEq(hook.pendingETH(alice), 5 ether, "alice receives only her 50% share");

        // The other half is credited to the sink...
        uint256[] memory sinkIds = hook.ownedTokensOf(address(sink));
        for (uint256 i; i < sinkIds.length; ++i) hook.claim(sinkIds[i]);
        assertEq(hook.pendingETH(address(sink)), 5 ether, "the other 50% is credited to the sink");

        // ...and is unreachable. Both withdrawal functions pay the CALLER's own credit, so nobody can
        // extract the sink's balance for it: alice withdrawing takes only her own 5 ETH and leaves the
        // sink's untouched. The sink has no function that could originate the call itself.
        vm.prank(alice); hook.withdrawPending();
        assertEq(hook.pendingETH(alice), 0, "alice took her own credit");
        assertEq(hook.pendingETH(address(sink)), 5 ether,
                 "the sink's 50% remains credited to an address that can never call withdrawPending");

        // And `withdrawPendingTo` does not let a third party reach it either: it pays the CALLER's credit
        // to a chosen recipient, not the recipient's credit. Asserted explicitly because without this the
        // "unreachable" claim above is untested — a version of `_withdrawPendingTo` that paid the
        // recipient's balance instead would falsify it and this test would still have passed.
        vm.prank(alice); hook.withdrawPendingTo(address(sink));
        assertEq(hook.pendingETH(address(sink)), 5 ether,
                 "a third party cannot drain the sink's credit by naming it as a recipient");
    }
}

/// A failing collect must be OBSERVABLE, not silent.
///
/// `pokeFees` deliberately swallows a POSM-side revert, because this contract is immutable with no admin
/// and a bare revert there would be unrecoverable. The hazard is that a swallowed failure used to look
/// exactly like "nothing accrued" — so the keeper that bounds the fee backlog could report ten healthy
/// pokes while nothing was being collected and the backlog compounded. `PokeCollectFailed` is the alarm.
contract FeeLegPokeAlarm is Test {
    address constant HOOK = address(0x2040);
    address constant OWNER = address(0xB0B);
    event PokeCollectFailed();

    IHook hook;

    function setUp() public {
        PMStub pm = new PMStub();
        FailingPOSM posm = new FailingPOSM();
        Permit2Stub p2 = new Permit2Stub();
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(address(pm), OWNER, address(posm), address(p2), address(0), uint256(0)), HOOK);
        hook = IHook(HOOK);
        vm.store(HOOK, bytes32(uint256(0)), bytes32(uint256(1))); // seeded
        vm.prank(HOOK); hook.transfer(address(0xA1), 5 ether);    // shares exist, so poke does not early-return
    }

    function test_AFailingCollectEmitsTheAlarmAndDoesNotRevert() public {
        assertEq(hook.totalShares(), 5, "shares exist so pokeFees proceeds to the collect");
        vm.expectEmit(false, false, false, true, HOOK);
        emit PokeCollectFailed();
        hook.pokeFees();   // must NOT revert - bricking on a POSM failure would be unrecoverable
    }
}
