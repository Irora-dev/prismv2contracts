/**
 * `merkle/push-airdrop.mjs` — plan, delivery and exit codes.  node --test test/push-plan.test.mjs
 *
 * WHY THIS EXISTS. `forge test` cannot reach the airdrop runner — it is JavaScript — and the launch-state
 * suite covers only `launch.mjs`, so without this file nothing exercises the tool that actually delivers the
 * airdrop. The failures it has to catch are the quiet ones: a crash before a plan can print (an airdrop that
 * cannot be delivered at all), and an exit 0 while holders are still unpaid. Both look like success to a
 * wrapper, and a fork run is an expensive place to discover that a number is wrong.
 *
 * It runs the REAL runner as a subprocess against a stub JSON-RPC endpoint, so the control flow under test is
 * the shipped one and no chain, fork or key is involved. The stub speaks only the calls the runner makes,
 * hand-encoded rather than pulled from a library, so this file adds no dependency of its own — including the
 * keccak256 below, which exists because ethers rehashes the transaction it signed and rejects an
 * `eth_sendRawTransaction` reply whose hash does not match. `keccak256 agrees with known vectors` is the
 * test that keeps that hand-rolled hash honest; if it fails, every `Pushed` topic in this file is wrong.
 *
 * WHAT THESE TESTS COVER, and the change to the runner that each one must fail on:
 *   1 dry-run plan             — restoring the `rowGas(r, …)` crash, or inflating a gas constant past 2^24
 *   2 --chunk-gas too high     — dropping the proof that every planned chunk can finish
 *   3 fully paid, empty vault  — (the happy path; guards the exit code a wrapper loops on)
 *   4 --min-prism dust         — dropping the EARLY vault check
 *   5 claims subset            — dropping the EARLY vault check
 *   6 subset AFTER a delivery  — dropping the FINAL vault check   ← only reachable by sending
 *   7 chunk stopped short      — trusting the receipt instead of the `Pushed` event
 *   8 gasFloor stop, 0 failed  — marking a chunk that stopped part-way as complete
 *   9 nothing delivered        — advising a re-run that cannot converge
 *
 * Tests 6-9 send. The stub signs nothing itself: the runner signs with the anvil dev key passed via `--key`,
 * and the stub keccak-hashes the raw transaction it receives, so the hash the runner waits on is the real
 * one. No chain, still no dependency.
 *
 * The runner itself imports `ethers`, and `merkle/node_modules` is gitignored — so these tests SKIP rather
 * than fail when it is absent. `cd merkle && npm install` to run them for real.
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const ROOT = resolve(import.meta.dirname, "..");
const RUNNER = resolve(ROOT, "merkle", "push-airdrop.mjs");
const CLAIMS = resolve(ROOT, "airdrop", "claims.json");
const HAVE_ETHERS = existsSync(resolve(ROOT, "merkle", "node_modules", "ethers"));

// Lowercase throughout: ethers rejects a mixed-case address unless its EIP-55 checksum is right, and
// these are invented fixtures.
const VAULT = "0x5376b6db1c1d8df0a1f5bd4a5d0e4f7c9a2b3c4d";
const TOKEN = "0x349d3bf6a1b2c3d4e5f60718293a4b5c6d7e8a04";
const BATCHER = "0xa0d7127e3c8b1cf1cb2a4ee6b3f8d9c0e1a2b3c4";
// anvil's first dev key. Only the runner ever holds it; the stub never validates a signature.
const DEV_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

// Selectors the runner calls (verified with `cast sig`).
const SEL = {
  migration: "0x1705a3bd",
  token: "0xfc0c546a",
  balanceOf: "0x70a08231",
  pendingOf: "0x5f4ce0c0",
};

// ── keccak256, so the stub can answer a send with the hash ethers will demand ────────────────────
// ethers' `broadcastTransaction` re-derives the hash of the transaction it signed and throws if the node
// disagrees, so "return a deterministic hash" is not enough — it has to be keccak256 of the raw bytes.
// Keccak-f[1600], rate 136, original 0x01 padding (node's `sha3-256` is NOT this: different padding).
const MASK64 = (1n << 64n) - 1n;
const RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];
const ROT = [
  [0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
  [28, 55, 25, 21, 56], [27, 20, 39, 8, 14],
];
const rotl = (v, n) => (n === 0 ? v : ((v << BigInt(n)) | (v >> BigInt(64 - n))) & MASK64);

function keccakF(A) {
  for (let round = 0; round < 24; round++) {
    const C = [], D = [];
    for (let x = 0; x < 5; x++) C[x] = A[x] ^ A[x + 5] ^ A[x + 10] ^ A[x + 15] ^ A[x + 20];
    for (let x = 0; x < 5; x++) D[x] = C[(x + 4) % 5] ^ rotl(C[(x + 1) % 5], 1);
    for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) A[x + 5 * y] ^= D[x];
    const B = new Array(25).fill(0n);
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) B[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(A[x + 5 * y], ROT[x][y]);
    }
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        A[x + 5 * y] = B[x + 5 * y] ^ (~B[((x + 1) % 5) + 5 * y] & MASK64 & B[((x + 2) % 5) + 5 * y]);
      }
    }
    A[0] ^= RC[round];
  }
}

/** keccak256 of a Buffer, as a 0x-prefixed 32-byte hex string. */
function keccak256(bytes) {
  const RATE = 136;
  const buf = Buffer.concat([bytes, Buffer.alloc(RATE - (bytes.length % RATE))]);
  buf[bytes.length] |= 0x01;
  buf[buf.length - 1] |= 0x80;
  const A = new Array(25).fill(0n);
  for (let off = 0; off < buf.length; off += RATE) {
    for (let i = 0; i < RATE / 8; i++) A[i] ^= buf.readBigUInt64LE(off + i * 8);
    keccakF(A);
  }
  let hex = "0x";
  for (let i = 0; i < 4; i++) {
    const le = Buffer.alloc(8);
    le.writeBigUInt64LE(A[i]);
    hex += le.toString("hex");
  }
  return hex;
}

const utf8Hash = (s) => keccak256(Buffer.from(s, "utf8"));
// The runner decodes its results from events, so the topics have to be right to the bit.
const TOPIC_PUSHED = utf8Hash("Pushed(uint256,uint256,uint256,uint256)");
const TOPIC_ROW_FAILED = utf8Hash("RowFailed(uint256,address)");

/** A complete, valid-looking block: ethers rejects a partial one field by field. */
const BLOCK = {
  number: "0x1868000", hash: "0x" + "11".repeat(32), parentHash: "0x" + "22".repeat(32),
  timestamp: "0x68000000", gasLimit: "0x2255100", gasUsed: "0x0",
  baseFeePerGas: "0x3b9aca00", miner: "0x" + "00".repeat(20),
  difficulty: "0x0", totalDifficulty: "0x0", extraData: "0x", size: "0x0",
  transactions: [], uncles: [], nonce: "0x0000000000000000",
  sha3Uncles: "0x" + "00".repeat(32), logsBloom: "0x" + "00".repeat(256),
  transactionsRoot: "0x" + "00".repeat(32), stateRoot: "0x" + "00".repeat(32),
  receiptsRoot: "0x" + "00".repeat(32), mixHash: "0x" + "00".repeat(32),
};

const word = (hex) => hex.replace(/^0x/, "").padStart(64, "0");
const addrWord = (a) => word(a.toLowerCase());
const uintWord = (n) => word(BigInt(n).toString(16));
/** bool[] as a dynamic array: offset, length, then one word each. */
const boolArray = (flags) =>
  "0x" + uintWord(32) + uintWord(flags.length) + flags.map((f) => uintWord(f ? 1 : 0)).join("");

/**
 * The `Pushed` / `RowFailed` logs a real batcher would emit, hand-encoded. All four `Pushed` fields are
 * non-indexed, so they live in `data`, one word each, in declaration order.
 */
function pushedLogs(txHash, { delivered, alreadyClaimed = 0, failed = 0, stoppedAt, rowFailures = [] }) {
  const site = { address: BATCHER, blockHash: BLOCK.hash, blockNumber: BLOCK.number, transactionHash: txHash, transactionIndex: "0x0", removed: false };
  const logs = rowFailures.map(([index, account], i) => ({
    ...site, logIndex: "0x" + i.toString(16),
    topics: [TOPIC_ROW_FAILED],
    data: "0x" + uintWord(index) + addrWord(account),
  }));
  logs.push({
    ...site, logIndex: "0x" + logs.length.toString(16),
    topics: [TOPIC_PUSHED],
    data: "0x" + uintWord(delivered) + uintWord(alreadyClaimed) + uintWord(failed) + uintWord(stoppedAt),
  });
  return logs;
}

/**
 * A stub endpoint.
 *   `pending(amountWei, { sent, address })` decides who still needs paying — `sent` is how many transactions
 *      the stub has already accepted, so a test can make a delivery actually change the answer.
 *   `vaultBalance` is what the token reports for the vault, the authoritative "is anyone owed" reading.
 *   `push(n)` — if given, sends are accepted and the n-th one gets a status-1 receipt carrying these
 *      `Pushed` args. If absent, a send is refused, which is what every non-delivering test wants.
 */
async function withStubRpc({ pending, vaultBalance, push }, body) {
  const claims = JSON.parse(readFileSync(CLAIMS, "utf8")).claims;
  const amountOf = new Map(Object.entries(claims).map(([a, c]) => [a.toLowerCase(), BigInt(c.amount)]));
  const sent = [];   // raw transactions accepted, in order; index == nonce

  const server = createServer((req, res) => {
    let raw = "";
    req.on("data", (d) => (raw += d));
    req.on("end", () => {
      const reqs = JSON.parse(raw);
      const one = ({ method, params, id }) => {
        let result = null;
        if (method === "eth_chainId") result = "0x1";
        else if (method === "eth_blockNumber") result = "0x1868000";
        else if (method === "net_version") result = "1";
        // The dry run reads a block for its fee estimate, and ethers validates the whole shape.
        else if (method === "eth_getBlockByNumber" || method === "eth_getBlockByHash") result = BLOCK;
        else if (method === "eth_gasPrice" || method === "eth_maxPriorityFeePerGas") result = "0x3b9aca00";
        else if (method === "eth_estimateGas") result = "0x5208";
        // One nonce per accepted send, so consecutive chunks are distinct transactions.
        else if (method === "eth_getTransactionCount") result = "0x" + sent.length.toString(16);
        else if (method === "eth_sendRawTransaction") {
          if (!push) {
            return { jsonrpc: "2.0", id, error: { code: -32000, message: "stub: sends are not enabled for this test" } };
          }
          const bytes = Buffer.from(params[0].replace(/^0x/, ""), "hex");
          const hash = keccak256(bytes);              // exactly what ethers will re-derive and compare
          sent.push(hash);
          result = hash;
        } else if (method === "eth_getTransactionReceipt") {
          const n = sent.indexOf(params[0]);
          if (n === -1) result = null;                // unknown hash: not mined
          else {
            const args = push(n);
            result = {
              transactionHash: params[0], transactionIndex: "0x0",
              blockHash: BLOCK.hash, blockNumber: BLOCK.number,
              from: "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266", to: BATCHER,
              contractAddress: null, status: "0x1", type: "0x2",
              gasUsed: "0x" + BigInt(args.gasUsed ?? 500_000).toString(16),
              cumulativeGasUsed: "0x" + BigInt(args.gasUsed ?? 500_000).toString(16),
              effectiveGasPrice: "0x3b9aca00", logsBloom: "0x" + "00".repeat(256),
              logs: pushedLogs(params[0], args),
            };
          }
        } else if (method === "eth_call") {
          const data = params[0].data ?? params[0].input ?? "";
          const sel = data.slice(0, 10);
          if (sel === SEL.migration) result = "0x" + addrWord(VAULT);
          else if (sel === SEL.token) result = "0x" + addrWord(TOKEN);
          else if (sel === SEL.balanceOf) {
            // `vaultBalance: "fail"` makes the vault read error, which is a DIFFERENT fact from "empty".
            if (vaultBalance === "fail") {
              return { jsonrpc: "2.0", id, error: { code: -32005, message: "rate limit exceeded" } };
            }
            result = "0x" + uintWord(vaultBalance);
          }
          else if (sel === SEL.pendingOf) {
            // Decode the address[] argument: [offset][len][addr…]
            const b = data.slice(10);
            const len = Number(BigInt("0x" + b.slice(64, 128)));
            const addrs = [];
            for (let i = 0; i < len; i++) {
              addrs.push("0x" + b.slice(128 + i * 64 + 24, 128 + (i + 1) * 64));
            }
            result = boolArray(addrs.map((a) =>
              pending(amountOf.get(a.toLowerCase()) ?? 0n, { sent: sent.length, address: a.toLowerCase() })));
          } else result = "0x";
        } else result = "0x";
        return { jsonrpc: "2.0", id, result };
      };
      const out = Array.isArray(reqs) ? reqs.map(one) : one(reqs);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(out));
    });
  });

  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const url = `http://127.0.0.1:${server.address().port}`;
  try {
    return await body(url);
  } finally {
    await new Promise((r) => server.close(r));
  }
}

/**
 * Run the real runner. Must be ASYNC: `spawnSync` blocks this process's event loop, so the stub server above
 * could never answer the child's requests and both sides would wait forever.
 */
function runPush(url, extra = []) {
  return new Promise((res) => {
    const child = spawn("node", [RUNNER, "--batcher", BATCHER, "--rpc", url, ...extra], {
      cwd: resolve(ROOT, "merkle"),
      env: { ...process.env, PRIVATE_KEY: "" },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (out += d));
    const kill = setTimeout(() => child.kill("SIGKILL"), 60_000);
    child.on("close", (code) => { clearTimeout(kill); res({ code, out }); });
  });
}

/** Write a claims file holding only `rows` of the shipped tree, carrying the REAL root verbatim. */
async function subsetClaims(t, name, from, to) {
  const claims = JSON.parse(readFileSync(CLAIMS, "utf8"));
  const rows = Object.entries(claims.claims).slice(from, to);
  const path = resolve(ROOT, "merkle", name);
  const { writeFileSync, rmSync } = await import("node:fs");
  writeFileSync(path, JSON.stringify({ ...claims, claims: Object.fromEntries(rows), count: rows.length }));
  t.after(() => rmSync(path, { force: true }));
  const total = Object.values(claims.claims).reduce((s, c) => s + BigInt(c.amount), 0n);
  const mine = rows.reduce((s, [, c]) => s + BigInt(c.amount), 0n);
  return { name, rows, residual: total - mine };   // residual: what the vault owes everyone else
}

const ALL_PAID = () => false;
const ALL_PENDING = () => true;
const UNIT = 10n ** 18n;
// Three dust holders (< 1 PRISM each, so no NFT mint): they pack into a single transaction, which keeps
// the delivering tests to one send and one receipt.
const DUST = [420, 423];

describe("the stub's hand-rolled keccak256", () => {
  test("keccak256 agrees with known vectors", () => {
    assert.equal(keccak256(Buffer.alloc(0)), "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
    assert.equal(utf8Hash("abc"), "0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45");
    // Long enough to cross the 136-byte rate boundary, which one-block-only bugs pass.
    assert.equal(utf8Hash("a".repeat(1000)), "0xb6a4ac1f51884d71f30fa397a5e155de3099e11fc0edef5d08b646e621e19de9");
    // The two event topics this file encodes. Independently checked with `cast sig-event`.
    assert.equal(TOPIC_PUSHED, "0x7f6931f25a599f182b2293e74921dd3d69d27427ef4f54e0881510772846b1aa");
    assert.equal(TOPIC_ROW_FAILED, "0x8f12f1b79a90043442ccc883a11791e74221ecaf0096a8627f5fd26b11a2095b");
  });
});

describe("push-airdrop plan and exit codes", { skip: HAVE_ETHERS ? false : "merkle/node_modules/ethers absent — run `cd merkle && npm install`" }, () => {
  /**
   * The plan itself. This is the assertion that a crash-before-any-output cannot pass — `rowGas` takes an
   * amount, not a row, and passing the row throws "Cannot mix BigInt and other types" before anything prints.
   */
  test("a dry run prints a feasible plan for the whole shipped tree", async () => {
    const { code, out } = await withStubRpc(
      { pending: ALL_PENDING, vaultBalance: 4454677055887032075331n },
      (url) => runPush(url, ["--dry-run"]),
    );
    assert.equal(code, 0, out.slice(-400));
    assert.match(out, /1203 holders/);
    assert.match(out, /48 transaction/);
    assert.doesNotMatch(out, /Cannot mix BigInt/);
    assert.doesNotMatch(out, /cannot finish/);
  });

  /**
   * EIP-7825 from the operator's side. `--chunk-gas` is the knob an operator reaches for to cut the
   * transaction count, and above ~15.5M the packer produces chunks whose gas limit clamps to 2^24 while
   * their rows need more than that — a plan that would stop part-way and leave holders unpaid. The runner
   * proves each planned chunk can finish and REFUSES, which is the fail-safe direction. Deleting that proof
   * is the one change no other test here notices: the plan then prints and exit 0 invites the operator to
   * send it.
   */
  test("a chunk-gas that would strand rows is refused, not planned", async () => {
    const { code, out } = await withStubRpc(
      { pending: ALL_PENDING, vaultBalance: 4454677055887032075331n },
      (url) => runPush(url, ["--dry-run", "--chunk-gas", "30000000"]),
    );
    assert.match(out, /planned chunk\(s\) cannot finish within their own gas limit/, out.slice(-700));
    assert.match(out, /Lower --chunk-gas/, out.slice(-700));
    assert.notEqual(code, 0, `a plan that stops part-way was accepted:\n${out.slice(-700)}`);
    assert.doesNotMatch(out, /--dry-run: nothing sent/, out.slice(-700));
  });

  test("a fully paid tree with an empty vault exits 0", async () => {
    const { code, out } = await withStubRpc(
      { pending: ALL_PAID, vaultBalance: 0n },
      (url) => runPush(url),
    );
    assert.equal(code, 0, out.slice(-400));
    assert.match(out, /already been paid/);
  });

  /**
   * The `--min-prism` case: the subset is fully paid, the dust is not. Exiting 0 here would end a
   * loop-until-zero wrapper — which LAUNCH.md instructs — with 783 holders still owed.
   */
  test("--min-prism exits non-zero while the excluded dust holders are unpaid", async () => {
    const { code, out } = await withStubRpc(
      { pending: (amt) => amt < UNIT, vaultBalance: 3794492053683903665254n },
      (url) => runPush(url, ["--min-prism", "1"]),
    );
    assert.notEqual(code, 0, out.slice(-400));
    assert.match(out, /NOT been paid|still holds/);
  });

  /**
   * THE ONE THIS FILE WAS WRITTEN FOR. A claims file cannot audit itself: every other completion check
   * compares `rows` against `allRows`, and both are parsed from the same file. Point the runner at a
   * three-row subset and nothing inside the file contradicts "all 3 confirmed paid" — while the vault still
   * holds everything owed to everyone outside it. The vault's own balance is the only reading that comes
   * from outside the file, so it is the only one that can catch this.
   */
  test("a claims subset does not report success while the vault still holds a balance", async (t) => {
    const { name } = await subsetClaims(t, ".push-plan-subset.json", 0, 3);
    const { code, out } = await withStubRpc(
      { pending: ALL_PAID, vaultBalance: 3794492053683903665254n },
      (url) => runPush(url, ["--claims", name]),
    );
    assert.notEqual(code, 0, `expected non-zero while the vault is non-empty:\n${out.slice(-500)}`);
    assert.match(out, /still holds/);
  });

  /**
   * "I could not read it" is not "it is empty". Both call sites treat a missing objection as no objection, so
   * a vault read that returned null on failure would let a single rate-limited `balanceOf` silence the veto
   * and exit 0 over a subset file with holders unpaid — and a 429 during a 48-transaction push is ordinary.
   * The only safe direction is to refuse to claim completion on a reading that never arrived.
   */
  test("an unreadable vault balance refuses to report completion", async (t) => {
    const { name } = await subsetClaims(t, ".push-plan-unread.json", 0, 3);
    const { code, out } = await withStubRpc(
      { pending: ALL_PAID, vaultBalance: "fail" },
      (url) => runPush(url, ["--claims", name]),
    );
    assert.match(out, /COULD NOT READ the vault balance/, out.slice(-600));
    assert.notEqual(code, 0, `exit 0 on a vault reading that never arrived:\n${out.slice(-600)}`);
  });

  /**
   * THE SAME DEFECT ON THE OTHER PATH. The check above lives in TWO places: the early return for "nobody in
   * this file is pending", and the final verification after the sends. The test above only reaches the first, because
   * its subset is already paid. This one delivers first — the three rows really are outstanding, the stub
   * accepts the transaction and returns a receipt whose `Pushed` event says all three landed — and only then
   * does the runner ask the vault, which still holds what the other 1200 holders are owed. Deleting the
   * final copy of the check turns this into a clean exit 0 reporting "all 3 confirmed paid".
   */
  test("a delivery does not report success while the vault still holds a balance", async (t) => {
    const { name, rows, residual } = await subsetClaims(t, ".push-plan-delivered.json", ...DUST);
    assert.equal(rows.length, 3);
    // Outstanding until the stub accepts a transaction; paid afterwards. That is what puts the runner in the
    // final verification block with `stillPending === 0`, which nothing else in this file can do.
    const { code, out } = await withStubRpc(
      {
        pending: (_amt, { sent }) => sent === 0,
        vaultBalance: residual,
        push: () => ({ delivered: 3, alreadyClaimed: 0, failed: 0, stoppedAt: 3, gasUsed: 214_472 }),
      },
      (url) => runPush(url, ["--claims", name, "--key", DEV_KEY, "--yes"]),
    );
    // The delivery must really have happened, or this test would be re-testing the early exit.
    assert.match(out, /1 transaction\(s\)/, out.slice(-600));
    assert.match(out, /delivered 3, already 0, failed 0, stopped at 3\/3/, out.slice(-600));
    assert.match(out, /all 3 confirmed paid/, out.slice(-600));
    assert.match(out, /done: 3 delivered/, out.slice(-600));
    // …and the vault must still veto the success it would otherwise have reported.
    assert.match(out, new RegExp(`vault still holds ${residual} wei`), out.slice(-600));
    assert.notEqual(code, 0, `exit 0 after delivering 3 of 1203 holders:\n${out.slice(-600)}`);
  });

  /**
   * A chunk that runs out of gas part-way delivers some rows and stops. The batcher reports that through the
   * `Pushed` event, not through the receipt — a status-1 receipt says only that the transaction did not
   * revert — so a runner that trusts the receipt reports a finished airdrop. Here 2 of 3 land, row 2 fails,
   * and the vault is empty (nothing else is owed), so the only thing keeping the exit code honest is the
   * unpaid row.
   */
  test("a chunk that stops short is reported from the event and exits non-zero", async (t) => {
    const { name, rows } = await subsetClaims(t, ".push-plan-short.json", ...DUST);
    const lastAddr = rows[2][0];
    const { code, out } = await withStubRpc(
      {
        // The row that failed stays pending after the send; the two that landed do not. Matched by
        // ADDRESS, not amount: two of these three dust holders are owed the same wei.
        pending: (_amt, { sent, address }) => sent === 0 || address === lastAddr.toLowerCase(),
        vaultBalance: 0n,
        push: () => ({ delivered: 2, alreadyClaimed: 0, failed: 1, stoppedAt: 2, rowFailures: [[2, lastAddr]] }),
      },
      (url) => runPush(url, ["--claims", name, "--key", DEV_KEY, "--yes"]),
    );
    assert.match(out, /row 2 failed: /, out.slice(-600));
    assert.match(out, /delivered 2, already 0, failed 1, stopped at 2\/3/, out.slice(-600));
    assert.match(out, /1 of 3 still unpaid/, out.slice(-600));
    assert.match(out, /1 row\(s\) were attempted and did not deliver/, out.slice(-600));
    // Something DID deliver, so a re-run converges and the runner should say so.
    assert.match(out, /Re-run this command to finish them/, out.slice(-600));
    assert.notEqual(code, 0, `exit 0 with a holder unpaid:\n${out.slice(-600)}`);
  });

  /**
   * The documented real stop mode, which has no failed rows at all: the batcher checks `gasFloor` and stops
   * before STARTING a row it cannot finish, so a chunk delivers 169 of 177 with `failed = 0` and a status-1
   * receipt. Nothing about that transaction looks wrong; only `stoppedAt < rows` says the pass did not
   * complete. The runner must mark that line `!` rather than `✓`, because an operator scanning 48 lines for a
   * problem reads the marker, not the numbers.
   */
  test("a chunk stopped by gasFloor with no failed rows is still marked as short", async (t) => {
    const { name, rows } = await subsetClaims(t, ".push-plan-floor.json", ...DUST);
    const lastAddr = rows[2][0];
    const { code, out } = await withStubRpc(
      {
        pending: (_amt, { sent, address }) => sent === 0 || address === lastAddr.toLowerCase(),
        vaultBalance: 0n,
        // delivered 2, failed 0, stopped at 2 of 3 — the row was never entered, so it never failed.
        push: () => ({ delivered: 2, alreadyClaimed: 0, failed: 0, stoppedAt: 2 }),
      },
      (url) => runPush(url, ["--claims", name, "--key", DEV_KEY, "--yes"]),
    );
    assert.match(out, /! gas [\d,]+ — delivered 2, already 0, failed 0, stopped at 2\/3/, out.slice(-700));
    assert.doesNotMatch(out, /✓ gas [\d,]+ — delivered 2/, out.slice(-700));
    assert.match(out, /1 of 3 still unpaid/, out.slice(-700));
    assert.notEqual(code, 0, `exit 0 with a holder never attempted:\n${out.slice(-700)}`);
  });

  /**
   * The opposite advice, and the reason the distinction exists: when NOTHING delivered, re-running repeats
   * the same result forever. That is what a proof which does not verify against the deployed root looks
   * like, and telling the operator to "re-run to finish" turned it into an infinite loop.
   */
  test("a run that delivered nothing does not advise a re-run that cannot converge", async (t) => {
    const { name } = await subsetClaims(t, ".push-plan-nothing.json", ...DUST);
    const { code, out } = await withStubRpc(
      {
        pending: ALL_PENDING,
        vaultBalance: 0n,
        push: () => ({ delivered: 0, alreadyClaimed: 0, failed: 3, stoppedAt: 3 }),
      },
      (url) => runPush(url, ["--claims", name, "--key", DEV_KEY, "--yes"]),
    );
    assert.match(out, /3 of 3 still unpaid/, out.slice(-600));
    assert.match(out, /NOTHING was delivered this run/, out.slice(-600));
    assert.doesNotMatch(out, /Re-run this command to finish them/, out.slice(-600));
    assert.notEqual(code, 0, `exit 0 having delivered nothing:\n${out.slice(-600)}`);
  });
});
