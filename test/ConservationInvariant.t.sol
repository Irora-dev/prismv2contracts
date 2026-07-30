// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

/// Conservation of both fee legs, tightening what `test/InvariantPrism.t.sol` asserts:
/// `invariant_ethSolvency` asserts only `hook.balance >= Sum pendingETH`, i.e. the REALIZED half of
/// the ETH liability. The unrealized half — `(accFeesPerShareETH - debt)/ACC_SCALE` summed over every
/// live share — is never included, and the mock POSM is dealt 1,000,000 ETH, so the slack is many
/// orders of magnitude wide. An ETH over-promise (the mirror image of the PRISM check that IS tight)
/// would pass 30,000 calls unnoticed. This file states the tight version for BOTH legs and adds the
/// handler actions the existing suite does not drive: withdrawPendingTo, mirror safeTransferFrom,
/// transfers to every excluded sink, 1-wei / exact-multiple / self transfers, third-party
/// transferFrom, and an atomic mint->poke->claim bundle in a single call frame.

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
    function syncNFTs(uint256 max) external;
    function pendingETH(address) external view returns (uint256);
    function pendingPRISM(address) external view returns (uint256);
    function pendingFees(uint256 tokenId) external view returns (uint256, uint256);
    function accFeesPerShareETH() external view returns (uint256);
    function accFeesPerSharePRISM() external view returns (uint256);
}

interface IMirror {
    function transferFrom(address, address, uint256) external;
    function safeTransferFrom(address, address, uint256) external;
    function setApprovalForAll(address, bool) external;
    function approve(address, uint256) external;
}

interface IPrismMin { function transfer(address, uint256) external returns (bool); }
interface IBalOf   { function balanceOf(address) external view returns (uint256); }

contract Permit2Stub { function approve(address,address,uint160,uint48) external {} }
contract MockPoolManager { function exttload(bytes32) external pure returns (bytes32) { return bytes32(0); } }

/// One-shot POSM: a collect drains what accrued, exactly like the real one. Ghost-counts every wei
/// and every PRISM it has ever pushed INTO the hook, which is what makes the conservation bound tight.
contract GhostPOSM {
    uint256 public feeEth;
    uint256 public feePrism;
    address public prism;
    uint256 public totalEthPaid;
    uint256 public totalPrismPaid;
    receive() external payable {}
    function setPrism(address p) external { prism = p; }
    function arm(uint256 e, uint256 p) external { feeEth = e; feePrism = p; }
    function modifyLiquidities(bytes calldata, uint256) external {
        uint256 e = feeEth; uint256 p = feePrism;
        feeEth = 0; feePrism = 0;
        if (e > 0) { (bool ok,) = msg.sender.call{value: e}(""); require(ok, "eth"); totalEthPaid += e; }
        if (p > 0 && prism != address(0) && IBalOf(prism).balanceOf(address(this)) >= p) {
            IPrismMin(prism).transfer(msg.sender, p);
            totalPrismPaid += p;
        }
    }
    function nextTokenId() external pure returns (uint256) { return 1; }
    function multicall(bytes[] calldata) external {}
}

/// Accepts ERC-721 pushes. Also usable as a withdrawPendingTo destination.
contract GoodReceiver {
    bytes4 constant SEL = 0x150b7a02;
    receive() external payable {}
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return SEL;
    }
}

contract Handler is Test {
    IHook   public hook;
    IMirror public mirror;
    address public HOOKADDR;
    GhostPOSM public posm;
    address[] public actors;
    GoodReceiver public rx;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// Ghost: PRISM paid out of the hook to satisfy `pendingPRISM`. Needed to make the PRISM
    /// non-inflation bound tight — the existing suite ignores already-withdrawn PRISM entirely.
    uint256 public prismPaidOut;

    /// Ghost: PRISM an ACTOR sent straight to 0xdEaD. `balanceOf(DEAD)` is otherwise not a clean
    /// reading of the fee-layer burn, and treating it as one produces a false over-promise report.
    uint256 public directToDead;

    constructor(IHook h, address ha, GhostPOSM p, address[] memory a, GoodReceiver r) {
        hook = h; HOOKADDR = ha; posm = p; actors = a; rx = r;
        mirror = IMirror(h.mirror());
    }

    function _actor(uint256 s) internal view returns (address) { return actors[s % actors.length]; }

    // ── ordinary churn ───────────────────────────────────────────────────────
    function transfer(uint256 f, uint256 t, uint256 amt) external {
        address from = _actor(f); address to = _actor(t);
        uint256 bal = hook.balanceOf(from);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        vm.prank(from); try hook.transfer(to, amt) {} catch {}
    }

    /// EXACT whole-token multiples: the boundary case where transferable == mintBudget and toMint == 0.
    function transferExact(uint256 f, uint256 t, uint256 whole) external {
        address from = _actor(f); address to = _actor(t);
        uint256 bal = hook.balanceOf(from);
        if (bal < 1 ether) return;
        uint256 amt = bound(whole, 1, bal / 1 ether) * 1 ether;
        vm.prank(from); try hook.transfer(to, amt) {} catch {}
    }

    /// One wei: crosses a boundary only when the recipient sat at 1e18-1 mod 1e18.
    function transferWei(uint256 f, uint256 t) external {
        address from = _actor(f); address to = _actor(t);
        if (hook.balanceOf(from) == 0) return;
        vm.prank(from); try hook.transfer(to, 1) {} catch {}
    }

    /// Leave the recipient exactly 1 wei short of a boundary, then tip it over.
    function tipBoundary(uint256 f, uint256 t) external {
        address from = _actor(f); address to = _actor(t);
        if (from == to) return;
        uint256 need = 1 ether - 1 - (hook.balanceOf(to) % 1 ether);
        if (need == 0 || hook.balanceOf(from) < need + 1) return;
        vm.prank(from); try hook.transfer(to, need) {} catch {}
        vm.prank(from); try hook.transfer(to, 1) {} catch {}
    }

    function selfTransfer(uint256 f, uint256 amt) external {
        address a = _actor(f);
        uint256 bal = hook.balanceOf(a);
        if (bal == 0) return;
        vm.prank(a); try hook.transfer(a, bound(amt, 1, bal)) {} catch {}
    }

    /// Every excluded sink, not just the hook. address(0) included: solady's `transfer` permits it.
    function toExcluded(uint256 f, uint256 which, uint256 amt) external {
        address from = _actor(f);
        uint256 bal = hook.balanceOf(from);
        if (bal == 0) return;
        address[6] memory sinks = [HOOKADDR, DEAD, address(posm), address(mirror), address(0), address(0)];
        address to = sinks[which % 5];
        uint256 send = bound(amt, 1, bal);
        vm.prank(from); try hook.transfer(to, send) {} catch { return; }
        // The transfer itself delivers exactly `send` to DEAD; any fee burn a nested poke performs is
        // ON TOP of that and is genuine fee-layer burn, so only `send` is subtracted out below.
        if (to == DEAD) directToDead += send;
    }

    /// Third-party pull: ERC-20 allowance moves NFTs (documented DN404 behaviour) — drive it.
    function pullTransfer(uint256 f, uint256 sp, uint256 t, uint256 amt) external {
        address from = _actor(f); address spender = _actor(sp); address to = _actor(t);
        uint256 bal = hook.balanceOf(from);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        vm.prank(from); try hook.approve(spender, amt) {} catch { return; }
        vm.prank(spender); try hook.transferFrom(from, to, amt) {} catch {}
    }

    // ── mirror / ERC-721 surface ─────────────────────────────────────────────
    function mirrorMove(uint256 f, uint256 t, uint256 ts) external {
        address from = _actor(f); address to = _actor(t);
        if (from == to) return;
        uint256[] memory ids = hook.ownedTokensOf(from);
        if (ids.length == 0) return;
        vm.prank(from); try mirror.transferFrom(from, to, ids[ts % ids.length]) {} catch {}
    }

    function mirrorSafeMoveToContract(uint256 f, uint256 ts) external {
        address from = _actor(f);
        uint256[] memory ids = hook.ownedTokensOf(from);
        if (ids.length == 0) return;
        vm.prank(from); try mirror.safeTransferFrom(from, address(rx), ids[ts % ids.length]) {} catch {}
    }

    function mirrorApprovedMove(uint256 f, uint256 sp, uint256 t, uint256 ts) external {
        address from = _actor(f); address spender = _actor(sp); address to = _actor(t);
        if (from == to) return;
        uint256[] memory ids = hook.ownedTokensOf(from);
        if (ids.length == 0) return;
        uint256 id = ids[ts % ids.length];
        vm.prank(from); try mirror.approve(spender, id) {} catch { return; }
        vm.prank(spender); try mirror.transferFrom(from, to, id) {} catch {}
    }

    // ── fee layer ────────────────────────────────────────────────────────────
    function poke(uint256 e, uint256 p) external {
        posm.arm(bound(e, 0, 3 ether), bound(p, 0, 2 ether));
        try hook.pokeFees() {} catch {}
    }

    function claim(uint256 a, uint256 ts) external {
        uint256[] memory ids = hook.ownedTokensOf(_actor(a));
        if (ids.length == 0) return;
        try hook.claim(ids[ts % ids.length]) {} catch {}
    }

    function claimAll(uint256 a) external {
        uint256[] memory ids = hook.ownedTokensOf(_actor(a));
        if (ids.length == 0) return;
        try hook.claimMany(ids) {} catch {}
    }

    function withdraw(uint256 a) external {
        address who = _actor(a);
        uint256 owed = hook.pendingPRISM(who);
        vm.prank(who);
        try hook.withdrawPending() { prismPaidOut += owed; } catch {}
    }

    /// The existing suite never drives this. Routes value to a THIRD party, which then mirror-mints.
    function withdrawTo(uint256 a, uint256 t) external {
        address who = _actor(a); address to = _actor(t);
        uint256 owed = hook.pendingPRISM(who);
        vm.prank(who);
        try hook.withdrawPendingTo(to) { prismPaidOut += owed; } catch {}
    }

    function sync(uint256 a, uint256 m) external {
        address who = _actor(a);
        vm.prank(who); try hook.syncNFTs(bound(m, 0, 400)) {} catch {}
    }

    /// mint -> poke -> claim, all inside ONE call frame, so the anti-JIT transient marker is shared.
    function atomicJIT(uint256 f, uint256 t, uint256 whole, uint256 e) external {
        address from = _actor(f); address to = _actor(t);
        if (from == to) return;
        uint256 bal = hook.balanceOf(from);
        if (bal < 1 ether) return;
        posm.arm(bound(e, 0, 3 ether), 0);
        vm.prank(from);
        try hook.transfer(to, bound(whole, 1, bal / 1 ether) * 1 ether) {} catch { return; }
        try hook.pokeFees() {} catch {}
        uint256[] memory ids = hook.ownedTokensOf(to);
        if (ids.length == 0) return;
        try hook.claimMany(ids) {} catch {}
    }

    function actorsLength() external view returns (uint256) { return actors.length; }
    function actorAt(uint256 i) external view returns (address) { return actors[i]; }
}

contract ConservationInvariant is Test {
    address constant HOOKA = address(0x2040); // beforeInitialize + afterSwap flag bits
    address constant OWNER = address(0xB0B);
    address constant DEAD  = 0x000000000000000000000000000000000000dEaD;
    uint256 constant SUPPLY = 5000 ether;

    IHook hook;
    MockPoolManager pm;
    GhostPOSM posm;
    Permit2Stub p2;
    Handler handler;
    GoodReceiver rx;
    address[] actors;
    uint256 hookPrismAtStart;

    function setUp() public {
        pm = new MockPoolManager(); posm = new GhostPOSM(); p2 = new Permit2Stub();
        rx = new GoodReceiver();
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(address(pm), OWNER, address(posm), address(p2), address(0), uint256(0)), HOOKA);
        hook = IHook(HOOKA);
        vm.store(HOOKA, bytes32(uint256(0)), bytes32(uint256(1))); // seeded = true
        vm.deal(address(posm), 1_000_000 ether);

        actors.push(address(0xA1)); actors.push(address(0xA2));
        actors.push(address(0xA3)); actors.push(address(0xA4));
        actors.push(address(rx));   // a CONTRACT holder, so the pending-credit-to-contract path is live

        vm.prank(HOOKA); hook.transfer(actors[0], 400 ether); // > MAX_REALIGN => under-mirrored
        vm.prank(HOOKA); hook.transfer(actors[1], 50 ether);
        vm.prank(HOOKA); hook.transfer(actors[2], 7 ether);
        vm.prank(HOOKA); hook.transfer(actors[3], 3 ether + 0.4 ether);
        vm.prank(HOOKA); hook.transfer(actors[4], 2 ether + 0.9 ether);

        // Fee reservoir for the PRISM leg. Funded ONCE so the withdrawn-PRISM ghost stays exact.
        vm.prank(HOOKA); hook.transfer(address(posm), 600 ether);
        posm.setPrism(HOOKA);
        hookPrismAtStart = hook.balanceOf(HOOKA);

        // Burn the seed forfeit so the very first collection is not swallowed.
        posm.arm(0, 0);
        hook.pokeFees();

        handler = new Handler(hook, HOOKA, posm, actors, rx);
        targetContract(address(handler));
    }

    // ── obligation accounting ────────────────────────────────────────────────

    function _sumPendingETH() internal view returns (uint256 s) {
        for (uint256 i; i < actors.length; ++i) s += hook.pendingETH(actors[i]);
    }
    function _sumPendingPRISM() internal view returns (uint256 s) {
        for (uint256 i; i < actors.length; ++i) s += hook.pendingPRISM(actors[i]);
    }
    /// `(acc - debt)/ACC_SCALE` over every live share. THE TERM THE EXISTING ETH CHECK OMITS.
    function _sumUnrealized() internal view returns (uint256 e, uint256 p) {
        for (uint256 i; i < actors.length; ++i) {
            uint256[] memory ids = hook.ownedTokensOf(actors[i]);
            for (uint256 j; j < ids.length; ++j) {
                (uint256 oe, uint256 op) = hook.pendingFees(ids[j]);
                e += oe; p += op;
            }
        }
    }
    function _sumActorETH() internal view returns (uint256 s) {
        for (uint256 i; i < actors.length; ++i) s += actors[i].balance;
    }

    /// TIGHT ETH SOLVENCY: the hook can pay every wei it currently owes, realized AND unrealized.
    function invariant_ethSolventIncludingUnrealized() public view {
        (uint256 unrealE,) = _sumUnrealized();
        assertGe(HOOKA.balance, _sumPendingETH() + unrealE, "hook cannot cover its full ETH liability");
    }

    /// TIGHT ETH NON-INFLATION: everything the fee layer has ever promised or paid in ETH came out of
    /// ETH the POSM actually delivered. Catches an over-promise that the balance check would tolerate.
    function invariant_ethNeverPromisesMoreThanReceived() public view {
        (uint256 unrealE,) = _sumUnrealized();
        assertLe(_sumActorETH() + _sumPendingETH() + unrealE, posm.totalEthPaid(), "ETH over-promised");
    }

    /// Exact ETH conservation: nothing appears, nothing evaporates outside the two ledgers.
    function invariant_ethExactlyConserved() public view {
        assertEq(HOOKA.balance + _sumActorETH(), posm.totalEthPaid(), "ETH leaked");
    }

    /// TIGHT PRISM NON-INFLATION, now including PRISM already withdrawn (the existing suite's bound
    /// silently forgives every payout that has already happened).
    function invariant_prismNeverPromisesMoreThanReceived() public view {
        (, uint256 unrealP) = _sumUnrealized();
        uint256 owed = _sumPendingPRISM() + unrealP + handler.prismPaidOut();
        uint256 feeBurn = hook.balanceOf(DEAD) - handler.directToDead();
        assertLe(feeBurn + owed, posm.totalPrismPaid(), "PRISM over-promised");
    }

    function invariant_prismSolventIncludingUnrealized() public view {
        (, uint256 unrealP) = _sumUnrealized();
        assertGe(hook.balanceOf(HOOKA), _sumPendingPRISM() + unrealP, "hook cannot cover PRISM liability");
    }

    /// No unbacked shares, on every actor including the contract holder.
    function invariant_noUnbackedShares() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertLe(hook.nftBalanceOf(actors[i]), hook.balanceOf(actors[i]) / 1 ether, "unbacked");
        }
    }

    /// Every share is accounted for on a known actor: nothing parked anywhere invisible.
    function invariant_sharesAllOnActors() public view {
        uint256 s;
        for (uint256 i; i < actors.length; ++i) s += hook.nftBalanceOf(actors[i]);
        assertEq(hook.totalShares(), s, "shares off-actor");
    }

    /// Not one share on any excluded address, ever.
    function invariant_excludedHoldNothing() public view {
        assertEq(hook.nftBalanceOf(HOOKA), 0);
        assertEq(hook.nftBalanceOf(address(pm)), 0);
        assertEq(hook.nftBalanceOf(address(posm)), 0);
        assertEq(hook.nftBalanceOf(address(p2)), 0);
        assertEq(hook.nftBalanceOf(hook.mirror()), 0);
        assertEq(hook.nftBalanceOf(DEAD), 0);
        assertEq(hook.nftBalanceOf(address(0)), 0);
        assertEq(hook.pendingETH(HOOKA) + hook.pendingPRISM(HOOKA), 0);
        assertEq(hook.pendingETH(DEAD) + hook.pendingPRISM(DEAD), 0);
        assertEq(hook.pendingETH(address(0)) + hook.pendingPRISM(address(0)), 0);
    }

    function invariant_supplyConserved() public view {
        uint256 s;
        for (uint256 i; i < actors.length; ++i) s += hook.balanceOf(actors[i]);
        s += hook.balanceOf(HOOKA) + hook.balanceOf(address(pm)) + hook.balanceOf(address(posm))
           + hook.balanceOf(address(p2)) + hook.balanceOf(hook.mirror())
           + hook.balanceOf(DEAD) + hook.balanceOf(address(0));
        assertEq(s, SUPPLY, "supply moved");
    }
}
