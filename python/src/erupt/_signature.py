"""Erupt-Signature (erupt-cloud/PROTOCOL.md §4.3): an HMAC-SHA256 the server puts on every forward, keyed by
the node's access token, so the token need not travel and the signed headers cannot be forged."""
import hashlib
import hmac

HEADER_TIMESTAMP = "Erupt-Timestamp"
HEADER_SIGNATURE = "Erupt-Signature"
HEADER_ENFORCED = "Erupt-Enforced"
WINDOW_SECONDS = 300
UNSIGNED_PAYLOAD = "UNSIGNED-PAYLOAD"


def sign(access_token, method, path_and_query, timestamp, enforced, user, body):
    """``body`` is the raw bytes, or None for a multipart upload the server re-encodes (not covered)."""
    canonical = "\n".join([
        method.upper(), path_and_query, str(timestamp), enforced or "",
        hashlib.sha256((user or "").encode()).hexdigest(),
        UNSIGNED_PAYLOAD if body is None else hashlib.sha256(body).hexdigest(),
    ])
    return hmac.new(access_token.encode(), canonical.encode(), hashlib.sha256).hexdigest()


def verify(access_token, method, path_and_query, timestamp, enforced, user, body, signature, now):
    try:
        ts = int(str(timestamp).strip())
    except (TypeError, ValueError):
        return False
    if abs(now - ts) > WINDOW_SECONDS:
        return False
    expected = sign(access_token, method, path_and_query, ts, enforced, user, body)
    return hmac.compare_digest(expected.encode(), str(signature).strip().encode())
