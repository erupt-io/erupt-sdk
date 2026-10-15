// Erupt-Signature (erupt-cloud/PROTOCOL.md §4.3): an HMAC-SHA256 the server puts on every forward, keyed by
// the node's access token, so the token need not travel and the signed headers cannot be forged.
import { createHash, createHmac, timingSafeEqual } from "node:crypto";

export const WINDOW_SECONDS = 300;
const UNSIGNED_PAYLOAD = "UNSIGNED-PAYLOAD";

const sha256 = (data: Buffer | string) => createHash("sha256").update(data).digest("hex");

/** `body` is the raw bytes, or null for a multipart upload the server re-encodes (not covered). */
export function sign(accessToken: string, method: string, pathAndQuery: string, timestamp: number | string,
                     enforced: string | null | undefined, user: string | null | undefined, body: Buffer | null): string {
  const canonical = [method.toUpperCase(), pathAndQuery, String(timestamp), enforced ?? "", sha256(user ?? ""),
    body === null ? UNSIGNED_PAYLOAD : sha256(body)].join("\n");
  return createHmac("sha256", accessToken).update(canonical).digest("hex");
}

export function verify(accessToken: string, method: string, pathAndQuery: string, timestamp: string | null | undefined,
                       enforced: string | null | undefined, user: string | null | undefined, body: Buffer | null,
                       signature: string, nowSeconds: number): boolean {
  const ts = Number((timestamp ?? "").trim());
  if (!timestamp || !Number.isInteger(ts) || Math.abs(nowSeconds - ts) > WINDOW_SECONDS) return false;
  const expected = Buffer.from(sign(accessToken, method, pathAndQuery, ts, enforced, user, body));
  const given = Buffer.from(signature.trim());
  return expected.length === given.length && timingSafeEqual(expected, given);
}
