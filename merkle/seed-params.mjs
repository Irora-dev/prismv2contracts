#!/usr/bin/env node
/**
 * Derive the pool-seed half of `.env` from the two numbers a human actually decides.
 *
 *   node seed-params.mjs --fdv-eth 56.68 --reserve 4454677055887032075331
 *   node seed-params.mjs --tick 44800   --reserve 4454677055887032075331
 *   node seed-params.mjs --fdv-eth 116.44 --reserve 0            # fair launch, no airdrop
 *
 * WHY THIS EXISTS. `SEED_LIQUIDITY` and `MIN_SEED_PRISM` were the last two values an operator had to
 * compute by hand, and they are the most dangerous ones to get wrong:
 *
 *   - PRISM per unit of liquidity depends ENTIRELY on the tick — ~46 at tick 76600 but 2.23 at 16000.
 *     DEPLOY.md warns that sizing from the wrong figure under-seeds by up to 20x, and an undersized seed
 *     deploys perfectly cleanly and then bricks the fee layer forever: below one whole PRISM of float,
 *     `totalShares` can never leave zero, so every fee the pool ever earns is unclaimable.
 *   - `MIN_SEED_PRISM` may only ever RAISE the bar. A value below the 90%-of-float floor is silently
 *     discarded by the guard it appears to set, so an operator can believe they tightened a check they
 *     did not. This prints exactly the floor.
 *
 * Integer arithmetic throughout, matching `Deploy.s.sol` and Uniswap's `TickMath` bit for bit. NEVER
 * compute `sqrtPriceX96` with floating point: v4's `TickMath` rounds the square root UP, so a
 * `floor(sqrt(1.0001^t) * 2^96)` formula lands one wei low and `seed()` reverts `MaximumAmountExceeded`.
 *
 * This only derives the numbers. `Deploy.s.sol` validates them independently on the way in, and
 * `script/Preflight.s.sol` re-checks the whole config — so a mistake here still cannot reach a broadcast.
 */

const Q96 = 1n << 96n;
const SUPPLY = 5000n * 10n ** 18n;
const UNIT = 10n ** 18n;
const TICK_SPACING = 200n;
const MIN_TICK = -887200n;          // the lowest tick usable at spacing 200
const MAX_TICK = 887200n;

/** Uniswap v4 `TickMath.getSqrtPriceAtTick`, integer-exact, rounding UP as v4 does. */
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
  return (r >> 32n) + (r % (1n << 32n) === 0n ? 0n : 1n);   // round UP, exactly as v4 does
}

/** `Deploy.s.sol`'s own implied-FDV expression, step for step, so the two cannot disagree. */
function impliedFdvWei(sqrtP) {
  return ((SUPPLY * Q96) / sqrtP) * Q96 / sqrtP;
}

/** PRISM consumed by `L` over [tickLower, tickUpper] when the price opens AT tickUpper (single-sided).
 *  Rounds UP, because that is what v4's SqrtPriceMath does when charging for a mint — a floor here reports
 *  one wei less than the chain will actually take, and every figure derived from it inherits the error. */
function prismForLiquidity(L, tickLower, tickUpper) {
  const n = L * (sqrtPriceAtTick(tickUpper) - sqrtPriceAtTick(tickLower));
  return n / Q96 + (n % Q96 === 0n ? 0n : 1n);
}

/** The inverse: liquidity needed to deposit exactly `prism`. */
function liquidityForPrism(prism, tickLower, tickUpper) {
  return (prism * Q96) / (sqrtPriceAtTick(tickUpper) - sqrtPriceAtTick(tickLower));
}

/** Aligned tick whose implied FDV is closest to the target. Integer search — no logarithms, no floats. */
function tickForFdv(targetWei) {
  let best = null;
  for (let t = MIN_TICK; t <= MAX_TICK; t += TICK_SPACING) {
    const fdv = impliedFdvWei(sqrtPriceAtTick(t));
    const err = fdv > targetWei ? fdv - targetWei : targetWei - fdv;
    if (best === null || err < best.err) best = { tick: t, fdv, err };
  }
  return best;
}

const arg = (name) => {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? undefined : process.argv[i + 1];
};

const fdvEth  = arg("fdv-eth");
const tickArg = arg("tick");
const reserve = arg("reserve");
const lowerArg = arg("tick-lower");
const seedArg  = arg("seed-prism");

if ((!fdvEth && !tickArg) || reserve === undefined) {
  console.error("usage: node seed-params.mjs (--fdv-eth <n> | --tick <n>) --reserve <wei> [--tick-lower <n>]");
  console.error("  --fdv-eth   the fully-diluted valuation you intend, in ETH (e.g. 56.68)");
  console.error("  --tick      or name SEED_TICK_UPPER directly");
  console.error("  --reserve   MIGRATION_AMOUNT in wei (0 for a fair launch with no airdrop)");
  console.error("  --tick-lower   defaults to -887200 (full width; see DEPLOY.md before changing)");
  console.error("  --seed-prism   wei of PRISM to seed; defaults to the whole float. Pass this when you");
  console.error("                 intend to strand a specific amount in the hook (e.g. keeping a prior");
  console.error("                 burn burnt) — whatever you do not seed is unrecoverable.");
  process.exit(1);
}

const migrationAmount = BigInt(reserve);
if (migrationAmount > SUPPLY) { console.error("reserve exceeds the 5000 PRISM supply"); process.exit(1); }

const tickLower = lowerArg !== undefined ? BigInt(lowerArg) : MIN_TICK;
if (tickLower % TICK_SPACING !== 0n) { console.error("tick-lower must be a multiple of 200"); process.exit(1); }

// `--fdv-eth` and `--tick` are two ways of saying the same thing, so when both are given they are two
// independent statements of the launch price and must agree. That agreement is the only thing that can
// catch a mistyped tick: `TARGET_FDV_WEI` below is computed FROM the tick, so on its own the deploy's
// ±25% FDV band compares the price against itself and passes for every tick, right or wrong. Tick
// alignment catches nothing either — 4800, 14800, 48400 and 84400 are all multiples of 200, and a
// dropped digit launches ~54x too cheap.
let declaredWei;
if (fdvEth !== undefined) {
  const [w, f = ""] = String(fdvEth).split(".");
  declaredWei = BigInt(w) * UNIT + BigInt((f + "000000000000000000").slice(0, 18));
}

let tickUpper;
if (tickArg !== undefined) {
  tickUpper = BigInt(tickArg);
  if (tickUpper % TICK_SPACING !== 0n) { console.error("tick must be a multiple of 200"); process.exit(1); }
  if (declaredWei !== undefined) {
    const implied = impliedFdvWei(sqrtPriceAtTick(tickUpper));
    if (implied * 100n < declaredWei * 95n || implied * 100n > declaredWei * 105n) {
      console.error(
        `--tick ${tickUpper} implies an FDV of ${implied} wei, but --fdv-eth says ${declaredWei} wei.\n` +
        `They disagree by more than 5%. Drop one of the two and let this script derive it.`,
      );
      process.exit(1);
    }
  }
} else {
  // Parse the ETH figure as a decimal string to avoid a float ever touching the arithmetic.
  const [whole, frac = ""] = String(fdvEth).split(".");
  const targetWei = BigInt(whole) * UNIT + BigInt((frac + "000000000000000000").slice(0, 18));
  tickUpper = tickForFdv(targetWei).tick;
}
if (tickLower >= tickUpper) { console.error("tick-lower must be below the launch tick"); process.exit(1); }

const sqrtP = sqrtPriceAtTick(tickUpper);
const fdvWei = impliedFdvWei(sqrtP);
const float_ = SUPPLY - migrationAmount;

// Seed the whole float less a wei of headroom, unless told otherwise. POSM rounds the deposit it requires
// UP, so targeting the float exactly makes it ask for every wei the hook holds — zero slack on a one-shot
// operation, and one wei over aborts with `TRANSFER_FROM_FAILED` from inside Permit2, which names nothing
// useful. 1e9 wei is 0.000000001 PRISM: invisible at any display precision, and reducing the target can
// only ever seed LESS, so it is strictly the safe direction.
const SEED_HEADROOM_WEI = 1_000_000_000n;
const seedTarget = seedArg !== undefined ? BigInt(seedArg) : float_ - SEED_HEADROOM_WEI;
if (seedTarget > float_) {
  console.error(`--seed-prism ${seedTarget} exceeds the ${float_} wei float left after the reserve`);
  process.exit(1);
}
const liquidity = liquidityForPrism(seedTarget, tickLower, tickUpper);
const prismUsed = prismForLiquidity(liquidity, tickLower, tickUpper);
const floor90 = (float_ * 90n) / 100n;

// `MIN_SEED_PRISM` is an upward-only override, so emitting the 90%-of-float floor it already applies
// internally leaves the knob inert: the effective bar stays 90%, and a seed 10% short deploys cleanly
// while stranding that PRISM in a hook that earns no fee shares and, once renounced, cannot release it.
// Emit the deposit this liquidity actually makes instead, less a microtoken for POSM's ceiling rounding.
const MIN_SEED_SLACK_WEI = 10n ** 12n;
const minSeed = prismUsed > floor90 + MIN_SEED_SLACK_WEI ? prismUsed - MIN_SEED_SLACK_WEI : floor90;

const fmt = (w) => `${w / UNIT}.${(w % UNIT).toString().padStart(18, "0")}`;

console.log(`# derived for a launch valuation of ~${fmt(fdvWei)} ETH at tick ${tickUpper}`);
console.log(`# PRISM per 1e18 of liquidity at this tick: ${fmt(prismForLiquidity(UNIT, tickLower, tickUpper))}`);
console.log(`MIGRATION_AMOUNT=${migrationAmount}`);
console.log(`SEED_SQRT_PRICE_X96=${sqrtP}`);
console.log(`SEED_TICK_LOWER=${tickLower}`);
console.log(`SEED_TICK_UPPER=${tickUpper}`);
console.log(`SEED_LIQUIDITY=${liquidity}`);
console.log(`TARGET_FDV_WEI=${fdvWei}`);
console.log(`MIN_SEED_PRISM=${minSeed}`);
// `Renounce.s.sol` re-checks this ON-CHAIN before giving up ownership, and it is the only seed check that
// survives a hand-run `seed()` — every guard in `Deploy.s.sol` runs in simulation. Emit it here too, or an
// operator who reached for this script instead of `make-env.mjs` silently loses that protection.
console.log(`MIN_SEED_LIQUIDITY=${(liquidity * 9999n) / 10000n}`);
console.log();
console.log(`# float available to seed : ${fmt(float_)} PRISM`);
console.log(`# this liquidity deposits : ${fmt(prismUsed)} PRISM`);
console.log(`# stranded in the hook    : ${fmt(float_ - prismUsed)} PRISM  (unrecoverable, by design)`);
console.log(`# 90%-of-float floor      : ${fmt(floor90)} PRISM  <- MIN_SEED_PRISM cannot go below this`);

// Guards mirroring the ones `Deploy.s.sol` will apply, so a bad answer is caught here rather than later.
const problems = [];
if (prismUsed < floor90)       problems.push("the seed is below 90% of the float — Deploy.s.sol will reject it");
if (prismUsed < 50n * UNIT)    problems.push("the seed is under 50 PRISM — too small for whole-token buys, the fee layer would never start");
if (fdvWei < UNIT / 1000n)     problems.push("the implied FDV is essentially zero — this price sells the supply for nothing");

// A caveat is not a problem: this configuration is valid, it just carries a weaker guarantee than the
// same numbers reached via --fdv-eth. Say so plainly, but do not fail a documented mode over it.
const caveats = [];
if (tickArg !== undefined && declaredWei === undefined) {
  caveats.push(
    "TARGET_FDV_WEI above was DERIVED from --tick, so it cannot vouch for it: the deploy's FDV band " +
    "would be checking the price against itself. Add --fdv-eth <n> to have the two cross-checked, or " +
    "satisfy yourself by hand that " + fmt(fdvWei) + " ETH is the valuation you mean.",
  );
}
if (tickUpper === MAX_TICK)    problems.push("tick 887200 sells the entire supply for about one gwei");
if (caveats.length) {
  console.log();
  for (const c of caveats) console.log(`# NOTE: ${c}`);
}
if (problems.length) {
  console.log();
  for (const p of problems) console.log(`# !! ${p}`);
  process.exitCode = 1;
} else {
  console.log();
  console.log("# Sanity checks passed. Paste these into .env, then run:  forge script script/Preflight.s.sol");
  console.log("# Preflight re-validates everything independently — do not skip it.");
}
