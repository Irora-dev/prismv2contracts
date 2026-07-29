#!/usr/bin/env node
/**
 * Push the PRISM v2 airdrop out to every holder, so nobody has to claim.
 *
 *   node push-airdrop.mjs --batcher 0x… --rpc $RPC_URL --key $PK
 *   node push-airdrop.mjs --batcher 0x… --dry-run          # plan only, sends nothing
 *
 * Safe to interrupt and re-run: the vault records who has been paid, the batcher skips them, and
 * this script re-reads that state on every run. Nothing is double-sent and nothing is lost.
 *
 * Why it chunks the way it does: cost per holder varies ~150x, because the fee-share mirror mints
 * one NFT per whole PRISM (~37k gas each). A dust holder costs ~61k; a 256-token holder ~9.3M. So
 * chunks are packed by *estimated gas*, not by a fixed row count, and an unusually large holder
 * gets a transaction to itself.
 *
 * Flags:
 *   --batcher <addr>   PrismAirdropBatcher address                                    (required)
 *   --claims <path>    per-holder proofs      (default ../airdrop/claims.json, the shipped set)
 *   --rpc <url>        RPC endpoint                                       (default $RPC_URL)
 *   --key <hex>        signer private key                                 (default $PRIVATE_KEY)
 *   --chunk-gas <n>    gas to target per transaction                            (default 12000000)
 *   --min-prism <n>    skip holders below this allocation, e.g. 1 to skip dust      (default 0)
 *   --dry-run          print the plan and cost estimate, send nothing
 *   --yes              skip the confirmation prompt
 */
import { readFileSync } from "fs";
import { Contract, JsonRpcProvider, Wallet, formatEther, formatUnits } from "ethers";

// ── the gas model ────────────────────────────────────────────────────────────────────────────────
// Calibrated on a mainnet fork WITH pool fees accrued, which is the only state that matters: every
// mint writes two virgin `_setFeeDebt` slots, and those cost 20,000 gas each rather than 100 once any
// fee has ever been collected. An earlier calibration was taken on a pool that had never swapped, so
// it read ~37,000/NFT and understated the real cost by 2.05x — which under-sized every chunk.
// 63,278 measured on a fork with both accumulators hot, plus ~4% margin. The 61,297 that stood here was
// taken on a colder path and ran ~3.2% light — small per row, but a 177-row dust chunk is then ~350k short,
// the batcher stops before starting a row it cannot finish, and the chunk delivers 169 of 177. Nothing is
// lost (the runner reports the shortfall and a re-run converges) but the documented single pass did not
// finish, so the estimate must be conservative rather than central.
const GAS_BASE = 66_000;        // a claim that mints no NFT (holder owns < 1 whole PRISM)
const GAS_PER_NFT = 78_000;     // each whole PRISM mints one fee-share NFT (measured ~76,300)
const GAS_POKE = 70_000;        // _maybePoke() fires a POSM collect on any claim that mints
const MAX_REALIGN = 128n;       // the hook mints at most this many NFTs per transfer
const GAS_CALLDATA_BASE = 200;
const GAS_CALLDATA_PER_PROOF = 32 * 16; // 32-byte proof element at 16 gas/byte
const UNIT = 10n ** 18n;

// EIP-7825: a single transaction may not be given more than 2^24 gas, regardless of the block gas
// limit. Asking for more is not merely wasteful — the node rejects the transaction outright.
const TX_GAS_CAP = 16_777_216;
const GAS_TX_OVERHEAD = 21_000;

const ABI = [
  "function push(address[] accounts, uint256[] amounts, bytes32[][] proofs, uint256 from, uint256 gasFloor) returns (uint256 delivered, uint256 alreadyClaimed, uint256 failed, uint256 stoppedAt)",
  "function pendingOf(address[] accounts) view returns (bool[])",
  "function migration() view returns (address)",
  "event Pushed(uint256 delivered, uint256 alreadyClaimed, uint256 failed, uint256 stoppedAt)",
  "event RowFailed(uint256 index, address account)",
];

const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
};
const flag = (name) => process.argv.includes(`--${name}`);

const batcherAddr = arg("batcher");
const claimsPath = arg("claims", "../airdrop/claims.json");
const rpcUrl = arg("rpc", process.env.RPC_URL || process.env.ETH_RPC_URL);
const pk = arg("key", process.env.PRIVATE_KEY);
const chunkGas = Number(arg("chunk-gas", "12000000"));
const minPrism = Number(arg("min-prism", "0"));
const dryRun = flag("dry-run");

if (!batcherAddr) {
  console.error("--batcher <address> is required (deploy it with script/DeployBatcher.s.sol)");
  process.exit(1);
}
if (!rpcUrl) {
  console.error("no RPC: pass --rpc or set RPC_URL");
  process.exit(1);
}

/** Gas a single row will cost, from the measured model. */
const rowGas = (amountWei, proofDepth = 14) => {
  const whole = amountWei / UNIT;
  const nfts = whole > MAX_REALIGN ? MAX_REALIGN : whole;
  const n = Number(nfts);
  return GAS_BASE
    + n * GAS_PER_NFT
    + (n > 0 ? GAS_POKE : 0)
    + GAS_CALLDATA_BASE + proofDepth * GAS_CALLDATA_PER_PROOF;
};

const { claims, merkleRoot, count } = JSON.parse(readFileSync(claimsPath, "utf8"));
const allRows = Object.entries(claims).map(([address, c]) => ({
  address,
  amount: BigInt(c.amount),
  proof: c.proof,
}));
let rows = allRows;
console.log(`claims file      : ${claimsPath}`);
console.log(`merkle root      : ${merkleRoot}`);
console.log(`holders in tree  : ${count}`);

if (minPrism > 0) {
  const threshold = BigInt(Math.floor(minPrism * 1e18));
  const before = rows.length;
  rows = rows.filter((r) => r.amount >= threshold);
  console.log(`--min-prism ${minPrism}   : skipping ${before - rows.length} holders below it, ${rows.length} remain`);
}

const provider = new JsonRpcProvider(rpcUrl);
const signer = pk ? new Wallet(pk, provider) : null;
const batcher = new Contract(batcherAddr, ABI, signer ?? provider);

console.log(`batcher          : ${batcherAddr}`);
console.log(`vault            : ${await batcher.migration()}`);

// ── skip anyone already paid (idempotent restart) ───────────────────────────────────────────────
process.stdout.write("checking who still needs paying… ");
const pending = [];
for (let i = 0; i < rows.length; i += 500) {
  const slice = rows.slice(i, i + 500);
  const flags = await batcher.pendingOf(slice.map((r) => r.address));
  slice.forEach((r, j) => flags[j] && pending.push(r));
}
console.log(`${pending.length} of ${rows.length} outstanding`);
if (pending.length === 0) {
  console.log("\nnothing to do — every holder in this list has already been paid.");
  process.exit(0);
}

// ── pack chunks by estimated gas, respecting the per-transaction gas cap ────────────────────────
// The transaction's gas limit and the contract's `gasFloor` are independent budgets. `gasFloor` only
// has to cover the NEXT row; the limit has to cover the whole chunk plus one row's headroom so the
// last row is never entered under-funded. Deriving the limit from the floor (as this script used to)
// inflated it far past 2^24 for any chunk containing a large holder, and the node then rejected the
// transaction outright.
const rowsPerChunkCap = (r) => rowGas(r.amount, r.proof.length);
const worstRow = (rs) => Math.max(...rs.map(rowsPerChunkCap));

// Never plan a chunk whose worst row cannot itself fit in one transaction — that row is undeliverable
// and must be surfaced, not silently retried forever.
const undeliverable = pending.filter(
  (r) => rowsPerChunkCap(r) + GAS_TX_OVERHEAD > TX_GAS_CAP,
);
if (undeliverable.length) {
  console.error(`\nFATAL: ${undeliverable.length} holder(s) need more than the ${TX_GAS_CAP.toLocaleString()} gas`);
  console.error("a single transaction may be given (EIP-7825), so they cannot be delivered at all:");
  for (const r of undeliverable) {
    console.error(`  ${r.address}  ${formatEther(r.amount)} PRISM  needs ~${rowsPerChunkCap(r).toLocaleString()} gas`);
  }
  console.error("This means the token's MAX_REALIGN is set too high for its mint cost. Do not proceed.");
  process.exit(1);
}

// Effective ceiling for one transaction's worth of rows.
const budget = Math.min(chunkGas, TX_GAS_CAP - GAS_TX_OVERHEAD);
const chunks = [];
let cur = [];
let curGas = 0;
const flush = () => {
  if (!cur.length) return;
  const floor = Math.max(300_000, worstRow(cur));
  // limit = the work + headroom for the final row + a margin for the loop/event overhead + the
  // transaction's own intrinsic charge. That last term was missing: 21,000 plus the calldata cost is
  // deducted from the limit BEFORE execution begins, so a limit sized only to the work leaves the
  // batcher that much short and it stops before starting a row it cannot finish. `rowGas` already
  // carries a calldata estimate, so only the flat overhead needs adding here.
  const limit = Math.min(TX_GAS_CAP, curGas + floor + 100_000 + GAS_TX_OVERHEAD);
  chunks.push({ rows: cur, gas: curGas, gasFloor: floor, gasLimit: limit });
  cur = [];
  curGas = 0;
};
for (const r of pending) {
  const g = rowsPerChunkCap(r);
  // A chunk must fit its own rows AND leave one worst-row of headroom under the cap.
  if (cur.length && curGas + g + Math.max(worstRow(cur), g) + 100_000 > budget) flush();
  cur.push(r);
  curGas += g;
}
flush();

// Prove every planned chunk can actually finish, rather than trusting the constants above.
//
// The subtlety that has bitten this planner twice: `rowGas` folds a MODELLED calldata charge into the
// per-row figure, but on chain calldata is intrinsic — it is deducted from the gas limit before execution
// begins, not spent during it. So a chunk's real budget is `gasLimit - 21000 - 16·calldataBytes`, and what
// it must cover is only the EXECUTION half of `rowGas`. Getting that accounting wrong in either direction
// produces a plan that looks fine and stops short, which leaves holders unpaid until someone re-runs.
//
// Check it per chunk with the real encoded size, and refuse to send a plan that cannot complete. This
// turns "I verified the margin once by hand" into an invariant the runner enforces every time — including
// after someone edits a gas constant, which is exactly when it would otherwise quietly regress.
const CALLDATA_GAS_PER_BYTE = 16;
const intrinsicOf = (rows) =>
  GAS_TX_OVERHEAD +
  CALLDATA_GAS_PER_BYTE *
    (4 + rows.reduce((s, r) => s + 32 * 4 + r.proof.length * 32, 0));
const executionOf = (rows) =>
  rows.reduce((s, r) => s + (rowGas(r, r.proof.length) - GAS_CALLDATA_BASE - r.proof.length * GAS_CALLDATA_PER_PROOF), 0);

const unfinishable = chunks
  .map((c, i) => ({ i, need: executionOf(c.rows), avail: c.gasLimit - intrinsicOf(c.rows), rows: c.rows.length }))
  .filter((x) => x.avail < x.need);

if (unfinishable.length) {
  console.error(`\n${unfinishable.length} planned chunk(s) cannot finish within their own gas limit:`);
  for (const u of unfinishable.slice(0, 5)) {
    console.error(`  tx ${u.i + 1}: ${u.rows} rows need ${u.need} execution gas, only ${u.avail} available` +
                  ` (short by ${u.need - u.avail})`);
  }
  console.error("\nLower --chunk-gas so chunks hold fewer rows, and re-run. Sending as planned would stop");
  console.error("part-way through those transactions and leave holders unpaid until a further re-run.");
  process.exit(1);
}

const totalGas = chunks.reduce((a, c) => a + c.gas, 0);
const totalPrism = pending.reduce((a, r) => a + r.amount, 0n);
const fee = await provider.getFeeData();
const gasPrice = fee.maxFeePerGas ?? fee.gasPrice ?? 0n;

console.log(`\nplan: ${pending.length} holders, ${formatEther(totalPrism)} PRISM, ${chunks.length} transaction(s)`);
console.log(`  estimated gas  : ${totalGas.toLocaleString()}`);
console.log(`  gas price now  : ${formatUnits(gasPrice, "gwei")} gwei`);
console.log(`  estimated cost : ${formatEther(BigInt(totalGas) * gasPrice)} ETH`);
chunks.forEach((c, i) =>
  console.log(
    `  tx ${String(i + 1).padStart(3)}: ${String(c.rows.length).padStart(4)} holders, ` +
    `~${c.gas.toLocaleString()} gas (limit ${c.gasLimit.toLocaleString()}, floor ${c.gasFloor.toLocaleString()})`,
  ),
);
if (chunks.some((c) => c.gasLimit > TX_GAS_CAP)) {
  console.error("\nINTERNAL: a chunk exceeded the per-tx gas cap after planning — refusing to send.");
  process.exit(1);
}

if (dryRun) {
  console.log("\n--dry-run: nothing sent.");
  process.exit(0);
}
if (!signer) {
  console.error("\nno signer: pass --key or set PRIVATE_KEY (or use --dry-run)");
  process.exit(1);
}
if (!flag("yes")) {
  console.log(`\nSending from ${await signer.getAddress()}. Ctrl-C within 10s to abort…`);
  await new Promise((r) => setTimeout(r, 10_000));
}

// ── send ────────────────────────────────────────────────────────────────────────────────────────
let delivered = 0;
let failedRows = 0;
let spent = 0n;
let chunkErrors = 0;
for (const [i, c] of chunks.entries()) {
  const label = `tx ${i + 1}/${chunks.length} (${c.rows.length} holders)`;
  try {
    const tx = await batcher.push(
      c.rows.map((r) => r.address),
      c.rows.map((r) => r.amount),
      c.rows.map((r) => r.proof),
      0,
      c.gasFloor,
      { gasLimit: BigInt(c.gasLimit) },
    );
    process.stdout.write(`${label} → ${tx.hash} `);
    const rc = await tx.wait();
    spent += rc.gasUsed * (rc.gasPrice ?? gasPrice);

    // Read what actually happened rather than assuming the chunk completed. A state-changing call
    // gives a receipt, not return data, so the contract reports through the `Pushed` event.
    let d = null;
    for (const log of rc.logs) {
      try {
        const p = batcher.interface.parseLog(log);
        if (p?.name === "Pushed") d = p.args;
        if (p?.name === "RowFailed") {
          console.log(`\n    row ${p.args[0]} failed: ${p.args[1]}`);
        }
      } catch { /* not one of ours */ }
    }
    if (d) {
      delivered += Number(d[0]);
      failedRows += Number(d[2]);
      const short = Number(d[3]) < c.rows.length;
      console.log(
        `${d[2] > 0n || short ? "!" : "✓"} gas ${rc.gasUsed.toLocaleString()} — ` +
        `delivered ${d[0]}, already ${d[1]}, failed ${d[2]}, stopped at ${d[3]}/${c.rows.length}`,
      );
    } else {
      // No event decoded: report the receipt and let the closing verification be the arbiter.
      console.log(`? gas ${rc.gasUsed.toLocaleString()} (no Pushed event decoded)`);
    }
  } catch (e) {
    // One bad chunk must not abandon the chunks behind it — that turned a single oversized holder
    // into a permanent, unrecoverable stall of the whole airdrop.
    chunkErrors++;
    console.log(`\n${label} FAILED: ${e.shortMessage ?? e.message}`);
    console.log("  continuing with the remaining chunks; re-run afterwards to retry this one.");
  }
}

// ── verify on-chain, don't just trust the receipts ──────────────────────────────────────────────
// Checked against the FULL tree, not the --min-prism subset, so "all confirmed paid" can never mean
// "all of the ones I chose to look at".
process.stdout.write("\nverifying against the full holder list… ");
const stillPendingRows = [];
for (let i = 0; i < allRows.length; i += 500) {
  const slice = allRows.slice(i, i + 500);
  const flags = await batcher.pendingOf(slice.map((r) => r.address));
  slice.forEach((r, j) => flags[j] && stillPendingRows.push(r));
}
const stillPending = stillPendingRows.length;
const excluded = allRows.length - rows.length;
console.log(
  stillPending === 0
    ? `all ${allRows.length} confirmed paid.`
    : `${stillPending} of ${allRows.length} still unpaid`,
);
if (excluded > 0) {
  const excludedUnpaid = stillPendingRows.filter((r) => !rows.includes(r)).length;
  console.log(`  (${excluded} holder(s) were excluded by --min-prism; ${excludedUnpaid} of them are unpaid by design)`);
}
console.log(`\ndone: ${delivered} delivered across ${chunks.length} transaction(s), ${formatEther(spent)} ETH of gas.`);
if (failedRows > 0) console.log(`${failedRows} row(s) were attempted and did not deliver.`);
if (chunkErrors > 0) console.log(`${chunkErrors} chunk(s) never landed.`);

if (stillPending > 0) {
  // Distinguish "retry will help" from "retrying forever will not". A row that is unpaid but was
  // never attempted-and-failed is usually a proof that does not verify against the deployed root —
  // no number of re-runs fixes that, and the old script's advice to just re-run looped indefinitely.
  // Only a DELIVERY counts as progress. Failures do not: a row that reverts deterministically (a
  // proof that does not verify against the deployed root) fails identically on every attempt, so
  // treating a failure as progress is what turned "re-run to finish" into an infinite loop.
  if (delivered > 0) {
    console.log("Re-run this command to finish them — already-paid holders are skipped automatically.");
  } else {
    console.log("NOTHING was delivered this run, so re-running will repeat the same result.");
    console.log("Check that claims.json was generated from the SAME snapshot as the deployed");
    console.log(`merkle root, and that the vault holds enough reserve. Root in this file: ${merkleRoot}`);
  }
  process.exit(1);
}
