using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Http;
using Microsoft.Data.Sqlite;

namespace Erupt.Tests;

/// <summary>A virtual field is in the build only; a list or dictionary field round-trips as JSON.</summary>
public class FieldTests
{
    private const string Token = "node-secret";

    [EruptModel("Widget")]
    private sealed class Widget
    {
        [Pk] public long Id { get; set; }
        [Field("Name")] public string? Name { get; set; }
        [Field("Note", Virtual = true)] public string? Note { get; set; }
        [Field("Roles"), Choice("ADMIN", "Admin"), Choice("USER", "User")] public List<string>? Roles { get; set; }
        [Field("Attrs")] public Dictionary<string, string>? Attrs { get; set; }
    }

    [EruptModel("Bad")]
    private sealed class Bad
    {
        [Pk] public long Id { get; set; }
        [Field("Tags", Search = true)] public List<string>? Tags { get; set; }
    }

    private sealed class PowerServer : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("""{"add":true,"edit":true,"delete":true,"viewDetails":true}"""),
            });
    }

    private static async Task<JsonNode?> Call(EruptNode node, string method, string path, object? body = null)
    {
        var context = new DefaultHttpContext();
        context.Request.Method = method;
        context.Request.Path = path;
        context.Request.Headers["Access-Token"] = Token;
        context.Request.Headers["token"] = "t1";
        context.Request.Headers["erupt"] = "Widget";
        context.Request.Body = new MemoryStream(body is null ? [] : Encoding.UTF8.GetBytes(System.Text.Json.JsonSerializer.Serialize(body)));
        context.Response.Body = new MemoryStream();
        await node.HandleAsync(context);
        return JsonNode.Parse(Encoding.UTF8.GetString(((MemoryStream)context.Response.Body).ToArray()));
    }

    public static TheoryData<string> Stores => ["memory", "sqlite"];

    [Theory]
    [MemberData(nameof(Stores))]
    public async Task VirtualAndJsonFields(string store)
    {
        var keep = new SqliteConnection("Data Source=widget;Mode=Memory;Cache=Shared");
        keep.Open(); // the shared in-memory database lives while one connection is open
        IRepository repo = store == "memory"
            ? new MemoryRepository()
            : new DbRepository(() => new SqliteConnection("Data Source=widget;Mode=Memory;Cache=Shared"), "widget") { AutoCreateSqlite = true };
        var node = new EruptNode(new NodeOptions { Name = "n", AccessToken = Token, Servers = ["http://server"] })
        {
            Http = new HttpClient(new PowerServer()),
        };
        node.Register(EruptModel.Of<Widget>().Edit(w => w.Note, new Edit { Type = EditType.DIVIDE }), repo);
        var build = await Call(node, "GET", "/erupt-api/build/Widget");
        var fields = build!["eruptModel"]!["eruptFieldModels"]!.AsArray();
        Assert.Equal(5, fields.Count);
        Assert.Equal("ADMIN", fields[3]!["componentValue"]![0]!["value"]!.GetValue<string>());
        var added = await Call(node, "POST", "/erupt-api/data/modify/Widget",
            new { name = "A", note = "ignored", roles = new[] { "ADMIN", "USER" }, attrs = new Dictionary<string, string> { ["env"] = "prod" } });
        Assert.True(added!["success"]!.GetValue<bool>());
        var page = await Call(node, "POST", "/erupt-api/data/table/Widget", new { pageIndex = 1, pageSize = 10 });
        var row = page!["list"]![0]!.AsObject();
        Assert.Equal("""["ADMIN","USER"]""", row["roles"]!.ToJsonString());
        Assert.Equal("""{"env":"prod"}""", row["attrs"]!.ToJsonString());
        Assert.False(row.ContainsKey("note"));
        var refused = await Call(node, "POST", "/erupt-api/data/modify/Widget", new { name = "B", roles = "ADMIN" });
        Assert.False(refused!["success"]!.GetValue<bool>());
        keep.Dispose();
    }

    [Fact]
    public void JsonFieldsRefuseSearch() => Assert.Throws<ArgumentException>(() => EruptModel.Of<Bad>());
}
