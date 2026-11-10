using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;

namespace Erupt.Tests;

/// <summary>A virtual field is in the build only; a list or dictionary field round-trips as JSON.</summary>
public class FieldTests
{
    private const string Token = Calls.Token;

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

    private static async Task<JsonNode?> Call(EruptNode node, string method, string path, object? body = null) =>
        (await Calls.Send(node, method, path, body, "Widget")).Body;

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
        var node = new EruptNode(new NodeOptions { Name = "n", AccessToken = Token, Servers = ["http://server"] });
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
        keep.Dispose();
    }

    [Fact]
    public void JsonFieldsRefuseSearch() => Assert.Throws<ArgumentException>(() => EruptModel.Of<Bad>());
}
