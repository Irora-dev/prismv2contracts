#!/usr/bin/env node
/**
 * Find holders whose fee-shares have not caught up with their balance, and print the one command each
 * of them needs to run.
 *
 *   node check-shares.mjs --hook 0x… --rpc $RPC_URL                 # everyone in claims.json
 *   node check-shares.mjs --hook 0x… --rpc $RPC_URL --addr 0x…      # just one holder
 *   node check-shares.mjs --hook 0x… --rpc $RPC_URL --json          # machine-readable
 *
 * WHY THIS EXISTS, and why it is not a claim UI.
 *
 * Nobody has to claim: `push-airdrop.mjs` delivers every allocation straight to its owner's wallet. But
 * delivering PRISM and mirroring it into fee-shares are two different things, and the push can only do
 * the first:
 *
 *   - `MAX_REALIGN` caps fresh mints at 128 per transfer, because an unbounded mint loop would exceed
 *     the per-transaction gas limit and strand the largest claims entirely.
 *   - So a holder receiving more than 128 whole PRISM in one transfer gets ALL their PRISM and only 128
 *     fee-shares. The rest are unminted, and until they are minted that holder earns no fees on them.
 *   - `syncNFTs` mints the remainder — but it is `msg.sender`-only (`address user = msg.sender`, not a
 *     parameter). **Nobody can do it for them.** Not the pusher, not the deployer, not a keeper.
 *
 * And the contract emits no event when a mint truncates, so an affected holder has no way to notice.
 * That is what this closes: it reads the gap straight off the chain (`balanceOf / 1e18 - nftBalanceOf`)
 * and tells you exactly who to contact and what to tell them.
 *
 * For the published 1203-holder snapshot this is 5 addresses holding 288 unminted shares — 6.8% of the
 * share base. The other 1198 holders are fully mirrored by the push and need to do nothing at all.
 *
 * Run it right after the airdrop push, and again a few days later to see who still has not acted.
 */
import { readFileSync } from "fs";
import { Contract, JsonRpcProvider } from "ethers";

const ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function nftBalanceOf(address) view returns (uint256)",
  "function totalShares() view returns (uint256)",
];

// `PrismMigration.claimed` is the only AUTHORITATIVE answer to "was this holder paid". A zero balance is
// not: it is equally true of a holder who received their allocation and then sold, and 783 of the 1203
// holders hold under one whole PRISM, so that is the likely case rather than the exotic one. Pass
// --migration to get the exact answer; without it this falls back to the balance heuristic and says so.
const VAULT_ABI = ["function claimed(address) view returns (bool)"];

const UNIT = 10n ** 18n;

const arg = (name) => {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? undefined : process.argv[i + 1];
};

const hook   = arg("hook");
const rpc    = arg("rpc", ) ?? process.env.RPC_URL;
const claims = arg("claims") ?? "../airdrop/claims.json";
const one    = arg("addr");
const vaultAddr = arg("migration");
const asJson = process.argv.includes("--json");

if (!hook || !rpc) {
  console.error("usage: node check-shares.mjs --hook 0x… --rpc <url> [--addr 0x…] [--claims ../airdrop/claims.json] [--json]");
  process.exit(1);
}

const provider = new JsonRpcProvider(rpc);
const prism = new Contract(hook, ABI, provider);
const vault = vaultAddr ? new Contract(vaultAddr, VAULT_ABI, provider) : null;

// Allocation per address, so a zero on-chain balance can be told apart from a zero allocation. Keyed
// lower-case: the claims file uses EIP-55 checksummed keys and `--addr` is whatever the operator typed,
// so comparing them raw would miss on casing alone and silently report an unpaid holder as mirrored.
const allocation = new Map();
const loadClaims = () => {
  const parsed = JSON.parse(readFileSync(claims, "utf8")).claims;
  for (const [a, c] of Object.entries(parsed)) allocation.set(a.toLowerCase(), BigInt(c.amount));
  return Object.keys(parsed);
};

let addresses;
if (one) {
  addresses = [one];
  // Load the allocations here too, best-effort. Without them the unpaid check below cannot fire, so a
  // single-holder run would report an unpaid holder as "fully mirrored" — the exact defect this check
  // exists to close, left in place on the one path a worried holder is most likely to use. Best-effort
  // because checking an address that is not in the tree at all is legitimate.
  try { loadClaims(); } catch { /* no claims file: fall through to the mirroring check only */ }
} else {
  try {
    addresses = loadClaims();
  } catch (e) {
    console.error(`could not read ${claims}: ${e.message}`);
    console.error("run merkle/generate.mjs first, or pass --addr to check a single holder.");
    process.exit(1);
  }
}

const gapped = [];
// A holder who was never paid has balanceOf == 0, so `entitled > shares` is false and the mirroring check
// below calls them fully mirrored — which is true and beside the point. This script runs immediately after
// the airdrop push, so reporting "nothing to do" over an unpaid holder would confirm a distribution that
// did not finish. Track them separately: the claims file says what each address is owed, so a zero balance
// against a nonzero allocation means unpaid, not mirrored.
const unpaid = [];
let checked = 0;

// Sequential rather than parallel: a public RPC endpoint will rate-limit 1200 concurrent calls, and this
// is a diagnostic that runs occasionally, not a hot path.
for (const addr of addresses) {
  const [bal, shares] = await Promise.all([prism.balanceOf(addr), prism.nftBalanceOf(addr)]);
  checked++;
  const entitled = bal / UNIT;
  const owed = allocation.get(addr.toLowerCase());
  // With the vault, "unpaid" is a fact. Without it, a zero balance is only a HINT — it cannot distinguish
  // never-paid from paid-and-sold, so treat it as suspected and label it that way in the output.
  let isUnpaid = false;
  if (owed !== undefined && owed > 0n) {
    if (vault) isUnpaid = !(await vault.claimed(addr));
    else isUnpaid = bal === 0n;
  }
  if (isUnpaid) unpaid.push({ addr, owed });
  else if (entitled > shares) gapped.push({ addr, entitled, shares, gap: entitled - shares });
  if (!asJson && checked % 200 === 0) process.stderr.write(`  …checked ${checked}/${addresses.length}\n`);
}

gapped.sort((a, b) => (b.gap > a.gap ? 1 : b.gap < a.gap ? -1 : 0));

if (asJson) {
  console.log(JSON.stringify({
    hook, checked,
    totalShares: (await prism.totalShares()).toString(),
    unpaid: unpaid.map((u) => ({ address: u.addr, owedWei: u.owed.toString() })),
    underMirrored: gapped.map((g) => ({
      address: g.addr,
      wholeTokens: g.entitled.toString(),
      feeShares: g.shares.toString(),
      unmintedShares: g.gap.toString(),
    })),
  }, null, 2));
  process.exit(unpaid.length > 0 ? 1 : 0);
}

const totalGap = gapped.reduce((s, g) => s + g.gap, 0n);
console.log(`checked ${checked} holder(s) against ${hook}`);
console.log(`totalShares on-chain: ${await prism.totalShares()}`);
console.log();

// Report this FIRST and loudest: an unfinished distribution matters more than an unmirrored one, and this
// script runs immediately after the push. Saying "nothing to do" over an unpaid holder would rubber-stamp
// a distribution that stopped early.
if (unpaid.length > 0) {
  const owedTotal = unpaid.reduce((s2, u) => s2 + u.owed, 0n);
  console.log(`!! ${unpaid.length} holder(s) have NOT BEEN PAID AT ALL — ${owedTotal} wei of allocation`);
  console.log("   is still sitting in the vault. This is not a mirroring gap; the push did not finish.");
  console.log("   Re-run `node merkle/push-airdrop.mjs` until it reports 0 unpaid, THEN re-run this.");
  console.log();
  for (const u of unpaid.slice(0, 20)) console.log(`  ${u.addr}  owed ${u.owed} wei`);
  if (unpaid.length > 20) console.log(`  …and ${unpaid.length - 20} more`);
  console.log();
}

if (gapped.length === 0) {
  if (unpaid.length === 0) {
    console.log(vault
      ? "Every holder checked is paid and fully mirrored. Nothing to do."
      : "Every holder checked is fully mirrored. Nothing to do. (Pass --migration to also confirm payment.)");
  } else {
    console.log("Nobody who WAS paid is under-mirrored — but see the unpaid holders above.");
  }
  process.exit(unpaid.length > 0 ? 1 : 0);
}

console.log(`${gapped.length} holder(s) are UNDER-MIRRORED, holding ${totalGap} unminted fee-share(s)`);
console.log("between them. They earn no fees on those shares until they act, and NOBODY can act for");
console.log("them — `syncNFTs` is caller-only by design.");
console.log();
for (const g of gapped) {
  const pct = g.entitled > 0n ? (g.gap * 100n) / g.entitled : 0n;
  console.log(`  ${g.addr}`);
  console.log(`    holds ${g.entitled} whole PRISM but only ${g.shares} fee-shares — ${g.gap} unminted (${pct}% of their entitlement)`);
  console.log(`    they run:  cast send ${hook} 'syncNFTs(uint256)' 0 --rpc-url <rpc> --account <their wallet>`);
  console.log();
}
console.log("`syncNFTs(0)` means \"mint as many as fit in this transaction\". A holder more than 128 shares");
console.log("short needs to call it more than once — it is capped per transaction for the same gas reason");
console.log("the shortfall exists. Re-run this script to confirm the gap closed.");

// Decide the exit code HERE, at the end of every path. It used to sit inside the `gapped.length === 0`
// branch, which made it dead in the state the launch actually produces: the shipped snapshot leaves 5
// holders under-mirrored by design, so the script always reached the report above and exited 0 — with any
// unpaid holders printed further up. A human reading the output was never misled; a wrapper or CI step
// checking the exit code was.
process.exit(unpaid.length > 0 ? 1 : 0);
