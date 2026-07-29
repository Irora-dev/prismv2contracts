// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey}  from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks}   from "@uniswap/v4-core/src/interfaces/IHooks.sol";

interface IHook {
    function mirror() external view returns (address);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function nftBalanceOf(address) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function ownedTokensOf(address) external view returns (uint256[] memory);
    function pokeFees() external;
    function claim(uint256 tokenId) external;
    function claimMany(uint256[] calldata) external;
    function withdrawPending() external;
    function withdrawPendingTo(address) external;
    function syncNFTs(uint256 max) external;
    function pendingETH(address) external view returns (uint256);
    function pendingPRISM(address) external view returns (uint256);
    function pendingFees(uint256 tokenId) external view returns (uint256, uint256);
    function accFeesPerShareETH() external view returns (uint256);
    function forfeitNextCollection() external view returns (bool);
}

contract Permit2Stub {
    function approve(address, address, uint160, uint48) external {}
}

/// Minimal PoolManager: `isUnlocked()` reads exttload(IS_UNLOCKED_SLOT); return 0 => locked,
/// so pokeFees proceeds past its `isUnlocked` guard.
contract MockPoolManager {
    function exttload(bytes32) external pure returns (bytes32) { return bytes32(0); }
}

/// Configurable POSM stand-in. On modifyLiquidities it either reverts (to exercise the
/// try/catch) or forwards `feeEth` ETH to the caller (the hook), simulating a fee collection
/// that bumps accFeesPerShareETH. Uses ETH-only so it never triggers ERC20 realignment noise.
contract MockPOSM {
    bool    public shouldRevert;
    uint256 public feeEth;

    receive() external payable {}
    function setRevert(bool v) external { shouldRevert = v; }
    function setFeeEth(uint256 v) external { feeEth = v; }

    function modifyLiquidities(bytes calldata, uint256) external {
        require(!shouldRevert, "POSM down");
        if (feeEth > 0) {
            (bool ok,) = msg.sender.call{value: feeEth}("");
            require(ok, "fund hook");
        }
    }
    // seed() path is not exercised in these unit tests.
    function nextTokenId() external pure returns (uint256) { return 1; }
    function multicall(bytes[] calldata) external {}
}

/// Executes mint -> poke -> claim in ONE message call, so the anti-JIT transient marker is
/// unambiguously shared across the sequence (single tx context) regardless of test-runner
/// transient-storage semantics. `source` is an EXCLUDED address (the hook) so receiving whole
/// tokens MINTS fresh shares (mirrors a flash-borrow from the pool), not a share move.
contract AtomicJITAttacker {
    function run(IHook hook, address source, uint256 amount) external returns (uint256 freshId) {
        hook.transferFrom(source, address(this), amount); // mint fresh shares (marks tx)
        hook.pokeFees();                                  // advance the accumulator
        freshId = hook.ownedTokensOf(address(this))[0];
        hook.claim(freshId);                              // try to realize the jump, same tx
    }
}

contract HardeningUnit is Test {
    address constant V2_ADDR = address(0x2040); // beforeInitialize + afterSwap
    address constant OWNER   = address(0xB0B);

    IHook  hook;
    MockPoolManager pm;
    MockPOSM        posm;
    Permit2Stub     permit2;

    address user  = address(0xA11CE);
    address user2 = address(0xCAFE);
    address whale;
    address bigReceiver = address(0xB19);
    RejectsEth rejecter;

    function setUp() public {
        pm      = new MockPoolManager();
        posm    = new MockPOSM();
        permit2 = new Permit2Stub();
        whale   = address(0xDECAF);

        deployCodeTo(
            "PrismHookV2.sol:PrismHookV2",
            abi.encode(address(pm), OWNER, address(posm), address(permit2), address(0), uint256(0)),
            V2_ADDR
        );
        hook = IHook(V2_ADDR);

        // Force seeded=true (slot 0) so pokeFees runs without a full V4 seed.
        vm.store(V2_ADDR, bytes32(uint256(0)), bytes32(uint256(1)));

        // Fund the mock POSM with ETH to hand out as "collected fees".
        vm.deal(address(posm), 100 ether);

        // Baseline PRE-EXISTING shares. Minted in setUp (a separate tx from each test body), so
        // they are NOT under the same-tx anti-JIT quarantine when claimed inside a test.
        rejecter = new RejectsEth();
        _giveShares(user, 4);
        _giveShares(whale, 10);
        _giveShares(address(rejecter), 2);
    }

    function _giveShares(address to, uint256 wholeTokens) internal {
        vm.prank(V2_ADDR);
        hook.transfer(to, wholeTokens * 1 ether);
    }

    // ─────────────────────────── M4: pull-based claims ───────────────────────────

    /// claim() must NOT push ETH; it credits pendingETH and value leaves only via withdraw.
    function test_ClaimIsPullBasedNoPush() public {
        // user has 4 pre-existing shares; total = 16. claim() pokes internally once.
        posm.setFeeEth(16 ether);           // 16 ETH / 16 shares = 1 ETH per share
        uint256 tid = hook.ownedTokensOf(user)[0];

        uint256 userEthBefore = user.balance;
        hook.claim(tid);                    // pokes once, then CREDITS pending (no push)

        assertEq(user.balance, userEthBefore, "claim must not push ETH to the owner");
        assertEq(hook.pendingETH(user), 1 ether, "owed credited to pending, not pushed");

        // Value leaves only on withdraw (pull).
        vm.prank(user);
        hook.withdrawPending();
        assertEq(user.balance, userEthBefore + 1 ether, "withdraw pays out");
        assertEq(hook.pendingETH(user), 0);
    }

    /// A contract owner that rejects ETH can no longer be griefed into entombment: claim just
    /// credits pending, and the split withdrawal routes it wherever the owner chooses.
    function test_NoEntombmentForEthRejector() public {
        // rejecter has 2 pre-existing shares (setUp); it has no receive()/fallback.
        posm.setFeeEth(16 ether);           // 16 ETH / 16 shares = 1 ETH per share; claim pokes once
        uint256 tid = hook.ownedTokensOf(address(rejecter))[0];

        hook.claim(tid);                    // no push -> cannot revert, cannot entomb
        assertEq(hook.pendingETH(address(rejecter)), 1 ether, "credited, recoverable");

        // rejecter routes its pending ETH to an address that CAN receive.
        rejecter.withdrawTo(hook, user2);
        assertEq(hook.pendingETH(address(rejecter)), 0, "recovered to a chosen address");
        assertEq(user2.balance, 1 ether, "ETH delivered to the chosen recipient");
    }

    // ─────────────────────────── M1: try/catch poke ───────────────────────────

    /// A reverting POSM must not brick transfers or claims.
    function test_PokeFailureDoesNotBrickTransfersOrClaims() public {
        // user has 4 pre-existing shares.
        posm.setRevert(true);               // POSM is "down"

        // A whole-token transfer triggers _maybePoke -> pokeFees -> POSM revert (caught).
        vm.prank(user);
        hook.transfer(user2, 1 ether);      // must NOT revert
        assertEq(hook.balanceOf(user2), 1 ether, "transfer succeeded despite POSM down");

        // Claims still work (they just collect nothing).
        uint256 tid = hook.ownedTokensOf(user)[0];
        hook.claim(tid);                    // must NOT revert
        assertEq(hook.pendingETH(user), 0, "no fees, but no brick");

        // Recovery: once POSM is healthy, the next poke books fees normally.
        posm.setRevert(false);
        posm.setFeeEth(2 ether);
        hook.pokeFees();
        assertGt(hook.accFeesPerShareETH(), 0, "poke recovers after POSM heals");
    }

    // ─────────────────────────── deploy safety: canonical Permit2 ───────────────────────────

    /// Regression: the constructor must deploy against the REAL (canonical) Permit2. solady fixes
    /// canonical Permit2's ERC20 allowance at type(uint256).max and reverts any finite value, so a
    /// scoped `_approve(this, permit2, SUPPLY)` would brick construction — invisible to a stub whose
    /// address != the canonical one. This deploys with the canonical address to exercise that path.
    function test_ConstructsAgainstCanonicalPermit2() public {
        address CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        Permit2Stub stub = new Permit2Stub();
        vm.etch(CANONICAL_PERMIT2, address(stub).code); // make the layer-2 approve call succeed

        address hookAddr = address(0x6040); // beforeInitialize + afterSwap (0x6040 & 0x3FFF == 0x2040)
        deployCodeTo(
            "PrismHookV2.sol:PrismHookV2",
            abi.encode(address(pm), OWNER, address(posm), CANONICAL_PERMIT2, address(0), uint256(0)),
            hookAddr
        );
        // Reaching here means construction did NOT revert Permit2AllowanceIsFixedAtInfinity.
        assertGt(hookAddr.code.length, 0, "hook deploys against canonical Permit2");
        assertEq(IHook(hookAddr).totalShares(), 0);
    }

    // ─────────────────────────── M2: init-race gate ───────────────────────────

    function _hostKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0:   Currency.wrap(address(0)),
            currency1:   Currency.wrap(V2_ADDR),
            fee:         10000,
            tickSpacing: 200,
            hooks:       IHooks(V2_ADDR)
        });
    }

    /// beforeInitialize reverts for any initializer other than seed() (seeding flag not set).
    function test_BeforeInitializeRejectsFrontRun() public {
        PoolKey memory key = _hostKey();
        vm.prank(address(pm)); // the PoolManager itself, but outside seed()
        vm.expectRevert(); // UnauthorizedInitialize()
        IHooks(V2_ADDR).beforeInitialize(address(0xBAD), key, uint160(1));
    }

    /// And a non-PoolManager caller is rejected earlier by onlyPoolManager.
    function test_BeforeInitializeOnlyPoolManager() public {
        PoolKey memory key = _hostKey();
        vm.prank(address(0xBAD));
        vm.expectRevert(); // NotPoolManager()
        IHooks(V2_ADDR).beforeInitialize(address(0xBAD), key, uint160(1));
    }

    // ─────────────────────────── M3: bounded mint + sync ───────────────────────────

    /// A large receive under-mirrors (capped) instead of OOG-reverting; syncNFTs catches up.
    function test_MintCapUnderSyncsAndSyncCatchesUp() public {
        // bigReceiver has no prior shares.
        uint256 sharesBefore = hook.totalShares(); // 16 from setUp baseline
        _giveShares(bigReceiver, 300);             // 300 whole tokens in one transfer

        assertEq(hook.balanceOf(bigReceiver), 300 ether, "got all the tokens");
        assertEq(hook.nftBalanceOf(bigReceiver), 128, "minting capped at MAX_REALIGN");
        assertEq(hook.totalShares(), sharesBefore + 128, "capped -> under eligible supply");

        // Catch up the remainder (self-only). `syncNFTs` is bounded by MAX_REALIGN as well, so a
        // holder this large needs more than one call — the deliberate cost of sizing the cap so no
        // single *mint batch* can exceed the EIP-7825 per-transaction gas limit. Note this bounds the
        // MINT direction only: the move and burn loops are uncapped (capping them could leave an
        // address holding more shares than backing), so a large enough transfer can still exceed the
        // cap. Measured thresholds are documented next to MAX_REALIGN in PrismHookV2.
        for (uint256 k; k < 4 && hook.nftBalanceOf(bigReceiver) < 300; ++k) {
            vm.prank(bigReceiver);
            hook.syncNFTs(0);
        }
        assertEq(hook.nftBalanceOf(bigReceiver), 300, "repeated sync minted the remainder");
        assertEq(hook.totalShares(), sharesBefore + 300);

        // Never above eligible supply.
        assertLe(hook.nftBalanceOf(bigReceiver), hook.balanceOf(bigReceiver) / 1 ether, "no unbacked shares");
    }

    /// Invariant under UNDER-mirroring: transferring from an under-synced holder never creates
    /// unbacked shares (nftBalance <= floor(balance/UNIT) for everyone), and totalShares stays
    /// equal to the sum of all holders' nftBalances.
    function test_UnderSyncedTransferKeepsInvariant() public {
        _giveShares(bigReceiver, 300);                 // 128 NFTs / 300 tokens (under-synced)
        assertEq(hook.nftBalanceOf(bigReceiver), 128);

        // Under-synced sender sends 100 to a fresh recipient.
        vm.prank(bigReceiver);
        hook.transfer(user2, 100 ether);

        // No unbacked shares anywhere.
        assertLe(hook.nftBalanceOf(bigReceiver), hook.balanceOf(bigReceiver) / 1 ether, "sender backed");
        assertLe(hook.nftBalanceOf(user2),       hook.balanceOf(user2)       / 1 ether, "recipient backed");

        // totalShares == sum of every holder's nftBalance (user, whale, rejecter, bigReceiver, user2).
        uint256 sum = hook.nftBalanceOf(user) + hook.nftBalanceOf(whale)
                    + hook.nftBalanceOf(address(rejecter)) + hook.nftBalanceOf(bigReceiver)
                    + hook.nftBalanceOf(user2);
        assertEq(hook.totalShares(), sum, "totalShares == sum of nftBalances");

        // And never above eligible supply overall.
        assertLe(hook.totalShares(), hook.balanceOf(bigReceiver)/1 ether + hook.balanceOf(user2)/1 ether
                                   + hook.balanceOf(user)/1 ether + hook.balanceOf(whale)/1 ether
                                   + hook.balanceOf(address(rejecter))/1 ether, "shares <= eligible supply");
    }

    /// F3: fees that accrue while totalShares==0 (a zero-share period) must be FORFEITED on the
    /// next collection, not swept by the first shareholder. Arm the flag as seed()/burn-to-zero
    /// does, then verify the next poke forfeits (acc unchanged) and the one after distributes.
    function test_ForfeitFirstCollectionAfterZeroShares() public {
        // user has 4 pre-existing shares (setUp). Arm forfeit as seed() would (slot 0: seeded + flag).
        vm.store(V2_ADDR, bytes32(uint256(0)), bytes32(uint256(0x101)));
        assertTrue(hook.forfeitNextCollection(), "flag armed");

        posm.setFeeEth(16 ether);
        hook.pokeFees();                                   // first collection -> FORFEITED
        assertEq(hook.accFeesPerShareETH(), 0, "zero-share backlog forfeited, not distributed");
        assertFalse(hook.forfeitNextCollection(), "flag cleared");

        hook.pokeFees();                                   // next collection -> distributed
        assertGt(hook.accFeesPerShareETH(), 0, "subsequent fees distribute normally");
    }

    /// The "dead address receives fees" failure mode, prevented at the root: an excluded address
    /// (PoolManager / the hook) holds NO fee shares, so it accrues nothing and can be paid
    /// nothing — even while holding a large PRISM reserve and while fees are actively booked.
    function test_ExcludedAddressesNeverReceiveFees() public {
        // Give the PoolManager a big PRISM "reserve" (both endpoints excluded -> no realign).
        vm.prank(V2_ADDR);
        hook.transfer(address(pm), 500 ether);
        assertEq(hook.balanceOf(address(pm)), 500 ether, "pool holds a reserve");
        assertEq(hook.nftBalanceOf(address(pm)), 0, "but the pool holds ZERO fee shares");
        assertEq(hook.nftBalanceOf(V2_ADDR), 0, "and the hook holds ZERO fee shares");

        // Book a fee round (claim pokes once); the denominator is only live user shares (16).
        posm.setFeeEth(16 ether);
        uint256 tid = hook.ownedTokensOf(whale)[0];
        hook.claim(tid);                    // 16 ETH / 16 shares = 1 ETH per share

        // The excluded addresses accrued nothing and have nothing to claim.
        assertEq(hook.pendingETH(address(pm)),  0, "pool cannot be credited ETH fees");
        assertEq(hook.pendingPRISM(address(pm)),0, "pool cannot be credited PRISM fees");
        assertEq(hook.pendingETH(V2_ADDR),      0, "hook cannot be credited ETH fees");

        // The full fee went to a live holder, undiluted by any dead share.
        assertEq(hook.pendingETH(whale), 1 ether, "live holder gets the undiluted per-share fee");
    }

    /// withdrawPendingTo cannot route fees to a dead/excluded sink (defense-in-depth footgun guard).
    function test_WithdrawToExcludedReverts() public {
        posm.setFeeEth(16 ether);
        uint256 tid = hook.ownedTokensOf(user)[0];
        hook.claim(tid);                                 // user now has 1 ETH pending
        assertEq(hook.pendingETH(user), 1 ether);

        vm.prank(user);
        vm.expectRevert();                               // ExcludedRecipient (pool)
        hook.withdrawPendingTo(address(pm));

        vm.prank(user);
        vm.expectRevert();                               // ExcludedRecipient (hook itself)
        hook.withdrawPendingTo(V2_ADDR);

        // A normal recipient still works.
        vm.prank(user);
        hook.withdrawPendingTo(user2);
        assertEq(user2.balance, 1 ether, "normal recipient still paid");
    }

    /// The Spectrum buy-and-burn sends PRISM to 0xdEaD. In v2 that address is an excluded burn
    /// sink, so burned PRISM mints NO fee-shares and does NOT dilute holders (it's truly removed
    /// from the fee layer, shrinking the circulating share base — the deflationary intent).
    function test_BurnSinkReceivesNoFeeShares() public {
        address BURN = 0x000000000000000000000000000000000000dEaD;
        uint256 sharesBefore = hook.totalShares();

        // Simulate the burner delivering bought PRISM to the sink (from the hook's balance).
        vm.prank(V2_ADDR);
        hook.transfer(BURN, 20 ether);

        assertEq(hook.balanceOf(BURN), 20 ether, "sink holds the burned PRISM");
        assertEq(hook.nftBalanceOf(BURN), 0, "sink holds ZERO fee-shares (excluded)");
        assertEq(hook.totalShares(), sharesBefore, "no shares minted -> no dilution");

        // And it can't be a fee recipient either.
        posm.setFeeEth(16 ether);
        hook.pokeFees();
        assertEq(hook.pendingETH(BURN), 0, "burn sink accrues no fees");
    }

    /// syncNFTs cannot mint phantom shares for an already-synced holder.
    function test_SyncNoopWhenSynced() public {
        // user is fully synced (4 <= MAX_REALIGN) from setUp.
        uint256 sharesBefore = hook.totalShares();
        vm.prank(user);
        hook.syncNFTs(100);
        assertEq(hook.totalShares(), sharesBefore, "no phantom shares when already synced");
        assertEq(hook.nftBalanceOf(user), 4);
    }

    // ─────────────────────────── H1: anti-atomic-JIT ───────────────────────────

    /// The atomic mint->poke->claim skim yields ZERO to the attacker (quarantine), while the
    /// fees are genuinely available (a pre-existing holder can claim them). The attacker mints
    /// by pulling whole tokens from the hook (an excluded source == a flash-borrow from the pool).
    function test_AtomicJITYieldsZero() public {
        // whale has 10 pre-existing shares (setUp).
        uint256 whaleTid = hook.ownedTokensOf(whale)[0];

        AtomicJITAttacker atk = new AtomicJITAttacker();
        vm.prank(V2_ADDR);
        hook.approve(address(atk), type(uint256).max); // let attacker pull from the hook

        posm.setFeeEth(5 ether);                       // standing fees waiting to be booked

        uint256 freshId = atk.run(hook, V2_ADDR, 5 ether);

        // Quarantine: the freshly-minted share realized nothing.
        assertEq(hook.pendingETH(address(atk)), 0, "atomic JIT captured zero");
        (uint256 owedEth,) = hook.pendingFees(freshId);
        assertEq(owedEth, 0, "fresh share carries no claimable balance same-tx");

        // The fees were real: the pre-existing whale share still earns them.
        hook.claim(whaleTid);
        assertGt(hook.pendingETH(whale), 0, "honest pre-existing holder still earns the fees");
    }

    /// The sell-side variant (mint -> poke -> move/burn capture) is also quarantined.
    function test_AtomicJITSellSideYieldsZero() public {
        AtomicJITSeller s = new AtomicJITSeller();
        vm.prank(V2_ADDR);
        hook.approve(address(s), type(uint256).max);
        posm.setFeeEth(5 ether);

        s.run(hook, V2_ADDR, 3 ether);                 // mint 3 from hook, poke, send them onward
        assertEq(hook.pendingETH(address(s)), 0, "sell-side atomic JIT captured zero");
    }
}

/// Rejects plain ETH transfers (no receive/fallback).
contract RejectsEth {
    function withdrawTo(IHook hook, address to) external {
        hook.withdrawPendingTo(to);
    }
}

/// Mint -> poke -> sell (send tokens back to the excluded source, burning the fresh shares).
contract AtomicJITSeller {
    function run(IHook hook, address source, uint256 amount) external {
        hook.transferFrom(source, address(this), amount); // receive from hook -> mint fresh shares
        hook.pokeFees();                                  // acc jumps
        hook.transfer(source, amount);                    // send back to hook -> burns fresh shares
        hook.withdrawPending();                           // try to take anything captured
    }
}

