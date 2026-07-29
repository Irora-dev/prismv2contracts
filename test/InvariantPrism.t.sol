// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

interface IHook {
    function mirror() external view returns (address);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function nftBalanceOf(address) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function ownedTokensOf(address) external view returns (uint256[] memory);
    function pokeFees() external;
    function claim(uint256) external;
    function claimMany(uint256[] calldata) external;
    function withdrawPending() external;
    function syncNFTs(uint256 max) external;
    function pendingETH(address) external view returns (uint256);
    function pendingPRISM(address) external view returns (uint256);
    function accFeesPerSharePRISM() external view returns (uint256);
    function pendingFees(uint256 tokenId) external view returns (uint256, uint256);
}
interface IMirror {
    function transferFrom(address, address, uint256) external;
    function setApprovalForAll(address, bool) external;
}

contract Permit2Stub { function approve(address,address,uint160,uint48) external {} }
contract MockPoolManager { function exttload(bytes32) external pure returns (bytes32) { return bytes32(0); } }
interface IPrismMin { function transfer(address, uint256) external returns (bool); }
interface IPrismLike { function balanceOf(address) external view returns (uint256); }

contract MockPOSM {
    uint256 public feeEth;
    uint256 public feePrism;          // the PRISM leg — previously absent, so PRISM fees were NEVER
    address public prism;             // exercised and PRISM solvency was asserted nowhere
    /// Ghost counters. Without them the only available measure of the fee stream was the hook's entire
    /// PRISM balance, which is dominated by unseeded float — that is what made the solvency invariant
    /// unfalsifiable (~4,341 PRISM of slack against a promise base capped at 160).
    uint256 public totalPrismPaid;    // PRISM this mock has ever delivered into the hook
    uint256 public prismLegFirings;   // times the PRISM leg actually paid
    uint256 public prismLegStarved;   // times it could not, because the reservoir was empty
    receive() external payable {}
    function setFeeEth(uint256 v) external { feeEth = v; }
    function setFeePrism(uint256 v) external { feePrism = v; }
    function setPrism(address v) external { prism = v; }
    function modifyLiquidities(bytes calldata, uint256) external {
        if (feeEth > 0) { (bool ok,) = msg.sender.call{value: feeEth}(""); require(ok); }
        // Mirrors the real collect: PRISM arrives INTO the hook, which pokeFees sees as a gain.
        if (feePrism > 0 && prism != address(0)) {
            // Reservoir exhaustion used to be INVISIBLE: the transfer reverted inside pokeFees'
            // try/catch, so most pokes silently exercised no PRISM leg at all while the fuzzer still
            // reported 0 reverts. Now starvation is counted (and the harness refills, see Handler.poke).
            if (IPrismLike(prism).balanceOf(address(this)) < feePrism) { prismLegStarved++; return; }
            IPrismMin(prism).transfer(msg.sender, feePrism);
            totalPrismPaid += feePrism;
            prismLegFirings++;
        }
    }
    function nextTokenId() external pure returns (uint256) { return 1; }
    function multicall(bytes[] calldata) external {}
}

/// Bounded random-action driver. All transfers stay within the actor set (+ the hook as an
/// excluded source/sink), so every NFT ever minted rests on a known actor and the sum invariants
/// are checkable. Actions swallow reverts (bounded preconditions) so the fuzzer keeps exploring.
contract Handler is Test {
    IHook   public hook;
    IMirror public mirror;
    address public HOOKADDR;
    MockPOSM public posm;
    address[] public actors;

    constructor(IHook _hook, address _hookAddr, MockPOSM _posm, address[] memory _actors) {
        hook = _hook; HOOKADDR = _hookAddr; posm = _posm; actors = _actors;
        mirror = IMirror(_hook.mirror());
    }

    function _actor(uint256 s) internal view returns (address) { return actors[s % actors.length]; }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to   = _actor(toSeed);
        uint256 bal  = hook.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(from);
        try hook.transfer(to, amount) {} catch {}
    }

    // Move whole tokens back to the hook (excluded) to force burns / churn.
    function sendToHook(uint256 fromSeed, uint256 wholeTokens) external {
        address from = _actor(fromSeed);
        uint256 bal  = hook.balanceOf(from);
        if (bal < 1 ether) return;
        uint256 amt = bound(wholeTokens, 1, bal / 1 ether) * 1 ether;
        vm.prank(from);
        try hook.transfer(HOOKADDR, amt) {} catch {}
    }

    function mirrorTransfer(uint256 fromSeed, uint256 toSeed, uint256 tokenSeed) external {
        address from = _actor(fromSeed);
        address to   = _actor(toSeed);
        if (from == to) return;
        uint256[] memory ids = hook.ownedTokensOf(from);
        if (ids.length == 0) return;
        uint256 id = ids[tokenSeed % ids.length];
        vm.prank(from);
        try mirror.transferFrom(from, to, id) {} catch {}
    }

    function claim(uint256 actorSeed, uint256 tokenSeed) external {
        address a = _actor(actorSeed);
        uint256[] memory ids = hook.ownedTokensOf(a);
        if (ids.length == 0) return;
        uint256 id = ids[tokenSeed % ids.length];
        try hook.claim(id) {} catch {}
    }

    function sync(uint256 actorSeed, uint256 max) external {
        address a = _actor(actorSeed);
        vm.prank(a);
        try hook.syncNFTs(bound(max, 0, 400)) {} catch {}
    }

    /// Drives BOTH fee legs. The PRISM leg was previously never exercised at all, so the 80/20 split,
    /// the PRISM burn and PRISM solvency all went unfuzzed across 30k sequences.
    ///
    /// The reservoir is TOPPED UP here rather than being allowed to run dry. Exhaustion made the leg
    /// no-op silently inside pokeFees' try/catch, so the vast majority of pokes exercised nothing while
    /// the run still looked clean. The float the mock draws from is real supply moved in setUp, so
    /// topping up means moving it back rather than minting.
    function poke(uint256 fee, uint256 feeP) external {
        posm.setFeeEth(bound(fee, 0, 3 ether));
        uint256 want = bound(feeP, 0, 2 ether);
        posm.setFeePrism(want);
        if (want > 0 && hook.balanceOf(address(posm)) < want) {
            // Refill from the hook's own unseeded float, which is excluded and otherwise inert.
            uint256 avail = hook.balanceOf(HOOKADDR);
            uint256 top   = avail > 200 ether ? 200 ether : avail;
            if (top > 0) { vm.prank(HOOKADDR); try hook.transfer(address(posm), top) {} catch {} }
        }
        try hook.pokeFees() {} catch {}
    }

    function withdraw(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        vm.prank(a);
        try hook.withdrawPending() {} catch {}
    }

    function claimManyOf(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        uint256[] memory ids = hook.ownedTokensOf(a);
        if (ids.length == 0) return;
        try hook.claimMany(ids) {} catch {}
    }

    // Operator-approved mirror transfer: `op` moves `owner`'s token to a third actor.
    function operatorMove(uint256 ownerSeed, uint256 opSeed, uint256 toSeed, uint256 tokenSeed) external {
        address owner = _actor(ownerSeed);
        address op    = _actor(opSeed);
        address to    = _actor(toSeed);
        if (owner == to) return;
        uint256[] memory ids = hook.ownedTokensOf(owner);
        if (ids.length == 0) return;
        uint256 id = ids[tokenSeed % ids.length];
        vm.prank(owner);
        try mirror.setApprovalForAll(op, true) {} catch { return; }
        vm.prank(op);
        try mirror.transferFrom(owner, to, id) {} catch {}
    }

    function actorsLength() external view returns (uint256) { return actors.length; }
    function actorAt(uint256 i) external view returns (address) { return actors[i]; }
}

contract InvariantPrism is Test {
    address constant V2_ADDR = address(0x2040);
    address constant OWNER   = address(0xB0B);
    uint256 constant SUPPLY  = 5000 ether;

    IHook hook;
    MockPoolManager pm;
    MockPOSM posm;
    Permit2Stub permit2;
    Handler handler;
    address[] actors;

    function setUp() public {
        pm = new MockPoolManager(); posm = new MockPOSM(); permit2 = new Permit2Stub();
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(address(pm), OWNER, address(posm), address(permit2), address(0), uint256(0)), V2_ADDR);
        hook = IHook(V2_ADDR);
        vm.store(V2_ADDR, bytes32(uint256(0)), bytes32(uint256(1))); // seeded = true
        vm.deal(address(posm), 1_000_000 ether);

        actors.push(address(0xA1)); actors.push(address(0xA2));
        actors.push(address(0xA3)); actors.push(address(0xA4));

        // Distribute an initial float from the hook to the actors (varied sizes incl. a large one).
        vm.prank(V2_ADDR); hook.transfer(actors[0], 400 ether);   // forces under-sync (>MAX_REALIGN)
        vm.prank(V2_ADDR); hook.transfer(actors[1], 50 ether);
        vm.prank(V2_ADDR); hook.transfer(actors[2], 7 ether);
        vm.prank(V2_ADDR); hook.transfer(actors[3], 3 ether);

        // Give the POSM mock a PRISM reservoir so it can pay PRISM fees into the hook, exactly as the
        // real collect does. Without this the PRISM fee path is never exercised at all.
        vm.prank(V2_ADDR); hook.transfer(address(posm), 200 ether);
        posm.setPrism(V2_ADDR);

        handler = new Handler(hook, V2_ADDR, posm, actors);
        targetContract(address(handler));
    }

    function _sumNFTs() internal view returns (uint256 s) {
        for (uint256 i = 0; i < actors.length; i++) s += hook.nftBalanceOf(actors[i]);
    }
    function _sumPendingETH() internal view returns (uint256 s) {
        for (uint256 i = 0; i < actors.length; i++) s += hook.pendingETH(actors[i]);
    }
    function _sumBalances() internal view returns (uint256 s) {
        for (uint256 i = 0; i < actors.length; i++) s += hook.balanceOf(actors[i]);
        s += hook.balanceOf(V2_ADDR) + hook.balanceOf(address(pm)) + hook.balanceOf(address(posm));
        // The 20% PRISM fee burn sends to 0x…dEaD, which is a real balance and must be counted or
        // conservation appears to fail. Before the PRISM fee leg existed this term was always zero,
        // which is why it was missing.
        s += hook.balanceOf(0x000000000000000000000000000000000000dEaD);
    }
    function _sumPendingPRISM() internal view returns (uint256 s) {
        for (uint256 i = 0; i < actors.length; i++) s += hook.pendingPRISM(actors[i]);
    }

    /// The obligation that has ACCRUED but not yet been captured into `pendingPRISM` — i.e. what every
    /// live share could still claim, `(acc - debt) / ACC_SCALE` summed over all of them. The old
    /// solvency check ignored this entirely and looked only at captured pending, which is the smaller
    /// half of the liability and frequently zero.
    function _sumUnrealizedPRISM() internal view returns (uint256 s) {
        for (uint256 i = 0; i < actors.length; i++) {
            uint256[] memory ids = hook.ownedTokensOf(actors[i]);
            for (uint256 j = 0; j < ids.length; j++) {
                (, uint256 owedPrism) = hook.pendingFees(ids[j]);
                s += owedPrism;
            }
        }
    }

    /// No unbacked shares: every holder's NFT count is backed by whole tokens it holds.
    function invariant_noUnbackedShares() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            assertLe(hook.nftBalanceOf(actors[i]), hook.balanceOf(actors[i]) / 1 ether, "unbacked share");
        }
    }
    /// totalShares equals the sum of all holders' NFT balances (excluded hold none).
    function invariant_sharesEqualSumNFTs() public view {
        assertEq(hook.totalShares(), _sumNFTs(), "totalShares != Sum nftBalance");
    }
    /// Shares never exceed the whole-token supply.
    function invariant_sharesUnderSupply() public view {
        assertLe(hook.totalShares(), SUPPLY / 1 ether, "shares exceed supply");
    }
    /// Excluded addresses never hold fee shares.
    function invariant_excludedNoShares() public view {
        assertEq(hook.nftBalanceOf(V2_ADDR), 0, "hook holds shares");
        assertEq(hook.nftBalanceOf(address(pm)), 0, "pool holds shares");
    }
    /// ETH solvency: the hook holds at least the sum of everyone's realized (pending) ETH.
    function invariant_ethSolvency() public view {
        assertGe(V2_ADDR.balance, _sumPendingETH(), "insolvent on pending ETH");
    }
    /// PRISM solvency, measured against the FEE STREAM rather than the hook's whole balance.
    ///
    /// The earlier version asserted `balanceOf(hook) >= sumPendingPRISM`, which could not fail: the
    /// hook's balance is dominated by unseeded float (~4,341 PRISM in this harness) while the promises
    /// were capped by the mock reservoir at ~160, leaving three orders of magnitude of dead slack. It
    /// also compared against *captured* pending only, ignoring the larger unrealised obligation.
    ///
    /// The tight statement is conservation of the stream the fee layer actually controls: every PRISM
    /// the hook received as a fee has either been burned, paid out to a holder, or is still held for
    /// one — so what it received must cover what it burned plus what it still owes. No float term
    /// appears on either side, so the bound is tight and a mis-split, a double-credit or an over-burn
    /// all break it.
    function invariant_prismSolvency() public view {
        uint256 received = posm.totalPrismPaid();
        uint256 burned   = hook.balanceOf(0x000000000000000000000000000000000000dEaD);
        uint256 owed     = _sumPendingPRISM() + _sumUnrealizedPRISM();
        assertLe(burned + owed, received, "fee layer promised more PRISM than it received");
    }

    /// The burn must be exactly the 20% share of what came in — never more. Catches an over-burn that
    /// the inequality above would tolerate if promises happened to be small.
    function invariant_prismBurnNeverExceedsItsShare() public view {
        uint256 received = posm.totalPrismPaid();
        uint256 burned   = hook.balanceOf(0x000000000000000000000000000000000000dEaD);
        // Per-collect flooring means the burn can only ever be at or below the nominal 20%.
        assertLe(burned, received * 2_000 / 10_000, "burned more than the 20% share");
    }

    /// There is deliberately NO coverage assertion here, and the reason is worth recording so that
    /// nobody adds one back.
    ///
    /// Every PRISM assertion above is vacuously true in a sequence where the fee leg never fires, so
    /// asserting `prismLegFirings > 0` in `afterInvariant` looks like the fix. It is flaky by
    /// construction: `afterInvariant` runs after EACH run, not once per campaign, and this suite is 500
    /// runs x depth 60. With nine handler actions a 60-call sequence draws `poke` only ~6 times, and
    /// `bound(feeP, 0, 2 ether)` can return 0, so sequences with zero firings genuinely occur — measured
    /// directly while building this: a failing sequence had `poke` called ZERO times, with
    /// `modifyLiquidities` entered only 3 times, all via `_maybePoke` on ordinary transfers.
    ///
    /// Coverage is therefore proven DETERMINISTICALLY in `test/FeeLegUnit.t.sol`, which drives the PRISM
    /// leg with fixed inputs and checks the 80/20 split, the burn and the accumulator exactly. Random
    /// exploration and coverage guarantees want different tools; mixing them yields a flaky suite that
    /// proves neither.

    /// PRISM supply is conserved across all holders (no mint/burn of the ERC20 itself).
    function invariant_supplyConserved() public view {
        assertEq(_sumBalances(), SUPPLY, "supply not conserved");
    }
}
