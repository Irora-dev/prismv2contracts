#!/usr/bin/env node
/**
 * Turn a raw chain snapshot into the airdrop basis that `generate.mjs` consumes.
 *
 *   node merkle/prepare-basis.mjs <snapshot.json> [basis.json]
 *
 * A snapshot derived from chain state is a record of who HELD PRISM, which is not the same question as
 * who should RECEIVE it: it also names the burn sink and any Uniswap pool holding PRISM. `generate.mjs`
 * refuses to build a tree containing those (see forbidden.mjs), and that refusal is deliberate — but
 * the operator then has to remove the rows somehow, and hand-editing the input to an immutable airdrop
 * is exactly the step that should not be improvised.
 *
 * So this does it mechanically and prints a manifest of every row it dropped, with the amount, so the
 * drop is reviewable and the tree stays reproducible from the published snapshot alone.
 *
 * Anything not in the forbidden set is passed through untouched. This never re-weights, rounds, or
 * redistributes an allocation — dropped PRISM is simply not airdropped, and stays in the hook.
 */
import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { dirname } from "path";
import { getAddress } from "ethers";
import { FORBIDDEN } from "./forbidden.mjs";

const inPath = process.argv[2];
const outPath = process.argv[3] || "out/basis.json";
if (!inPath) {
  console.error("usage: node merkle/prepare-basis.mjs <snapshot.json> [basis.json]");
  process.exit(1);
}

const raw = JSON.parse(readFileSync(inPath, "utf8"));
const rows = Array.isArray(raw) ? raw : (raw.holders ?? raw.claims ?? raw.snapshot);
if (!Array.isArray(rows)) {
  console.error("snapshot must be an array (or {holders|claims|snapshot:[...]})");
  process.exit(1);
}

const addrOf = (r) => r.address ?? r.holder ?? r.account ?? r.wallet;
const amtOf  = (r) => r.amount ?? r.prismHeld ?? r.balance ?? r.value ?? r.allocation ?? r.effectivePrismWei;

const kept = [];
const dropped = [];
let keptTotal = 0n;
let droppedTotal = 0n;

for (const r of rows) {
  const a = addrOf(r), amt = amtOf(r);
  if (a == null || amt == null) { console.error("row missing address/amount:", JSON.stringify(r)); process.exit(1); }
  const addr = getAddress(String(a));
  if (/[.,]/.test(String(amt))) { console.error(`amount for ${addr} is not integer wei: ${amt}`); process.exit(1); }
  const amount = BigInt(amt);

  const why = FORBIDDEN.get(addr.toLowerCase());
  if (why) { dropped.push({ address: addr, amount: amount.toString(), reason: why }); droppedTotal += amount; continue; }
  kept.push({ address: addr, amount: amount.toString() });
  keptTotal += amount;
}

// Create the output directory rather than assuming it exists. The default output is `out/basis.json`
// and `out/` is gitignored, so on a fresh clone it does not exist — following the runbook literally
// failed here with a bare ENOENT on the very first command. `generate.mjs` already does this.
mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, JSON.stringify(kept, null, 2));

const prism = (w) => (Number(w / 10n ** 12n) / 1e6).toString();
console.log(`in  : ${rows.length} rows, ${prism(keptTotal + droppedTotal)} PRISM  (${inPath})`);
if (dropped.length === 0) {
  console.log("dropped: nothing — the snapshot named no infrastructure address.");
} else {
  console.log(`dropped: ${dropped.length} infrastructure row(s), ${prism(droppedTotal)} PRISM NOT airdropped:`);
  // Print wei as well as PRISM: a dust row is a real dropped allocation, and rounding it to "0 PRISM"
  // in the one manifest an operator reviews would hide it.
  for (const d of dropped) {
    console.log(`  ${d.address}  ${prism(BigInt(d.amount)).padStart(16)} PRISM  (${d.amount} wei)  ${d.reason}`);
  }
}
console.log(`out : ${kept.length} rows, ${prism(keptTotal)} PRISM  -> ${outPath}`);
console.log(`      MERKLE_TOTAL / MIGRATION_AMOUNT basis (wei): ${keptTotal}`);
console.log(`\nnext: node merkle/generate.mjs ${outPath}`);
