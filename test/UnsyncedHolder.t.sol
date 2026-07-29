// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

interface IHook {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function nftBalanceOf(address) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function ownedTokensOf(address) external view returns (uint256[] memory);
    function pokeFees() external;
    function claim(uint256) external;
    function withdrawPending() external;
    function syncNFTs(uint256) external;
    function pendingETH(address) external view returns (uint256);
    function accFeesPerShareETH() external view returns (uint256);
}

interface IPrismMin { function transfer(address, uint256) external returns (bool); }

contract Permit2Stub { function approve(address,address,uint160,uint48) external {} }
contract PMStub { function exttload(bytes32) external pure returns (bytes32) { return bytes32(0); } }

contract FeePOSM {
    uint256 public feeEth;
    receive() external payable {}
    function set(uint256 e) external { feeEth = e; }
    function modifyLiquidities(bytes calldata, uint256) external {
        uint256 e = feeEth; feeEth = 0;                       // one-shot; a collect drains what accrued
        if (e > 0) { (bool ok,) = msg.sender.call{value: e}(""); require(ok, "eth send"); }
    }
    function nextTokenId() external pure returns (uint256) { return 1; }
    function multicall(bytes[] calldata) external {}
}

/// What an UNDER-MIRRORED holder costs, and whether anyone can turn it to their advantage.
///
/// A holder receiving more than `MAX_REALIGN` (128) whole PRISM in one transfer gets ALL their PRISM and
/// only 128 fee-shares. `syncNFTs` mints the rest and is caller-only, so nobody can do it for them and no
/// event announces it. For the published snapshot that is 5 holders and 288 shares.
///
/// The question these tests answer is not "is it untidy" but "can it be abused". Established below:
///
///   1. Under-mirroring is the SAFE direction — shares never exceed backing, so no unbacked share exists.
///   2. Fees accruing during the window go to the OTHER holders, correctly: `totalShares` genuinely
///      excludes the unminted shares, so the accumulator divides by the right number and every share
///      outstanding gets its true pro-rata slice. Nothing is destroyed or stranded.
///   3. Syncing later works, but the new shares earn only from that point — `_setFeeDebt` stamps them at
///      the current accumulator. So delay is a REAL and PERMANENT loss to the late syncer, and a matching
///      gain to everyone else. That is the actual cost, and it is why the operator should chase them.
///   4. Nobody can prevent the sync, and nobody can profit beyond passively holding shares that were
///      always theirs.
contract UnsyncedHolder is Test {
    address constant HOOK  = address(0x2040);
    address constant OWNER = address(0xB0B);
    uint256 constant ACC_SCALE = 1e12;

    IHook hook;
    FeePOSM posm;
    address big   = address(0xB16);      // receives >128 whole tokens: ends under-mirrored
    address small = address(0x5A11);     // receives <128: fully mirrored

    function setUp() public {
        PMStub pm = new PMStub();
        posm = new FeePOSM();
        Permit2Stub p2 = new Permit2Stub();
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(address(pm), OWNER, address(posm), address(p2), address(0), uint256(0)), HOOK);
        hook = IHook(HOOK);
        vm.store(HOOK, bytes32(uint256(0)), bytes32(uint256(1))); // seeded
        vm.deal(address(posm), 1000 ether);

        // Exactly the shape the airdrop push produces: one transfer of the full allocation from an
        // excluded address (the vault), which is where MAX_REALIGN bites.
        vm.prank(HOOK); hook.transfer(big, 287 ether);     // the largest real holder's allocation
        vm.prank(HOOK); hook.transfer(small, 100 ether);   // a holder under the cap
    }

    /// 1. The push delivers PRISM exactly, and under-mirroring is the safe direction.
    function test_PrismIsExactAndSharesNeverExceedBacking() public view {
        assertEq(hook.balanceOf(big), 287 ether, "PRISM delivered in full, to the wei");
        assertEq(hook.nftBalanceOf(big), 128, "but only 128 shares - MAX_REALIGN");
        assertEq(hook.nftBalanceOf(small), 100, "a holder under the cap is fully mirrored");

        // The invariant that matters: never MORE shares than backing. Under is safe, over would not be.
        assertLe(hook.nftBalanceOf(big), hook.balanceOf(big) / 1 ether, "no unbacked share");
        assertLe(hook.nftBalanceOf(small), hook.balanceOf(small) / 1 ether, "no unbacked share");
    }

        /// 4. No attacker can prevent the sync, and the "griefing" vector actually HELPS an unsynced holder.
    ///
    /// Forcing shares onto a third party is the documented griefing vector. Aimed at an under-mirrored
    /// holder it mints shares that holder is already entitled to — a favour, not an attack — and it can
    /// never push them past their own entitlement.
    function test_NobodyCanBlockTheSyncAndForcingOnlyHelps() public {
        address attacker = address(0xA77ACC);
        vm.prank(HOOK); hook.transfer(attacker, 5 ether);

        uint256 before_ = hook.nftBalanceOf(big);
        vm.prank(attacker); hook.transfer(big, 1 ether);      // "attack": push a token at them
        assertGe(hook.nftBalanceOf(big), before_, "forcing can only ever ADD shares they are owed");
        assertLe(hook.nftBalanceOf(big), hook.balanceOf(big) / 1 ether, "and never past entitlement");

        // The holder can still sync whenever they like — permissionless for self, and unblockable.
        vm.prank(big); hook.syncNFTs(0);
        vm.prank(big); hook.syncNFTs(0);
        assertEq(hook.nftBalanceOf(big), hook.balanceOf(big) / 1 ether, "sync succeeds regardless");
    }
}

/// The cost of syncing LATE, measured across real transaction boundaries.
///
/// `setUp` is its own transaction, so state it establishes is genuinely "from a previous block" as far as
/// the anti-JIT quarantine is concerned. That matters here: minting and claiming inside one transaction
/// makes the fresh shares quarantined and credit ZERO, which looks exactly like the effect being measured
/// and would silently overstate it. (Measured while writing this: 159 shares credited 0 for that reason.)
contract UnsyncedHolderSyncedLate is Test {
    address constant HOOK = address(0x2040);
    address constant OWNER = address(0xB0B);
    IHook hook;
    FeePOSM posm;
    address big   = address(0xB16);
    address small = address(0x5A11);

    function setUp() public {
        posm = new FeePOSM();
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(address(new PMStub()), OWNER, address(posm), address(new Permit2Stub()),
                       address(0), uint256(0)), HOOK);
        hook = IHook(HOOK);
        vm.store(HOOK, bytes32(uint256(0)), bytes32(uint256(1)));
        vm.deal(address(posm), 1000 ether);

        vm.prank(HOOK); hook.transfer(big, 287 ether);     // under-mirrored at 128
        vm.prank(HOOK); hook.transfer(small, 100 ether);

        // A fee round lands while `big` is still under-mirrored...
        posm.set(10 ether);
        hook.pokeFees();
        // ...and only afterwards does `big` catch up. All of this is in setUp, i.e. a prior transaction.
        vm.prank(big); hook.syncNFTs(0);
        vm.prank(big); hook.syncNFTs(0);
    }

    function test_TheMissedRoundIsGoneButFutureRoundsAreFull() public {
        assertEq(hook.nftBalanceOf(big), 287, "synced, just too late");
        assertEq(hook.totalShares(), 387);

        // Claim what the missed round left owing.
        uint256[] memory ids = hook.ownedTokensOf(big);
        for (uint256 i; i < ids.length; ++i) hook.claim(ids[i]);
        uint256 fromMissedRound = hook.pendingETH(big);

        uint256 ifSyncedInTime = uint256(10 ether) * 287 / 387;   // 74% of the round
        uint256 onlyThe128     = uint256(10 ether) * 128 / 228;   // what it actually held then
        console2.log("round 1 if synced in time (wei):", ifSyncedInTime);
        console2.log("round 1 actually earned   (wei):", fromMissedRound);
        console2.log("permanently forgone       (wei):", ifSyncedInTime - fromMissedRound);

        // The 159 late shares earn NOTHING from a round that predates them: they were stamped with the
        // accumulator as it stood when minted. This is the real, unrecoverable cost of delay.
        assertApproxEqRel(fromMissedRound, onlyThe128, 0.01e18, "only the shares held at the time earn");
        assertLt(fromMissedRound, ifSyncedInTime, "syncing late costs real, unrecoverable fees");

        // But from here on it earns its full weight — the loss is bounded to the delay.
        vm.prank(big); hook.withdrawPending();
        posm.set(10 ether);
        hook.pokeFees();
        for (uint256 i; i < ids.length; ++i) hook.claim(ids[i]);

        uint256 fullShare = uint256(10 ether) * 287 / 387;
        console2.log("round 2 earned            (wei):", hook.pendingETH(big));
        console2.log("round 2 full entitlement  (wei):", fullShare);
        assertApproxEqRel(hook.pendingETH(big), fullShare, 0.01e18, "full pro-rata once synced");
    }

    /// Conservation across the whole episode: the fee layer never promises more than it took in, whatever
    /// the sync state. A shortfall is integer-division dust retained by the hook, which is the safe side.
    function test_NoFeesLostOrDoubleCounted() public {
        posm.set(10 ether);
        hook.pokeFees();                                  // round 2, after the sync

        uint256[] memory a = hook.ownedTokensOf(big);
        for (uint256 i; i < a.length; ++i) hook.claim(a[i]);
        uint256[] memory b = hook.ownedTokensOf(small);
        for (uint256 i; i < b.length; ++i) hook.claim(b[i]);

        uint256 promised = hook.pendingETH(big) + hook.pendingETH(small);
        console2.log("collected across both rounds (wei):", uint256(20 ether));
        console2.log("promised to holders          (wei):", promised);
        console2.log("dust retained by the hook    (wei):", uint256(20 ether) - promised);

        assertLe(promised, 20 ether, "never promises more than it received");
        assertGt(promised, 19.99 ether, "and the remainder is only rounding dust");
    }
}
