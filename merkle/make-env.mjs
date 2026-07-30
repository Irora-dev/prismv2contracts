#!/usr/bin/env node
/**
 * Write a complete, ready-to-deploy `.env` for the shipped launch. One command, no decisions.
 *
 *   node merkle/make-env.mjs > .env          # run from the repo root
 *   node merkle/make-env.mjs --print         # show it without redirecting
 *
 * WHY THIS EXISTS.
 *
 * Every value in `.env` is either already decided, already committed, or mechanically derivable — so
 * asking an operator to assemble it by hand only creates opportunities to get it wrong, and the ways to
 * get it wrong are unrecoverable. What this removes:
 *
 *   - **The snapshot.** `airdrop/basis.json`, `claims.json` and `canary.json` are committed, so the root
 *     and total are facts in the repo rather than something to regenerate. Verify them with
 *     `verify-airdrop.mjs` if you want to; you do not need to rebuild them.
 *   - **The seed parameters.** The launch tick, price, liquidity and floors are fixed and fork-verified.
 *     Derived here with the same integer arithmetic `Deploy.s.sol` validates against.
 *   - **`SALT_NONCE`.** Generated fresh from a CSPRNG on every run. It must be unpredictable to a griefer
 *     *before* you broadcast — with a guessable nonce your CREATE2 address is derivable and can be
 *     squatted, which is a cheap repeatable denial of service. Note this is the one value that must stay
 *     secret: `.env` is gitignored, and it should stay that way.
 *
 * What it deliberately does NOT set: `RPC_URL` / `ETH_RPC_URL`. That is your own infrastructure and the
 * script has no business guessing it.
 *
 * `Deploy.s.sol` and `Preflight.s.sol` re-validate everything independently, so a mistake here still
 * cannot reach a broadcast.
 */
import { readFileSync } from "fs";
import { randomBytes } from "crypto";

const Q96 = 1n << 96n;
const SUPPLY = 5000n * 10n ** 18n;
const UNIT = 10n ** 18n;

// ── THE SHIPPED LAUNCH ────────────────────────────────────────────────────────────────────────────
// Tick 44800 ≈ a 56.68 ETH fully-diluted valuation, fork-verified end to end against real mainnet state.
// Changing this is changing the launch price; do that in DEPLOY.md §2 with a fresh dry run, not here.
const LAUNCH_TICK = 44800n;
const TICK_LOWER  = -887200n;   // full width: the position earns fees only in range and can never be
                                // rebalanced, so narrowing it would put an expiry date on fee income

// The same valuation again, stated by hand, as a second source of truth for the tick above.
// `Deploy.s.sol` refuses a price whose implied FDV is more than 25% from `TARGET_FDV_WEI`, so that the
// operator has to state the valuation they intend. That guard is worth nothing if we derive the target
// from the very price it checks: it collapses to `impliedFdv(p) == impliedFdv(p)` and cannot notice a
// mistyped tick. Nor does tick alignment notice one — 4800, 14800, 48400 and 84400 are all multiples of
// 200, and a dropped digit launches ~54x too cheap while every other guard stays green.
// So: a mistyped LAUNCH_TICK now disagrees with a number a human typed, and we refuse to emit at all.
// Change both together, deliberately, or not at all.
const LAUNCH_FDV_ETH = 56n;     // tick 44800 implies ~56.68 ETH; keep these two in step

/** Uniswap v4 `TickMath.getSqrtPriceAtTick`, integer-exact, rounding UP exactly as v4 does. */
function sqrtPriceAtTick(tick) {
  const abs = tick < 0n ? -tick : tick;
  if (abs > 887272n) throw new Error(`tick ${tick} out of range`);
  let r = (abs & 1n) !== 0n ? 0xfffcb933bd6fad37aa2d162d1a594001n : 1n << 128n;
  const C = [
    [0x2n, 0xfff97272373d413259a46990580e213an], [0x4n, 0xfff2e50f5f656932ef12357cf3c7fdccn],
    [0x8n, 0xffe5caca7e10e4e61c3624eaa0941cd0n], [0x10n, 0xffcb9843d60f6159c9db58835c926644n],
    [0x20n, 0xff973b41fa98c081472e6896dfb254c0n], [0x40n, 0xff2ea16466c96a3843ec78b326b52861n],
    [0x80n, 0xfe5dee046a99a2a811c461f1969c3053n], [0x100n, 0xfcbe86c7900a88aedcffc83b479aa3a4n],
    [0x200n, 0xf987a7253ac413176f2b074cf7815e54n], [0x400n, 0xf3392b0822b70005940c7a398e4b70f3n],
    [0x800n, 0xe7159475a2c29b7443b29c7fa6e889d9n], [0x1000n, 0xd097f3bdfd2022b8845ad8f792aa5825n],
    [0x2000n, 0xa9f746462d870fdf8a65dc1f90e061e5n], [0x4000n, 0x70d869a156d2a1b890bb3df62baf32f7n],
    [0x8000n, 0x31be135f97d08fd981231505542fcfa6n], [0x10000n, 0x9aa508b5b7a84e1c677de54f3e99bc9n],
    [0x20000n, 0x5d6af8dedb81196699c329225ee604n], [0x40000n, 0x2216e584f5fa1ea926041bedfe98n],
    [0x80000n, 0x48a170391f7dc42444e8fa2n],
  ];
  for (const [bit, mul] of C) if ((abs & bit) !== 0n) r = (r * mul) >> 128n;
  if (tick > 0n) r = ((1n << 256n) - 1n) / r;
  return (r >> 32n) + (r % (1n << 32n) === 0n ? 0n : 1n);
}

const root = new URL("../airdrop/", import.meta.url);
let canary;
try {
  canary = JSON.parse(readFileSync(new URL("canary.json", root), "utf8"));
} catch (e) {
  console.error(`could not read airdrop/canary.json: ${e.message}`);
  console.error("Run this from the repo root, or from merkle/ — the shipped airdrop data lives in ./airdrop.");
  process.exit(1);
}

// Headroom on the seed, in wei of PRISM. `seed()` deposits `L × (√Pu − √Pl) / 2^96` and POSM rounds that
// requirement UP, so sizing `L` to consume the float exactly makes POSM ask for every wei the hook holds —
// zero slack on a one-shot, unrecoverable operation. Worse, exceeding the balance by even one wei aborts
// with `TRANSFER_FROM_FAILED` raised inside Permit2, which says nothing about liquidity or balances.
//
// So leave a deliberate gap. 1e9 wei is 0.000000001 PRISM: invisible at any display precision, nine
// orders of magnitude more margin than the rounding needs, and it keeps "the whole supply is either
// distributed or working as liquidity" true to fifteen decimal places. Reducing `L` can only ever seed
// LESS, so this is strictly the safe direction — it cannot over-seed.
const SEED_HEADROOM_WEI = 1_000_000_000n;

const migrationAmount = BigInt(canary.total);
const sqrtP     = sqrtPriceAtTick(LAUNCH_TICK);
const fdvWei    = ((SUPPLY * Q96) / sqrtP) * Q96 / sqrtP;
const float_    = SUPPLY - migrationAmount;
const seedTarget = float_ - SEED_HEADROOM_WEI;
const liquidity = (seedTarget * Q96) / (sqrtP - sqrtPriceAtTick(TICK_LOWER));
const floor90   = (float_ * 90n) / 100n;

// `Deploy.s.sol` takes MIN_SEED_PRISM as an override that may only ever RAISE its internal bar — so do
// not emit that internal bar, `(float * 90) / 100`, as the value: it makes the knob
// inert and leaves the effective floor at 90% of the float. A mistakenly lowered SEED_LIQUIDITY could
// then strand up to 54.53 PRISM (1.1% of supply) in the hook, which is excluded from fee shares and,
// once ownership is renounced, has no path back out: `seed()` is the only mover and it is one-shot.
// Pin the bar to the seed we actually intend, less a microtoken of slack for POSM's ceiling rounding,
// so any meaningful under-seed reverts in simulation instead of deploying cleanly and losing the tokens.
const MIN_SEED_SLACK_WEI = 10n ** 12n;   // 0.000001 PRISM — 1000x the headroom, invisible when displayed

// What POSM will actually require, computed the same way it does (ceiling). Refuse to emit a config that
// cannot possibly work rather than letting the operator discover it as an opaque Permit2 revert.
//
// Compute the ceiling explicitly, and do NOT reach for `-((-x) / Q96)`: that is the ceiling-division
// trick for languages with FLOOR division, but BigInt truncates toward zero, so for a positive numerator
// the two negations cancel and it returns the floor — reading as a ceiling while behaving as one wei
// low. This number has to be exact: the header below tells the operator how many wei to expect left in
// the hook, and `LAUNCH.md` step 7 asks them to compare that very number by eye in the last read-only
// step before renouncing.
const ceilDiv = (n, d) => n / d + (n % d === 0n ? 0n : 1n);
const deposit = ceilDiv(liquidity * (sqrtP - sqrtPriceAtTick(TICK_LOWER)), Q96);
if (deposit > float_) {
  console.error(`internal error: computed deposit ${deposit} exceeds the float ${float_}`);
  process.exit(1);
}
if (deposit < floor90) {
  console.error(`internal error: computed deposit ${deposit} is below the 90% floor ${floor90}`);
  process.exit(1);
}

// 32 bytes of CSPRNG, reduced to fit uint256 comfortably. Unpredictable is the only requirement.
const saltNonce = BigInt("0x" + randomBytes(31).toString("hex"));

const fmt = (w) => `${w / UNIT}.${(w % UNIT).toString().padStart(18, "0")}`;

// Cross-check the tick against the hand-stated valuation. 5% is far tighter than the on-chain 25% band
// but still looser than the ~2% tick grid, so an intentional one-step move does not trip it while every
// digit-sized slip does. Fail before writing a .env: the operator cannot broadcast what we refuse to
// emit, which makes this the cheapest possible place to catch it.
const minSeed = deposit - MIN_SEED_SLACK_WEI;
if (minSeed < floor90) {
  console.error(`internal error: MIN_SEED_PRISM ${minSeed} would weaken the 90% floor ${floor90}`);
  process.exit(1);
}

const declaredFdvWei = LAUNCH_FDV_ETH * UNIT;
if (fdvWei * 100n < declaredFdvWei * 95n || fdvWei * 100n > declaredFdvWei * 105n) {
  console.error(
    `LAUNCH_TICK ${LAUNCH_TICK} implies an FDV of ${fmt(fdvWei)} ETH, but LAUNCH_FDV_ETH says ` +
    `${LAUNCH_FDV_ETH} ETH.\nOne of the two is wrong. Fix whichever you did not mean to change — ` +
    `and if you are moving the launch price on purpose, update BOTH.`,
  );
  process.exit(1);
}

const out = `# PRISM deploy configuration — generated by merkle/make-env.mjs
#
# Launch: tick ${LAUNCH_TICK}, a fully-diluted valuation of ~${fmt(fdvWei)} ETH.
# Airdrop: ${canary.count} holders, ${fmt(migrationAmount)} PRISM, root ${canary.root}
# Seed: ${fmt(deposit)} of the ${fmt(float_)} PRISM float.
# ${float_ - deposit} wei (${fmt(float_ - deposit)} PRISM) stays in the hook as deliberate rounding
# headroom — POSM rounds its requirement up, and consuming the float to the last wei would leave a
# one-shot mainnet operation with zero margin. It is invisible at any display precision.
#
# SALT_NONCE below was generated randomly and must stay SECRET until you have deployed: a predictable
# nonce lets a griefer squat your CREATE2 address and block the deploy. Never commit this file.
#
# Set RPC_URL and ETH_RPC_URL yourself — they are your own infrastructure, so export them in your shell:
#
#     export RPC_URL="https://…"
#     export ETH_RPC_URL="$RPC_URL"
#
# Two statements, not one: a shell expands a whole line before it assigns any of it, so setting both on a
# single export line gives ETH_RPC_URL whatever it held BEFORE — empty, or worse a stale endpoint that
# forks the wrong chain and still reports a result.
#
# They are deliberately NOT assigned in this file. An empty assignment here is not the same as leaving
# them alone: sourcing a .env OVERRIDES the current environment, so a blank would silently clear an
# endpoint you had already exported. Every step that needs one then fails with forge reading the empty
# string as a local socket path, which reads as a broken tool rather than a missing variable — and the
# step it takes out is the mainnet dry run, the last check before the irreversible broadcast.

MERKLE_ROOT=${canary.root}
MERKLE_TOTAL=${canary.total}
MIGRATION_AMOUNT=${canary.total}
CANARY_PATH=airdrop/canary.json

SEED_SQRT_PRICE_X96=${sqrtP}
SEED_TICK_LOWER=${TICK_LOWER}
SEED_TICK_UPPER=${LAUNCH_TICK}
SEED_LIQUIDITY=${liquidity}
TARGET_FDV_WEI=${fdvWei}
MIN_SEED_PRISM=${minSeed}

# Floor on the liquidity the pool must actually hold, re-checked by Renounce.s.sol ON-CHAIN before it
# gives up ownership. Every seed check in Deploy.s.sol runs in simulation only, and the documented
# recovery for a reverted step is to finish that step by hand — where a single dropped digit seeds a
# fraction of the float and cannot be retried, because seed() is one-shot. This is the check that
# survives that path. Set just under SEED_LIQUIDITY so rounding can never trip it.
MIN_SEED_LIQUIDITY=${(liquidity * 9999n) / 10000n}

SALT_NONCE=${saltNonce}
`;

process.stdout.write(out);

if (process.argv.includes("--print")) {
  process.stderr.write("\n# Nothing was written. Redirect to .env when you are ready:\n");
  process.stderr.write("#   node merkle/make-env.mjs > .env\n");
}
