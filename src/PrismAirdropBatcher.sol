// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPrismMigrationB {
    function claim(address account, uint256 amount, bytes32[] calldata proof) external;
    function claimed(address account) external view returns (bool);
    function token() external view returns (address);
    function merkleRoot() external view returns (bytes32);

    // Declared so this contract can tell a PERMANENT failure from a RETRIABLE one by selector.
    error AlreadyClaimed();
    error InvalidProof();
}

/// @notice Pushes the PRISM v2 snapshot airdrop out to holders in batches, so nobody has to claim.
///
/// `PrismMigration.claim` is permissionless and always delivers to `account`, never to the caller —
/// so anyone can submit a holder's proof on their behalf. This contract just loops that call. It is:
///
/// - **non-custodial** — PRISM goes straight from the vault to the holder; this contract never holds,
///   approves or routes a single token, and has no way to. There is nothing here to rug.
/// - **permissionless and ownerless** — no admin, no pause, no privileged caller. Any address can run
///   a batch, so the distribution does not depend on the launcher staying interested.
/// - **stateless** — the only storage is the immutable vault address. Progress lives in the vault's
///   own `claimed` mapping, so batches are idempotent and safe to retry.
///
/// Two failure modes make a naive loop unusable, and both are handled:
///
/// 1. *A single bad row must not kill the batch.* Re-running an overlapping chunk would hit
///    `AlreadyClaimed` and revert everything. Each claim is therefore attempted in `try/catch` and a
///    failure is counted and skipped, never propagated.
/// 2. *Cost per holder varies by ~150x.* Gas scales with the amount delivered, not the recipient
///    count, because the fee-share mirror mints one NFT per whole PRISM — **~76k gas each** in
///    production, since each mint writes two virgin fee-debt slots at 20,000 gas apiece once any pool
///    fee has accrued. (A pool that has never collected a fee reads ~37k; do not size anything from
///    that number.) A dust holder costs ~61k; a mint-capped holder ~9.9M. You cannot know how many
///    rows fit in a transaction, so `push` stops cleanly when remaining gas drops below `gasFloor`
///    and reports where it got to. Feed that index back in to resume.
contract PrismAirdropBatcher {
    IPrismMigrationB public immutable migration;

    /// @param delivered     holders who received their allocation in this call
    /// @param alreadyClaimed rows that were settled before this call — safe to skip
    /// @param failed        rows attempted that did NOT deliver, whether skipped as permanently
    ///   invalid or stopped on as retriable. Never silently folded into `alreadyClaimed`, so a
    ///   nonzero value here always means "something in this range still owes someone".
    /// @param stoppedAt     index to pass as `from` to resume. On a retriable (out-of-gas) failure it
    ///   points AT the offending row so a resume re-attempts it. Reaching `accounts.length` means the
    ///   range was walked to the end — check `failed` to know whether it was walked *cleanly*.
    event Pushed(uint256 delivered, uint256 alreadyClaimed, uint256 failed, uint256 stoppedAt);

    /// @notice A row was attempted and did not deliver, so the caller can see exactly which.
    event RowFailed(uint256 index, address account);

    error LengthMismatch();
    error TokenNotWired();
    error BadRange();

    constructor(IPrismMigrationB _migration) {
        migration = _migration;
    }

    /// @notice Deliver allocations for rows `[from, ...)` until the list ends or gas runs low.
    /// @dev Rows must be the exact `(account, amount, proof)` triples from the snapshot tree — the
    ///   vault verifies each against its Merkle root, so a wrong row simply fails and is skipped; it
    ///   cannot mis-deliver. Ordering is irrelevant to correctness.
    /// @param gasFloor Stop before starting another claim once `gasleft()` falls below this. It must
    ///   exceed the true cost of the next row, or that row is attempted with too little gas. Cost is
    ///   driven by the fee-share mints: ~76,000 gas each once any pool fee has accrued (i.e. always,
    ///   in production), plus ~61,000 base and a ~68,000 fee poke. With `MAX_REALIGN = 128` the
    ///   worst-case row is ~10M gas, so **12_000_000 is a safe default** for a list containing large
    ///   holders. For an all-dust tail (allocations under one whole PRISM, which mint nothing),
    ///   ~300_000 is plenty.
    /// @return delivered     holders paid in this call
    /// @return alreadyClaimed rows already settled before this call
    /// @return failed        rows attempted that did not deliver. A permanently-invalid row is
    ///   counted and skipped so it cannot strand the rows behind it; a retriable out-of-gas row is
    ///   counted and stopped on.
    /// @return stoppedAt     resume index; points AT a retriable failure so a resume re-attempts it.
    ///   `stoppedAt == accounts.length && failed == 0` is the only "this range is fully settled" signal.
    function push(
        address[] calldata accounts,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs,
        uint256 from,
        uint256 gasFloor
    ) external returns (uint256 delivered, uint256 alreadyClaimed, uint256 failed, uint256 stoppedAt) {
        uint256 n = accounts.length;
        if (n != amounts.length || n != proofs.length) revert LengthMismatch();
        if (from > n) revert BadRange();
        // Every claim would revert until the vault knows the token; fail loudly instead of burning
        // gas to report `skipped == n`.
        if (migration.token() == address(0)) revert TokenNotWired();

        uint256 i = from;
        for (; i < n; ++i) {
            // Checked BEFORE starting a claim, so we never enter one we cannot finish. Without this
            // an out-of-gas inside `try` would consume 63/64 of the remaining gas and leave the loop
            // unable to make progress or return.
            if (gasleft() < gasFloor) break;

            // Cheap pre-filter: skipping a known-claimed row costs a cold SLOAD instead of a
            // reverted external call. Makes retrying an overlapping chunk nearly free.
            if (migration.claimed(accounts[i])) {
                ++alreadyClaimed;
                continue;
            }

            uint256 gasBefore = gasleft();
            try migration.claim(accounts[i], amounts[i], proofs[i]) {
                ++delivered;
            } catch (bytes memory reason) {
                uint256 burned = gasBefore - gasleft();
                // Two very different failures arrive here and must not be conflated.
                //
                // PERMANENT — `InvalidProof` or `AlreadyClaimed`. Retrying changes nothing, so this
                // row is counted and skipped, letting the rest of the batch through: one corrupt row
                // must not strand every row behind it.
                //
                // RETRIABLE — anything else, and the case that matters is out of gas. EIP-150 forwards
                // only 63/64 of the remaining gas, so the inner claim can exhaust its share while this
                // frame survives on the retained 1/64 — enough to keep looping and return normally.
                // Note it does NOT surface as empty returndata: `claim` wraps the token transfer in a
                // low-level call and converts a failure into `TransferFailed()`, so a starved row is
                // indistinguishable by selector from a token that genuinely refused. Both are treated
                // as retriable and STOP the loop at this index. Advancing past a holder who was never
                // paid is what turns an incomplete run into a "list complete" result with a silent hole
                // in it, so it must not happen.
                //
                // Note what that does NOT cover, because the gas test below is what actually decides:
                // a vault genuinely short of reserve reverts CHEAPLY (solady raises
                // `InsufficientBalance`, which `claim` converts to `TransferFailed`), so it reads as
                // neither permanent nor starved and every remaining row is attempted and skipped rather
                // than stopped on. That wastes gas but loses nothing and stays visible: each row
                // increments `failed` and emits `RowFailed`, and `failed != 0` is exactly the signal
                // that this range still owes someone. Only `stoppedAt == accounts.length && failed == 0`
                // means settled.
                ++failed;
                emit RowFailed(i, accounts[i]);

                bytes4 sel;
                if (reason.length >= 4) {
                    assembly { sel := mload(add(reason, 0x20)) }
                }
                bool permanent = sel == IPrismMigrationB.InvalidProof.selector
                              || sel == IPrismMigrationB.AlreadyClaimed.selector;

                // The selector alone cannot decide this. `TransferFailed()` is raised BOTH when the
                // transfer ran out of gas (retriable — give the row more gas) AND when the vault is
                // genuinely short of reserve (permanent — no amount of retrying helps), because
                // `claim` swallows the token's own revert data. Treating every `TransferFailed()` as
                // retriable makes one short row stall every row behind it forever; treating every one
                // as permanent silently abandons a starved holder. Gas separates them: a starved call
                // consumes essentially all of the 63/64 it was forwarded, while a deterministic revert
                // costs a few thousand gas and returns.
                // The two outcomes differ by more than an order of magnitude, so the threshold does not
                // need to be tight. A deterministic revert costs a few tens of thousands of gas and
                // returns; a starved row burns nearly everything it was given. Note the starvation
                // nests twice — `claim` forwards 63/64 to the token transfer, which exhausts that — so
                // ~(63/64)^2 ≈ 97% of `gasBefore` disappears, not the ~98.4% one level would suggest.
                // Half is a deliberately loose midpoint: any usable `gasFloor` is far more than twice
                // the cost of a deterministic revert, so nothing legitimate lands near the boundary.
                bool starved = burned > gasBefore / 2;

                if (!permanent && starved) break;      // retriable: stop AT this row, do not advance

                // Permanent (or cheap-and-deterministic): skip it so it cannot strand the rows behind
                // it. Still stop if that revert left us under the floor, so the next row is never
                // entered under-funded — advancing is safe because this row cannot succeed as-is.
                if (gasleft() < gasFloor) { ++i; break; }
            }
        }
        stoppedAt = i;
        emit Pushed(delivered, alreadyClaimed, failed, stoppedAt);
    }

    /// @notice Which of `accounts` still need delivering. Lets a runner skip settled rows off-chain
    ///   instead of paying gas to discover they are already done.
    function pendingOf(address[] calldata accounts) external view returns (bool[] memory pending) {
        pending = new bool[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) pending[i] = !migration.claimed(accounts[i]);
    }

    /// @notice Count of `accounts` still awaiting delivery — a one-call progress read.
    function pendingCount(address[] calldata accounts) external view returns (uint256 count) {
        for (uint256 i; i < accounts.length; ++i) if (!migration.claimed(accounts[i])) ++count;
    }
}
