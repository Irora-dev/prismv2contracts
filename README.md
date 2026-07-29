# PRISM contracts

An open, self-serve package to deploy **PRISM** — a fixed-supply Uniswap-V4 hybrid token that pays
trading fees to holders — **correctly and safely** on Ethereum mainnet, and to distribute the supply to
a holder snapshot via a Merkle airdrop.

The design goal throughout is that a fee share can only ever rest somewhere it can actually be claimed
from, so the fee denominator always equals the tokens genuinely held by claimable holders. Everything
else in the repo exists to make a one-shot, unrecoverable deploy verifiable before it is signed.

**The token is immutable: no admin, no upgrades, no pause, and the deploy runs once.** That shapes how
this repo is built — the configuration is generated rather than hand-entered, every value is re-derived
and cross-checked before anything is signed, and the launch is verified end to end against real mainnet
state first. [`DEPLOY.md`](./DEPLOY.md) is the reference; [`LAUNCH.md`](./LAUNCH.md) is the step-by-step.

## What it is

- **PrismHookV2** — the token. It is simultaneously an ERC-20 (`PRISM`, fixed supply 5000), a
  Uniswap-V4 hook owning one {ETH, PRISM} pool, a DN404-style ERC-721 "fee-share" mirror (whole
  tokens ↔ fee-share NFTs), and a fee distributor.
- **PrismMirror** — the ERC-721 facade for the fee-share NFTs (deployed by the hook).
- **PrismArt** — on-chain SVG art for the NFTs.
- **PrismMigration** — a Merkle-claim airdrop that holds the reserve (excluded from the fee layer)
  and lets snapshot holders claim their v2 PRISM.

### Fee mechanics (community decision)
- **ETH** fees: **100%** to holders.
- **PRISM** fees: **80%** to holders, **20%** burned (sent to `0x…dEaD`, which is excluded from the
  fee layer so the burn truly removes it from circulation — no dilution).

## Fee-share eligibility

A single `_isExcluded()` set is used as **both** the realignment gate **and** a destination guard on
NFT transfers, so a fee-share NFT can *only ever* rest on a realignment-eligible holder. A share cannot
come to rest on the PoolManager, the hook, the airdrop vault or the burn sink, so the fee denominator
can never exceed the whole tokens actually held by holders able to claim. This matters because every
share counted in the denominator dilutes the rest: a share nobody can claim would divert its slice of
every fee round permanently.

Two consequences worth knowing before you hold or integrate:

- Fee shares mirror **whole** tokens only. A balance below 1 PRISM earns nothing until it crosses a
  whole-token boundary.
- PRISM held by a contract that cannot call `withdrawPending()` — an ordinary Uniswap V2/V3 pool is the
  common case — still mints shares, and that share of fees is not recoverable. Do not create one.

## Testing

The suite covers unit behaviour, hardening cases, stateful invariant fuzzing (8 invariants × 500 runs
× 30,000 calls), Halmos symbolic proofs of the core arithmetic (7), and end-to-end validation against
mainnet's real Uniswap V4 contracts on a fork.

Every guard that defends an unrecoverable configuration mistake is **mutation-tested** — the guard is
deliberately weakened to confirm a test actually fails, rather than trusting a green suite.

To reproduce the symbolic proofs, one of them needs a raised solver budget:
`halmos --match-contract SymbolicChecks --solver-timeout-assertion 120000`.

## How the hybrid behaves

PRISM is one contract that is simultaneously an ERC-20 and an ERC-721, so a few behaviours differ from a
plain token. They are intentional and worth knowing before you integrate:
- An ERC-20 approval also authorizes moving your fee-share NFTs (approving PRISM = approving its NFTs).
- Ordinary trading mints/burns NFTs, so marketplace listings on a fee-share NFT can be invalidated.
- `nftBalanceOf ≤ balanceOf/1e18` (a large single receive under-mirrors until you call `syncNFTs`).
- A single **outflow** (transfer or sell) of more than **~2,500 whole tokens (~half the supply)**
  in one transaction reverts out-of-gas; chunk it. Buys/receives are unaffected. (Measured in
  `test/GasCeiling.t.sol`.)
- **Fees are booked when they are collected, so collect them often.** A v4 swap runs inside
  `PoolManager.unlock`, and `_maybePoke` deliberately returns early while the manager is unlocked, since
  collecting mid-swap is not safe. So a buy mints fee-shares before the fees already earned have been
  booked, and the next collection divides that backlog across the new share count as well. Collecting
  frequently keeps the unbooked backlog small, which is why `pokeFees()` is **permissionless and free to
  call** and why `merkle/keeper.mjs` ships with the repo. **Run the keeper from the moment you seed** —
  it is part of the launch, not an optimisation.

## Quick start

```bash
# Twelve of the test suites fork mainnet and read this directly, so `forge test` reports 14 failures
# without it. That is a missing variable, not broken code. `--fork-url` does NOT substitute for it.
export ETH_RPC_URL="<your mainnet endpoint>"

forge build
forge test                       # everything, including the mainnet-fork suites
# Symbolic proofs (pip install halmos). The longer solver budget is REQUIRED, not optional —
# check_feeSplitConservationAndNoOverflow times out at the default and passes at 120s.
halmos --match-contract SymbolicChecks --solver-timeout-assertion 120000
```

## Deploy

**[`LAUNCH.md`](./LAUNCH.md) is the step-by-step procedure** — every command, the result to expect, and
two explicit stop gates for the decisions that cannot be undone. It is written to be executed one step at
a time, by a person or an agent. **[`DEPLOY.md`](./DEPLOY.md)** explains *why* each number matters.

In short:

1. `cd merkle && npm i`, then `node prepare-basis.mjs ../your-snapshot.json out/basis.json` (drops
   infrastructure addresses, printing exactly what it dropped) and `node generate.mjs out/basis.json` →
   prints `MERKLE_ROOT` + `totalAmount`, and writes per-holder proofs plus a canary leaf.
2. Fill in `.env` (from `.env.example`): the Merkle root, the airdrop reserve, and the pool seed params.
3. `forge script script/Deploy.s.sol --rpc-url $RPC_URL ...` (simulate first, then `--broadcast --slow`).
4. Confirm `seeded()` on-chain, **then** run `script/Renounce.s.sol`.

The script deploys the migration vault, CREATE2-deploys the hook at a mined flag-valid address, wires
the token and seeds the pool. It is **three transactions on sequential nonces, not one**, and its
`require`s run during local simulation only — so simulation catches every deterministic configuration
mistake before you sign anything, but a step that fails on-chain does not stop the next one from being
mined. Renouncing ownership is a separate, separately-guarded script for exactly that reason: renouncing
an unseeded hook is terminal. Read DEPLOY.md's opening warning before broadcasting.

### Distributing the airdrop

Holders don't have to claim. `migration.claim` is permissionless and always delivers to `account`, so
`PrismAirdropBatcher` + `merkle/push-airdrop.mjs` can push everyone's allocation to them:

```bash
MIGRATION=<vault> forge script script/DeployBatcher.s.sol --rpc-url $RPC_URL --broadcast
cd merkle && node push-airdrop.mjs --batcher <batcher> --dry-run   # plan + live cost estimate
```

The batcher is ownerless and never holds a token, so anyone can run the distribution — it doesn't
depend on the launcher. Batches are idempotent, so it is safe to interrupt and re-run. See
[DEPLOY.md §7](./DEPLOY.md) for costs and the one caveat about very large holders.

## Repo layout

```
src/        PrismHookV2, PrismMirror, PrismArt, PrismMigration, PrismAirdropBatcher, base/BaseHook
merkle/     prepare-basis.mjs (chain snapshot -> airdrop basis; drops infrastructure, prints a manifest)
            generate.mjs (basis -> Merkle root + per-holder proofs + deploy canary)
            seed-params.mjs (derive the pool-seed half of .env; never compute these by hand)
            forbidden.mjs (the addresses that must never be a leaf, shared by both)
            push-airdrop.mjs (deliver the airdrop to holders; nobody has to claim)
            keeper.mjs (collect pool fees on an interval; a security control, see below)
            check-shares.mjs (who is under-mirrored and needs syncNFTs; no event reports this)
script/     Deploy.s.sol, Preflight.s.sol (read-only config check), Renounce.s.sol (separate step),
            DeployBatcher.s.sol, HookMiner.sol
test/       unit, hardening, invariant-fuzz, mainnet-fork, and Halmos symbolic tests
lib/        vendored dependencies; each keeps its own license (THIRD-PARTY-NOTICES.md)
```
