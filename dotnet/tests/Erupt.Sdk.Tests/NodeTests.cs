using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Http;
using Microsoft.Data.Sqlite;

namespace Erupt.Tests;

public class NodeTests
{
    private const string Token = Calls.Token;

    private sealed class FakeServer(Func<HttpRequestMessage, HttpResponseMessage> answer) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) => Task.FromResult(answer(request));
    }

    private static EruptNode Node(EruptModel? article = null)
    {
        var node = new EruptNode(new NodeOptions { Name = "blog", AccessToken = Token, Servers = ["http://server"] });
        node.Register<Category>(new MemoryRepository(new Record { ["name"] = "Tech" }, new Record { ["name"] = "Python", ["parent"] = 1 }));
        node.Register(article ?? EruptModel.Of<Article>(), new MemoryRepository());
        return node;
    }

    private static Task<(int Status, JsonNode? Body)> Call(EruptNode node, string method, string path, object? body = null,
        string? erupt = "Article", Action<HttpRequest>? tweak = null, string account = "admin", string? enforced = null, bool signed = true) =>
        Calls.Send(node, method, path, body, erupt, tweak, account, enforced, signed);

    [Fact]
    public async Task Guards()
    {
        var node = Node();
        Assert.Equal(403, (await Call(node, "GET", "/erupt-api/build/Article", tweak: r => r.Headers.Origin = "http://evil")).Status);
        Assert.Equal(404, (await Call(node, "GET", "/erupt-api/build/Article", erupt: "Category")).Status);
        Assert.Equal(404, (await Call(node, "GET", "/erupt-api/build/Article", tweak: r => r.Headers["eruptParent"] = "blog.Category")).Status);
        Assert.Equal(200, (await Call(node, "GET", "/erupt-api/build/Article", tweak: r => r.Headers["eruptParent"] = "blog.Article")).Status);
        Assert.Equal(404, (await Call(node, "GET", "/erupt-api/nothing/here")).Status);
        Assert.Equal("blog", (await Call(node, "GET", "/node-health", erupt: null, signed: false)).Body!.GetValue<string>());
    }

    [Fact]
    public async Task EveryCallIsSigned()
    {
        var node = Node();
        // the access token alone no longer passes (§12.2)
        Assert.Equal(403, (await Call(node, "GET", "/erupt-api/build/Article", signed: false, tweak: r => r.Headers["Access-Token"] = Token)).Status);
        Assert.Equal(403, (await Call(node, "GET", "/erupt-api/build/Article", tweak: r => r.Headers[Signature.HeaderSignature] = "00")).Status);
        // a signature covers what it vouches for
        Assert.Equal(403, (await Call(node, "POST", "/erupt-api/data/table/Article", new { }, tweak: r => r.Headers[Signature.HeaderEnforced] = "power,query,record")).Status);
        Assert.Equal(403, (await Call(node, "GET", "/erupt-api/build/Article", tweak: r => r.Headers[Signature.HeaderTimestamp] = "1")).Status);
    }

    [Theory]
    [InlineData("POST", "/erupt-api/data/table/Article", "power")]
    [InlineData("POST", "/erupt-api/data/table/Article", "query")]
    [InlineData("POST", "/erupt-api/data/modify/Article", "power,query")]
    [InlineData("POST", "/erupt-api/data/modify/Article/update", "power")]
    [InlineData("POST", "/erupt-api/data/modify/Article/delete", "")]
    [InlineData("GET", "/erupt-api/data/Article/1", "query")]
    [InlineData("GET", "/erupt-api/data/init-value/Article", "")]
    [InlineData("POST", "/erupt-api/invoke/Article/operation/x", "record")]
    public async Task EachEndpointNeedsItsEnforced(string method, string path, string enforced)
    {
        var node = Node();
        Assert.Equal(403, (await Call(node, method, path, method == "POST" ? new { } : null, enforced: enforced)).Status);
    }

    [Fact]
    public async Task BuildNeedsNothingEnforced() => Assert.Equal(200, (await Call(Node(), "GET", "/erupt-api/build/Article", enforced: "")).Status);

    [Fact]
    public async Task CrudAndReferences()
    {
        var node = Node();
        var (status, r) = await Call(node, "POST", "/erupt-api/data/modify/Article",
            new { title = "Hello", views = 7, review_at = "2026-01-05 10:30:00", category = 2 });
        Assert.Equal(200, status);
        Assert.True(r!["success"]!.GetValue<bool>());
        var (_, page) = await Call(node, "POST", "/erupt-api/data/table/Article", new { pageIndex = 1, pageSize = 10 });
        var row = page!["list"]![0]!;
        Assert.Equal(7, row["views"]!.GetValue<long>());
        Assert.Equal("2026-01-05T10:30:00.000", row["review_at"]!.GetValue<string>());
        // a reference travels as its key; the server resolves labels and flattened columns
        Assert.Equal(2, row["category"]!.GetValue<long>());
        Assert.False(row.AsObject().ContainsKey("category_name"));
        // the server checked the record (§12.7): the node stores what it is sent
        Assert.True((await Call(node, "POST", "/erupt-api/data/modify/Article", new { status = "draft" })).Body!["success"]!.GetValue<bool>());
        Assert.False((await Call(node, "POST", "/erupt-api/data/modify/Article", new { views = "many" })).Body!["success"]!.GetValue<bool>());
        var (treeStatus, _) = await Call(node, "GET", "/erupt-api/data/Article/reference-tree/topic");
        Assert.Equal(404, treeStatus); // the server builds reference trees
        // the picker is the server's too: it reads the referenced model's own table
        Assert.Equal(404, (await Call(node, "POST", "/erupt-api/data/Article/reference-table/category", new { })).Status);
    }

    [Fact]
    public async Task Operations()
    {
        var notes = new List<object?>();
        var node = Node(article: EruptModel.Of<Article>()
            .Operation("publish", new OperationOptions { Title = "Publish", Form = EruptModel.Of<PublishForm>() }, op =>
            {
                notes.Add(op.Param!["note"]);
                return Task.CompletedTask;
            })
            .Operation("feature", new OperationOptions { Title = "Feature" }, _ => Task.FromResult<string?>("alert('featured')"))
            .Operation("single", new OperationOptions { Title = "Single", Mode = RowOperationMode.SINGLE }, _ => Task.CompletedTask)
            .Operation("button", new OperationOptions { Title = "Button", Mode = RowOperationMode.BUTTON }, op => Task.FromResult<string?>($"rows:{op.Rows.Count}"))
            .Operation("hidden", new OperationOptions { Title = "Hidden", Show = _ => false }, _ => Task.CompletedTask));
        await Call(node, "POST", "/erupt-api/data/modify/Article", new { title = "A" });
        await Call(node, "POST", "/erupt-api/data/modify/Article", new { title = "B" });
        var ids = new[] { 1 };
        const string path = "/erupt-api/invoke/Article/operation/";
        var (_, r) = await Call(node, "POST", path + "publish", new { ids, param = new { note = "go" } });
        Assert.Equal("Executed successfully", r!["message"]!.GetValue<string>());
        Assert.Equal(["go"], notes);
        Assert.False((await Call(node, "POST", path + "feature", new { ids = Array.Empty<int>() })).Body!["success"]!.GetValue<bool>());
        Assert.False((await Call(node, "POST", path + "single", new { ids = new[] { 1, 2 } })).Body!["success"]!.GetValue<bool>());
        Assert.True((await Call(node, "POST", path + "single", new { ids = new[] { "2" } })).Body!["success"]!.GetValue<bool>());
        Assert.Equal("rows:0", (await Call(node, "POST", path + "button", new { })).Body!["data"]!.GetValue<string>());
        Assert.False((await Call(node, "POST", path + "feature", new { ids = new[] { "x" } })).Body!["success"]!.GetValue<bool>()); // a bad key
        Assert.Equal("alert('featured')", (await Call(node, "POST", path + "feature", new { ids })).Body!["data"]!.GetValue<string>());
        Assert.Equal(403, (await Call(node, "POST", path + "hidden", new { ids })).Status);
        Assert.Equal(404, (await Call(node, "POST", path + "missing", new { })).Status);
        const string form = "/erupt-api/invoke/Article/operation-form/";
        Assert.Equal("""{"note":null}""", (await Call(node, "POST", form + "publish", new { })).Body!["data"]!.ToJsonString());
        Assert.Null((await Call(node, "POST", form + "feature", new { })).Body!["data"]); // an operation without a form
        Assert.Equal(404, (await Call(node, "POST", "/erupt-api/data/Article/operator/publish", new { ids })).Status);
    }

    [Fact]
    public async Task DataProxy()
    {
        var node = Node();
        node.Register<Memo>(new MemoryRepository());
        MemoProxy.Calls.Clear();
        var (_, build) = await Call(node, "GET", "/erupt-api/build/Memo", erupt: "Memo");
        Assert.Equal("""{"text":"hi"}""", build!["eruptModel"]!["searchCondition"]!.ToJsonString());
        Assert.Equal("new", (await Call(node, "GET", "/erupt-api/data/init-value/Memo", erupt: "Memo")).Body!["text"]!.GetValue<string>());
        var (_, fail) = await Call(node, "POST", "/erupt-api/data/modify/Memo", new { text = "forbidden" }, "Memo");
        Assert.Equal((false, "forbidden text"), (fail!["success"]!.GetValue<bool>(), fail["message"]!.GetValue<string>()));
        Assert.True((await Call(node, "POST", "/erupt-api/data/modify/Memo", new { text = "a" }, "Memo")).Body!["success"]!.GetValue<bool>());
        var (_, page) = await Call(node, "POST", "/erupt-api/data/table/Memo", new { }, "Memo");
        Assert.Equal("A", page!["list"]![0]!["text"]!.GetValue<string>());
        var pk = page["list"]![0]!["id"]!.GetValue<long>();
        Assert.Equal("a?", (await Call(node, "GET", $"/erupt-api/data/Memo/{pk}", erupt: "Memo")).Body!["text"]!.GetValue<string>());
        Assert.True((await Call(node, "POST", "/erupt-api/data/modify/Memo/update", new { id = pk, text = "b" }, "Memo")).Body!["success"]!.GetValue<bool>());
        Assert.True((await Call(node, "POST", "/erupt-api/data/modify/Memo/delete", new[] { pk }, "Memo")).Body!["success"]!.GetValue<bool>());
        Assert.Equal([("BeforeAdd", (object?)"a"), ("AfterAdd", "a"), ("BeforeUpdate", "b"), ("AfterUpdate", "b"), ("BeforeDelete", "b"), ("AfterDelete", "b")],
            MemoProxy.Calls);
    }

    [Fact]
    public async Task BeforeFetch()
    {
        using var keep = new SqliteConnection("Data Source=task;Mode=Memory;Cache=Shared");
        keep.Open(); // the shared in-memory database lives while one connection is open
        var node = Node();
        var task = EruptModel.Of<TaskItem>()
            .Vis(new Vis { Code = "q", Title = "Question", Type = VisType.TABLE }, filter: "title = 'a?'")
            .Vis(new Vis { Title = "Reversed", Type = VisType.TABLE }, "title desc", "1 = 1", "2 = 2");
        node.Register(task, new DbRepository(() => new SqliteConnection("Data Source=task;Mode=Memory;Cache=Shared"), "task") { AutoCreateSqlite = true });
        foreach (var (title, owner, done) in new[] { ("a", "admin", false), ("b", "admin", true), ("c", "root", false), ("a?", "admin", false) })
            await Call(node, "POST", "/erupt-api/data/modify/Task", new { title, owner, done }, "Task");
        var (_, page) = await Call(node, "POST", "/erupt-api/data/table/Task", new { }, "Task");
        Assert.Equal(["a", "a?"], page!["list"]!.AsArray().Select(r => r!["title"]!.GetValue<string>()));
        Assert.Equal(2, page["total"]!.GetValue<long>());
        (_, page) = await Call(node, "POST", "/erupt-api/data/table/Task",
            new { condition = new[] { new { key = "title", expression = "EQ", value = "a" } } }, "Task", account: "root");
        Assert.Empty(page!["list"]!.AsArray());
        // a view's own filter and order run on the node, and stay out of the build
        (_, page) = await Call(node, "POST", "/erupt-api/data/table/Task", new { vis = "q" }, "Task");
        Assert.Equal(["a?"], page!["list"]!.AsArray().Select(r => r!["title"]!.GetValue<string>()));
        (_, page) = await Call(node, "POST", "/erupt-api/data/table/Task", new { vis = "Reversed" }, "Task");
        Assert.Equal(["a?", "a"], page!["list"]!.AsArray().Select(r => r!["title"]!.GetValue<string>()));
        var (_, build) = await Call(node, "GET", "/erupt-api/build/Task", null, "Task");
        var vis = build!["eruptModel"]!["eruptJson"]!["vis"]!.AsArray().Select(v => v!.AsObject()).ToList();
        Assert.Equal(["q", "Reversed"], vis.Select(v => v["code"]!.GetValue<string>()));
        Assert.DoesNotContain(vis, v => v.ContainsKey("filter") || v.ContainsKey("orderBy"));
    }

    [Fact]
    public async Task LinkTree()
    {
        var node = Node();
        node.Register(EruptModel.Of<Doc>().Options(new EruptOptions { LinkTree = new LinkTree { Field = "topic", DependNode = true } }),
            new MemoryRepository(new Record { ["title"] = "a", ["topic"] = 1 }, new Record { ["title"] = "b", ["topic"] = 2 }, new Record { ["title"] = "c", ["topic"] = 3 }));
        async Task<IEnumerable<string>> Titles(object body) =>
            (await Call(node, "POST", "/erupt-api/data/table/Doc", body, "Doc")).Body!["list"]!.AsArray().Select(r => r!["title"]!.GetValue<string>());
        // the server sends the picked tree keys as IN on the tree field, and NULL on the key before a pick (§12.4)
        Assert.Empty(await Titles(new { condition = new[] { new { key = "id", expression = "NULL" } } }));
        Assert.Equal(["b"], await Titles(new { condition = new[] { new { key = "topic", expression = "IN", value = new[] { 2 } } } }));
        Assert.Equal(["a", "b"], await Titles(new { condition = new[] { new { key = "topic", expression = "IN", value = new[] { 1, 2 } } } }));
        // linkTreeVal is not a v2 input: the node ignores it
        Assert.Equal(3, (await Titles(new { linkTreeVal = new[] { 2 } })).Count());
        Assert.Contains("must be a reference field", Assert.Throws<ArgumentException>(() =>
            EruptModel.Of<Doc>().Options(new EruptOptions { LinkTree = new LinkTree { Field = "title" } })).Message);
    }

    [Fact]
    public async Task Queries()
    {
        var node = Node();
        foreach (var (title, views) in new[] { ("a", 1), ("b", 5), ("c", 9) })
            await Call(node, "POST", "/erupt-api/data/modify/Article", new { title, views, publish_date = $"2026-01-0{views}" });
        async Task<List<string>> Titles(object body) =>
            [.. (await Call(node, "POST", "/erupt-api/data/table/Article", body)).Body!["list"]!.AsArray().Select(r => r!["title"]!.GetValue<string>())];
        object Where(string key, string expression, object? value = null) => new { condition = new[] { new { key, expression, value } } };
        Assert.Equal(["c", "b"], await Titles(Where("views", "GT", 1))); // Article orders by id desc
        Assert.Equal(["b"], await Titles(Where("publish_date", "RANGE", new[] { "2026-01-02", "2026-01-06" })));
        Assert.Equal(["c", "a"], await Titles(Where("views", "IN", new[] { 1, 9 })));
        Assert.Equal(["b"], await Titles(Where("title", "LIKE", "b")));
        Assert.Empty(await Titles(Where("title", "NULL")));
        // any stored field may be searched (the server adds conditions of its own), the key among them
        Assert.Equal(["a"], await Titles(Where("id", "EQ", 1)));
        Assert.Equal(["a", "b", "c"], await Titles(new { sort = new[] { new { field = "id", direction = "ASC" } } }));
        Assert.Equal(3, (await Titles(new { sort = new[] { new { field = "body", direction = "ASC" } } })).Count); // not sortable: the server checked
        // "field.column" orders by the field before the dot
        Assert.Equal(["c", "b"], await Titles(new { sort = new[] { new { field = "views.label", direction = "DESC" } }, pageSize = 2 }));
        // an unknown operator fails rather than matching every row
        var (_, odd) = await Call(node, "POST", "/erupt-api/data/table/Article", Where("views", "ABOUT", 1));
        Assert.Equal("illegal operator 'ABOUT'", odd!["message"]!.GetValue<string>());
        (_, odd) = await Call(node, "POST", "/erupt-api/data/table/Article", Where("views", "", 1));
        Assert.False(odd!["success"]!.GetValue<bool>());
        var (_, fail) = await Call(node, "POST", "/erupt-api/data/table/Article", Where("missing", "EQ", 1));
        Assert.Equal("illegal search field 'missing'", fail!["message"]!.GetValue<string>());
        (_, fail) = await Call(node, "POST", "/erupt-api/data/table/Article", new { sort = new[] { new { field = "missing", direction = "ASC" } } });
        Assert.Equal("illegal sort field 'missing'", fail!["message"]!.GetValue<string>());
        // the node caps the page size on its own
        Assert.Equal(1000, (await Call(node, "POST", "/erupt-api/data/table/Article", new { pageSize = 5000 })).Body!["pageSize"]!.GetValue<int>());
    }

    [Fact]
    public async Task FieldTypesAndInvoke()
    {
        static FieldUpdate Refuse(Record _) => throw new EruptFailure("not now");
        var node = Node();
        node.Register(EruptModel.Of<Order>()
            .Fetch(o => o.Status, form => [("new", "New"), (form.GetValueOrDefault("note") as string ?? "x", "From form")])
            .Fetch(o => o.Tags, _ => ["red", "blue"])
            .OnChange(o => o.Qty, form => new FieldUpdate { FormData = new Record { ["note"] = $"{form["qty"]} items" } })
            .Complete(o => o.City, async (_, typed) =>
            {
                await Task.Yield();
                return new[] { "Paris", "Tokyo" }.Where(c => c.Contains(typed, StringComparison.OrdinalIgnoreCase));
            })
            .Click(o => o.Calc, _ => new FieldUpdate { Eval = "alert(1)", FormData = new Record { ["qty"] = 2 } })
            .Click(o => o.Stop, Refuse), new MemoryRepository());
        var (_, build) = await Call(node, "GET", "/erupt-api/build/Order", erupt: "Order");
        var fields = build!["eruptModel"]!["eruptFieldModels"]!.AsArray().ToDictionary(f => f!["fieldName"]!.GetValue<string>(), f => f!);
        JsonNode Edit(string name) => fields[name]["eruptFieldJson"]!["edit"]!;
        Assert.Equal("""["invoke"]""", Edit("status")["choiceType"]!["fetchHandler"]!.ToJsonString());
        Assert.Equal("""["invoke"]""", Edit("tags")["tagsType"]!["fetchHandler"]!.ToJsonString());
        Assert.Equal("invoke", Edit("qty")["onchange"]!.GetValue<string>());
        Assert.Equal(["MARKDOWN", "ATTACHMENT", "BUTTON", "MULTI_CHOICE"], new[] { "body", "files", "calc", "colors" }.Select(n => Edit(n)["type"]!.GetValue<string>()));
        Assert.Equal(["Category", "Category"], new[] { "cats", "sections" }.Select(n => fields[n]["fieldReturnName"]!.GetValue<string>()));
        Assert.Empty(fields["calc"]["eruptFieldJson"]!["views"]!.AsArray());

        Task<(int Status, JsonNode? Body)> Invoke(string kind, string field, object? form = null, string? value = null) =>
            Call(node, "POST", $"/erupt-api/invoke/Order/{kind}/{field}", new { form = form ?? new { }, value }, "Order");
        Assert.Equal("""[{"value":"new","label":"New"},{"value":"n","label":"From form"}]""",
            (await Invoke("options", "status", new { note = "n" })).Body!["data"]!.ToJsonString());
        Assert.Equal("""["red","blue"]""", (await Invoke("options", "tags")).Body!["data"]!.ToJsonString());
        Assert.Equal("""{"formData":{"note":"3 items"}}""", (await Invoke("onchange", "qty", new { qty = 3 })).Body!["data"]!.ToJsonString());
        Assert.Equal("""["Paris"]""", (await Invoke("autocomplete", "city", value: "pa")).Body!["data"]!.ToJsonString());
        Assert.Equal("alert(1)", (await Invoke("button", "calc")).Body!["data"]!["eval"]!.GetValue<string>());
        var stop = (await Invoke("button", "stop")).Body!;
        Assert.Equal((false, "not now"), (stop["success"]!.GetValue<bool>(), stop["message"]!.GetValue<string>()));
        Assert.Equal(404, (await Invoke("button", "qty")).Status); // a field without that code
        Assert.Equal(404, (await Invoke("options", "missing")).Status);

        // picked records arrive as their keys (§12.4)
        var (_, r) = await Call(node, "POST", "/erupt-api/data/modify/Order",
            new { cats = new[] { 1, 2 }, sections = new[] { 3 }, tags = "red", colors = new[] { "red" } }, "Order");
        Assert.True(r!["success"]!.GetValue<bool>());
        var row = (await Call(node, "POST", "/erupt-api/data/table/Order", new { }, "Order")).Body!["list"]![0]!.AsObject();
        Assert.Equal(("[1,2]", "[3]", """["red"]"""), (row["cats"]!.ToJsonString(), row["sections"]!.ToJsonString(), row["colors"]!.ToJsonString()));
        Assert.False(row.ContainsKey("calc"));
        Assert.Equal("invoke", node.NodeInfo()["capabilities"]![0]!.GetValue<string>());

        // field code belongs to its type
        Assert.Contains("belongs to AUTO_COMPLETE", Assert.Throws<ArgumentException>(() => EruptModel.Of<Order>().Complete(o => o.Note, (_, _) => [])).Message);
        Assert.Contains("belongs to BUTTON", Assert.Throws<ArgumentException>(() => EruptModel.Of<Order>().Click(o => o.Qty, _ => new FieldUpdate())).Message);
        Assert.Contains("belongs to TAGS", Assert.Throws<ArgumentException>(() => EruptModel.Of<Order>().Fetch(o => o.Status, _ => ["a"])).Message);
        Assert.Contains("belongs to CHOICE", Assert.Throws<ArgumentException>(() => EruptModel.Of<Order>().Fetch(o => o.Note, _ => [("a", "A")])).Message);
    }

    [Fact]
    public async Task OnchangeAnswersOnlyWhatItSets()
    {
        var node = Node();
        node.Register(EruptModel.Of<Order>()
            .OnChange(o => o.Qty, _ => new FieldUpdate())
            .Click(o => o.Calc, _ => new FieldUpdate { Eval = "alert(1)" }), new MemoryRepository());
        Task<(int Status, JsonNode? Body)> Invoke(string kind, string field) =>
            Call(node, "POST", $"/erupt-api/invoke/Order/{kind}/{field}", new { form = new { } }, "Order");
        Assert.Equal("{}", (await Invoke("onchange", "qty")).Body!["data"]!.ToJsonString());
        Assert.Equal("""{"eval":"alert(1)"}""", (await Invoke("button", "calc")).Body!["data"]!.ToJsonString());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task MultiChoiceSearchesTheValuesItHolds(bool sqlite)
    {
        using var keep = new SqliteConnection("Data Source=palette;Mode=Memory;Cache=Shared");
        keep.Open();
        IRepository repo = sqlite
            ? new DbRepository(() => new SqliteConnection("Data Source=palette;Mode=Memory;Cache=Shared"), "palette") { AutoCreateSqlite = true }
            : new MemoryRepository();
        var node = Node();
        node.Register<Palette>(repo);
        foreach (var (name, colors) in new[] { ("a", new[] { "red", "blue" }), ("b", new[] { "blue" }), ("c", new[] { "green" }) })
            await repo.AddAsync(new Record { ["name"] = name, ["colors"] = colors.Cast<object?>().ToList() });
        async Task<string[]> Names(string expression, object value) =>
            (await Call(node, "POST", "/erupt-api/data/table/Palette", new { condition = new[] { new { key = "colors", expression, value } } }, "Palette"))
            .Body!["list"]!.AsArray().Select(r => r!["name"]!.GetValue<string>()).ToArray();
        Assert.Equal(["a", "b"], await Names("IN", new[] { "blue" }));
        Assert.Equal(["a"], await Names("IN", new[] { "red", "blue" })); // every value searched for
        Assert.Equal(["a"], await Names("EQ", "red"));
        Assert.Equal(["c"], await Names("NOT_IN", new[] { "blue" }));
    }

    private static EruptNode BookNode()
    {
        var node = Node();
        node.Register(EruptModel.Of<Author>().Drill(new Drill { Title = "Books", Link = new Link { LinkErupt = "Book" } }, joinColumn: "author.id"),
            new MemoryRepository(new Record { ["name"] = "Ann" }, new Record { ["name"] = "Bob" }));
        node.Register(EruptModel.Of<Book>().Edit(b => b.Shelf, new Edit { ReferenceTableType = new ReferenceTableType { DependField = "author" } }),
            new MemoryRepository(new Record { ["title"] = "a", ["author"] = 1 }, new Record { ["title"] = "b", ["author"] = 2 }, new Record { ["title"] = "c", ["author"] = 1 }));
        return node;
    }

    [Fact]
    public async Task Drill()
    {
        var node = BookNode();
        // the server sends the join as a condition; the body names the drill (§12.4)
        object Drilled(string erupt, string code) => new
        {
            condition = new[] { new { key = "author", expression = "EQ", value = 1 } }, drill = new { erupt, code },
        };
        var (_, page) = await Call(node, "POST", "/erupt-api/data/table/Book", Drilled("Author", "Books"), "Book");
        Assert.Equal(["a", "c"], page!["list"]!.AsArray().Select(r => r!["title"]!.GetValue<string>()));
        Assert.Equal(403, (await Call(node, "POST", "/erupt-api/data/table/Book", Drilled("Author", "x"), "Book")).Status);
        Assert.Equal(403, (await Call(node, "POST", "/erupt-api/data/table/Book", Drilled("Nobody", "Books"), "Book")).Status);
        // the v1 headers mean nothing any more
        var (_, all) = await Call(node, "POST", "/erupt-api/data/table/Book", new { }, "Book", r => r.Headers["Drill"] = "x");
        Assert.Equal(3, all!["list"]!.AsArray().Count);
        var (_, build) = await Call(node, "GET", "/erupt-api/build/Author", erupt: "Author");
        var drill = build!["eruptModel"]!["eruptJson"]!["drills"]![0]!.AsObject();
        // the link goes to the server whole: it reads the source row and joins on its columns (§12.3)
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse("""{"title":"Books","code":"Books","link":{"linkErupt":"Book","column":"id","joinColumn":"author.id"}}"""), drill), drill.ToJsonString());
    }

    [Fact]
    public async Task DrillAddsItsLinkCondition()
    {
        using var keep = new SqliteConnection("Data Source=drill;Mode=Memory;Cache=Shared");
        keep.Open();
        var node = new EruptNode(new NodeOptions { Name = "blog", AccessToken = Token, Servers = ["http://server"] });
        node.Register<Category>(new MemoryRepository());
        node.Register(EruptModel.Of<Author>().Drill(new Drill { Title = "Short", Code = "short", Link = new Link { LinkErupt = "Book", LinkCondition = "length(title) = 1" } }, "author"),
            new MemoryRepository(new Record { ["name"] = "Ann" }));
        node.Register<Book>(new DbRepository(() => new SqliteConnection("Data Source=drill;Mode=Memory;Cache=Shared"), "book") { AutoCreateSqlite = true });
        foreach (var title in new[] { "a", "bb" }) await Call(node, "POST", "/erupt-api/data/modify/Book", new { title, author = 1 }, "Book");
        var (_, page) = await Call(node, "POST", "/erupt-api/data/table/Book", new { drill = new { erupt = "Author", code = "short" } }, "Book");
        Assert.Equal(["a"], page!["list"]!.AsArray().Select(r => r!["title"]!.GetValue<string>()));
    }

    [Fact]
    public async Task SimpleTypesAndDependColumn()
    {
        var node = BookNode();
        var (_, build) = await Call(node, "GET", "/erupt-api/build/Book", erupt: "Book");
        var edit = build!["eruptModel"]!["eruptFieldModels"]!.AsArray().ToDictionary(f => f!["fieldName"]!.GetValue<string>(), f => f!["eruptFieldJson"]!["edit"]!);
        Assert.Equal(["COLOR", "RATE", "HIDDEN", "TRANSFER"], new[] { "colour", "stars", "secret", "readers" }.Select(n => edit[n]["type"]!.GetValue<string>()));
        Assert.Equal("parent", edit["shelf"]["referenceTableType"]!["dependColumn"]!.GetValue<string>()); // the server reads it off the build
        Assert.True((await Call(node, "POST", "/erupt-api/data/modify/Book", new { title = "d", stars = 4, readers = new[] { 2 } }, "Book")).Body!["success"]!.GetValue<bool>());
        var row = (await Call(node, "POST", "/erupt-api/data/table/Book", new { }, "Book")).Body!["list"]!.AsArray()[^1]!;
        Assert.Equal((4, "[2]"), (row["stars"]!.GetValue<long>(), row["readers"]!.ToJsonString()));
    }

    [Fact]
    public async Task NodeConfigAndUserInfo()
    {
        var node = Node();
        var seen = new List<(string Path, string? Token)>();
        node.Http = new HttpClient(new FakeServer(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            seen.Add((path, request.Headers.TryGetValues("token", out var token) ? token.Single() : null));
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(path.Contains("userinfo") ? """{"account":"admin","roles":["r"]}""" : "cfg"),
            };
        }));
        Assert.Equal("cfg", await node.ConfigAsync());
        Assert.Equal("cfg", await node.GroupConfigAsync());
        Assert.Equal("""{"account":"admin","roles":["r"]}""", (await node.UserInfoAsync())!.ToJsonString());
        Assert.Equal(["/erupt-cloud-api/node-config/blog", "/erupt-cloud-api/node-group-config/blog", "/erupt-cloud-api/userinfo/blog"], seen.Select(s => s.Path));
    }

    [Fact]
    public async Task BeforeFetchNeedsSql()
    {
        var node = Node();
        node.Register<TaskItem>(new MemoryRepository());
        Assert.Equal(500, (await Call(node, "POST", "/erupt-api/data/table/Task", new { }, "Task")).Status);
    }

    [Fact]
    public async Task RegistersAsV2AndKeepsBeatingWithAV2Server()
    {
        var node = Node();
        var sent = new List<JsonNode>();
        node.Http = new HttpClient(new FakeServer(request =>
        {
            lock (sent) sent.Add(JsonNode.Parse(request.Content!.ReadAsStringAsync().Result)!);
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("""{"protocolVersion":2}""") };
        }));
        typeof(NodeOptions).GetProperty(nameof(NodeOptions.Heartbeat))!.SetValue(node.Options, TimeSpan.FromMilliseconds(10));
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(300));
        await node.HeartbeatAsync(cts.Token);
        Assert.True(sent.Count > 1);
        Assert.Equal(2, sent[0]["protocolVersion"]!.GetValue<int>());
    }

    [Theory]
    [InlineData("")]
    [InlineData("null")]
    [InlineData("""{"protocolVersion":1}""")]
    [InlineData("""{"protocolVersion":"2"}""")]
    [InlineData("<html>")]
    public async Task AnOlderServerStopsTheHeartbeat(string answer)
    {
        var node = Node();
        var calls = 0;
        node.Http = new HttpClient(new FakeServer(_ =>
        {
            Interlocked.Increment(ref calls);
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(answer) };
        }));
        // it returns on its own: no retry, no v1 fallback
        await node.HeartbeatAsync(new CancellationTokenSource(TimeSpan.FromSeconds(10)).Token).WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(1, calls);
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
