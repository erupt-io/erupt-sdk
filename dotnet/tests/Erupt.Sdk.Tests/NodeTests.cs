using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Http;

namespace Erupt.Tests;

public class NodeTests
{
    private const string Token = "node-secret";

    private sealed class PowerServer(Func<HttpRequestMessage, HttpResponseMessage> answer) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) => Task.FromResult(answer(request));
    }

    private static EruptNode Node(bool serverUp = true)
    {
        var node = new EruptNode(new NodeOptions { Name = "blog", AccessToken = Token, Servers = ["http://server"] });
        node.Http = new HttpClient(new PowerServer(_ => serverUp
            ? new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("""{"add":true,"edit":true,"delete":true,"viewDetails":true,"export":true,"importable":true}"""),
            }
            : new HttpResponseMessage(HttpStatusCode.InternalServerError)));
        node.Register<Category>(new MemoryRepository(new Record { ["name"] = "Tech" }, new Record { ["name"] = "Python", ["parent"] = 1 }));
        node.Register(EruptModel.Of<Article>(), new MemoryRepository());
        return node;
    }

    private static async Task<(int Status, JsonNode? Body)> Call(EruptNode node, string method, string path, object? body = null,
        string? erupt = "Article", Action<HttpRequest>? tweak = null)
    {
        var context = new DefaultHttpContext();
        context.Request.Method = method;
        context.Request.Path = path;
        context.Request.Headers["Access-Token"] = Token;
        context.Request.Headers["token"] = "t1";
        context.Request.Headers["user"] = Convert.ToBase64String(Encoding.UTF8.GetBytes("""{"uid":1,"account":"admin"}"""));
        if (erupt is not null) context.Request.Headers["erupt"] = erupt;
        context.Request.Body = new MemoryStream(body is null ? [] : Encoding.UTF8.GetBytes(body as string ?? System.Text.Json.JsonSerializer.Serialize(body)));
        tweak?.Invoke(context.Request);
        context.Response.Body = new MemoryStream();
        await node.HandleAsync(context);
        var text = Encoding.UTF8.GetString(((MemoryStream)context.Response.Body).ToArray());
        return (context.Response.StatusCode, text.StartsWith('{') || text.StartsWith('[') ? JsonNode.Parse(text) : JsonValue.Create(text));
    }

    [Fact]
    public async Task Guards()
    {
        var node = Node();
        Assert.Equal(403, (await Call(node, "GET", "/erupt-api/build/Article", tweak: r => r.Headers.Origin = "http://evil")).Status);
        Assert.Equal(403, (await Call(node, "GET", "/erupt-api/build/Article", tweak: r => r.Headers["Access-Token"] = "bad")).Status);
        Assert.Equal(404, (await Call(node, "GET", "/erupt-api/build/Article", erupt: "Category")).Status);
        Assert.Equal(404, (await Call(node, "GET", "/erupt-api/build/Article", tweak: r => r.Headers["eruptParent"] = "blog.Category")).Status);
        Assert.Equal(200, (await Call(node, "GET", "/erupt-api/build/Article", tweak: r => r.Headers["eruptParent"] = "blog.Article")).Status);
        Assert.Equal("blog", (await Call(node, "GET", "/node-health", erupt: null)).Body!.GetValue<string>());
    }

    [Fact]
    public async Task CrudAndReferences()
    {
        var node = Node();
        var (status, r) = await Call(node, "POST", "/erupt-api/data/modify/Article",
            new { title = "Hello", views = "7", review_at = "2026-01-05 10:30:00", category = new { id = "2", name = "Python" } });
        Assert.Equal(200, status);
        Assert.True(r!["success"]!.GetValue<bool>());
        var (_, page) = await Call(node, "POST", "/erupt-api/data/table/Article", new { pageIndex = 1, pageSize = 10 });
        var row = page!["list"]![0]!;
        Assert.Equal(7, row["views"]!.GetValue<long>());
        Assert.Equal("2026-01-05T10:30:00.000", row["review_at"]!.GetValue<string>());
        // a reference travels as its key; the server resolves labels and flattened columns
        Assert.Equal(2, row["category"]!.GetValue<long>());
        Assert.False(row.AsObject().ContainsKey("category_name"));
        var (_, fail) = await Call(node, "POST", "/erupt-api/data/modify/Article", new { status = "draft" });
        Assert.Equal("Title cannot be empty", fail!["message"]!.GetValue<string>());
        var (treeStatus, _) = await Call(node, "GET", "/erupt-api/data/Article/reference-tree/topic");
        Assert.Equal(404, treeStatus); // the server builds reference trees
    }

    [Fact]
    public async Task FailsClosedWithoutTheServer()
    {
        var node = Node(serverUp: false);
        Assert.Equal(403, (await Call(node, "POST", "/erupt-api/data/modify/Article", new { title = "x" })).Status);
    }

    [Fact]
    public void RegisterNeedsReferencedModelsFirst()
    {
        var node = new EruptNode(new NodeOptions { Name = "blog", AccessToken = Token, Servers = ["http://server"] });
        Assert.Contains("register Category before", Assert.Throws<ArgumentException>(() => node.Register(EruptModel.Of<Article>(), new MemoryRepository())).Message);
        Assert.Contains("only an operation form", Assert.Throws<ArgumentException>(() => node.Register<PublishForm>(new MemoryRepository())).Message);
    }

    [Fact]
    public void AddressFromLocalhostIsIPv4AndValid()
    {
        Assert.Equal(IPAddress.Loopback, EruptNode.LocalIp("http://localhost:8080"));
        var node = new EruptNode(new NodeOptions { Name = "blog", AccessToken = Token, Servers = ["http://localhost:8080"] });
        node.ResolveAddress(9090);
        Assert.Equal("http://127.0.0.1:9090", node.Options.Address);
        Assert.True(Uri.TryCreate(node.Options.Address, UriKind.Absolute, out _));
    }

    [Fact]
    public void IPv6AddressIsBracketed()
    {
        Assert.Equal("[::1]:9090", EruptNode.HostPort(IPAddress.IPv6Loopback, 9090));
        var node = new EruptNode(new NodeOptions { Name = "blog", AccessToken = Token, Servers = ["http://[::1]:8080"] });
        node.ResolveAddress(9090);
        Assert.Equal("http://[::1]:9090", node.Options.Address);
        Assert.Equal("::1", new Uri(node.Options.Address!).Host.Trim('[', ']'));
    }
}
