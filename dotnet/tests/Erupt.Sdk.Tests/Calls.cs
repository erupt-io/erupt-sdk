using System.Text;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Http;

namespace Erupt.Tests;

/// <summary>Calls to a node as a v2 server makes them: signed, with the Erupt-Enforced each endpoint needs.</summary>
internal static class Calls
{
    internal const string Token = "node-secret";

    /// <summary>What a v2 node requires in Erupt-Enforced for an endpoint (PROTOCOL.md §12.2).</summary>
    internal static string Required(string method, string path) => (method, path.Split('/')) switch
    {
        ("GET", [_, _, "build", ..]) => "",
        ("POST", [_, _, "data", "table", ..]) => "power,query",
        ("POST", [_, _, "data", "modify", _]) or ("POST", [_, _, "data", "modify", _, "update"]) => "power,record",
        _ => "power",
    };

    /// <summary>
    /// <paramref name="enforced"/> defaults to what the endpoint requires; <paramref name="signed"/> false sends the call
    /// without a signature.
    /// </summary>
    internal static async Task<(int Status, JsonNode? Body)> Send(EruptNode node, string method, string path, object? body = null,
        string? erupt = "Article", Action<HttpRequest>? tweak = null, string account = "admin", string? enforced = null, bool signed = true)
    {
        var context = new DefaultHttpContext();
        var request = context.Request;
        request.Method = method;
        request.Path = path;
        var user = Convert.ToBase64String(Encoding.UTF8.GetBytes($$"""{"uid":1,"account":"{{account}}"}"""));
        request.Headers["token"] = "t1";
        request.Headers["user"] = user;
        if (erupt is not null) request.Headers["erupt"] = erupt;
        var bytes = body is null ? [] : Encoding.UTF8.GetBytes(body as string ?? System.Text.Json.JsonSerializer.Serialize(body));
        request.Body = new MemoryStream(bytes);
        if (signed)
        {
            enforced ??= Required(method, path);
            var ts = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            request.Headers[Signature.HeaderTimestamp] = ts.ToString();
            request.Headers[Signature.HeaderEnforced] = enforced;
            request.Headers[Signature.HeaderSignature] = Signature.Sign(Token, method, path, ts, enforced, user, bytes);
        }
        tweak?.Invoke(request);
        context.Response.Body = new MemoryStream();
        await node.HandleAsync(context);
        var text = Encoding.UTF8.GetString(((MemoryStream)context.Response.Body).ToArray());
        return (context.Response.StatusCode, text.StartsWith('{') || text.StartsWith('[') ? JsonNode.Parse(text) : JsonValue.Create(text));
    }
}
