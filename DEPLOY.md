# PRISM — mainnet deploy runbook

> The contract is **immutable and unrecoverable** once deployed. Do a dry run and double-check every
> number before you broadcast.
>
> **The deploy is THREE transactions, not one** (two if you launch with no airdrop). `forge script` emits one transaction
> per state-changing call on sequential nonces, and the script's `require`s run only during local
> simulation — the script contract is never deployed on-chain. Simulation *does* reliably catch every
> deterministic configuration mistake before anything is signed, which is what those checks are for.
> What it cannot catch is one step failing on-chain (out of gas against a simulated limit, a reorg, a
> state race), and **a reverted transaction does not stop the next one from being mined.**
>
> Two consequences you must plan around:
> - Broadcast with **`--slow`** so each transaction is confirmed before the next is sent.
> - **Renouncing ownership is a separate script** (§6) and must not run until you have confirmed
>   on-chain that the seed landed. Renouncing an unseeded hook is terminal: nothing but `seed()` can
>   ever create the pool, so the token would be permanently inert with all 5,000 PRISM stranded.
>
> If a step reverts, **do not re-run `Deploy.s.sol`** — the hook already exists, so it will revert at
> the CREATE2 step, and forcing past it would mint a second hook and orphan the first with a dead
> 5,000-PRISM supply. Finish the remaining steps by hand instead.

## 0. Prerequisites
- Foundry (`forge`), Node 18+, and an RPC URL for Ethereum mainnet.
- A funded deployer key (gas only — the pool seed is single-sided PRISM, so no ETH liquidity is
  required). Prefer a hardware wallet (`--ledger` / `--trezor`, which asks you to confirm on the device) or
  an encrypted keystore (`--account`, which prompts for a password) — never a raw `--private-key`. See
  LAUNCH.md's "How signing actually works" for which of those an agent may run on your behalf.
- **`export ETH_RPC_URL=<your mainnet endpoint>`** before running the suite. Twelve test suites fork
  mainnet and read that variable directly, so without it `forge test` reports 14 failures with
  `environment variable "ETH_RPC_URL" not found` — which looks like broken code and is not.
- `forge build && forge test` pass locally.

## 1. Generate the airdrop Merkle tree
Your snapshot is a JSON array of `{ address, amount }` (amount in **wei**); the field names the
published PRISM snapshots use are also accepted. Then:
```bash
cd merkle && npm install
node prepare-basis.mjs ../path/to/snapshot.json out/basis.json   # drop infrastructure rows
node generate.mjs out/basis.json                                 # build the tree
```
`generate.mjs` prints **`MERKLE_ROOT`**, **`totalAmount (wei)`** and the holder count, and writes
`merkle/out/claims.json` (per-holder proofs for your claim UI/CLI), `tree.json`, and `canary.json`
(§3). It enforces address dedup, rejects malformed rows, rejects a non-integer amount, and **refuses
outright to build a tree containing an infrastructure address.**

That refusal is why `prepare-basis.mjs` exists. A snapshot taken from chain state answers "who held
PRISM", which is not "who should receive it" — it also names the burn sink and any Uniswap pool holding
PRISM. `claim` is permissionless and always delivers to `account`, so a leaf naming one of those is
claimable by anyone and lands PRISM on an address that can never hold fee-shares, diverting that slice
of every future fee round permanently. `prepare-basis.mjs` removes exactly those rows and **prints a manifest of every
one, with its amount in both PRISM and wei** — check it. Dropped PRISM is not redistributed; it simply
is not airdropped and stays in the hook.

For the published PRISM snapshot this drops 2 rows (the burn sink at 14.856845729748716678 PRISM, and
the V3 WETH/PRISM 0.3% pool at 1 wei), taking 1205 holders / 4469.533901616780792010 PRISM to **1203
holders / 4454677055887032075331 wei**, root
`0x2cd60218d3f802a855996dbcbf7db5db860f88c541468c7601e02e627d33e12f`.

- Set `MIGRATION_AMOUNT` (below) to **exactly `totalAmount`**. The deploy requires equality, not merely
  coverage: a larger reserve mints PRISM into a vault no proof can reach (unrecoverable, and taken out of
  the tradable float), and a smaller one leaves late claimers hitting `TransferFailed` when it runs out.
- For a **fair launch with no airdrop**, skip this step, set `MIGRATION_AMOUNT=0` and
  `MERKLE_ROOT=0x0000…0000`.

## 2. Choose the pool seed params

Read this section twice. Three of the four numbers here can produce a deploy that **succeeds and
leaves the token permanently broken**, and a reverted deploy is the safe outcome, not the dangerous
one.

**`SEED_TICK_UPPER` is your launch price.** Not `SEED_SQRT_PRICE_X96` — that only sets where the quote
*starts*, and for single-sided liquidity everything above `SEED_TICK_UPPER` is a phantom quote with no
liquidity behind it: a one-wei trade relocates the price to `SEED_TICK_UPPER` for free, and until
someone does, every aggregator and oracle reads a price that does not exist. **Set
`SEED_SQRT_PRICE_X96` *at* `SEED_TICK_UPPER`, not above it.**

Derive the tick from your intended fully-diluted valuation, then round to the 200 spacing:

```
tickUpper    = floor( ln(5000 / FDV_in_ETH) / ln(1.0001) / 200 ) * 200
sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tickUpper)      # NOTE: rounds UP, not floor
```

That `floor` can land one spacing below the tick you want — for a 56.68 ETH target it yields 44600, not
the 44800 in the table — so **use `merkle/seed-params.mjs` rather than this formula.** It searches aligned
ticks with integer arithmetic and returns the closest, which is what the table rows were derived with.

| Target FDV | `SEED_TICK_UPPER` | Actual FDV | PRISM/ETH | `SEED_SQRT_PRICE_X96` |
|---|---:|---:|---:|---|
| **56.68 ETH** (~$198k @ $3.5k/ETH) — **the configuration below** | **44800** | **56.6798 ETH** | **88.21** | **744133035780855425119189031190** |
| 10 ETH | 62000 | 10.1503 ETH | 492.60 | 1758430331955991512042274893876 |
| 100 ETH | 39000 | 101.2293 ETH | 49.39 | 556815713337552406329560678361 |
| 116.44 ETH | 37600 | 116.4406 ETH | 42.94 | 519173346924859298652142127695 |
| 1000 ETH | 16000 | 1009.5633 ETH | 4.95 | 176318465955219228901572735582 |

These are the **exact** `TickMath.getSqrtPriceAtTick(tickUpper)` values. Note that TickMath rounds the
square root **UP** (`(x + 2^32 - 1) >> 32`), so a `floor(sqrt(1.0001^t) · 2^96)` spreadsheet formula
lands one wei low and is wrong by construction. Take these values, or derive them with the integer
algorithm — never with a float.

Verified on a mainnet fork: a value even **one wei below** the exact price at `tickUpper` puts the
opening tick at `tickUpper − 1`, so the position needs ETH on side 0, and since `seed()` passes
`amount0Max = 0` the deploy reverts inside POSM with `MaximumAmountExceeded` (selector `0x31e30ad0`).
If you see that error, your `SEED_SQRT_PRICE_X96` is below the price at `SEED_TICK_UPPER` — fix the
price, do not nudge the tick. A revert here is the safe outcome, but responding to it by adjusting
numbers until something passes is how you launch at a price you did not choose. For a target FDV not in
this table, take the value from Uniswap's own `TickMath` rather than a spreadsheet — note that the
`v4-core` vendored here is partial and does **not** include `TickMath`, so get it from upstream.

### The configuration

Tick **44800**, fork-verified end to end against real mainnet state with the real airdrop root: the pool
opened at exactly 44800, `amount0` required was 0, and the implied FDV came out at 56679759771485417094
wei against a declared `TARGET_FDV_WEI` of 56679759771485429760 — 12,666 wei apart, well inside the ±25%
band.

```
MIGRATION_AMOUNT=4454677055887032075331
SEED_SQRT_PRICE_X96=744133035780855425119189031190
SEED_TICK_LOWER=-887200
SEED_TICK_UPPER=44800
SEED_LIQUIDITY=58060767042176831420
TARGET_FDV_WEI=56679759771485417094
MIN_SEED_PRISM=545322943111967924665
```

**This seeds effectively the entire float.** Fork-measured: 4454.677055887032075331 airdropped +
545.322944111967924665 seeded, leaving **1,000,000,004 wei (0.000000001 PRISM)** in the hook — two parts in
ten trillion of the supply, invisible at six decimal places.

That residual is deliberate headroom, not waste. `seed()` deposits `L × (√Pu − √Pl) / 2^96` and POSM rounds
its requirement UP, so sizing the liquidity to consume the float exactly makes POSM ask for every wei the
hook holds: it works, but with **zero** slack on a one-shot, unrecoverable operation. A gap of 1e9 wei is
nine orders of magnitude more than the rounding needs and costs nothing observable.

The intent still holds — the whole supply is either distributed or working as liquidity. PRISM idling in the
hook is permanently unrecoverable and earns nothing, so nothing meaningful is withheld; deflation comes from
the 20% PRISM-side fee burn on every trade, verifiable on-chain and requiring no withheld supply.

> ⚠️ **Do not raise `SEED_LIQUIDITY` by hand, and re-run the dry run if you change any of these numbers.**
>
> An earlier version of this configuration sized the liquidity to consume the float to the last wei. It
> worked — verified at three blocks and at the chain head — but with **zero** slack: POSM rounds its
> requirement up, and the ceiling landed exactly on the balance. Measured with `SEED_LIQUIDITY` incremented
> by just 1, the deploy aborts with **`TRANSFER_FROM_FAILED`** raised inside Permit2, which says nothing
> about liquidity or balances. The current value leaves 1e9 wei of headroom so that edge is nowhere near.
>
> Note the arithmetic is **structural**: the deposit depends only on `SEED_LIQUIDITY`, the two ticks and the
> reserve — all fixed constants. Pool state, block number and market conditions never enter it, so a
> passing dry run cannot turn into a failing broadcast. The risk is exclusively hand-editing, which is why
> `merkle/make-env.mjs` derives these and self-checks the result against the float before emitting it.

Derive these for any other valuation rather than computing them by hand:

```bash
node merkle/seed-params.mjs --fdv-eth 56.68 --reserve <MIGRATION_AMOUNT>
node merkle/seed-params.mjs --tick 44800   --reserve <MIGRATION_AMOUNT>    # or name the tick directly
```

It uses the same integer `TickMath` and the same implied-FDV expression as `Deploy.s.sol`, prints the block
ready to paste, and refuses configurations the deploy would reject. `SEED_LIQUIDITY` and `MIN_SEED_PRISM`
are the two worth never computing by hand: PRISM per unit of liquidity depends entirely on the tick (~46 at
76600, 9.39 at 44800, 2.23 at 16000), and a `MIN_SEED_PRISM` below the 90%-of-float floor is silently
discarded by the guard it appears to set.

Two cross-checks in `make-env.mjs` exist because the on-chain guards cannot catch these on their own:

* It emits `MIN_SEED_PRISM` as **the seed it actually intends**, not as the 90%-of-float floor. Emitting the
  floor made the knob inert — `validateSeededAmount` takes `max(env, 90%)` — so a mistakenly lowered
  `SEED_LIQUIDITY` could strand up to **54.53 PRISM** in a hook that is excluded from fee shares and, after
  renouncing, has no path back out. The bar now sits a microtoken below the whole float.
* It states the launch valuation **twice**: once as `LAUNCH_TICK`, once by hand as `LAUNCH_FDV_ETH`, and
  refuses to emit if they disagree by more than 5%. `Deploy.s.sol`'s ±25% FDV band exists so the operator
  must declare the valuation they intend, but that band is vacuous when `TARGET_FDV_WEI` is derived from the
  very price it checks: it reduces to `impliedFdv(p) == impliedFdv(p)`. Tick alignment does not help either
  — 4800, 14800, 48400 and 84400 are all multiples of 200, and a dropped digit launches ~54x too cheap with
  every other guard green. **If you move the launch price, change both constants.**

The **37600** row remains fork-verified as an alternative at a roughly 2x higher valuation
(`SEED_LIQUIDITY=80951486627637257491` when seeding 530.466098383219207988 PRISM). The lower valuation was
chosen because the number of tokens a fixed amount of support capital can absorb scales inversely with the
launch price, so a lower launch covers proportionally more of the distributed supply.

**`MERKLE_TOTAL` and `MIGRATION_AMOUNT` are `4454677055887032075331`, not `4454677056000000000000`.**
Rounding the reserve to a tidier figure is an easy mistake and it will not deploy: the canary compares
its own `total` against `MERKLE_TOTAL`, so a rounded value fails that check. Copy the digits from
`generate.mjs`, never retype them.

For reference, the `76600` value corresponds to **2,120.9 PRISM/ETH — a 2.36 ETH FDV**
for the whole 5,000 supply. If that is not what you intended, do not use it.

**`SEED_TICK_LOWER` is your depth.** Use `-887200` for a full curve. A narrow range concentrates the
entire float into a few ticks: measured, `[76400, 76600]` with a large liquidity value let **one buyer
take 99.9% of the supply for 2.4 ETH**, and every check passed.

**`SEED_LIQUIDITY` sets how much PRISM actually goes in**, and too little is unrecoverable. It must
require **≤ `5000 − MIGRATION_AMOUNT/1e18` PRISM**, and it should require nearly all of it. The PRISM consumed is
`L × 1.0001^(tickUpper/2)`, so the PRISM-per-liquidity figure depends entirely on the tick — at 76600
it is ~46, but at the ticks you should actually use it is far lower: **22.2 at tick 62000, 7.03 at
39000, **9.392 at 44800**, 6.6187 at 37800, 6.5529 at 37600, 2.2255 at 16000**. Sizing from "46"
under-seeds by up to 20x.
(At tick 37600, `SEED_LIQUIDITY=80951486627637257491` consumes 530.466098383219207988 PRISM,
fork-measured — leaving 14.856846112967924669 PRISM behind, NOT "within 10 wei of the float" as an earlier
version of this line claimed. The §2 configuration seeds the whole float instead and strands nothing; use
`merkle/seed-params.mjs` for a liquidity value matching whatever you actually intend.) Whatever you
leave in the hook is stranded there forever, and if the seeded float is under one whole PRISM,
`totalShares` can never leave zero — which means `pokeFees` returns early forever and **every fee the
pool ever earns becomes unclaimable.** The script now enforces `MIN_SEED_PRISM` (default: 90% of the
float) so this cannot pass silently. That check is **upward-only**: a `MIN_SEED_PRISM` below 90% of the
float is ignored, because as a downward override it was worse than having no check at all — `0` allowed
99.98% of supply to strand and still deploy. There is also an absolute floor of 50 PRISM, because a
share needs a *whole* token and a ~1-PRISM pool yields buyers zero whole tokens after price impact.

**Every one of these is silently truncated** if you add a digit — `SEED_LIQUIDITY` to `uint128`, the
ticks to `int24`, the price to `uint160`. A tick of `16777416` becomes `200`, a ~2,000,000× price error
that deploys cleanly. The script now round-trips each value and refuses a truncated one, but count the
digits yourself as well.

**Expect to be sniped.** The pool is live the moment the seed transaction lands, and `seed`'s calldata
is public in the mempool beforehand. With the reference `L=1e18`, a single 1 ETH buy took 97.85% of the
float and 100% of the fee shares. Seed depth is the only defence, because fee shares are proportional
to whole tokens held — a thin seed sells a permanent claim on protocol revenue for pocket change.

## 3. Configure `.env`
```bash
cp .env.example .env    # then fill in every field
```
Fill: `RPC_URL`, `MERKLE_ROOT`, `MERKLE_TOTAL`, `MIGRATION_AMOUNT`, `SEED_SQRT_PRICE_X96`,
`SEED_TICK_LOWER`, `SEED_TICK_UPPER`, `SEED_LIQUIDITY`, **`TARGET_FDV_WEI`** (the valuation you intend,
checked against the price within 25%) and **`SALT_NONCE`** (a random secret — a nonce of 0 makes the
deploy address publicly derivable and squattable, which was demonstrated end to end).

## 4. Dry run (simulate — no broadcast)
```bash
source .env
forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --sender <your deployer address>
```
It runs the whole deploy against a fork of current mainnet and prints the resulting addresses.
**If it reverts, fix your config — do not broadcast.** Common causes: `SEED_LIQUIDITY` needs more
PRISM than available, or requires too little (`MIN_SEED_PRISM`); the opening price is below
`SEED_TICK_UPPER`; ticks not multiples of 200; `MERKLE_TOTAL` unset or above `MIGRATION_AMOUNT`.

**Pass `--sender`.** Without it the rehearsal mines a different salt and a different owner than the real
broadcast, so the address it prints is not the address you will get. Then check that address is empty on
mainnet immediately before broadcasting:

```bash
cast code <printed hook address> --rpc-url "$RPC_URL"   # must be 0x
```

If it has code, someone squatted it — bump `SALT_NONCE` and re-run. (The squatted contract is a
legitimate hook owned by you, since the address is bound to the initcode hash; it is a nuisance, not a
takeover.)

## 5. Broadcast
```bash
forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --sender <deployer> \
  --account <your-keystore> --broadcast --slow --verify
```
This is **three transactions** on sequential nonces — or **two** with no airdrop (use `--slow`):
1. deploys `PrismMigration(MERKLE_ROOT, deployer)` through the CREATE2 factory,
2. mines a flag-valid CREATE2 salt and deploys `PrismHookV2` (mints the reserve to the vault, the
   rest to the hook),
3. `hook.seed(...)` (initializes the pool + mints the LP position to the hook).

**The airdrop is not opened by the deploy.** `migration.setToken(hook)` is the switch that makes the
reserve distributable — `claim` refuses while it is unset and is permissionless once it is set — so it is a
separate step (`script/OpenAirdrop.s.sol`, §6b) run once the pool has had time to trade. Note the
consequence: the deploy key is needed again for that step, *after* the renounce.

Ownership is deliberately **still held** at this point. Total measured cost: **9,087,021 gas** across the
three transactions, from a full mainnet-fork dry run of the configuration in §2, plus a separate ~24,000 gas
for the renounce. About **0.045 ETH at 5 gwei** or 0.27 ETH at 30 gwei.

An earlier figure of 6,619,259 here understated it by 37%; it predated the config guards and the
CREATE2 salt search. **Fund against 9.1M plus margin, and re-read your own dry run's estimate rather than
this number** — it is the one place where being optimistic can half-deploy the token, since a reverted
transaction does not stop the next.

Record the printed **PrismHookV2**, **PrismMirror**, and **PrismMigration** addresses.

If any transaction reverts, do **not** re-run this script — see the warning at the top. Complete the
remaining steps by hand, leaving the renounce for last.

## 6. Verify on-chain, then renounce

Check all of this **before** giving up ownership, because renouncing is the point of no return:

- `seeded()` == `true` — the single most important check. Renouncing an unseeded hook is terminal.
- `balanceOf(hook)` equals the small remainder you expected. This is the only real proof the float
  actually went into the pool; a tiny seed passes every other check.
- The pool's current tick equals `SEED_TICK_UPPER` (not some higher phantom value), and
  `globalTickLower`/`globalTickUpper` are the range you intended.
- `totalShares()` == 0 (nobody has bought yet), the LP position's liquidity > 0.
- `migration.token()` == the hook, `balanceOf(migration)` == `MIGRATION_AMOUNT`,
  `nftBalanceOf(migration)` == 0, and `migration.merkleRoot()` == the root printed by `generate.mjs`.
- Verify one real holder's `(account, amount, proof)` from `merkle/out/claims.json` against the
  deployed root. A wrong root locks the reserve forever and nothing else detects it.

Then, and only then:

```bash
HOOK=<hook address> forge script script/Renounce.s.sol --rpc-url "$RPC_URL" \
  --sender <deployer> --account <your-keystore> --broadcast
```

That script re-checks `seeded()` and ownership **in local simulation against the latest block,
immediately before signing** — the broadcast transaction itself is a bare 4-byte `renounceOwnership()`
call with no on-chain guard, because forge script `require`s never execute on-chain. That is still a
real safety net for the mistake it targets (running it against an unseeded hook), since `seeded` only
ever goes false→true and only the owner can change the owner. It is not protection against a reorg
between simulation and inclusion.

**Etherscan:** `--verify` needs `ETHERSCAN_API_KEY` in the environment and an `[etherscan]` section in
`foundry.toml`; neither ships here, so expect to verify manually. Note `PrismMirror` is deployed by the
hook's constructor and forge does **not** verify it — verify the user-facing ERC-721 yourself.

## 7. Distribute the airdrop

You have two options, and they are not exclusive — you can push to most holders and leave the claim
path open for the rest.

### Option A — push it out (holders do nothing)

`migration.claim` is permissionless and always delivers to `account`, so anyone can submit a holder's
proof on their behalf. `PrismAirdropBatcher` loops that call, and `merkle/push-airdrop.mjs` sizes and
sends the transactions:

```bash
MIGRATION=<vault address> forge script script/DeployBatcher.s.sol \
  --rpc-url $RPC_URL --account <keystore> --broadcast --verify

cd merkle
node push-airdrop.mjs --batcher <batcher address> --dry-run    # plan + cost, sends nothing
node push-airdrop.mjs --batcher <batcher address> --key $PK    # send it
```

The batcher is ownerless, holds no funds, and never touches PRISM (it goes vault → holder directly),
so **anyone** can run this — the distribution does not depend on you staying involved.

Cost scales with the *amount* delivered, not the holder count, because the mirror mints one fee-share
NFT per whole PRISM. Each mint costs **~76k gas** in production — two virgin `_setFeeDebt` slots at
20,000 each, not the ~100 they cost on a pool that has never collected a fee, which is why an earlier
figure of ~37k understated this by 2x. Measured: a dust holder ~61k gas, a mint-capped holder ~10M.
For a ~1,200-holder / 4,455-PRISM list that is **~419M gas across ~47 transactions** — roughly 0.11 ETH
at 0.26 gwei but **~2.1 ETH at 5 gwei**, so watch the gas price. `--dry-run` prints the live estimate,
and it is accurate to well under 1% against real execution.

Useful details:
- **Safe to interrupt and re-run.** The vault records who has been paid; the batcher skips them. Retry
  the same command as often as you like — nothing double-sends. If a run delivers nothing at all, the
  script says so rather than telling you to retry, because that means the proofs do not match the
  deployed root and retrying cannot help.
- **`--min-prism 1`** skips holders below one whole PRISM. On the corrected snapshot that is 783
  holders whose allocations are worth less than the gas to deliver them; skipping saves ~52M gas and
  they can still claim normally. The closing verification always checks the **full** list, so it can
  never report "all paid" about a filtered subset.
- **Every transaction is capped at 2^24 = 16,777,216 gas by EIP-7825**, whatever the block limit is.
  The runner sizes chunks against that cap and refuses to plan a transaction that would exceed it; if
  any single holder's claim cannot fit, it aborts and names them rather than looping forever.
- **One caveat.** A transfer mints at most `MAX_REALIGN` (128) fee-share NFTs, and `syncNFTs` is bounded
  the same way and is `msg.sender`-only. A holder above 128 whole PRISM receives all their PRISM but
  must call `syncNFTs` themselves — possibly more than once — to mirror the remainder and earn on the
  full amount. On the published snapshot 5 holders are above that threshold. This bound is what keeps
  every claim inside the per-transaction gas cap; do not raise it without re-measuring.

### Option B — holders claim

Publish `merkle/out/claims.json` and a UI/CLI that calls `migration.claim(account, amount, proof)`.
Each holder pays their own gas. Note that anything never claimed stays locked in the vault **forever**
— there is no sweep.
- **Any buy-and-burn or similar integration** pointed at a previous PRISM address must be repointed to
  the new hook before launch. The burn destination stays `0x…dEaD`, which this token already excludes from
  the fee layer, so burned PRISM mints no shares and genuinely leaves circulation.

## Pre-flight checklist

Run through this immediately before broadcasting. Every item below corresponds to a failure that
deploys *successfully* and cannot be undone.

1. `MERKLE_ROOT` is nonzero **iff** `MIGRATION_AMOUNT > 0`, and `MERKLE_TOTAL` matches what
   `generate.mjs` printed. Confirm `MIGRATION_AMOUNT` is in **wei** — recount the digits.
2. `CANARY_PATH` points at the `canary.json` written by the **same** `generate.mjs` run that produced
   `MERKLE_ROOT`. The deploy re-verifies that leaf for you and this is the only check that can catch a
   well-formed root built from the wrong snapshot — if it fails, regenerate the tree, never bypass it.
3. Re-read `prepare-basis.mjs`'s dropped-row manifest. Every address on it gets **nothing**, forever.
   Confirm each is genuinely infrastructure and that no real holder is among them.
4. `SEED_TICK_UPPER` is the launch price you actually intend (§2), and `SEED_SQRT_PRICE_X96` is the
   price *at* that tick, not above it.
5. `SEED_TICK_LOWER` is your depth — `-887200` unless you have a specific reason.
6. Both ticks: multiples of 200, within ±887200, lower < upper. No extra digits anywhere.
7. The PRISM the seed will consume (`L × 1.0001^(tickUpper/2)`) is nearly all of
   `5000 − MIGRATION_AMOUNT/1e18`. Whatever you leave behind is locked forever.
8. Dry run with `--sender`, then `cast code` the printed hook address on mainnet — it must be empty.
9. Deployer funded for **≥ 9.1M gas across the three transactions** (a full fork dry-run of the planned
    config measured 9,087,021), **plus the separate renounce transaction**, plus margin. Fund for well
    over the estimate: because a reverted transaction does not stop the next, running out of gas
    part-way through is one of the few ways to half-deploy this. Broadcast at a low base fee.
10. Broadcast with `--slow`, and understand you are signing three transactions whose `require`s do not
    run on-chain.
11. Verify §6 in full — **especially `seeded()`** — before running `Renounce.s.sol`.
12. **Have a `pokeFees()` keeper ready to run from the moment the pool is live.** It is permissionless
    and free to call. Uncollected fees are split with anyone who buys before they are collected (a swap
    cannot poke, because it runs inside `PoolManager.unlock`), so the uncollected backlog is the prize
    and a frequent keeper keeps it too small to be worth taking. See the README's known-properties list.
13. Expect the first buyer to take a large share of the float and 100% of the fee shares in the launch
    block. Size the seed so that outcome is acceptable to you.

## Rollback
There is none for the token itself once ownership is renounced — that is the point of no return, and it
is why renounce is a separate, guarded step.

Before renounce you still hold the one privileged function (`seed`), so a mis-seeded pool is the only
thing you cannot fix even then: `seed()` is one-shot. If a step reverts mid-deploy, finish the remaining
steps by hand rather than re-running `Deploy.s.sol` — the hook already exists, and forcing a second
deploy would orphan the first with a dead 5,000-PRISM supply on mainnet.

Every dollar of caution here is cheaper than an unrecoverable mistake.
