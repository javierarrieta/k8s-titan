#!/usr/bin/env bash
# tesla-forwarder-tests.sh — prove the shipped forwarder script actually works, without a cluster,
# a car, or Redis installed.
#
# Why this exists as a file rather than a step in a plan: the forwarder is the only hand-written code
# in this deployment, it runs from a ConfigMap rather than an image, and every failure mode it has is
# silent. The bridge answers 200 to an unparseable body. fleet-telemetry publishes to a channel whose
# name contains literal braces. A RESP parser that returns a decoded string instead of a Buffer
# corrupts flatbuffers payloads without any layer noticing. None of that shows up in `make check`
# unless someone puts it here.
#
# Two layers, both against the artifact that actually ships — the JS is read out of
# apply/50-apps/tesla/forwarder.yaml, not from a copy that could drift:
#   1. the RESP parser, driven directly (framing, partial reads, binary safety)
#   2. the whole process, spawned for real against a fake Redis and a fake bridge on localhost
#
# Skips out loud when node is absent, the same way `make scan` skips when ggshield is: a gate that
# passes because the tool was missing is worse than no gate.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

MANIFEST=apply/50-apps/tesla/forwarder.yaml

if ! command -v node >/dev/null; then
  echo "tesla-forwarder-tests: SKIPPED - node is not on PATH"
  exit 0
fi
[ -f "$MANIFEST" ] || { echo "FAIL: $MANIFEST missing - nothing to test"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- extract the shipped script ---------------------------------------------------------------
python3 - "$MANIFEST" "$WORK/forwarder.js" <<'PY'
import sys, yaml
want = None
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc.get("kind") == "ConfigMap" and "tesla-forwarder.js" in (doc.get("data") or {}):
        want = doc["data"]["tesla-forwarder.js"]
if want is None:
    sys.exit("FAIL: no ConfigMap carrying data['tesla-forwarder.js'] in " + sys.argv[1])
open(sys.argv[2], "w").write(want)
PY

# Everything above `// Serialised:` is pure functions with no side effects, so it can be required
# without opening a socket. That split is a contract this test depends on; if the script is ever
# reorganised so the parser sits below the connect logic, this fails loudly rather than testing
# nothing.
python3 - "$WORK/forwarder.js" "$WORK/parser.js" <<'PY'
import sys
src = open(sys.argv[1]).read()
head = src.split("// Serialised:")[0]
if "function read(" not in head or "function encode(" not in head:
    sys.exit("FAIL: the parser is no longer above the '// Serialised:' marker - this test's split is stale")
open(sys.argv[2], "w").write(head + "\nmodule.exports = { read, encode };\n")
PY

echo "--- layer 1: the RESP parser ---"
cat > "$WORK/parser.test.js" <<'JS'
const assert = require("node:assert");
const { read, encode } = require(process.argv[2]);
const mk = (...p) => Buffer.from(encode(...p));
let n = 0;
const t = (name, fn) => { fn(); n++; console.log("  ok - " + name); };

t("a full pmessage is consumed exactly", () => {
  const buf = mk("pmessage", "tesla_telemetry_V_*", "tesla_telemetry_V_{TEST}", "hi");
  const [v, used] = read(buf, 0);
  assert.strictEqual(used, buf.length);
  assert.strictEqual(v.length, 4);
  // Elements come back as Buffers, so `v[0] === "pmessage"` is false and only .toString() works.
  // handle() in the shipped script depends on that; this assert is here so nobody "simplifies" it.
  assert.ok(Buffer.isBuffer(v[0]));
  assert.strictEqual(v[0].toString(), "pmessage");
  assert.strictEqual(v[3].toString(), "hi");
});

t("an incomplete reply returns null instead of throwing or losing data", () => {
  const buf = mk("pmessage", "*", "ch:x", "payload");
  assert.strictEqual(read(buf.subarray(0, 20), 0), null);
});

t("two replies coalesced into one TCP read are both parsed", () => {
  const one = mk("pmessage", "*", "ch:x", '{"a":1}');
  const two = Buffer.concat([one, one]);
  const a = read(two, 0);
  const b = read(two, a[1]);
  assert.strictEqual(a[0][3].toString(), '{"a":1}');
  assert.strictEqual(b[0][3].toString(), '{"a":1}');
});

t("+simple, :integer and -error are handled", () => {
  assert.strictEqual(read(Buffer.from("+PONG\r\n"), 0)[0], "PONG");
  assert.strictEqual(read(Buffer.from(":42\r\n"), 0)[0], "42");
  assert.match(String(read(Buffer.from("-ERR nope\r\n"), 0)[0]), /nope/);
});

t("a bulk string survives invalid UTF-8 byte for byte", () => {
  // The reason the parser returns Buffer at all. If transmit_decoded_records is ever turned off the
  // payload is flatbuffers, and a string round-trip would replace these bytes with U+FFFD while
  // every layer still reported success.
  const bin = Buffer.from([0xc3, 0x28, 0xa0, 0x00, 0xff]);
  let s = "*4\r\n";
  for (const p of ["pmessage", "*", "ch:x"]) s += `$${Buffer.byteLength(p)}\r\n${p}\r\n`;
  s += `$${bin.length}\r\n`;
  const buf = Buffer.concat([Buffer.from(s, "utf8"), bin, Buffer.from("\r\n")]);
  const [v, used] = read(buf, 0);
  assert.strictEqual(used, buf.length);
  assert.ok(Buffer.isBuffer(v[3]));
  assert.ok(v[3].equals(bin), `bytes mangled: ${[...v[3]]}`);
});
console.log(`  ${n} parser assertions passed`);
JS
node "$WORK/parser.test.js" "$WORK/parser.js"

echo "--- layer 2: the whole process, against a fake redis and a fake bridge ---"
cat > "$WORK/e2e.test.js" <<'JS'
const assert = require("node:assert");
const net = require("node:net");
const http = require("node:http");
const { spawn } = require("node:child_process");

const PAYLOAD = JSON.stringify({
  vin: "TESTVIN",
  createdAt: "2026-10-16T12:00:00Z",
  data: [{ key: "VehicleSpeed", value: { doubleValue: 42.5 } }],
});
const CHANNEL = "tesla_telemetry_V_{TESTVIN}";
const PATTERN = "tesla_telemetry_V_*";

const posts = [];
const bridge = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    posts.push(body);
    res.writeHead(200, { "content-type": "application/json" });
    res.end('{"status":"ok"}');
  });
});

// The minimum a redis server has to do for PSUBSCRIBE: accept AUTH, acknowledge the subscribe, then
// push one pmessage. Anything the forwarder sends that this does not understand is a test failure,
// not something to swallow - a script that wrote a malformed command would otherwise pass.
// Replies are built with the same RESP encoder the forwarder uses, because the first version of this
// test hand-counted `$9` for "psubscribe" (ten characters), desynced the parser, and the forwarder
// correctly threw the garbage away - which is the forwarder working, and the test being wrong.
const resp = (...parts) => {
  let out = `*${parts.length}\r\n`;
  for (const p of parts) out += `$${Buffer.byteLength(String(p))}\r\n${p}\r\n`;
  return out;
};
const seen = [];
const fakeRedis = net.createServer((sock) => {
  let buf = "";
  sock.on("data", (c) => {
    buf += c.toString("latin1");
    if (buf.includes("PSUBSCRIBE")) {
      seen.push(buf);
      sock.write(resp("psubscribe", PATTERN, 1));
      setTimeout(() => sock.write(resp("pmessage", PATTERN, CHANNEL, PAYLOAD)), 50);
    }
  });
});

const listen = (s) => new Promise((r) => s.listen(0, "127.0.0.1", r));

(async () => {
  await listen(bridge);
  await listen(fakeRedis);
  const health = 8080 + Math.floor(Math.random() * 500);
  const child = spawn(process.execPath, [process.argv[2]], {
    env: {
      ...process.env,
      REDIS_HOST: "127.0.0.1",
      REDIS_PORT: String(fakeRedis.address().port),
      BRIDGE_URL: "http://127.0.0.1:" + bridge.address().port + "/",
      PATTERN,
      HEALTH_PORT: String(health),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let out = "";
  child.stdout.on("data", (d) => (out += d));
  child.stderr.on("data", (d) => (out += d));

  const deadline = Date.now() + 8000;
  while (posts.length === 0 && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 100));
  }

  let failed = null;
  try {
    assert.deepStrictEqual(seen.length, 1, "forwarder sent exactly one startup command set");
    assert.match(seen[0], /PSUBSCRIBE/, "it subscribes before it does anything else");
    assert.strictEqual(posts.length, 1, "exactly one frame forwarded");
    const body = JSON.parse(posts[0]);
    // The shape the bridge's POST handler requires: req.body.message.data, base64, decoding to JSON
    // with a `vin`. Anything else and the bridge logs "Bad POST body" and answers 200 anyway.
    assert.ok(body.message && typeof body.message.data === "string", "body is {message:{data}}");
    assert.strictEqual(Buffer.from(body.message.data, "base64").toString("utf8"), PAYLOAD,
      "the payload arrives byte-for-byte, not re-encoded");
    assert.strictEqual(JSON.parse(Buffer.from(body.message.data, "base64").toString("utf8")).vin,
      "TESTVIN", "the bridge can recover the VIN, which is how it routes the frame");

    const healthBody = await new Promise((res, rej) =>
      http.get({ host: "127.0.0.1", port: health, path: "/" }, (r) => {
        let b = ""; r.on("data", (c) => (b += c)); r.on("end", () => res({ code: r.statusCode, b }));
      }).on("error", rej));
    assert.strictEqual(healthBody.code, 200, "health endpoint reports 200 while connected");
    const h = JSON.parse(healthBody.b);
    assert.strictEqual(h.connected, true, "health says connected");
    assert.ok(h.forwarded >= 1, "health counts what it forwarded");
  } catch (e) {
    failed = e;
  }

  child.kill();
  bridge.close();
  fakeRedis.close();
  if (failed) {
    console.error(out);
    throw failed;
  }
  console.log("  ok - redis frame reached the bridge with the exact body the bridge requires");
})();
JS
node "$WORK/e2e.test.js" "$WORK/forwarder.js"

echo "tesla-forwarder-tests: all passed"
