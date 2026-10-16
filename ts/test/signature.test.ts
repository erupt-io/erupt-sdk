import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { signRequest, verifySignature } from "../src/index.js";

// computed by the Java reference, CloudSignature; the test runs from ts/dist/test
const doc = JSON.parse(readFileSync(join(import.meta.dirname, "..", "..", "..", "conformance", "signature-vectors.json"), "utf8"));

test("signatures match the Java vectors", () => {
  for (const v of doc.vectors) {
    const body = v.body === null ? null : Buffer.from(v.body, "utf8");
    assert.equal(signRequest(doc.accessToken, v.method, v.pathAndQuery, v.timestamp, v.enforced, v.user, body), v.signature, v.case);
    const ts = String(v.timestamp);
    assert.ok(verifySignature(doc.accessToken, v.method, v.pathAndQuery, ts, v.enforced, v.user, body, v.signature, v.timestamp + 300), v.case);
    assert.ok(!verifySignature(doc.accessToken, v.method, v.pathAndQuery, ts, v.enforced, v.user, body, v.signature, v.timestamp + 301), v.case);
  }
});
