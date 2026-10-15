package erupt

import (
	"encoding/json"
	"os"
	"strconv"
	"testing"
)

type signatureVectors struct {
	AccessToken string `json:"accessToken"`
	Vectors     []struct {
		Case         string  `json:"case"`
		Method       string  `json:"method"`
		PathAndQuery string  `json:"pathAndQuery"`
		Timestamp    int64   `json:"timestamp"`
		Enforced     *string `json:"enforced"`
		User         *string `json:"user"`
		Body         *string `json:"body"`
		Signature    string  `json:"signature"`
	} `json:"vectors"`
}

// The vectors are computed by the Java reference (xyz.erupt.cloud.common.http.CloudSignature).
func TestSignatureVectors(t *testing.T) {
	raw, err := os.ReadFile("../conformance/signature-vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var doc signatureVectors
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	deref := func(s *string) string {
		if s == nil {
			return ""
		}
		return *s
	}
	for _, v := range doc.Vectors {
		var body []byte
		if v.Body != nil {
			body = []byte(*v.Body)
		}
		got := Sign(doc.AccessToken, v.Method, v.PathAndQuery, v.Timestamp, deref(v.Enforced), deref(v.User), body)
		if got != v.Signature {
			t.Errorf("%s: got %s, want %s", v.Case, got, v.Signature)
		}
		ts := strconv.FormatInt(v.Timestamp, 10)
		if !VerifySignature(doc.AccessToken, v.Method, v.PathAndQuery, ts, deref(v.Enforced), deref(v.User), body, v.Signature, v.Timestamp+300) {
			t.Errorf("%s: should verify at +300s", v.Case)
		}
		if VerifySignature(doc.AccessToken, v.Method, v.PathAndQuery, ts, deref(v.Enforced), deref(v.User), body, v.Signature, v.Timestamp+301) {
			t.Errorf("%s: should not verify at +301s", v.Case)
		}
	}
	if len(doc.Vectors) == 0 {
		t.Fatal("no vectors")
	}
}
