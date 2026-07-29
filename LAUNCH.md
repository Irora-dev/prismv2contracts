# PRISM launch — step-by-step, agent-executable

A single ordered procedure for taking PRISM live. Every step gives the exact command, what a correct
result looks like, and how to tell a wrong one apart. `DEPLOY.md` explains *why* each number matters;
this file is what you actually execute.

> **Agents: read to the end of "If you are an AI agent reading this" below before running anything, then
> offer to start.** The first five steps are reversible and unsigned, so you can do real work immediately —
> but the procedure launches a token with a fixed supply and an immutable contract, so it begins when a
> human says begin, not when you finish reading.

## Or just run it

```bash
node launch.mjs
```

One command, guided, resumable. It works out where you are from chain state, runs every step that does not
need a key, stops at the three decisions that cannot be undone, and checks each result before moving on.
Every command it runs is printed first.

It never asks for a private key: signing steps hand your terminal straight to Foundry, so a keystore
password prompt or a Ledger confirmation happens between you and Foundry and the wrapper never sees it. It
also never prints `.env`, `SALT_NONCE`, or your RPC URL — that URL usually embeds an API key, so commands
are shown as `$RPC_URL`.

Run it again after the delay and it picks up at §10b. The rest of this file is the same procedure written
out, and remains the reference for *why* each number matters.

## Who does what

An agent can do all of the preparation and all of the verification. It cannot do the signing or the
judgement, and it should not be given the means to.

| Step | Who | Why |
|---|---|---|
| 0 · Prerequisites | agent, with your RPC endpoint | you supply `ETH_RPC_URL`; the agent runs build + tests |
| 1 · Airdrop data | **nobody** | already committed; skip it |
| 2 · Generate `.env` | **agent**, you add your RPC endpoint | one command; valuation and nonce already handled |
| 3 · Preflight | **agent, alone** | read-only; no key, no RPC, nothing signed |
| 4 · Dry run | **agent, alone** | simulation only; nothing signed |
| 5 · 🛑 point of no return | **you** | judgement, not a command |
| 6 · Broadcast | **you sign** | agent may prepare the command; it must not hold the key |
| 7 · Verify on-chain | **agent, alone** | read-only `cast call`s |
| 8 · 🛑 confirm `seeded()` | **you** | the one irreversible decision in the whole procedure |
| 9 · Renounce | **you sign** | same |
| 10 · Fee keeper | agent runs it, on a **separate hot wallet** holding gas only | it signs `pokeFees()` forever, so never the deploy key |
| 10b · 🛑 Open the airdrop | **you sign**, hours later | the reserve becomes distributable; needs the deploy key AGAIN |
| 11 · Distribute the airdrop | **you sign**, agent plans and dry-runs | many transactions; agent should verify each batch |
| 11b · Who needs `syncNFTs` | **agent, alone** | read-only |
| 12 · Post-launch verification | **agent, alone** | read-only |

So five steps are fully autonomous, four are collaborative, and five need you — every one of those five
either signs a transaction or makes a decision that cannot be undone.

### How much of this is just signing

Counted from a real rehearsal, the whole launch is about **53 transactions**, and only **5 of them need
the deploy key**:

| | transactions | key needed |
|---|---:|---|
| Deploy (§6) | 3 | **the deployer key** — it becomes `owner`, and only `owner` can `seed()` |
| Renounce (§9) | 1 | **the same key** — nothing else can renounce |
| Open the airdrop (§10b) | 1 | **the same key again**, hours later — nothing else can open it |
| Batcher deploy (§11) | 1 | any funded wallet; the batcher is ownerless and grants nothing |
| Airdrop push (§11) | ~47 | any funded wallet — **gas only** |
| Fee keeper (§10) | ongoing | a separate gas-only wallet |

The push is the bulk of the volume and needs **no privilege at all**. `PrismAirdropBatcher` has no owner
and never touches a token; `PrismMigration.claim(account, amount, proof)` is permissionless and always
delivers to `account`, so the caller is irrelevant and cannot redirect anything. The worst a stolen push
key can do is waste its own gas. So point it at a throwaway hot wallet with some ETH and let it run
unattended (`--yes`), which is exactly how it was rehearsed.

That leaves the human doing, across the entire launch:

- **5 signatures** with the real key: 3 deploy + 1 renounce in one sitting, then **1 more hours later** to
  open the airdrop. That last one is why the key is not finished when you renounce — see below.
- **Two values to paste**: your RPC endpoint and your deployer address. Nothing else — the airdrop data and
  its Merkle root are committed, the seed parameters are fixed, and `SALT_NONCE` is generated for you. The
  deploy path needs no `npm install`.
- **No decisions.** The valuation is already set (§2). The dropped-row review is already done and its
  result committed. `.env` is one command.
- **One judgement moment**: the final go/no-go at §5 — confirming you intend to launch, not working
  anything out. The §8 gate needs no judgement either: `Renounce.s.sol` itself hard-requires `seeded()`,
  so it physically cannot renounce an unseeded hook.

Everything else — deriving every seed parameter, preflight, the dry run, all verification, finding who
still needs `syncNFTs` — the agent does alone, and none of it can move funds.

**Never give an agent the deploy key.** Between `seed()` and `renounceOwnership()` that key can
permanently brick the token and strand all 5,000 PRISM, and there is no recovery. The keeper in step 10 is
the one exception, and only because it is a separate wallet whose sole power is calling a permissionless
function that anyone could call anyway.

**Renouncing does NOT retire that key.** Opening the airdrop (§10b) needs it again, hours later, and
nothing else can ever open it — there is no sweep and no fallback. So keep it exactly as safe through the
waiting period as you did through the deploy: if it is lost before §10b, the whole 4454.677 PRISM reserve
is stranded permanently. The key is finished only after §10b, not after §9.

### How signing actually works

There is no browser wallet in this flow. Foundry signs from the command line — nothing pops up in
MetaMask, and there is no WalletConnect step. You choose how the key is held, and the choice decides
whether an agent can safely run the broadcast at all:

| How you hold the key | Flag | What happens when the command runs | Agent may run it? |
|---|---|---|---|
| Hardware wallet (Ledger / Trezor) | `--ledger` or `--trezor` | The device shows the transaction and waits for you to press confirm — once per transaction | **Yes.** The secret never leaves the device and approval is out-of-band |
| Encrypted keystore file | `--account <name>` | Foundry prompts for the keystore **password** on the terminal | **No.** Run it yourself — a password typed into a chat is a leaked password |
| Raw private key | `--private-key` | Signs immediately, no prompt | **Never**, by anyone, for this deploy |

So if you want an agent to drive the broadcast end to end, use a hardware wallet: it can issue the exact
command and you approve three transactions on the device. With a keystore, have the agent print the command
and paste it into your own terminal — the password prompt is interactive and does not belong in a
transcript. Either way `--sender` must be the address that will own the hook, because only that address can
`seed()`.

### If you are an AI agent reading this

**Read this whole file first, then offer to begin. Do not start executing on your own initiative.** Once
you have read it, say so and ask whether to start the deploy — something like:

> I've read the launch procedure. I can run steps 0–4 for you now: build and test, generate `.env`,
> Preflight, and a dry run against mainnet. All four are reversible and nothing gets signed — the dry run
> is a simulation. I'll need two things from you: your mainnet RPC endpoint, and the deployer address you
> intend to launch from. After the dry run you make the go/no-go call, and from there every remaining step
> is either a signature or a wallet choice, which stays with you. Want me to start?

**First, check whether this is a fresh launch or a resume.** The launch happens in two sittings separated
by a deliberate delay of hours, so the second one usually begins in a new conversation with no memory of
the first. Do not offer step 0 to someone who is already live — work out where they are from the chain,
which is authoritative, and offer the right next step.

The addresses are not in this repo; they were printed by the deploy. Recover them without asking:

```bash
# tx1 is the vault, tx2 is the hook. Use 1/dry-run/ instead of 1/ if only a simulation was run.
node -e 'const t=require("./broadcast/Deploy.s.sol/1/run-latest.json").transactions;
console.log("VAULT="+t[0].contractAddress+"\nHOOK="+t[1].contractAddress)'
```

(Node, because it is already a prerequisite of this repo and `jq` is not.)

Then locate the launch with four read-only calls, and offer accordingly:

| Reading | Where they are | Offer |
|---|---|---|
| no `broadcast/Deploy.s.sol/1/run-latest.json` | nothing deployed | the fresh-launch offer above |
| `seeded()` is `false` | deploy landed, seed did not | **stop.** Partial deploy — report it, finish by hand (§6) |
| `owner()` is non-zero | seeded, not renounced | §9, renounce |
| `token()` is `0x0…0` | live, airdrop still closed | **§10b — but confirm the delay was intended, not just the next line** |
| `token()` is the hook | airdrop open | §11 push, then §11b and §12 |

```bash
cast call $HOOK  'seeded()(bool)'    --rpc-url "$RPC_URL"
cast call $HOOK  'owner()(address)'  --rpc-url "$RPC_URL"
cast call $VAULT 'token()(address)'  --rpc-url "$RPC_URL"
```

For a resume, say which state you found and why that is the next step, rather than just starting. And if
the reading is `token() == 0`, remember what §10b is: it is not a continuation, it is the decision to put
89% of the supply into circulation. Ask whether the intended delay has actually elapsed.

Then, once they say yes: **one step at a time, in order.** After each step, check the result against that
step's "expect" block before continuing, and report what you saw rather than only that it passed.

Four rules that do not bend:

1. **Never skip or reorder a `🛑 STOP` gate.** Each one guards a failure that cannot be undone once past it.
2. **Never ask for, accept, or store a private key** — not for step 6, 9, 10 or 11. Prepare the exact
   command, print it, and hand it over. If asked to hold a key, decline and explain why: between `seed()`
   and `renounceOwnership()` that key can permanently brick the token.
3. **Never print `.env` or `SALT_NONCE`** (see §2). Confirm the file exists and move on.
4. **Do not improvise around an unexpected result.** Stop and report it. A revert here is nearly always the
   system refusing a bad configuration, which is the good outcome — "adjusting numbers until something
   passes" is how a launch happens at a price nobody chose.

One judgement call is genuinely yours to surface rather than make: this deploys at a **fixed valuation**
(§2). Say what that valuation is in the currency the person is thinking in, and confirm it is the one they
mean, before the dry run rather than after.

---

## 0 · Prerequisites

```bash
forge --version && node --version          # Foundry, Node 18+
export ETH_RPC_URL="<your mainnet endpoint>"
export RPC_URL="$ETH_RPC_URL"
forge build && forge test
```

**Expect:** all tests pass, 0 failed. If you see 14 failures mentioning `ETH_RPC_URL`, that variable
is unset — it is not broken code.

You also need a funded deployer key. Budget **≥ 9.1M gas** for the deploy plus the renounce, and fund
well above the estimate: the deploy is three separate transactions and a reverted one does *not* stop the
next, so running dry part-way is one of the few ways to half-deploy this. Prefer a keystore
(`--account`) over a raw private key.

---

## 1 · The airdrop is already built — nothing to do

`airdrop/basis.json` (1203 holders), `airdrop/claims.json` (per-holder proofs) and `airdrop/canary.json`
are committed. The Merkle root is a fact in the repo, not something you produce:

```
MERKLE_ROOT   0x2cd60218d3f802a855996dbcbf7db5db860f88c541468c7601e02e627d33e12f
holders       1203
total         4454677055887032075331 wei  (4454.677055887032075331 PRISM)
```

**Skip to step 2.** Nothing here needs running, and the deploy path needs no `npm install` at all —
`make-env.mjs` uses only Node built-ins, and the Solidity scripts read the committed JSON directly.

<details>
<summary>Optional: prove the root derives from the basis rather than trusting it</summary>

```bash
cd merkle && npm install        # only needed for this optional check
node generate.mjs ../airdrop/basis.json /tmp/verify
cd ..
```

Expect `1203 holders`, `totalAmount (wei): 4454677055887032075331`, and the same root as above. Verified
reproducible. This is the only reason to install anything.

</details>

<details>
<summary>Launching a different distribution instead</summary>

Run `prepare-basis.mjs` on your own snapshot, then `generate.mjs` on the result (both need `npm install`),
point `MERKLE_ROOT` / `MERKLE_TOTAL` / `MIGRATION_AMOUNT` / `CANARY_PATH` at your own output, and **read the
dropped-row manifest before continuing** — every address on it receives nothing, forever. For the shipped
set that review is already done: the two dropped rows are the burn sink and a Uniswap V3 PRISM pool, both
confirmed on-chain.

</details>

---

## 2 · Generate `.env`

```bash
node merkle/make-env.mjs > .env
```

Then set `RPC_URL` and `ETH_RPC_URL` in it to your own endpoint. That is the only value you supply.

Everything else is filled in: the root, total and reserve come from the committed airdrop data; the seed
price, tick, liquidity and floors are the fork-verified launch configuration; and `SALT_NONCE` is generated
fresh from a CSPRNG on every run.

**Keep `.env` private, never commit it, and never paste or print its contents.** `SALT_NONCE` has to be
unpredictable until you have deployed — with a guessable nonce your CREATE2 address is derivable, and
someone can squat it to block the deploy. It is gitignored; leave it that way.

That last clause matters most if an agent is running this step, because printing a file it just generated
is a habit. **Do not echo `.env`, or the nonce, into any transcript, chat, issue, log or pull request** —
anywhere it lands is somewhere it can be read. Confirm the file exists and move on; nothing downstream
needs the nonce shown to a human. If it has already been exposed, generate a fresh one by re-running
`make-env.mjs` before you broadcast, and re-run Preflight and the dry run.

The launch valuation is not a prompt: this deploys at tick 44800, a fully-diluted valuation of ~56.68 ETH,
seeding the remaining float bar 1000000004 wei (0.000000001 PRISM) of deliberate rounding headroom — POSM
rounds its deposit requirement up, and a one-shot mainnet operation should not run with zero slack. That
residual stays in the hook and is unreachable, which is the intended trade.

To launch at a different price, the two constants that actually decide it are both in
`merkle/make-env.mjs`: **`LAUNCH_TICK`** sets the price, and **`LAUNCH_FDV_ETH`** states the same valuation
by hand as a cross-check. Change **both** — the script refuses to emit a `.env` if they disagree by more
than 5%, which is the point — then re-derive the numbers in `DEPLOY.md` §2 and do a fresh dry run.
Deliberately, not at the last minute. (`DEPLOY.md` §2 is a reference table, not the source of the price;
editing it alone changes nothing.)

---

## 3 · Preflight

```bash
forge script script/Preflight.s.sol
```

**Expect:** `PREFLIGHT PASSED`, plus the implied FDV and the canary account it verified. This runs every
configuration guard read-only — it touches no chain state, spends nothing, and signs nothing.

If it reverts, the message names the problem. Fix the configuration; do not work around the check. The
canary check in particular is the **only** thing that can catch a `MERKLE_ROOT` that is well-formed but
built from the wrong snapshot, and nothing on-chain can catch that later: `PrismMigration` has no sweep,
so a wrong root locks the entire reserve permanently.

---

## 4 · Dry run against mainnet

```bash
forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --sender <your deployer address>
```

**Expect:** `Script ran successfully`, and printed values matching your intent — the implied FDV, `canary
leaf verified against MERKLE_ROOT`, `pool opened at tick:` equal to your `SEED_TICK_UPPER`, and the seeded
PRISM amount. With the `DEPLOY.md` §2 configuration that amount is **545322944111967924665 wei** — the
entire remaining float bar **1000000004 wei** (0.000000001 PRISM) of deliberate rounding headroom, which is
the same figure §7 tells you to expect. If you see the float consumed to the last wei instead, you are
running an older configuration than this runbook documents.

Then confirm the predicted hook address is unoccupied:

```bash
cast code <printed PrismHookV2 address> --rpc-url "$RPC_URL"
```

**Expect:** exactly `0x`. Anything else means the address is taken — bump `SALT_NONCE` and redo step 4.

---

## 5 · 🛑 STOP — the point of no return begins here

Everything up to now is reversible. Nothing after this is. Before broadcasting, confirm:

- Step 3 printed `PREFLIGHT PASSED`.
- Step 4's printed tick equals your intended `SEED_TICK_UPPER`, and the FDV is the valuation you mean.
- `cast code` returned `0x`.
- The deployer is funded well above 9.1M gas, and the base fee is low.
- You have read `DEPLOY.md`'s opening warning and accept that this is three transactions, that its checks
  ran in simulation only, and that a mid-sequence failure must be finished by hand rather than re-run.

---

## 6 · Broadcast

```bash
forge script script/Deploy.s.sol --rpc-url "$RPC_URL" \
  --sender <deployer> --account <keystore> --broadcast --slow
```

`--slow` is required: it confirms each transaction before sending the next.

**Expect:** `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`, and the printed hook / mirror / vault / LP token
id. Record all four.

**If any step reverted:** finish the remaining steps by hand and stop to report. A re-run *will* now stop
itself at the CREATE2 step — the vault is deployed deterministically, so every input to the hook's mined
address is the same on a second run and it finds the hook already there. Treat that as a backstop rather
than a plan.

It is worth knowing this was not always so: while the vault was created with `new`, its address moved with
the deployer's nonce, so a re-run mined a *different* hook address, the already-deployed check passed, and
you ended up with a second complete 5,000 PRISM system while the first was orphaned along with any ETH
already paid into its pool — the exact outcome this runbook told you a re-run would prevent.

**Before you renounce, whatever happened:** confirm the reserve is reachable — `cast code $VAULT` must be
non-empty and `cast call $VAULT 'token()(address)'` must return the hook. `Renounce.s.sol` now enforces
both on-chain in the same transaction that renounces, so it will refuse rather than let you seal a launch
whose airdrop reserve was minted to an address that has no code.

---

## 7 · Verify on-chain before renouncing

```bash
HOOK=<hook>; VAULT=<vault>
cast call $HOOK 'seeded()(bool)'                    --rpc-url "$RPC_URL"
cast call $HOOK 'owner()(address)'                  --rpc-url "$RPC_URL"
cast call $HOOK 'balanceOf(address)(uint256)' $HOOK --rpc-url "$RPC_URL"
cast call $VAULT 'merkleRoot()(bytes32)'            --rpc-url "$RPC_URL"
cast call $VAULT 'token()(address)'                 --rpc-url "$RPC_URL"
```

**Expect:** `seeded()` is **`true`**; `owner()` is still your deployer; `merkleRoot()` equals your
`MERKLE_ROOT`; `token()` equals the hook address. The hook's own PRISM balance should be
**1000000004 wei** (0.000000001 PRISM) with the §2 configuration — deliberate rounding headroom, described
in DEPLOY.md §2. Anything materially larger means you seeded less than you intended, and since whatever
stays there is stranded permanently, understand it before renouncing.

---

## 8 · The unseeded-renounce guard (enforced in code)

**You do not have to police this one.** `Renounce.s.sol` hard-requires `seeded()` on-chain in the same
transaction that renounces:

```solidity
require(hook.seeded(), "hook is NOT seeded - renouncing now would brick it permanently");
```

So it physically cannot renounce an unseeded hook — if step 7 showed `false`, step 9 reverts rather than
bricking anything. Step 7 is still worth reading, because a `false` there means the seed did not land and
you have a partial deploy to finish by hand.

Why the guard exists at all: `seed()` is the only owner-gated function, and `_beforeInitialize` rejects any
pool initialization that does not originate inside it. So renouncing before a successful seed would mean the pool could never be created
by anyone, the fee logic would no-op forever, and the entire 5,000 PRISM supply would sit in an ownerless
contract with no exit. There is no recovery — which is why the check is in the script rather than left to
an operator remembering to look.

---

## 9 · Renounce

```bash
HOOK=<hook> forge script script/Renounce.s.sol --rpc-url "$RPC_URL" \
  --sender <deployer> --account <keystore> --broadcast
```

**Expect:** `Ownership renounced`, then `cast call $HOOK 'owner()(address)'` returns the zero address.
The token is now final and immutable.

---

## 10 · Start the fee keeper

Do this **immediately**, in the same session. It is a security control, not an optimisation: uncollected
fees are shared with anyone who buys before they are collected, so the uncollected backlog is the prize
and collecting often keeps it too small to be worth taking.

```bash
cd merkle
node keeper.mjs --hook $HOOK --rpc "$RPC_URL" --key $PK --interval 12
```

**Expect:** a `poke #N` line per interval. `nothing to collect` is a normal and healthy result. The
keeper tolerates reverts by design and should be left running.

---

## 10b · 🛑 Open the airdrop — the delay you planned for

**Wait here.** Everything above put the pool live with only the ~545 PRISM float in circulation. This step
puts the other 4454.677 PRISM — 89% of supply — into play, and it cannot be undone. Give the pool the
interval you intended (10–24 hours is the plan) so the float can actually trade first.

Why this is a separate step at all: `PrismMigration.claim` refuses while the vault's `token` is unset, and
is permissionless the moment it is set. So `setToken` is a single switch that opens the reserve to
everyone at once — there is no per-holder gate and no way to open it gradually. It used to run inside the
deploy, which meant the whole supply became movable in the same sequence that created the pool, one
transaction *before* the pool even existed.

```bash
HOOK=$HOOK VAULT=$VAULT RESERVE=4454677055887032075331 \
  forge script script/OpenAirdrop.s.sol --rpc-url "$RPC_URL" \
  --sender <deployer> --account <keystore> --broadcast
```

**Expect:** `AIRDROP IS OPEN`, and `cast call $VAULT 'token()(address)'` returns the hook. The script
refuses on its own if the pool is not seeded, if the vault already has a token wired, if the hook does not
name that vault, if the reserve does not match, or if `--sender` is not the vault's deployer — so a wrong
argument costs a reverted simulation, not a mis-wired airdrop.

**This is the last thing that needs the deploy key.** It is also the only step that can strand the reserve
by *inaction*: until it runs, nothing but that key can open the airdrop, there is no sweep, and no
fallback exists. If the key is lost during the wait, all 4454.677 PRISM is gone permanently.

Before running it, confirm you are past the delay on purpose and not just working down the list. Nothing
below is reversible either, but this is the step that decides *when* the supply arrives.

---

## 11 · Distribute the airdrop

Requires §10b: the vault must be wired, or every claim reverts `TokenNotSet` and the batcher refuses the
whole batch with `TokenNotWired`. Holders do not have to claim — this pushes allocations to their wallets.

```bash
MIGRATION=$VAULT forge script script/DeployBatcher.s.sol --rpc-url "$RPC_URL" \
  --sender <deployer> --account <keystore> --broadcast

cd merkle
node push-airdrop.mjs --batcher <batcher> --rpc "$RPC_URL" --dry-run
node push-airdrop.mjs --batcher <batcher> --rpc "$RPC_URL" --key $PK
```

**Expect:** the dry run prints a transaction plan (~47 transactions for a 1,203-holder tree) with a gas
estimate. The real run reports each batch. It is safe to interrupt and re-run: the vault records who has
been paid, the batcher skips them, and nothing is double-sent.

**Run it until it reports zero unpaid, not once.** The gas model is deliberately conservative but it is
still a model: a chunk can stop a few rows short of its own plan, because the batcher refuses to start a
claim it might not be able to finish. That is the safe behaviour — those rows are *not attempted*, never
half-paid — and the runner detects it, prints how many holders remain, tells you to re-run, and exits
non-zero. A second pass costs almost nothing, because already-paid rows are skipped by a single storage
read. Nothing is ever at risk: `claim` is permissionless and has no deadline, so an unpaid allocation
simply stays in the vault until someone sends it.

### 11b · Find who still needs to mirror, and tell them

Nobody has to *claim* — the push above delivered everything. But delivering PRISM and mirroring it into
fee-shares are different, and the push can only do the first: `MAX_REALIGN` caps fresh mints at 128 per
transfer, so a holder receiving more than 128 whole PRISM gets **all** their PRISM and only 128
fee-shares. `syncNFTs` mints the rest, and it is **caller-only** — nobody can do it for them.

```bash
cd merkle
node check-shares.mjs --hook $HOOK --migration $VAULT --rpc "$RPC_URL"
```

**Expect:** a list of under-mirrored holders with the exact command each needs. It also reports anyone who
was **never paid** — check that first and go back to §11 if it names anyone, because an unfinished
distribution matters more than an unmirrored one. It exits non-zero when anyone is unpaid, so it is safe to
wrap in a script.

`--migration $VAULT` is what makes the unpaid answer exact: it reads the vault's own `claimed()` record.
Without it the script can only infer from a zero balance, which is equally true of a holder who received
their allocation and then sold — and 783 of the 1203 hold under one whole PRISM, so that is the likely case
rather than the exotic one. (An unpaid holder also holds zero, and zero is trivially "fully mirrored",
which is why this step used to hand out a clean bill of health over a push that stopped short.)

For the published 1203-holder snapshot the mirroring gap is **5 addresses holding 288 unminted shares
between them, 6.8% of the share base** — the other 1198 are fully mirrored by the push and need do nothing.

Contact those holders with the printed command. Verified on a fork: the largest (287 whole PRISM, 128
shares) reached its full 287 with **two** `syncNFTs(0)` calls, because the shortfall itself exceeds the
128-per-call cap. Re-run this script later to see who has acted.

There is no event when a mint truncates, so this script is the only way an operator learns who is
affected. Run it right after the push and again a few days on.

---

## 12 · Post-launch verification

```bash
cast call $HOOK 'totalShares()(uint256)'             --rpc-url "$RPC_URL"
cast call $HOOK 'balanceOf(address)(uint256)' $VAULT --rpc-url "$RPC_URL"
```

**Expect:** `totalShares` in the low thousands and rising as holders receive; the vault's balance falling
toward zero as the push proceeds. Confirm the keeper is still logging.

---

## Troubleshooting: what a revert means, and what to do about it

| Symptom | Meaning | Action |
|---|---|---|
| `MaximumAmountExceeded` (`0x31e30ad0`) | `SEED_SQRT_PRICE_X96` is below the price at `SEED_TICK_UPPER` | Fix the price. **Do not nudge the tick.** |
| `pool did not open AT SEED_TICK_UPPER` | The price was above the tick — a phantom quote | Fix the price to the exact `TickMath` value |
| `canary proof does NOT verify` | The root and the tree disagree | Regenerate the tree. Never bypass this |
| `MIGRATION_AMOUNT != MERKLE_TOTAL` | Reserve retyped or rounded | Copy the exact digits from step 1 |
| `SEED_SQRT_PRICE_X96 outside v4's usable range` | Price outside v4's bounds | Take the value from `DEPLOY.md` §2 |
| `seeded PRISM below 90% of the float` | `SEED_LIQUIDITY` too small for this tick | The PRISM-per-liquidity rate is tick-dependent; see `DEPLOY.md` §2 |
| A deploy transaction reverted | Partial deploy | **Do not re-run `Deploy.s.sol`.** Finish by hand, and stop |
| `TRANSFER_FROM_FAILED` during `seed()` | `SEED_LIQUIDITY` exceeds the PRISM the hook holds. The shipped config leaves 1000000004 wei of headroom, so only a hand-edit gets here | Regenerate `.env` with `make-env.mjs`; do not hand-edit the liquidity |
