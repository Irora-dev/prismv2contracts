/**
 * `launch.mjs` state detection — run with:  node --test test/launch-state.test.mjs
 *
 * Uses only Node builtins, deliberately: the deploy path needs no `npm install` and this must not be the
 * thing that changes that.
 *
 * WHY THIS EXISTS. `launch.mjs` decides which of the launch's five signatures to offer by reading chain
 * state, and two of those signatures are irreversible. A misclassification is therefore the whole risk of
 * the file — not a crash, but confidently pointing the operator at the wrong step. The pair that matters
 * most is "the vault read failed" versus "there is no vault": they are one character apart in the code and
 * opposite in meaning, and conflating them ends the wizard with congratulations while 89% of the supply
 * sits unwired.
 *
 * Rather than testing a copy of the logic, this runs the real `launch.mjs` with stub `cast` and `forge`
 * binaries ahead of it on PATH, so the classification under test is the shipped one. No network, no chain.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const LAUNCH = resolve(import.meta.dirname, "..", "launch.mjs");
const ZERO = "0x" + "0".repeat(40);
const VAULT = "0x5376b6dB1c1D8dF0A1f5Bd4A5D0E4F7c9A2b3C4d";
const HOOK = "0x349D3bf6A1b2C3d4E5f60718293A4b5C6d7E8a04";

/** A stub `cast`/`forge`. Answers are looked up by function signature; the string "FAIL" exits non-zero,
 *  which is how `castCall` observes an unreachable endpoint. */
const STUB = `#!/usr/bin/env node
const a = process.argv.slice(2);
if (a[0] === "--version") { console.log("stub"); process.exit(0); }
if (a[0] === "chain-id") { console.log(process.env.STUB_CHAIN ?? "1"); process.exit(0); }
if (a[0] === "code") {
  const v = process.env.STUB_CODE ?? "0x6080604052";
  if (v === "FAIL") { console.error("Error: stub endpoint down"); process.exit(1); }
  console.log(v); process.exit(0);
}
if (a[0] === "call") {
  const answers = JSON.parse(process.env.STUB_ANSWERS);
  const v = answers[a[2]];
  if (v === undefined || v === "FAIL") { console.error("Error: stub has no answer"); process.exit(1); }
  console.log(v); process.exit(0);
}
process.exit(0);
`;

/** Run the real launch.mjs against stub binaries in a throwaway cwd holding a broadcast artifact. */
function runLaunch(answers, { artifact = true, chain = "1", code = undefined, input = "" } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "launch-state-"));
  const bin = join(dir, "bin");
  mkdirSync(bin);
  for (const name of ["cast", "forge"]) {
    writeFileSync(join(bin, name), STUB);
    chmodSync(join(bin, name), 0o755);
  }
  if (artifact) {
    const bd = join(dir, "broadcast", "Deploy.s.sol", "1");
    mkdirSync(bd, { recursive: true });
    // tx0 = vault, tx1 = hook. The vault entry is deliberately a WRONG address here: the file under test
    // is supposed to take the vault from the hook on-chain, so a test that agreed with the artifact could
    // not tell the two sources apart.
    writeFileSync(join(bd, "run-latest.json"), JSON.stringify({
      transactions: [{ contractAddress: "0xdeadbeef00000000000000000000000000000001" },
                     { contractAddress: HOOK }],
    }));
  }
  const r = spawnSync("node", [LAUNCH], {
    cwd: dir,
    input,
    encoding: "utf8",
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      RPC_URL: "https://stub.invalid/key",
      ETH_RPC_URL: "https://stub.invalid/key",
      STUB_ANSWERS: JSON.stringify(answers),
      STUB_CHAIN: chain,
      ...(code === undefined ? {} : { STUB_CODE: code }),
    },
  });
  // Strip ANSI so assertions read against the words the operator sees.
  return ((r.stdout ?? "") + (r.stderr ?? "")).replace(/\x1b\[[0-9;]*m/g, "");
}

const seededLive = { "seeded()(bool)": "true", "owner()(address)": ZERO };

/**
 * With no broadcast record the wizard cannot know whether this is a first launch or a resume from a clean
 * checkout, so it must ASK rather than assume. Blank means "first launch", and that assertion has to be
 * signed for: inferring it silently ends in a second complete 5,000 PRISM system.
 */
test("no artifact asks whether a hook already exists, and does not assume fresh", () => {
  const out = runLaunch(seededLive, { artifact: false });
  assert.match(out, /No broadcast record found/);
  assert.match(out, /Hook address from a previous run/);
  // It must not have reached the fresh-launch offer without the confirmation.
  assert.doesNotMatch(out, /Build and test/);
});

/**
 * Adoption must CLASSIFY in the same run. Asserting only that the address was adopted and that a re-run was
 * suggested is ALSO true of an infinite loop -- adopt, tell the operator to re-run, persist nothing, ask the
 * same question next time, leaving no way out but to claim nothing is deployed about a live system. So assert
 * that this run reaches a real state.
 */
test("no artifact plus a prior hook address adopts it and classifies in the same run", () => {
  const out = runLaunch({ ...seededLive, "owner()(address)": HOOK, "MIGRATION_VAULT()(address)": VAULT,
    "token()(address)": ZERO, "balanceOf(address)(uint256)": "1000000004 [1e9]" },
    { artifact: false, input: `${HOOK}\n` });
  assert.match(out, new RegExp(`adopted ${HOOK}`, "i"));
  // The point: it reaches a real state this run, rather than asking to be run again.
  assert.match(out, /Deployed and seeded\. Ownership is still held/);
  assert.doesNotMatch(out, /Re-run this command now/);
  assert.doesNotMatch(out, /Build and test/);
});

/** Adopting an address must not then ask the operator to swear nothing is deployed. */
test("adopting a hook does not also demand the nothing-is-deployed confirmation", () => {
  const out = runLaunch({ ...seededLive, "MIGRATION_VAULT()(address)": VAULT, "token()(address)": HOOK },
    { artifact: false, input: `${HOOK}\n` });
  assert.doesNotMatch(out, /NOTHING IS DEPLOYED/);
  assert.match(out, /airdrop is open/);
});

/** Code at the address is not enough: a bare code-length test accepts WETH with a green tick. */
test("an address with code that is not a PRISM hook is refused", () => {
  const out = runLaunch({ "seeded()(bool)": "FAIL", "owner()(address)": ZERO },
    { artifact: false, input: `${HOOK}\n` });
  assert.match(out, /does not answer like a PRISM v2 hook/);
  assert.doesNotMatch(out, /adopted/);
});

// What is NOT tested here, and why. Answering the confirmation gate needs a second sequential prompt, and
// a piped stdin cannot deliver one: readline consumes the whole buffer at the first `question`, and any
// line arriving while no question is pending is DROPPED. That is a genuine safety property of the wizard --
// typed-ahead input can never pre-answer an irreversible gate -- so it is worth keeping rather than working
// around. Verify the gate itself interactively, on a real terminal; the test above pins the part that matters
// most here: the fresh-launch path is not reachable without it.

test("seeded but still owned offers the renounce, not the airdrop", () => {
  const out = runLaunch({ ...seededLive, "owner()(address)": HOOK, "MIGRATION_VAULT()(address)": VAULT,
    "token()(address)": ZERO, "balanceOf(address)(uint256)": "1000000004 [1e9]" });
  assert.match(out, /Deployed and seeded\. Ownership is still held/);
});

test("unseeded hook stops for a human and never offers a signature", () => {
  const out = runLaunch({ "seeded()(bool)": "false", "owner()(address)": HOOK,
    "MIGRATION_VAULT()(address)": VAULT, "token()(address)": ZERO });
  assert.match(out, /partial deploy/);
  assert.doesNotMatch(out, /BROADCAST/);
});

test("renounced with an unwired vault is the airdrop-closed state", () => {
  const out = runLaunch({ ...seededLive, "MIGRATION_VAULT()(address)": VAULT,
    "token()(address)": ZERO, "balanceOf(address)(uint256)": "4454677055887032075331 [4.454e21]" });
  assert.match(out, /airdrop is still CLOSED/);
  // The reserve is echoed as a number the next step can consume, not as cast's annotated form. That string
  // is passed to `vm.envUint`, which rejects the brackets outright.
  assert.match(out, /vault holds 4454677055887032075331 wei/);
  assert.doesNotMatch(out, /4\.454e21/);
});

test("a wired vault is the airdrop-open state", () => {
  const out = runLaunch({ ...seededLive, "MIGRATION_VAULT()(address)": VAULT, "token()(address)": HOOK });
  assert.match(out, /airdrop is open/);
});

test("the vault comes from the hook, not from the broadcast artifact", () => {
  const out = runLaunch({ ...seededLive, "MIGRATION_VAULT()(address)": VAULT,
    "token()(address)": ZERO, "balanceOf(address)(uint256)": "4454677055887032075331" });
  assert.match(out, new RegExp(`vault ${VAULT}`));
  assert.doesNotMatch(out, /0xdeadbeef/);
});

test("a hook with no vault is complete, and is not offered an airdrop to open", () => {
  const out = runLaunch({ ...seededLive, "MIGRATION_VAULT()(address)": ZERO });
  assert.match(out, /no airdrop vault/);
  assert.doesNotMatch(out, /airdrop is still CLOSED/);
});

/**
 * The finding this file was written for. A failed read and a zero answer must not collapse into the same
 * state: "no vault" ends the wizard successfully, so a momentary endpoint failure would otherwise tell an
 * operator holding a closed airdrop that the launch is finished.
 */
/**
 * `token()(address)` is answered here on purpose. Without it, this test still passed with the
 * `vaultRead === "failed"` branch deleted, because the later `token === null` branch produced the stop
 * instead — so it named one branch and pinned another. Answering `token()` isolates the branch under test.
 */
test("a failed MIGRATION_VAULT read stops, and is never read as having no airdrop", () => {
  const out = runLaunch({ ...seededLive, "MIGRATION_VAULT()(address)": "FAIL", "token()(address)": ZERO });
  assert.match(out, /did not answer/);
  assert.doesNotMatch(out, /no airdrop vault/);
  assert.doesNotMatch(out, /launch is complete/);
});

test("a vault that answers MIGRATION_VAULT but not token() also stops", () => {
  const out = runLaunch({ ...seededLive, "MIGRATION_VAULT()(address)": VAULT, "token()(address)": "FAIL" });
  assert.match(out, /did not answer/);
  assert.doesNotMatch(out, /airdrop is still CLOSED/);
});

test("a non-mainnet endpoint is refused before anything is read", () => {
  const out = runLaunch(seededLive, { chain: "11155111" });
  assert.match(out, /not Ethereum mainnet/);
});

/**
 * The rest of the "a failed read is not an answer" family. Each of these readings, left unchecked,
 * classifies the launch on a value the endpoint never actually returned.
 */
test("an unreadable owner() never reads as already-renounced", () => {
  const out = runLaunch({ "seeded()(bool)": "true", "owner()(address)": "FAIL",
    "MIGRATION_VAULT()(address)": VAULT, "token()(address)": ZERO });
  assert.match(out, /did not answer owner\(\)/);
  // The dangerous outcomes: skipping past the renounce to opening the airdrop, or declaring the job done.
  assert.doesNotMatch(out, /airdrop is still CLOSED/);
  assert.doesNotMatch(out, /Open the airdrop/);
});

test("an unreadable seeded() is not treated as unseeded or as fresh", () => {
  const out = runLaunch({ "seeded()(bool)": "FAIL", "owner()(address)": HOOK });
  assert.match(out, /did not answer seeded\(\)/);
  assert.doesNotMatch(out, /Nothing deployed/);
  assert.doesNotMatch(out, /partial deploy/);
});

test("an endpoint that cannot answer `cast code` never reads as nothing-deployed", () => {
  const out = runLaunch(seededLive, { code: "FAIL" });
  assert.match(out, /Could not ask the endpoint/);
  // The one that matters most: "Nothing deployed" is the road to a second complete deploy.
  assert.doesNotMatch(out, /Nothing deployed/);
});

/**
 * An artifact naming an address with NO CODE is not evidence of a fresh start. It happens when a failed
 * hand-run broadcast overwrites `run-latest.json` after a successful launch: the record then points somewhere
 * empty while the real system is live. Without the code check that state skips the interrogation entirely --
 * `hook` is truthy and not a dry run -- and offers a deploy with no confirmation at all. It must ask.
 */
test("an artifact pointing at an empty address asks rather than assuming fresh", () => {
  const out = runLaunch(seededLive, { code: "0x" });
  assert.match(out, /Hook address from a previous run/);
  // The dangerous outcome: walking into the fresh-launch offer with no gate.
  assert.doesNotMatch(out, /Build and test/);
});

// The follow-on case -- that this state still reaches a fresh launch once the gate is answered -- is not
// testable here: it needs a second sequential prompt, and a piped stdin cannot deliver one (readline drains
// the buffer at the first `question` and drops anything arriving while none is pending). That is a safety
// property worth keeping, not a bug. Check it by hand on a real terminal instead.
