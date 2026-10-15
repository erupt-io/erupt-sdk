using System.Security.Cryptography;
using System.Text;

namespace Erupt;

/// <summary>
/// Erupt-Signature (erupt-cloud/PROTOCOL.md §4.3): an HMAC-SHA256 the server puts on every forward, keyed by the
/// node's access token, so the token need not travel and the signed headers cannot be forged.
/// </summary>
public static class Signature
{
    public const string HeaderTimestamp = "Erupt-Timestamp";
    public const string HeaderSignature = "Erupt-Signature";
    public const string HeaderEnforced = "Erupt-Enforced";
    public const long WindowSeconds = 300;
    private const string UnsignedPayload = "UNSIGNED-PAYLOAD";

    /// <param name="body">the raw body, or null for a multipart upload the server re-encodes (not covered)</param>
    public static string Sign(string accessToken, string method, string pathAndQuery, long timestamp, string? enforced, string? user, byte[]? body)
    {
        var canonical = string.Join("\n", method.ToUpperInvariant(), pathAndQuery, timestamp.ToString(System.Globalization.CultureInfo.InvariantCulture),
            enforced ?? "", Hex(SHA256.HashData(Encoding.UTF8.GetBytes(user ?? ""))), body is null ? UnsignedPayload : Hex(SHA256.HashData(body)));
        return Hex(HMACSHA256.HashData(Encoding.UTF8.GetBytes(accessToken), Encoding.UTF8.GetBytes(canonical)));
    }

    public static bool Verify(string accessToken, string method, string pathAndQuery, string? timestamp, string? enforced, string? user,
        byte[]? body, string signature, long now)
    {
        if (!long.TryParse(timestamp?.Trim(), System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var ts)) return false;
        if (Math.Abs(now - ts) > WindowSeconds) return false;
        var expected = Sign(accessToken, method, pathAndQuery, ts, enforced, user, body);
        return CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(expected), Encoding.UTF8.GetBytes(signature.Trim()));
    }

    private static string Hex(byte[] bytes) => Convert.ToHexString(bytes).ToLowerInvariant();
}
