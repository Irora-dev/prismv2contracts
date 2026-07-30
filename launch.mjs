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

/** Set once a broadcast has been attempted, after which "nothing was changed" stops being true. */
let broadcastStarted = false;

function die(msg, hint) {
  say(); bad(msg); if (hint) note(hint);
  say();
  if (broadcastStarted) {
    // A forge broadcast is one transaction per state-changing call, and a reverted transaction does not
    // stop the next from being mined — so a failure here can still have changed the chain. Telling the
    // operator otherwise is an invitation to re-run an irreversible step.
    say(`${RED}A broadcast was already attempted, so this run MAY have changed on-chain state.${R}`);
    say(`${DIM}Do NOT simply run again. Check what landed first: read the forge output above, and${R}`);
    // Do NOT name Deploy's artifact here. forge names the directory after the SCRIPT, so the renounce
    // writes broadcast/Renounce.s.sol/… and the airdrop step broadcast/OpenAirdrop.s.sol/… — and since
    // those steps are only reachable once the deploy has already succeeded, naming Deploy's file would hand
    // an operator whose renounce just failed a complete, successful, entirely irrelevant deploy record as
    // reassurance. From the one message whose whole job is to stop a wrong re-run.
    say(`${DIM}the broadcast/ directory named after the script you just ran. Then see LAUNCH.md §6${R}`);
    say(`${DIM}and its Troubleshooting table.${R}`);
  } else {
    say(`${DIM}Nothing was changed by this run. Fix the above and run again.${R}`);
  }
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
  // Redact before printing. Commands are shown so nothing is hidden, and this is the line that puts them
  // in the operator's scrollback — so it is also the line that would put an API key there. Arguments carry
  // the real endpoint (a literal `$RPC_URL` is not expanded: there is no shell here, and forge reads it as
  // a filesystem path), so the substitution has to happen on the way to the screen, not on the way to exec.
  const shown = redact([cmd, ...args.map((a) => (a.includes(" ") ? `"${a}"` : a))].join(" "));
  note(`$ ${shown}`);

  // Give the terminal back before handing it to the child.
  //
  // `createInterface` puts a tty into RAW mode and keeps it there for the life of the interface, and
  // `stdio: "inherit"` hands that same terminal to forge — so cooked mode has to be restored before the
  // child gets it. Raw mode means `-icanon -icrnl`, so Enter's carriage return is never translated to a
  // newline and Foundry's "Enter keystore password:" prompt — a canonical-mode line reader — waits for a
  // line that cannot arrive. `-isig` also means Ctrl-C cannot interrupt it, so it hangs rather than fails,
  // at every signature, for anyone using a keystore. Foundry sets `echonl` itself but assumes canonical
  // mode is already on.
  const wasRaw = Boolean(stdin.isTTY && stdin.isRaw);
  if (wasRaw) stdin.setRawMode(false);
  rl.pause();
  let r;
  try {
    r = spawnSync(cmd, args, {
      stdio: quiet ? ["ignore", "pipe", "pipe"] : "inherit",
      env: { ...process.env, ...env },
      encoding: "utf8",
    });
  } finally {
    // Restore whatever readline had, so the prompts after this step keep working.
    rl.resume();
    if (wasRaw && stdin.isTTY) stdin.setRawMode(true);
  }
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
    const out = execFileSync("cast", ["call", to, sig, ...args, "--rpc-url", RPC],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    // cast annotates a numeric return with a readable magnitude — `1000000004 [1e9]`. That is a courtesy
    // on a terminal and wrong everywhere else: it is not a number anything can parse, and `vm.envUint`
    // rejects it outright, so a reading passed on as a value would fail at the step that consumes it.
    // Strip it here, at the one boundary every reading crosses, rather than at each call site.
    return out.replace(/\s*\[[^\]]*\]$/, "");
  } catch { return null; }
}
/** Is there a contract at this address? Returns null if the question could not be ASKED, which is a
 *  different fact from "no". `cast call` fails for both, and reading a failure as "nothing is deployed" is
 *  how a momentary endpoint problem becomes an offer to deploy a second system on top of a live one. */
function castCode(addr) {
  try {
    return execFileSync("cast", ["code", addr, "--rpc-url", RPC],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch { return null; }
}
// NOTE: `isZeroAddr(null)` is TRUE, so never hand it an unchecked reading — "the call failed" would come
// back as "the zero address", and for `owner()` that means "already renounced".
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
// Redact the SECRET, not just the string you were given. An exact whole-URL replace is not enough, because
// reqwest re-emits a NORMALISED url: an explicit default port is dropped (`:80` disappears), an uppercase
// scheme is lower-cased, a trailing dot in the host is stripped. Any of those three ordinary spellings
// makes a whole-URL substring match miss and prints the key verbatim. Redacting the key itself holds
// however the surrounding url is spelled.
redact = (() => {
  const urls = new Set([RPC]);
  const secrets = new Set();
  try {
    const u = new URL(RPC);
    urls.add(u.href);                                  // the normalised form
    urls.add(u.origin + u.pathname + u.search);
    if (u.username) secrets.add(u.username);
    if (u.password) secrets.add(u.password);
    // Provider keys live in a path segment or a query value. Anything long enough to be one is redacted.
    for (const seg of u.pathname.split("/")) if (seg.length >= 8) secrets.add(seg);
    for (const [, v] of new URLSearchParams(u.search)) if (v.length >= 8) secrets.add(v);
  } catch { /* not parseable as a URL; the plain replacement below still applies */ }
  const longestFirst = (a, b) => b.length - a.length;
  const u2 = [...urls].filter(Boolean).sort(longestFirst);
  const s2 = [...secrets].filter(Boolean).sort(longestFirst);
  return (s) => {
    let out = String(s ?? "");
    for (const p of u2) out = out.split(p).join("$RPC_URL");
    for (const p of s2) out = out.split(p).join("<redacted>");
    return out;
  };
})();

try {
  // `stdio` is not optional here. Without it node pipes cast's stderr straight to this terminal, and cast's
  // transport errors quote the full endpoint — so the API key landed in the operator's scrollback at the
  // FIRST rpc call, one line after this script promised not to print it. Capture it instead and let the
  // `catch` below redact it.
  const chain = execFileSync("cast", ["chain-id", "--rpc-url", RPC],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  if (chain !== "1") die(`That endpoint is chain ${chain}, not Ethereum mainnet (1).`);
  ok("endpoint is Ethereum mainnet");
} catch (e) {
  // `e.message` is only "Command failed: cast chain-id …" — the actual reason (DNS, TLS, refused, 401) is on
  // stderr, which is now captured rather than echoed. Show it, redacted, or the operator gets a failure with
  // no diagnosis.
  const why = redact([String(e.stderr ?? "").trim(), String(e.message ?? e).trim()]
    .filter(Boolean).join("\n").split("\n").slice(0, 3).join("\n"));
  die("Could not reach that RPC endpoint.", why || undefined);
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

// A missing broadcast record is NOT evidence that nothing was deployed, and must never be read as such.
// `broadcast/` is gitignored, so a clean checkout, a second machine, a different working directory or a
// `git clean` all reach this point with a live token on chain. Inferring "fresh" from a missing record ends
// in a SECOND complete 5,000 PRISM system: step 2 writes a new random SALT_NONCE, which moves the predicted
// address, so `Deploy.s.sol`'s occupied-address guard asks about somewhere empty and the whole launch
// simulates cleanly over the top of the live one. Every other check passes too, because none of them knows
// a previous launch exists.
//
// So ask. The hook address is public, it is in the previous run's output, and it costs one paste.
// `castCode(hook) === "0x"` belongs in this condition too: an artifact naming an address with no code must
// not be read as "fresh" either, or a truthy `hook` outside a dry run skips this whole block and offers a
// deploy with no confirmation at all. That is reachable in practice — a failed hand-run broadcast
// overwrites `run-latest.json` after a successful launch, and the artifact then points somewhere empty
// while the real system is live. An empty address is a question, not a conclusion.
if (!hook || artifactIsDryRun || castCode(hook) === "0x") {
  say();
  warn("No broadcast record found in this directory (broadcast/ is gitignored, so it does not travel).");
  note("That is expected on a fresh launch — and it looks identical to resuming from a clean checkout,");
  note("another machine, or another directory, where the token may already be live. This script cannot");
  note("tell those apart on its own, so it has to ask.");
  say();
  const prior = (await rl.question("  Hook address from a previous run, or blank if this is a first launch: ")).trim();
  if (prior) {
    if (!/^0x[0-9a-fA-F]{40}$/.test(prior)) die("That is not an address.");
    const code = castCode(prior);          // one call, then branch on it
    if (code === null) {
      die("Could not reach the endpoint to check that address.", "Fix the endpoint and run again.");
    }
    if (code === "0x") {
      die(`No contract exists at ${prior} on mainnet.`,
          "Check the address. If you are certain nothing was ever deployed, run again and leave it blank.");
    }
    // "Has code" is not "is a PRISM hook": a code-length test alone accepts WETH with a green tick.
    // Ask the address something only this hook answers, so a wrong paste is refused here rather than
    // classified into a launch step. `MIGRATION_VAULT()` is an immutable getter present from construction.
    if (castCall(prior, "MIGRATION_VAULT()(address)") === null
        || castCall(prior, "seeded()(bool)") === null) {
      die(`${prior} has code, but it does not answer like a PRISM v2 hook.`,
          "It should respond to MIGRATION_VAULT() and seeded(). Check you pasted the HOOK address and not\n"
        + "  the vault, the mirror, or another token.");
    }
    hook = prior;
    artifactIsDryRun = false;
    ok(`adopted ${hook} from your input`);
    note("Run from the directory holding broadcast/ if you would rather it were found automatically.");
    // Falls straight through to the classification below. It must NOT stop and ask you to run again: doing
    // that persisted nothing, so the next run asked this same question, and the only way out of the loop was
    // to answer "nothing is deployed" about a live system -- turning the fix into the very hazard it exists
    // to prevent.
  } else {
    // Blank means "first launch". Make that an assertion the operator signs for, not a default -- and only
    // ask it when they have actually claimed it, never after adopting an address.
    await gate("Confirm NO PRISM v2 hook has ever been deployed by you. Deploying a second one is not"
      + "\n  reversible and would split the supply, the pool and the airdrop across two tokens.",
      "NOTHING IS DEPLOYED");
  }
}

let state = "fresh";
if (hook && !artifactIsDryRun) {
  // Ask whether the hook EXISTS before asking it anything. This is the one question with an unambiguous
  // negative answer, so it is the only safe place to decide "nothing is deployed".
  const hookCode = castCode(hook);
  if (hookCode === null) {
    die("Could not ask the endpoint whether the deploy is already on chain.",
        "A broadcast artifact exists, so something may well be deployed — and an unanswered read must not be\n"
      + "  read as 'nothing is there', because the step that follows would deploy a second complete system\n"
      + "  over a live one. Fix the endpoint and run again.");
  }
  if (hookCode === "0x") {
    warn("a broadcast artifact exists but the hook has no code on mainnet — treating as fresh");
  } else {
    const seededRaw = castCall(hook, "seeded()(bool)");
    const ownerRaw  = castCall(hook, "owner()(address)");
    // The hook has code, so these must answer. Letting either through as null would classify the launch on
    // a missing reading: an unreadable `owner()` reads as the zero address, i.e. "already renounced", which
    // skips the renounce, walks on to opening the airdrop, and never offers the renounce again — leaving a
    // live owner key on a token whose whole claim is that it has none.
    if (seededRaw === null || ownerRaw === null) {
      die(`The hook has code but did not answer ${seededRaw === null ? "seeded()" : "owner()"}.`,
          "That is an endpoint or ABI problem, not a state to infer from. Fix it and run again.");
    }
    // Take the vault from the HOOK, not from the artifact's second entry. It is an immutable constructor
    // argument, so the hook is the authoritative source and it needs no local file — the artifact is
    // gitignored, which means the operator resuming on another machine, or after a clean checkout, may not
    // have it at all. The artifact is still how we find the hook; this removes the second dependency on it.
    // Three outcomes, kept distinct on purpose. "The call failed" and "the answer was zero" are different
    // facts with opposite consequences — conflating them would let a momentary RPC failure read as "this
    // launch has no airdrop", which ends the wizard with congratulations while 89% of supply sits unwired.
    const onChainVault = castCall(hook, "MIGRATION_VAULT()(address)");
    const vaultRead = onChainVault === null ? "failed" : isZeroAddr(onChainVault) ? "none" : "ok";
    if (vaultRead === "ok") vault = onChainVault;
    else if (vaultRead === "none") vault = null;

    const seeded = seededRaw === "true";
    const owner  = ownerRaw;
    // Only ask the vault anything once we know there is one, and treat silence as its own state:
    // `isZeroAddr(null)` is true, so an unread vault would otherwise be indistinguishable from one that is
    // present but not yet wired — and those two send the operator to different places, one irreversible.
    const token  = vault ? castCall(vault, "token()(address)") : null;
    if (!seeded)                     state = "partial";
    else if (!isZeroAddr(owner))     state = "seeded_not_renounced";
    else if (vaultRead === "failed") state = "vault_unreadable";
    else if (vaultRead === "none")   state = "live_no_airdrop";
    else if (token === null)         state = "vault_unreadable";
    else if (isZeroAddr(token))      state = "live_airdrop_closed";
    else                             state = "airdrop_open";
    ok(`hook  ${hook}`);
    ok(`vault ${vault ?? "none — this hook was deployed with no airdrop"}`);
  }
} else if (artifactIsDryRun) {
  note("only a dry-run artifact found — nothing has been broadcast");
}

const WHERE = {
  fresh:                "Nothing deployed. Starting from the beginning.",
  partial:              "A deploy landed but the pool is NOT seeded — this is a partial deploy.",
  seeded_not_renounced: "Deployed and seeded. Ownership is still held.",
  live_no_airdrop:      "Live and renounced, with no airdrop vault. The launch is complete.",
  vault_unreadable:     "Live and renounced, but the airdrop vault did not answer.",
  live_airdrop_closed:  "Live and renounced. The airdrop is still CLOSED.",
  airdrop_open:         "The airdrop is open. Only distribution and verification remain.",
};
say(); say(`  ${B}${WHERE[state]}${R}`);

if (state === "partial") {
  die("Stopping: a partial deploy needs a human, not a script.",
      "Do NOT re-run the deploy. See LAUNCH.md §6 and the Troubleshooting table, finish the remaining\n  steps by hand, then run this again.");
}

if (state === "vault_unreadable") {
  die("Stopping: a read of the airdrop vault returned nothing.",
      "Either `MIGRATION_VAULT()` on the hook or `token()` on the vault gave no answer. That address holds\n"
    + "  89% of the supply, so this is not a state to guess at — a failing endpoint and a vault that is not\n"
    + "  what the hook thinks it is look identical from here. Re-run once the endpoint is healthy; if it\n"
    + "  persists, resolve it by hand against LAUNCH.md §10b rather than continuing.");
}

if (state === "live_no_airdrop") {
  say();
  ok("token live, ownerless, pool seeded");
  note("This hook has no migration vault, so there is no airdrop to open and nothing left to distribute.");
  note("Keep the fee keeper running (LAUNCH.md §10).");
  rl.close(); process.exit(0);
}

/** Print a signing command and run it with your terminal attached, so Foundry prompts you directly. */
async function signStep(title, argv, { verify, expect, env }) {
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
  let signer;
  if (how === "1") {
    // Ask which account. Foundry defaults to m/44'/60'/0'/0/0 — the FIRST account on the device — and a
    // deployer is very often not that one. Without this the wizard cannot reach a key on any other index at
    // all, and the operator learns that only when Foundry fails at the signing prompt, one keystroke after
    // the point-of-no-return gate.
    say();
    note("Which account on the device? Press Enter for the first, or give the path if your deployer is");
    note("elsewhere — m/44'/60'/0'/0/1 is the second; Ledger Live's second is m/44'/60'/1'/0/0.");
    const hdPath = (await rl.question("  Derivation path [m/44'/60'/0'/0/0]: ")).trim();
    signer = ["--ledger"];
    if (hdPath) {
      if (!/^m(\/\d+'?)+$/.test(hdPath)) {
        die(`"${hdPath}" is not a BIP-32 path.`, "Expected something like m/44'/60'/0'/0/1.");
      }
      signer.push("--hd-path", hdPath);
    }

    // Confirm the device holds the address that was typed, BEFORE any gate. This asks the Ledger the same
    // question forge is about to, so a wrong path or a wrong --sender is refused here, in the read-only
    // phase where every other configuration check in this system lives.
    say();
    note("Checking the device holds that address (confirm on the Ledger if it asks)…");
    const probe = ["wallet", "address", "--ledger"];
    if (hdPath) probe.push("--hd-path", hdPath);
    let onDevice;
    try {
      onDevice = execFileSync("cast", probe, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
    } catch (e) {
      die("Could not read an address from the Ledger.",
          redact([String(e.stderr ?? "").trim(), String(e.message ?? e).trim()]
            .filter(Boolean).join("\n").split("\n").slice(0, 3).join("\n"))
          + "\n  Is it plugged in, unlocked, with the Ethereum app open?");
    }
    if (onDevice.toLowerCase() !== sender.toLowerCase()) {
      die(`The Ledger holds ${onDevice} on that path, not ${sender}.`,
          "Either the derivation path is wrong or the deployer address is. Nothing has been signed — run\n"
        + "  again with the path that matches your deployer, or the address that matches your path.");
    }
    ok(`device holds ${onDevice}${hdPath ? ` at ${hdPath}` : " at the default path"}`);
  } else {
    signer = ["--account", (await rl.question("  Keystore account name: ")).trim()];
  }

  await gate(`About to BROADCAST: ${title}. This cannot be undone.`, "BROADCAST");
  // `env` carries the addresses the script reads from the environment. Passing them per-step, rather than
  // exporting them once, keeps each step's inputs visible at its own call site — and the scripts read them
  // with `vm.envAddress`, which aborts the whole run if one is missing, so a step that forgets one cannot
  // half-execute.
  broadcastStarted = true;
  run("forge", [...argv, "--sender", sender, ...signer, "--broadcast"], { env });

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
  note("240 tests, seventeen files of which fork mainnet through the endpoint above. A couple of minutes.");
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
    else run("sh", ["-c", "node merkle/make-env.mjs > .env.new && mv .env.new .env || { rm -f .env.new; exit 1; }"]);
  } else {
    run("sh", ["-c", "node merkle/make-env.mjs > .env.new && mv .env.new .env || { rm -f .env.new; exit 1; }"]);
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

  // No `verify` here, deliberately. `signStep` treats a verifier that returns nothing as a FAILED step, so
  // a placeholder `() => null` made a completely successful three-transaction deploy print a red cross and
  // "Fix the above and run again" — advice to repeat the one action in this whole procedure that must never
  // be repeated. The next run re-detects state from the chain, which is the real check.
  await signStep("6 · Broadcast the deploy (3 transactions)",
    ["script", "script/Deploy.s.sol", "--rpc-url", RPC, "--slow"], {});
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
  await signStep("9 · Renounce", ["script", "script/Renounce.s.sol", "--rpc-url", RPC], {
    env: { HOOK: hook },
    // Guard the reading before judging it. `isZeroAddr(null)` is true, so an endpoint that dies during this
    // step would otherwise print "confirmed on-chain: owner() is now the zero address" off the back of a
    // read that returned nothing — inventing the confirmation this line exists to provide.
    verify: () => {
      const o = castCall(hook, "owner()(address)");
      return o !== null && isZeroAddr(o) ? "owner() is now the zero address" : null;
    },
    expect: "owner() did not become zero, or could not be read.",
  });

  head("10 · Start the fee keeper");
  // The keeper, the share check and the airdrop push all `import … from "ethers"`, and `merkle/node_modules`
  // is gitignored — so on the tree the deploy was just run from, every one of them exits immediately with
  // ERR_MODULE_NOT_FOUND. Step 1 mentions `npm install` only for an optional reproducibility check, which
  // reads as "you can skip this". Say it here, where it is a prerequisite rather than a nicety.
  say(`  ${B}First: cd merkle && npm install${R} — the keeper needs it, and it is not installed by default.`);
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
  // The script re-checks this against the hook's own balance, so a wrong value fails closed rather than
  // wiring anything. Check it here anyway: an unreadable balance means the endpoint or the vault address is
  // wrong, and finding that out now is better than after typing the gate word for an irreversible step.
  if (!reserve || !/^[0-9]+$/.test(reserve) || reserve === "0") {
    die(`Could not read a reserve balance for the vault (got ${reserve === null ? "no answer" : `"${reserve}"`}).`,
        "Expected the vault to hold the airdrop reserve. Check the endpoint and see LAUNCH.md §10b.");
  }
  ok(`the vault holds ${reserve} wei — 89% of supply, currently not distributable`);
  say();
  say(`  ${B}This is the decision to put that supply into circulation. It cannot be undone.${R}`);
  note("Only the ~545 PRISM float has been tradeable until now. That was the point of waiting.");
  say();
  await gate("Has the interval you intended (10–24h) actually elapsed?", "YES IT HAS");

  await signStep("10b · Open the airdrop",
    ["script", "script/OpenAirdrop.s.sol", "--rpc-url", RPC],
    {
      env: { HOOK: hook, VAULT: vault, RESERVE: reserve },
      verify: () => (castCall(vault, "token()(address)")?.toLowerCase() === hook.toLowerCase()
        ? "vault is wired to the hook — the airdrop is open" : null),
      expect: "token() is not the hook.",
    });
  say();
  ok("nothing further needs the deploy key");
  note("Run `node launch.mjs` again to continue with the distribution.");
  rl.close(); process.exit(0);
}

// ── airdrop open: distribution and verification ──────────────────────────────────────────────────
head("11 · Distribute the airdrop");
say("  48 transactions, and they need NO privilege at all: the batcher is ownerless and `claim` always");
say("  pays the holder regardless of who calls. Use a throwaway hot wallet with gas only.");
note("Deploy the batcher first (LAUNCH.md §11), then run the push until it reports zero unpaid — it exits");
note("non-zero while anyone is still owed, so it is safe to wrap in a loop.");
say();
say(`    ${B}MIGRATION=${vault} forge script script/DeployBatcher.s.sol --rpc-url "$RPC_URL" --broadcast${R}`);
say(`    ${B}cd merkle && node push-airdrop.mjs --batcher <batcher> --dry-run${R}`);
note("This wizard stops short of the push on purpose: it is many transactions on a different wallet, and");
note("the runner already plans, dry-runs, resumes and refuses an infeasible plan better than a prompt can.");

head("11b · Who still needs to mirror");
note("Needs `cd merkle && npm install` first, as do the push above and the keeper — none of them run without it.");
say(`    ${B}cd merkle && node check-shares.mjs --hook ${hook} --migration ${vault} --rpc "$RPC_URL"${R}`);
note("Expect 5 addresses holding 288 unminted shares. `syncNFTs` is caller-only — nobody can do it for");
note("them, so this is outreach. It also names anyone never paid; check that first.");

head("Done");
ok("token live, ownerless, airdrop open");
note("Keep the keeper running. Re-run check-shares in a few days to see who still has not acted.");
rl.close();
