#!/usr/bin/env node
/**
 * PRISM launch — one command, guided, resumable.
 *
 *     node launch.mjs
 *
 * WHAT THIS IS. `LAUNCH.md` is the same procedure written for a reader. This runs it: it works out where
 * you are from chain state, does every step that does not need a key, stops at the three decisions that
 * cannot be undone, and checks each result before moving on. Nothing is hidden — every command it runs is
 * printed first.
 *
 * WHAT IT WILL NEVER DO, by construction:
 *   - Ask for, accept, or store a private key. Signing steps run `forge script` with your terminal's own
 *     stdin attached, so a keystore password prompt or a Ledger confirmation happens between you and
 *     Foundry. This wrapper never sees it.
 *   - Print `.env` or `SALT_NONCE`. A predictable salt lets someone squat your CREATE2 address, and
 *     anything printed is in your scrollback.
 *   - Print your RPC URL. It usually embeds an API key, so commands are shown as `$RPC_URL`.
 *   - Skip a gate, or continue past a check that failed.
 *
 * RESUMING. The launch is deliberately two sittings, hours apart, because the pool should trade before
 * 89% of the supply becomes movable. Run the same command again later — it reads the chain, not a
 * progress file, and tells you where you are.
 */
import { createInterface } from "node:readline/promises";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { stdin, stdout } from "node:process";

const rl = createInterface({ input: stdin, output: stdout });
const B = "\x1b[1m", DIM = "\x1b[2m", R = "\x1b[0m", G = "\x1b[32m", Y = "\x1b[33m", RED = "\x1b[31m";

const say   = (s = "") => console.log(s);
const head  = (s) => { say(); say(`${B}${s}${R}`); say("─".repeat(Math.min(s.length, 78))); };
const ok    = (s) => say(`  ${G}✓${R} ${s}`);
const warn  = (s) => say(`  ${Y}!${R} ${s}`);
const bad   = (s) => say(`  ${RED}✗${R} ${s}`);
const note  = (s) => say(`  ${DIM}${s}${R}`);

/** Placeholder until the endpoint is known; reassigned once RPC is read. */
let redact = (s) => String(s ?? "");

function die(msg, hint) {
  say(); bad(msg); if (hint) note(hint);
  say(); say(`${DIM}Nothing was changed by this run. Fix the above and run again.${R}`);
  rl.close(); process.exit(1);
}

/** Ask for a typed word. Enter alone is never enough for anything irreversible. */
async function gate(question, word) {
  say();
  const a = (await rl.question(`${Y}${question}${R}\n  Type ${B}${word}${R} to continue (anything else aborts): `)).trim();
  if (a !== word) die("Aborted at your request.", "Nothing was signed.");
}
const askYes = async (q) => /^y(es)?$/i.test((await rl.question(`  ${q} [y/N] `)).trim());

/** Run a command, showing it first. `quiet` keeps output for us instead of the screen. */
function run(cmd, args, { quiet = false, allowFail = false, env } = {}) {
  const shown = [cmd, ...args.map((a) => (a.includes(" ") ? `"${a}"` : a))].join(" ");
  note(`$ ${shown}`);
  const r = spawnSync(cmd, args, {
    stdio: quiet ? ["ignore", "pipe", "pipe"] : "inherit",
    env: { ...process.env, ...env },
    encoding: "utf8",
  });
  if (r.status !== 0 && !allowFail) {
    die(`\`${cmd}\` failed (exit ${r.status}).`,
        quiet ? redact((r.stderr || "").trim().split("\n").slice(-4).join("\n")) : undefined);
  }
  return r;
}

/** A read-only `cast call`. Returns null rather than throwing, so callers can branch on absence.
 *  stderr is discarded deliberately: "contract 0x… does not have any code" is an ANSWER here, not a
 *  failure, and letting cast's raw `Error:` text through makes a normal reading look like a crash. */
function castCall(to, sig, args = []) {
  try {
    return execFileSync("cast", ["call", to, sig, ...args, "--rpc-url", RPC],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch { return null; }
}
const isZeroAddr = (v) => !v || /^0x0{40}$/i.test(v.replace(/^0x/, "0x").toLowerCase());

// ── prerequisites ────────────────────────────────────────────────────────────────────────────────
head("PRISM launch");
say("Guided, resumable, and it never handles your key. Every command is printed before it runs.");
say(`${DIM}The full reasoning behind each step is in LAUNCH.md; this is the same procedure, executed.${R}`);

head("0 · Prerequisites");
for (const bin of ["forge", "cast", "node"]) {
  try { execFileSync(bin, ["--version"], { stdio: "ignore" }); ok(`${bin} found`); }
  catch { die(`\`${bin}\` is not on PATH.`, bin === "node" ? "Node 18+ required." : "Install Foundry: https://getfoundry.sh"); }
}

let RPC = process.env.RPC_URL || process.env.ETH_RPC_URL;
if (!RPC) {
  say();
  note("Your mainnet RPC endpoint. It is used for reads and simulation and is never printed back.");
  RPC = (await rl.question("  RPC endpoint: ")).trim();
  if (!/^https?:\/\//.test(RPC)) die("That does not look like an http(s) endpoint.");
}
ok("RPC endpoint set (not echoed — it usually contains an API key)");
process.env.RPC_URL = RPC;
process.env.ETH_RPC_URL = RPC;

// Strip the endpoint out of anything we echo from here on. Foundry puts the full URL in its error text and
// that URL usually embeds an API key, so printing it would leave the key in the operator's scrollback.
redact = (s) => String(s ?? "").split(RPC).join("$RPC_URL");

try {
  const chain = execFileSync("cast", ["chain-id", "--rpc-url", RPC], { encoding: "utf8" }).trim();
  if (chain !== "1") die(`That endpoint is chain ${chain}, not Ethereum mainnet (1).`);
  ok("endpoint is Ethereum mainnet");
} catch (e) {
  die("Could not reach that RPC endpoint.", redact(String(e.message || e).split("\n")[0]));
}

// ── locate the launch from chain state, not from a progress file ──────────────────────────────────
head("Where are we?");
const ART = ["broadcast/Deploy.s.sol/1/run-latest.json", "broadcast/Deploy.s.sol/1/dry-run/run-latest.json"];
let vault = null, hook = null, artifactIsDryRun = false;
for (const [i, p] of ART.entries()) {
  if (!existsSync(p)) continue;
  try {
    const txs = JSON.parse(readFileSync(p, "utf8")).transactions;
    vault = txs[0]?.contractAddress ?? null;
    hook  = txs[1]?.contractAddress ?? null;
    artifactIsDryRun = i === 1;
    break;
  } catch { /* fall through */ }
}

let state = "fresh";
if (hook && !artifactIsDryRun) {
  const code = castCall(hook, "seeded()(bool)");
  if (code === null) { warn("a broadcast artifact exists but the hook has no code on mainnet — treating as fresh"); }
  else {
    const seeded = code === "true";
    const owner  = castCall(hook, "owner()(address)");
    const token  = vault ? castCall(vault, "token()(address)") : null;
    if (!seeded)                    state = "partial";
    else if (!isZeroAddr(owner))    state = "seeded_not_renounced";
    else if (isZeroAddr(token))     state = "live_airdrop_closed";
    else                            state = "airdrop_open";
    ok(`hook  ${hook}`);
    ok(`vault ${vault}`);
  }
} else if (artifactIsDryRun) {
  note("only a dry-run artifact found — nothing has been broadcast");
}

const WHERE = {
  fresh:                "Nothing deployed. Starting from the beginning.",
  partial:              "A deploy landed but the pool is NOT seeded — this is a partial deploy.",
  seeded_not_renounced: "Deployed and seeded. Ownership is still held.",
  live_airdrop_closed:  "Live and renounced. The airdrop is still CLOSED.",
  airdrop_open:         "The airdrop is open. Only distribution and verification remain.",
};
say(); say(`  ${B}${WHERE[state]}${R}`);

if (state === "partial") {
  die("Stopping: a partial deploy needs a human, not a script.",
      "Do NOT re-run the deploy. See LAUNCH.md §6 and the Troubleshooting table, finish the remaining\n  steps by hand, then run this again.");
}

/** Print a signing command and run it with your terminal attached, so Foundry prompts you directly. */
async function signStep(title, argv, { verify, expect }) {
  head(title);
  note("This is a signature. Your terminal is attached to Foundry, so a keystore password prompt or a");
  note("Ledger confirmation happens between you and Foundry — this script never sees it.");
  say();
  const sender = (await rl.question("  Deployer address (--sender): ")).trim();
  if (!/^0x[0-9a-fA-F]{40}$/.test(sender)) die("That is not an address.");
  say();
  say("  How is the key held?");
  say("    1) hardware wallet (Ledger/Trezor) — you confirm on the device");
  say("    2) encrypted keystore — Foundry will prompt for the password");
  const how = (await rl.question("  Choose 1 or 2: ")).trim();
  const signer = how === "1"
    ? ["--ledger"]
    : ["--account", (await rl.question("  Keystore account name: ")).trim()];

  await gate(`About to BROADCAST: ${title}. This cannot be undone.`, "BROADCAST");
  run("forge", [...argv, "--sender", sender, ...signer, "--broadcast"]);

  if (verify) {
    say();
    const v = verify();
    if (!v) die(`${title} did not take effect on-chain.`, expect);
    ok(`confirmed on-chain: ${v}`);
  }
}

// ── sitting one ──────────────────────────────────────────────────────────────────────────────────
if (state === "fresh") {
  head("0 · Build and test");
  note("236 tests, twelve of which fork mainnet through the endpoint above. Takes a couple of minutes.");
  if (await askYes("Run the suite now? (recommended, and safe)")) run("forge", ["test"]);
  else warn("skipped — you are trusting the repo without checking it builds on your machine");

  head("1 · Airdrop data");
  ok("already committed: 1203 holders, root 0x2cd60218…d33e12f — nothing to generate");
  note("The optional reproducibility check is in LAUNCH.md §1 and needs `npm install`.");

  head("2 · Generate .env");
  note("Writes the root, reserve, seed price, tick, liquidity, both floors, and a random SALT_NONCE.");
  note("Its contents are never printed here: a predictable salt lets someone squat your CREATE2 address.");
  if (existsSync(".env")) {
    warn(".env already exists.");
    if (!await askYes("Overwrite it with a fresh one (new SALT_NONCE)?")) note("keeping the existing .env");
    else run("sh", ["-c", "node merkle/make-env.mjs > .env"]);
  } else {
    run("sh", ["-c", "node merkle/make-env.mjs > .env"]);
  }
  if (!existsSync(".env")) die(".env was not written.");
  ok(".env written (contents deliberately not shown)");
  note("It is gitignored. Do not commit, paste or print it.");

  head("3 · Preflight");
  note("Read-only. No key, nothing signed. Reverts by name on the first bad value.");
  run("sh", ["-c", "set -a; . ./.env; set +a; forge script script/Preflight.s.sol"]);

  head("4 · Dry run against mainnet");
  note("A full simulation against live state. Still nothing signed.");
  const senderForDry = (await rl.question("  Deployer address, for the simulation only: ")).trim();
  if (!/^0x[0-9a-fA-F]{40}$/.test(senderForDry)) die("That is not an address.");
  run("sh", ["-c",
    `set -a; . ./.env; set +a; forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --sender ${senderForDry}`]);

  say();
  say(`  ${B}Read the simulation output above before continuing.${R}`);
  note("The launch tick and the implied FDV are the valuation you are committing to. If the FDV is not");
  note("the number you intend, stop now and change LAUNCH_TICK and LAUNCH_FDV_ETH together in");
  note("merkle/make-env.mjs — not at the last minute, and not by nudging the tick until something passes.");

  await gate("Is the printed FDV the valuation you intend to launch at?", "YES");
  await gate("5 · POINT OF NO RETURN. Everything after this is irreversible. Ready to broadcast?", "I AM READY");

  await signStep("6 · Broadcast the deploy (3 transactions)",
    ["script", "script/Deploy.s.sol", "--rpc-url", "$RPC_URL", "--slow"],
    { verify: () => null });
  warn("Re-read the output: you need the printed hook and vault addresses for the rest.");
  note("They are also recoverable at any time from broadcast/Deploy.s.sol/1/run-latest.json.");
  say();
  note("Run this command again now — it will re-detect state from chain and continue from step 7.");
  rl.close(); process.exit(0);
}

if (state === "seeded_not_renounced") {
  head("7 · Verify on-chain before renouncing");
  const seeded = castCall(hook, "seeded()(bool)");
  const owner  = castCall(hook, "owner()(address)");
  const resid  = castCall(hook, "balanceOf(address)(uint256)", [hook]);
  const root   = vault ? castCall(vault, "merkleRoot()(bytes32)") : null;
  const tok    = vault ? castCall(vault, "token()(address)") : null;
  seeded === "true" ? ok("seeded() is true") : bad("seeded() is FALSE");
  ok(`owner() is ${owner} (still you — expected at this point)`);
  ok(`hook residual: ${resid} (the documented rounding headroom is 1000000004)`);
  if (root) ok(`vault root: ${root}`);
  if (tok)  ok(`vault token: ${tok} — zero is correct here; the airdrop opens later`);
  if (seeded !== "true") die("The pool is not seeded. Do not renounce.", "See LAUNCH.md §6.");

  head("8 · The unseeded-renounce guard");
  ok("enforced in code — Renounce.s.sol hard-requires seeded(), so this cannot be got wrong");

  await gate("9 · Renounce ownership. The token becomes permanently ownerless.", "RENOUNCE");
  await signStep("9 · Renounce", ["script", "script/Renounce.s.sol", "--rpc-url", "$RPC_URL"], {
    verify: () => (isZeroAddr(castCall(hook, "owner()(address)")) ? "owner() is now the zero address" : null),
    expect: "owner() did not become zero.",
  }, );

  head("10 · Start the fee keeper");
  say("  Run this in its own terminal, on a SEPARATE gas-only wallet — never the deploy key:");
  say(`    ${B}cd merkle && node keeper.mjs --hook ${hook} --rpc "$RPC_URL" --key $KEEPER_PK --interval 12${R}`);
  note("It signs pokeFees() indefinitely. Fees are booked when collected, so collecting often keeps the");
  note("unbooked backlog small. Treat it as part of the launch, not an optimisation.");

  head("Stop here.");
  say(`  ${B}The token is live and ownerless. The airdrop is still closed.${R}`);
  say("  Let the pool trade for the interval you planned — 10 to 24 hours.");
  say();
  say(`  ${RED}KEEP THE DEPLOY KEY.${R} Opening the airdrop needs it again, and nothing else can ever open`);
  say("  it — no sweep, no fallback. Lose it during the wait and the whole reserve is stranded.");
  say();
  note("When the interval has passed, run `node launch.mjs` again. It will pick up at step 10b.");
  rl.close(); process.exit(0);
}

if (state === "live_airdrop_closed") {
  head("10b · Open the airdrop");
  const reserve = castCall(hook, "balanceOf(address)(uint256)", [vault]);
  ok(`the vault holds ${reserve} wei — 89% of supply, currently not distributable`);
  say();
  say(`  ${B}This is the decision to put that supply into circulation. It cannot be undone.${R}`);
  note("Only the ~545 PRISM float has been tradeable until now. That was the point of waiting.");
  say();
  await gate("Has the interval you intended (10–24h) actually elapsed?", "YES IT HAS");

  await signStep("10b · Open the airdrop",
    ["script", "script/OpenAirdrop.s.sol", "--rpc-url", "$RPC_URL"],
    {
      verify: () => (castCall(vault, "token()(address)")?.toLowerCase() === hook.toLowerCase()
        ? "vault is wired to the hook — the airdrop is open" : null),
      expect: "token() is not the hook.",
    });
  process.env.HOOK = hook; process.env.VAULT = vault; process.env.RESERVE = reserve;
  say();
  ok("nothing further needs the deploy key");
  note("Run `node launch.mjs` again to continue with the distribution.");
  rl.close(); process.exit(0);
}

// ── airdrop open: distribution and verification ──────────────────────────────────────────────────
head("11 · Distribute the airdrop");
say("  ~47 transactions, and they need NO privilege at all: the batcher is ownerless and `claim` always");
say("  pays the holder regardless of who calls. Use a throwaway hot wallet with gas only.");
note("Deploy the batcher first (LAUNCH.md §11), then run the push until it reports zero unpaid — it exits");
note("non-zero while anyone is still owed, so it is safe to wrap in a loop.");
say();
say(`    ${B}MIGRATION=${vault} forge script script/DeployBatcher.s.sol --rpc-url "$RPC_URL" --broadcast${R}`);
say(`    ${B}cd merkle && node push-airdrop.mjs --batcher <batcher> --dry-run${R}`);
note("This wizard stops short of the push on purpose: it is many transactions on a different wallet, and");
note("the runner already plans, dry-runs, resumes and refuses an infeasible plan better than a prompt can.");

head("11b · Who still needs to mirror");
say(`    ${B}cd merkle && node check-shares.mjs --hook ${hook} --migration ${vault} --rpc "$RPC_URL"${R}`);
note("Expect 5 addresses holding 288 unminted shares. `syncNFTs` is caller-only — nobody can do it for");
note("them, so this is outreach. It also names anyone never paid; check that first.");

head("Done");
ok("token live, ownerless, airdrop open");
note("Keep the keeper running. Re-run check-shares in a few days to see who still has not acted.");
rl.close();
