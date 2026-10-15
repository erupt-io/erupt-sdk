package erupt

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
)

// Erupt-Signature (erupt-cloud/PROTOCOL.md §4.3): an HMAC-SHA256 the server puts on every forward, keyed by
// the node's access token, so the token need not travel and the signed headers cannot be forged.
const (
	HeaderTimestamp = "Erupt-Timestamp"
	HeaderSignature = "Erupt-Signature"
	HeaderEnforced  = "Erupt-Enforced"
	// SignatureWindow is how far, in seconds, a signed timestamp may be from the node's clock.
	SignatureWindow = 300
	unsignedPayload = "UNSIGNED-PAYLOAD"
)

// Sign computes the signature of a server call; body nil means a multipart upload, which is not covered.
func Sign(accessToken, method, pathAndQuery string, timestamp int64, enforced, user string, body []byte) string {
	payload := unsignedPayload
	if body != nil {
		payload = sha256Hex(body)
	}
	canonical := strings.Join([]string{strings.ToUpper(method), pathAndQuery, strconv.FormatInt(timestamp, 10),
		enforced, sha256Hex([]byte(user)), payload}, "\n")
	mac := hmac.New(sha256.New, []byte(accessToken))
	mac.Write([]byte(canonical))
	return hex.EncodeToString(mac.Sum(nil))
}

// VerifySignature checks a signature received with the given timestamp header against the node's clock (now, epoch seconds).
func VerifySignature(accessToken, method, pathAndQuery, timestamp, enforced, user string, body []byte, signature string, now int64) bool {
	ts, err := strconv.ParseInt(strings.TrimSpace(timestamp), 10, 64)
	if err != nil {
		return false
	}
	if diff := now - ts; diff > SignatureWindow || diff < -SignatureWindow {
		return false
	}
	expected := Sign(accessToken, method, pathAndQuery, ts, enforced, user, body)
	return hmac.Equal([]byte(expected), []byte(strings.TrimSpace(signature)))
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
