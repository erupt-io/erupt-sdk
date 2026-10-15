package xyz.erupt.sdk;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** conformance/signature-vectors.json, computed by the Java reference CloudSignature. */
class SignatureTest {

    @Test
    @SuppressWarnings("unchecked")
    void javaVectors() throws Exception {
        Map<String, Object> doc = (Map<String, Object>) Json.parse(Files.readString(Path.of("../conformance/signature-vectors.json")));
        String token = (String) doc.get("accessToken");
        for (Map<String, Object> v : (List<Map<String, Object>>) doc.get("vectors")) {
            byte[] body = v.get("body") == null ? null : ((String) v.get("body")).getBytes(StandardCharsets.UTF_8);
            long ts = (Long) v.get("timestamp");
            String method = (String) v.get("method"), path = (String) v.get("pathAndQuery"), enforced = (String) v.get("enforced"), user = (String) v.get("user");
            String signature = (String) v.get("signature");
            assertEquals(signature, Signature.sign(token, method, path, ts, enforced, user, body), (String) v.get("case"));
            assertTrue(Signature.verify(token, method, path, String.valueOf(ts), enforced, user, body, signature, ts + 300));
            assertFalse(Signature.verify(token, method, path, String.valueOf(ts), enforced, user, body, signature, ts + 301));
            assertFalse(Signature.verify(token, method, path, "x", enforced, user, body, signature, ts));
        }
    }
}
