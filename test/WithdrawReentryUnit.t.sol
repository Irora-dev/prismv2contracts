// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

/// `_withdrawPendingTo` (PrismHookV2.sol:818-843) makes an ALL-GAS ETH
/// call to an arbitrary recipient. Prior rounds proved the GUARDED entry points (`claim`,
/// `withdrawPending`, `syncNFTs`) revert re-entrantly. This file attacks what is NOT guarded and is
/// reachable from that same window: the ERC-20 surface (`transfer` / `transferFrom` / `approve`) and
/// `pokeFees()` itself — all of which re-enter the fee layer through `_afterTokenTransfer` ->
/// `_maybePoke` -> `pokeFees` -> `_mintCapped`.
///
/// It also settles the `pendingETH` restore line with tests that DISCRIMINATE — a weaker pair of tests
/// passes under either `=` or `+=` and settles nothing: the success path must KEEP credit created
/// mid-flight, and the failure path must show the credit actually rolled back.

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
    function withdrawPendingTo(address) external;
    function syncNFTs(uint256) external;
    function pendingETH(address) external view returns (uint256);
    function pendingPRISM(address) external view returns (uint256);
    function pendingFees(uint256) external view returns (uint256, uint256);
    function accFeesPerShareETH() external view returns (uint256);
}

contract Permit2Stub { function approve(address,address,uint160,uint48) external {} }
contract PMStub { function exttload(bytes32) external pure returns (bytes32) { return bytes32(0); } }

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

/// The victim/caller: a contract holder that owns shares and initiates the withdrawal.
contract Holder {
    IHook hook;
    constructor(IHook h) { hook = h; }
    receive() external payable {}
    function withdrawTo(address to) external { hook.withdrawPendingTo(to); }
    function withdrawSelf() external { hook.withdrawPending(); }
    function approveAll(address who) external { hook.approve(who, type(uint256).max); }
}

/// Hostile ETH recipient. During the all-gas send it hammers every UNGUARDED entry point.
contract HostileRecipient {
    IHook public hook;
    address public caller;         // the address whose pending is being paid
    uint256 public victimTokenId;  // a share owned by `caller`, claimable permissionlessly
    uint8   public mode;           // 0 = passive, 1 = churn ERC20+poke, 2 = credit caller then revert
                                   // 3 = credit caller then RETURN OK
    bool public reenteredGuarded;  // true if any guarded entry point unexpectedly succeeded
    uint256 public seenPending;

    function wire(IHook h, address c, uint256 id) external { hook = h; caller = c; victimTokenId = id; }
    function setMode(uint8 m) external { mode = m; }

    receive() external payable {
        if (mode == 0) return;

        // Guarded surface MUST be shut while we are inside _withdrawPendingTo.
        try hook.withdrawPending() { reenteredGuarded = true; } catch {}
        try hook.claimMany(new uint256[](0)) { reenteredGuarded = true; } catch {}
        try hook.syncNFTs(0) { reenteredGuarded = true; } catch {}
        try hook.claim(victimTokenId) { reenteredGuarded = true; } catch {}

        seenPending = hook.pendingETH(caller);

        if (mode == 1) {
            // UNGUARDED: ERC-20 movement drives _afterTokenTransfer -> _maybePoke -> pokeFees ->
            // _mintCapped, and pokeFees is itself public and unguarded.
            try hook.pokeFees() {} catch {}
            uint256 bal = hook.balanceOf(caller);
            if (bal >= 2 ether) { try hook.transferFrom(caller, address(this), 2 ether) {} catch {} }
            try hook.pokeFees() {} catch {}
            if (hook.balanceOf(address(this)) >= 1 ether) {
                try hook.transfer(caller, 1 ether) {} catch {}
            }
        } else if (mode == 2) {
            _creditCaller();
            revert("reject after crediting");
        } else if (mode == 3) {
            _creditCaller();
        }
    }

    /// `claim` is permissionless and credits the OWNER, so from here we can create pendingETH for
    /// `caller` mid-flight. Guarded, so it must be routed through an unguarded ERC-20 path instead:
    /// paying PRISM to `caller` mirror-mints and pokes, which is the only credit channel open here.
    function _creditCaller() internal {
        uint256 bal = hook.balanceOf(address(this));
        if (bal >= 1 ether) { try hook.transfer(caller, bal) {} catch {} }
        try hook.pokeFees() {} catch {}
    }
}

/// Rejects ETH outright, to exercise the restore branch on its own.
contract Rejector {
    receive() external payable { revert("no eth"); }
}

contract WithdrawReentryUnit is Test {
    address constant HOOKA = address(0x2040);
    address constant OWNER = address(0xB0B);
    uint256 constant ACC   = 1e12;

    IHook hook;
    PMStub pm;
    EthPOSM posm;
    Permit2Stub p2;
    Holder holder;
    HostileRecipient hostile;
    address bystander = address(0xB5);

    uint256 accRound1;

    function setUp() public {
        pm = new PMStub(); posm = new EthPOSM(); p2 = new Permit2Stub();
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(address(pm), OWNER, address(posm), address(p2), address(0), uint256(0)), HOOKA);
        hook = IHook(HOOKA);
        vm.store(HOOKA, bytes32(uint256(0)), bytes32(uint256(1))); // seeded
        vm.deal(address(posm), 1_000_000 ether);

        holder  = new Holder(hook);
        hostile = new HostileRecipient();
        // forge funds the test contract with ~2^96 wei by default; it is a withdrawal destination
        // below, so zero it or every conservation ghost is swamped.
        vm.deal(address(this), 0);

        // Shares minted HERE (transaction #1) so their accrual is live in every body.
        vm.prank(HOOKA); hook.transfer(address(holder), 20 ether);
        vm.prank(HOOKA); hook.transfer(bystander, 30 ether);
        vm.prank(HOOKA); hook.transfer(address(hostile), 6 ether);

        // Round 1: real ETH into the hook, distributed over 56 shares.
        posm.arm(28 ether);
        hook.pokeFees();
        accRound1 = hook.accFeesPerShareETH();
        assertGt(accRound1, 0);

        holder.approveAll(address(hostile)); // so the hostile recipient can pull mid-flight
        hostile.wire(hook, address(holder), hook.ownedTokensOf(address(holder))[0]);
    }

    function _totalObligation() internal view returns (uint256 t) {
        address[4] memory w = [address(holder), bystander, address(hostile), address(this)];
        for (uint256 i; i < 4; ++i) {
            t += hook.pendingETH(w[i]) + w[i].balance;
            uint256[] memory ids = hook.ownedTokensOf(w[i]);
            for (uint256 j; j < ids.length; ++j) { (uint256 e,) = hook.pendingFees(ids[j]); t += e; }
        }
    }
    function _paidOut() internal view returns (uint256 t) {
        address[4] memory w = [address(holder), bystander, address(hostile), address(this)];
        for (uint256 i; i < 4; ++i) t += w[i].balance;
    }
    function _solvent() internal view {
        assertLe(_totalObligation(), posm.totalPaid(), "ETH promised beyond what was received");
        assertLe(_totalObligation() - _paidOut(), HOOKA.balance, "hook cannot cover its promises");
        assertEq(HOOKA.balance + _paidOut(), posm.totalPaid(), "ETH leaked");
    }
    function _claimAll(address who) internal {
        uint256[] memory ids = hook.ownedTokensOf(who);
        for (uint256 i; i < ids.length; ++i) hook.claim(ids[i]);
    }

    /// The guarded surface is shut during the all-gas send; the UNGUARDED surface is open and gains
    /// nothing. The recipient is paid exactly what the caller was owed — not a wei more — and every
    /// other holder's entitlement survives intact.
    function test_hostileRecipientChurningUnguardedSurfaceGainsNothing() public {
        _claimAll(address(holder));
        uint256 owed = hook.pendingETH(address(holder));
        assertEq(owed, 20 * (accRound1 / ACC), "holder's slice is wrong");
        assertGt(owed, 0, "nothing owed: this test would prove nothing");

        // A second, uncollected round exists for the reentrant poke to try to double-count.
        posm.arm(11 ether);

        uint256 bystanderOwedBefore;
        {
            uint256[] memory ids = hook.ownedTokensOf(bystander);
            for (uint256 i; i < ids.length; ++i) { (uint256 e,) = hook.pendingFees(ids[i]); bystanderOwedBefore += e; }
        }
        uint256 hostileEthBefore = address(hostile).balance;

        hostile.setMode(1);
        holder.withdrawTo(address(hostile));

        assertFalse(hostile.reenteredGuarded(), "a guarded entry point was re-entered");
        // The recipient got exactly the caller's credit. The reentrant poke's 11 ETH went into the
        // accumulator for every live share, not into this payment.
        assertEq(address(hostile).balance - hostileEthBefore, owed, "recipient took the wrong amount");
        // Any pendingETH the holder ends with is NEW credit that the recipient's mid-flight pull
        // (using an ERC-20 allowance the holder itself granted) captured out of the holder's own
        // shares — its own accrued fees, not anyone else's. The anti-theft statement is the global
        // conservation check below, which is what would break if the churn manufactured value.
        assertLe(hook.pendingETH(address(holder)), posm.totalPaid(), "impossible credit");
        // The bystander never lost ground; it can only have gained from the reentrant collection.
        uint256 bystanderOwedAfter;
        {
            uint256[] memory ids = hook.ownedTokensOf(bystander);
            for (uint256 i; i < ids.length; ++i) { (uint256 e,) = hook.pendingFees(ids[i]); bystanderOwedAfter += e; }
        }
        assertGe(bystanderOwedAfter, bystanderOwedBefore, "bystander's accrued ETH was reduced");
        _solvent();
    }

    /// DISCRIMINATING TEST FOR THE SUCCESS PATH. The recipient creates NEW credit for the caller and
    /// then returns normally. `ok` is true, so no restore runs and the new credit MUST survive.
    /// If the restore were unconditional (or an `=` on the success path), the caller would end with
    /// the OLD amount instead — a different, checkable number.
    function test_creditCreatedDuringASuccessfulSendSurvives() public {
        _claimAll(address(holder));
        uint256 owed = hook.pendingETH(address(holder));
        assertGt(owed, 0);

        // Arm a round so the mid-flight poke actually accrues something for the holder's shares.
        posm.arm(9 ether);
        hostile.setMode(3);
        holder.withdrawTo(address(hostile));

        // The mid-flight activity (PRISM paid to the holder + a poke) accrued fresh, unrealized ETH
        // for the holder. Realise it and confirm it is nonzero — i.e. there WAS something the
        // restore could have clobbered.
        _claimAll(address(holder));
        uint256 after_ = hook.pendingETH(address(holder));
        assertGt(after_, 0, "no mid-flight credit was created: this test would prove nothing");
        assertTrue(after_ != owed, "post-state coincides with the pre-state: not discriminating");
        _solvent();
    }

    /// DISCRIMINATING TEST FOR THE FAILURE PATH. The recipient creates credit and THEN reverts. Its
    /// whole frame rolls back, so (a) the caller's credit is restored to exactly the original amount
    /// and (b) the mid-flight effects are provably gone — the shares it would have advanced still
    /// carry their unrealized accrual, and the hook's ETH never moved. This is what makes `=` and
    /// `+=` indistinguishable on that line, rather than merely untested.
    function test_failedSendRestoresExactlyAndRollsBackMidFlightEffects() public {
        _claimAll(address(holder));
        uint256 owed = hook.pendingETH(address(holder));
        assertGt(owed, 0);

        uint256 accBefore   = hook.accFeesPerShareETH();
        uint256 hookETH     = HOOKA.balance;
        uint256 sharesBefore = hook.totalShares();
        uint256 holderPrism = hook.balanceOf(address(holder));

        posm.arm(9 ether);          // something the mid-flight poke would have collected
        hostile.setMode(2);
        holder.withdrawTo(address(hostile));   // does NOT revert: the ETH leg fails softly

        assertEq(hook.pendingETH(address(holder)), owed, "credit not restored exactly");
        // Proof the reverted frame left nothing behind: the accumulator, the hook's ETH, the share
        // count and the holder's PRISM are all untouched, and the 9 ETH is still uncollected.
        assertEq(hook.accFeesPerShareETH(), accBefore, "mid-flight poke persisted");
        assertEq(HOOKA.balance, hookETH, "hook ETH moved on a failed send");
        assertEq(hook.totalShares(), sharesBefore, "mid-flight mint persisted");
        assertEq(hook.balanceOf(address(holder)), holderPrism, "mid-flight PRISM move persisted");
        assertEq(posm.feeEth(), 9 ether, "the armed round was collected by the reverted frame");

        // Retry to a good address recovers the full amount: nothing is stranded by the failure.
        uint256 before = address(this).balance;
        holder.withdrawTo(address(this));
        assertEq(address(this).balance - before, owed, "retry did not recover the credit");
        assertEq(hook.pendingETH(address(holder)), 0);
        _solvent();
    }

    /// A recipient that rejects ETH outright leaves the credit intact and fully recoverable by a
    /// retry to a different address — the failure does not revert the call and does not strand value.
    function test_ethRejectorKeepsCreditAndItStaysRecoverable() public {
        _claimAll(address(holder));
        uint256 owedETH = hook.pendingETH(address(holder));
        assertGt(owedETH, 0);

        Rejector rj = new Rejector();
        holder.withdrawTo(address(rj));
        assertEq(hook.pendingETH(address(holder)), owedETH, "ETH credit lost to a rejecting recipient");
        assertEq(address(rj).balance, 0);

        uint256 before = address(this).balance;
        holder.withdrawTo(address(this));
        assertEq(address(this).balance - before, owedETH, "credit not recoverable after a rejection");
        _solvent();
    }

    /// `withdrawPendingTo` refuses every excluded sink, so a holder cannot route its own fees
    /// somewhere unrecoverable — including the two v2 added (Permit2, the mirror) and the burn sink.
    function test_withdrawPendingToRejectsEverySink() public {
        _claimAll(address(holder));
        assertGt(hook.pendingETH(address(holder)), 0);
        address[7] memory bad = [HOOKA, address(pm), address(posm), address(p2),
                                 hook.mirror(), 0x000000000000000000000000000000000000dEaD, address(0)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert();
            holder.withdrawTo(bad[i]);
        }
        assertGt(hook.pendingETH(address(holder)), 0, "credit lost to a rejected sink");
        _solvent();
    }

    receive() external payable {}
}
