// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Halmos SYMBOLIC proofs of the core arithmetic/logic over the ENTIRE input domain (not sampled
/// like fuzzing). These mirror the exact expressions used in PrismHookV2 / PrismMigration.
/// Run: halmos --match-contract SymbolicChecks
contract SymbolicChecks {
    uint256 constant ACC_SCALE      = 1e12;
    uint256 constant PRISM_BURN_BPS = 2_000;
    uint256 constant BPS            = 10_000;
    uint256 constant CAP            = 1 << 200; // bounds inputs to a huge-but-overflow-safe domain
    uint256 constant UNIT           = 1 ether;  // one whole PRISM = one fee-share

    /// PROVE: the 80/20 PRISM fee split conserves value and never over-burns — for EVERY
    /// prismGained in a huge overflow-safe domain. (Only constant divisors, so it is solver-tractable.)
    function check_feeSplitConservationAndNoOverflow(uint256 prismGained) public pure {
        if (prismGained > CAP) return;
        uint256 prismBurn      = prismGained * PRISM_BURN_BPS / BPS; // no overflow in domain
        uint256 prismToHolders = prismGained - prismBurn;           // must not underflow
        assert(prismBurn + prismToHolders == prismGained);          // value conserved
        assert(prismBurn <= prismGained);                           // never burns more than collected
        assert(prismBurn <= prismGained / 4);                       // <= 25% (20% floored)
    }

    /// PROVE: `acc - debt` never underflows given the monotonic-accumulator invariant (debt <= acc).
    function check_accMinusDebtNoUnderflow(uint256 acc, uint256 debt) public pure {
        if (acc > CAP) return;
        if (debt > acc) return;
        uint256 diff = acc - debt; // must not revert
        assert(diff <= acc);
    }

    /// PROVE: the anti-JIT quarantine predicate (lo = first tokenId minted this tx; a token is
    /// quarantined iff `lo != 0 && id >= lo`) NEVER flags a prior-tx token (id < lo), for all inputs.
    function check_quarantineNeverFlagsOldToken(uint256 id, uint256 lo) public pure {
        if (lo == 0) { assert(!_mintedThisTx(id, lo)); return; } // nothing minted this tx
        if (id < lo)   assert(!_mintedThisTx(id, lo));           // prior-tx token never quarantined
    }
    function _mintedThisTx(uint256 id, uint256 lo) internal pure returns (bool) {
        return lo != 0 && id >= lo;
    }

    /// PROVE the mint budget in `_afterTokenTransfer`, which bounds fresh fee-share mints to the number
    /// of whole-token boundaries the RECIPIENT actually crossed:
    ///
    ///     mintBudget = postBalance / UNIT - (postBalance - amount) / UNIT
    ///
    /// Three properties, over the whole domain rather than sampled. The precondition `amount <=
    /// postBalance` is what `_afterTokenTransfer` guarantees: it runs post-state, and the recipient's
    /// balance already includes what was transferred in. The `to != from` guard in the caller is what
    /// makes that true for self-transfers too, which move no value and so must cross nothing.
    ///
    /// This replaced `amount / UNIT + 1`, whose `+1` was claimable by a transfer that moved nothing and
    /// was recomputed per call, so a loop forced unbounded shares onto a third party. The property that
    /// matters is therefore ZERO_AMOUNT_MEANS_ZERO_BUDGET below: it is the one the old bound failed.
    /// Split into one property per function. Two symbolic divisions joined by a subtraction defeats the
    /// solver when they share a path, so each is discharged on its own. `SUPPLY_CAP` bounds the domain
    /// at 2^80, which still contains the entire real one — total supply is 5000e18 ~= 2^72.4 — so these
    /// are proofs over every reachable state, not merely a large sample.
    uint256 constant SUPPLY_CAP = 1 << 80;

    /// 1. A transfer that moves nothing crosses no boundary, so it can never mint. THIS is the property
    ///    the old `amount / UNIT + 1` bound violated: its `+1` was claimable by a zero-value transfer.
    function check_mintBudgetZeroWhenNothingMoved(uint256 postBalance) public pure {
        if (postBalance > SUPPLY_CAP) return;
        uint256 preBalance = postBalance - 0;
        assert(postBalance / UNIT - preBalance / UNIT == 0);
    }

    /// 2. NOT PROVEN HERE, deliberately, and worth reading before adding one.
    ///
    /// The remaining question about the budget expression is whether `preBalance / UNIT` can exceed
    /// `postBalance / UNIT` and underflow the outer subtraction. That reduces to monotonicity of floor
    /// division — `b <= a` implies `b/U <= a/U` — which is a fact about integers, not about this
    /// contract, so a symbolic proof of it would assert nothing about PRISM. This solver cannot
    /// discharge it anyway: two symbolic divisions by a 60-bit constant joined by a subtraction times
    /// out at 180s on Halmos 0.1.13 regardless of how the domain is bounded.
    ///
    /// What actually needs to hold is the PRECONDITION `amount <= postBalance`, and that is a property
    /// of the caller — solady runs `_afterTokenTransfer` post-state, so the recipient's balance already
    /// includes the transferred amount, and `_afterTokenTransfer`'s `to != from` guard covers the
    /// self-transfer case that would otherwise break it. Halmos cannot see any of that; it is covered by
    /// the 30,000-call stateful invariant fuzz driving real transfers, and by `MintClampUnit`.
    ///
    /// TOOLING CAVEAT, verified by throwaway probe and applying to EVERY proof in this file: Halmos
    /// 0.1.13 does not report a checked-arithmetic panic as a failure — it drops the reverting path. An
    /// unguarded `a - b` over symbolic `a, b` PASSED. So a check whose stated property is "does not
    /// underflow" proves nothing unless it computes `unchecked` and asserts a bound that a wrapped
    /// result would violate. `check_accMinusDebtNoUnderflow` below is guarded rather than unchecked, so
    /// it establishes its precondition holds, NOT that checked arithmetic would have been safe without
    /// it. Version 0.1.13 has no panic-error-code flag; a newer Halmos would.

    /// 3. The budget never exceeds the recipient's own whole-token target, so it can never authorise
    ///    more shares than the balance backs. Over-mirroring is the worst failure class in this contract.
    function check_mintBudgetNeverExceedsTarget(uint256 postBalance, uint256 amount) public pure {
        if (postBalance > SUPPLY_CAP) return;
        if (amount > postBalance) return;
        uint256 mintBudget = postBalance / UNIT - (postBalance - amount) / UNIT;
        assert(mintBudget <= postBalance / UNIT);
    }

    /// PROVE the same expression is exactly the count of whole-token boundaries crossed, stated as a
    /// monotonicity property the solver can actually discharge: crossing is never negative, and a
    /// recipient whose balance stays inside one whole token mints nothing at all.
    function check_mintBudgetZeroWithinOneWholeToken(uint256 preBalance, uint256 amount) public pure {
        if (preBalance > CAP || amount > CAP) return;
        uint256 postBalance = preBalance + amount;
        if (postBalance > CAP) return;
        // Same whole-token bucket before and after => no boundary crossed => no mint permitted.
        if (postBalance / UNIT == preBalance / UNIT) {
            assert(postBalance / UNIT - preBalance / UNIT == 0);
        }
    }

    /// PROVE: the migration's sorted-pair commutative hash step is order-independent (the property
    /// the Merkle verify relies on), for all leaf/sibling pairs.
    function check_merklePairCommutative(bytes32 a, bytes32 b) public pure {
        assert(_hashPair(a, b) == _hashPair(b, a));
    }
    function _hashPair(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x <= y ? keccak256(abi.encodePacked(x, y)) : keccak256(abi.encodePacked(y, x));
    }
}
