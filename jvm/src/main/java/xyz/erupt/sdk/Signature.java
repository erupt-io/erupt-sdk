package xyz.erupt.sdk;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.Locale;

/**
 * Erupt-Signature (erupt-cloud/PROTOCOL.md §4.3): an HMAC-SHA256 the server puts on every forward, keyed by the
 * node's access token, so the token need not travel and the signed headers cannot be forged.
 */
public final class Signature {

    public static final String HEADER_TIMESTAMP = "Erupt-Timestamp";
    public static final String HEADER_SIGNATURE = "Erupt-Signature";
    public static final String HEADER_ENFORCED = "Erupt-Enforced";
    public static final long WINDOW_SECONDS = 300;
    private static final String UNSIGNED_PAYLOAD = "UNSIGNED-PAYLOAD";

    private Signature() {
    }

    /** {@code body} is the raw bytes, or null for a multipart upload the server re-encodes (not covered). */
    public static String sign(String accessToken, String method, String pathAndQuery, long timestamp, String enforced,
                              String user, byte[] body) {
        String canonical = String.join("\n", method.toUpperCase(Locale.ROOT), pathAndQuery, Long.toString(timestamp),
                enforced == null ? "" : enforced, sha256(utf8(user == null ? "" : user)), body == null ? UNSIGNED_PAYLOAD : sha256(body));
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(utf8(accessToken), "HmacSHA256"));
            return HexFormat.of().formatHex(mac.doFinal(utf8(canonical)));
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    /** True when {@code signature} matches and {@code timestamp} lies within 300 seconds of {@code now} (epoch seconds). */
    public static boolean verify(String accessToken, String method, String pathAndQuery, String timestamp, String enforced,
                                 String user, byte[] body, String signature, long now) {
        long ts;
        try {
            ts = Long.parseLong(timestamp.strip());
        } catch (RuntimeException e) {
            return false;
        }
        if (Math.abs(now - ts) > WINDOW_SECONDS || signature == null) return false;
        String expected = sign(accessToken, method, pathAndQuery, ts, enforced, user, body);
        return MessageDigest.isEqual(utf8(expected), utf8(signature.strip()));
    }

    private static String sha256(byte[] data) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(data));
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    private static byte[] utf8(String s) {
        return s.getBytes(StandardCharsets.UTF_8);
    }
}
