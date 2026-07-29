#!/usr/bin/env node
/**
 * Build the airdrop Merkle tree from a holder snapshot.
 *
 *   node merkle/generate.mjs <snapshot.json> [outDir]
 *
 * The leaf format — keccak256(bytes.concat(keccak256(abi.encode(address, uint256)))) with
 * sorted-pair internal hashing — is EXACTLY what `PrismMigration.claim` verifies (OpenZeppelin
 * StandardMerkleTree). So the root printed here goes straight into MERKLE_ROOT for the deploy,
 * and the per-account proofs feed a claim UI/CLI.
 *
 * Snapshot input: a JSON array of holders. Each entry needs an address and an amount (in wei):
 *   [{ "address": "0x…", "amount": "1000000000000000000" }, …]
 * Common alternative field names are accepted (holder/account, prismHeld/balance/value).
 *
 * IMPORTANT: set MIGRATION_AMOUNT (the deploy's airdrop reserve) to EXACTLY `totalAmount` printed
 * below. The deploy requires equality: a larger reserve mints PRISM into a vault no proof can reach,
 * and a smaller one leaves late claimers hitting TransferFailed. Address dedup is enforced.
 */
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { getAddress } from "ethers";
import { FORBIDDEN, GRANDFATHERED } from "./forbidden.mjs";

const inPath = process.argv[2];
const outDir = process.argv[3] || "out";
if (!inPath) { console.error("usage: node merkle/generate.mjs <snapshot.json> [outDir]"); process.exit(1); }

const raw = JSON.parse(readFileSync(inPath, "utf8"));
const rows = Array.isArray(raw) ? raw : (raw.holders ?? raw.claims ?? raw.snapshot);
if (!Array.isArray(rows)) { console.error("snapshot must be an array (or {holders|claims|snapshot:[...]})"); process.exit(1); }

const addrOf = (r) => r.address ?? r.holder ?? r.account ?? r.wallet;
// `effectivePrismWei` is the published snapshot's wei field. Its sibling `effectivePrism` is a DECIMAL
// string of the same number and is deliberately not accepted: reading "287.239…" as an amount would
// either throw deep inside BigInt or, worse, silently truncate an allocation.
const amtOf  = (r) => r.amount ?? r.prismHeld ?? r.balance ?? r.value ?? r.allocation ?? r.effectivePrismWei;

// A snapshot containing infrastructure is a snapshot bug, and failing loudly is the right response —
// run `prepare-basis.mjs` first if you are starting from a raw chain snapshot.
const seen = new Set();
const values = [];
let total = 0n;
for (const r of rows) {
  const a = addrOf(r), amt = amtOf(r);
  if (a == null || amt == null) { console.error("row missing address/amount:", JSON.stringify(r)); process.exit(1); }
  const addr = getAddress(String(a)); // checksums + validates
  const forbidden = FORBIDDEN.get(addr.toLowerCase());
  const gf = GRANDFATHERED.get(addr.toLowerCase());
  // The exception is only valid for the EXACT amount it was granted for — see forbidden.mjs. At any other
  // amount this is just a forbidden address again, and must be refused.
  const grandfathered = gf && BigInt(amt) === gf.amount ? gf.why : undefined;
  if (forbidden && !grandfathered) {
    console.error(`FORBIDDEN address in snapshot: ${addr} (${forbidden}).`);
    console.error("This is infrastructure, not a holder. Airdropping to it would create fee-shares");
    console.error("that can never be claimed, diluting every real holder. Remove the row and re-run.");
    process.exit(1);
  }
  if (forbidden && grandfathered) {
    // Refusing here would make the SHIPPED root unbuildable from the committed basis, which would cost
    // more than the row does — see the note in forbidden.mjs. Warn every time, never silently accept.
    console.error(`WARNING: ${addr} (${forbidden}) is a leaf in this snapshot.`);
    console.error(`  Permitted only because it is ${grandfathered}.`);
    console.error("  PRISM claimed to it is unrecoverable. It is below one whole token, so it mints no");
    console.error("  fee-shares and dilutes nobody. Do NOT add rows like this to a new tree.");
  }
  if (seen.has(addr)) { console.error("DUPLICATE address (a holder may appear only once):", addr); process.exit(1); }
  if (/[.,]/.test(String(amt))) {
    console.error(`amount for ${addr} is not integer wei: ${amt}`);
    console.error("Amounts must be whole wei. A decimal PRISM figure here would mis-scale the whole");
    console.error("airdrop by 18 orders of magnitude, and the deploy cannot detect it.");
    process.exit(1);
  }
  const amount = BigInt(amt);
  if (amount <= 0n) { console.error("non-positive amount for", addr); process.exit(1); }
  seen.add(addr);
  values.push([addr, amount.toString()]);
  total += amount;
}

const tree = StandardMerkleTree.of(values, ["address", "uint256"]);

const claims = {};
for (const [i, v] of tree.entries()) claims[v[0]] = { amount: v[1], proof: tree.getProof(i) };

mkdirSync(outDir, { recursive: true });
writeFileSync(`${outDir}/tree.json`, JSON.stringify(tree.dump()));
writeFileSync(`${outDir}/claims.json`, JSON.stringify({ merkleRoot: tree.root, totalAmount: total.toString(), count: values.length, claims }, null, 2));

// A canary: one real (account, amount, proof) triple in a fixed, flat shape that the deploy script can
// parse and verify against MERKLE_ROOT before broadcasting. Without this, a root from the wrong
// snapshot — or a stale root left in .env after regenerating — deploys perfectly cleanly and locks the
// entire airdrop reserve forever, because PrismMigration has no sweep and nothing on-chain can compare
// the root to the tree it came from. Every other check is env-vs-env and cannot see it.
const [canaryAddr, canaryClaim] = Object.entries(claims)[0];
writeFileSync(`${outDir}/canary.json`, JSON.stringify({
  root:    tree.root,
  total:   total.toString(),
  count:   values.length,
  account: canaryAddr,
  amount:  canaryClaim.amount,
  proof:   canaryClaim.proof,
}, null, 2));

console.log("holders          :", values.length);
console.log("totalAmount (wei):", total.toString());
console.log("totalAmount(PRISM):", (Number(total / 10n ** 14n) / 1e4).toString());
console.log("MERKLE_ROOT      :", tree.root);
console.log(`\nwrote ${outDir}/claims.json (per-account proofs), ${outDir}/tree.json`);
console.log(`and ${outDir}/canary.json (one leaf the deploy script verifies against your MERKLE_ROOT)`);
console.log("=> set MERKLE_ROOT and MERKLE_TOTAL to the values above, MIGRATION_AMOUNT == totalAmount,");
console.log(`   and CANARY_PATH=merkle/${outDir}/canary.json in .env  (paths are relative to the`);
console.log("   REPO ROOT, where forge runs - foundry.toml only permits reading ./merkle/out)");
