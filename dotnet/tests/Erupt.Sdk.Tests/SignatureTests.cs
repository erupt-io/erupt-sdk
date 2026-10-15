using System.Text;
using System.Text.Json.Nodes;

namespace Erupt.Tests;

/// <summary>The signature against the vectors computed by the Java reference, shared by every SDK.</summary>
public sealed class SignatureTests
{
    private static string VectorsPath()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "conformance", "signature-vectors.json");
            if (File.Exists(candidate)) return candidate;
        }
        throw new FileNotFoundException("conformance/signature-vectors.json");
    }

    [Fact]
    public void MatchesTheJavaVectors()
    {
        var doc = JsonNode.Parse(File.ReadAllText(VectorsPath()))!;
        var token = doc["accessToken"]!.GetValue<string>();
        var vectors = doc["vectors"]!.AsArray();
        Assert.NotEmpty(vectors);
        foreach (var v in vectors)
        {
            var body = v!["body"] is { } b ? Encoding.UTF8.GetBytes(b.GetValue<string>()) : null;
            var ts = v["timestamp"]!.GetValue<long>();
            string method = v["method"]!.GetValue<string>(), path = v["pathAndQuery"]!.GetValue<string>(), expected = v["signature"]!.GetValue<string>();
            string? enforced = v["enforced"]?.GetValue<string>(), user = v["user"]?.GetValue<string>();
            Assert.Equal(expected, Signature.Sign(token, method, path, ts, enforced, user, body));
            Assert.True(Signature.Verify(token, method, path, ts.ToString(), enforced, user, body, expected, ts + 300));
            Assert.False(Signature.Verify(token, method, path, ts.ToString(), enforced, user, body, expected, ts + 301));
        }
    }
}
