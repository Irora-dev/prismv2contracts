#!/usr/bin/env node
/**
 * Collect pool fees on an interval so the uncollected backlog never becomes worth stealing.
 *
 *   node keeper.mjs --hook 0x… --rpc $RPC_URL --key $PK [--interval 12] [--once] [--dry-run]
 *
 *   --interval N     seconds between pokes (default 12, about one block)
 *   --once           poke a single time and exit, for a cron-driven setup
 *   --dry-run        report what a poke would do, sending nothing and needing no key
 *   --gas-limit N    override the gas limit; see the note on estimateGas below before using it
 *
 * WHY THIS EXISTS — it is a security control, not an optimisation.
 *
 * Every Uniswap v4 swap executes inside `PoolManager.unlock`, and `_maybePoke` deliberately returns
 * early while the manager is unlocked (collecting mid-swap is not safe). So a buy through the pool mints
 * the buyer's fee-shares WITHOUT first booking the fees the position has already earned, and the next
 * collection then splits that backlog pro rata with the newly minted shares. A buyer can therefore take
 * a slice of fees the pool earned before they held anything. Doing it inside one transaction is blocked
 * by the anti-JIT quarantine, but that quarantine lives in transient storage, so it spans exactly one
 * transaction and two transactions in one bundle defeat it. Measured in review: 50% of a standing pot.
 *
 * The prize is exactly the size of the uncollected backlog. `pokeFees()` is permissionless and costs
 * only gas, so collecting often keeps the backlog too small to cover the attacker's round-trip swap
 * cost (~2% of the float's value at a 1% pool fee). Run this from the moment the pool is live.
 *
 * It is deliberately dumb: no state, no retries that could pile up, tolerant of reverts. `pokeFees`
 * cannot brick — it early-returns when unseeded, when `totalShares == 0`, or while the PoolManager is
 * unlocked, and it wraps the POSM collect in try/catch — so a failed call is never a problem, it just
 * means there was nothing to do or the node hiccuped.
 */
import { Contract, JsonRpcProvider, Wallet, formatEther } from "ethers";

const ABI = [
  "function pokeFees() external",
  "event PokeCollectFailed()",
  "function seeded() view returns (bool)",
  "function totalShares() view returns (uint256)",
  "function accFeesPerShareETH() view returns (uint256)",
  "function accFeesPerSharePRISM() view returns (uint256)",
];

const arg = (name, fallback = undefined) => {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1) return fallback;
  const v = process.argv[i + 1];
  return v && !v.startsWith("--") ? v : true;
};

const hook     = arg("hook");
const rpc      = arg("rpc", process.env.RPC_URL);
const key      = arg("key", process.env.PRIVATE_KEY);
const interval = Number(arg("interval", 12));          // seconds; ~1 block by default
const gasArg   = arg("gas-limit");
const once     = !!arg("once");
const dryRun   = !!arg("dry-run");

if (!hook || !rpc || (!key && !dryRun)) {
  console.error("usage: node keeper.mjs --hook 0x… --rpc <url> --key <hex> [--interval 12] [--once] [--dry-run]");
  console.error("  --dry-run needs no key: it reports what a poke would do without sending one.");
  console.error("  optional: --interval <seconds> --once --gas-limit <n>");
  process.exit(1);
}

// `Number("12s")` is NaN, and `setInterval(fn, NaN * 1000)` fires every 0 ms — an unattended
// transaction-spam loop that would drain the keeper wallet. `--interval 12s` is a natural typo, and
// `--interval` as the final argument yields 1 (the flag consumes nothing), so validate explicitly.
if (!Number.isFinite(interval) || interval < 1) {
  console.error(`--interval must be a whole number of seconds (got ${JSON.stringify(arg("interval"))})`);
  process.exit(1);
}

const provider = new JsonRpcProvider(rpc);
const signer   = key && !dryRun ? new Wallet(key, provider) : null;
const prism    = new Contract(hook, ABI, signer ?? provider);

let pokes = 0, failures = 0, alarms = 0, spent = 0n;

async function tick() {
  try {
    // Cheap pre-checks so a pointless transaction is never sent. `pokeFees` would early-return in both
    // of these cases anyway, but paying gas to learn that is silly when a view call is free.
    if (!(await prism.seeded())) { console.log(`[${new Date().toISOString()}] not seeded yet — skipping`); return; }
    const shares = await prism.totalShares();
    if (shares === 0n) { console.log(`[${new Date().toISOString()}] totalShares == 0 — nothing to distribute to`); return; }

    const beforeEth = await prism.accFeesPerShareETH();
    const beforePrism = await prism.accFeesPerSharePRISM();

    if (dryRun) {
      await prism.pokeFees.staticCall();
      console.log(`[${new Date().toISOString()}] dry-run: poke would succeed (shares=${shares})`);
      return;
    }

    // DO NOT let ethers use `eth_estimateGas` here. `pokeFees` wraps the POSM collect in try/catch so a
    // POSM failure can never brick the token — which means "the collect ran out of gas and was
    // swallowed" is a SUCCESSFUL transaction. The estimator's binary search therefore converges on that
    // cheap failing path, and every poke goes out under-funded: measured 43,436 estimated against 89,159
    // actually needed, so the collect silently did nothing. `--dry-run` cannot catch it either, because
    // `staticCall` runs with full block gas and reports success.
    //
    // So: take the estimate as a floor, multiply it, and never go below an absolute floor. Overpaying
    // costs nothing — unused gas is refunded — while underpaying makes this whole keeper inert.
    const est = await prism.pokeFees.estimateGas();
    let gasLimit = est * 4n;
    if (gasLimit < 400_000n) gasLimit = 400_000n;
    if (gasArg !== undefined) gasLimit = BigInt(gasArg);

    const tx = await prism.pokeFees({ gasLimit });
    const rc = await tx.wait();
    const cost = rc.gasUsed * (rc.gasPrice ?? 0n);
    spent += cost;
    pokes++;

    const afterEth = await prism.accFeesPerShareETH();
    const afterPrism = await prism.accFeesPerSharePRISM();
    const moved = afterEth !== beforeEth || afterPrism !== beforePrism;

    // A poke that does not revert has NOT necessarily collected: the POSM call is wrapped in try/catch
    // so the token can never be bricked by a POSM-side failure. That is why the contract emits
    // PokeCollectFailed — without checking it, a failing collect looks exactly like "nothing accrued",
    // and the backlog this keeper exists to bound would compound invisibly.
    const failed = rc.logs.some((l) => {
      try { return prism.interface.parseLog(l)?.name === "PokeCollectFailed"; } catch { return false; }
    });
    if (failed) {
      alarms++;
      console.error(
        `[${new Date().toISOString()}] *** ALARM *** poke #${pokes} ${tx.hash}: the collect FAILED and was ` +
        `swallowed. Fees are safe in the position but are NOT being distributed, and the backlog is ` +
        `compounding. Investigate POSM before this becomes worth stealing. (${alarms} total)`
      );
    } else {
      console.log(
        `[${new Date().toISOString()}] poke #${pokes} ${tx.hash} gas=${rc.gasUsed}/${gasLimit} ` +
        `cost=${formatEther(cost)} ETH ${moved ? "collected fees" : "nothing to collect"}`
      );
    }
  } catch (e) {
    failures++;
    // Never exit on a failure. A revert here means "nothing to do" or a flaky node; either way the next
    // tick handles it, and a keeper that dies on the first hiccup is worse than no keeper at all.
    console.warn(`[${new Date().toISOString()}] poke failed (${failures} total): ${e.shortMessage ?? e.message}`);
  }
}

console.log(`keeper: hook=${hook} interval=${interval}s ${dryRun ? "(DRY RUN)" : ""}`);
await tick();
if (!once) {
  setInterval(tick, interval * 1000);
  process.on("SIGINT", () => {
    console.log(`\nstopping. ${pokes} pokes, ${failures} failures, ${alarms} collect-failure alarms, ${formatEther(spent)} ETH gas spent.`);
    process.exit(0);
  });
}
