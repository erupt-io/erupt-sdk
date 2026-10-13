// A blog admin served from .NET. Create node "blog" on the erupt server first, then:
//
//   ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 dotnet run --project examples/Blog
using Erupt;
using Microsoft.Data.Sqlite;

static string? Env(string name) => Environment.GetEnvironmentVariable(name);

var node = new EruptNode(new NodeOptions
{
    Name = "blog",
    AccessToken = Env("ERUPT_ACCESS_TOKEN") ?? throw new InvalidOperationException("set ERUPT_ACCESS_TOKEN"),
    Servers = [Env("ERUPT_SERVER") ?? "http://localhost:8080"],
});

SqliteConnection Connect() => new("Data Source=blog.db");
node.Register<Category>(new DbRepository(Connect, "category") { AutoCreateSqlite = true });
node.Register(EruptModel.Of<Article>()
    .Operation("publish", new OperationOptions
    {
        Title = "Publish", Icon = "fa fa-paper-plane", Form = EruptModel.Of<PublishForm>(), IfExpr = "item.status !== 'published'",
    }, async op =>
    {
        foreach (var row in op.Rows)
            await op.Repo.UpdateAsync(row["id"]!, new Record { ["status"] = "published", ["publish_date"] = op.Param!["publish_date"] });
    })
    .Operation("feature", new OperationOptions
    {
        Title = "Feature", Mode = RowOperationMode.SINGLE, Icon = "fa fa-star", ConfirmText = "Feature this article on the home page?",
    }, op => op.Repo.UpdateAsync(op.Rows[0]["id"]!, new Record { ["featured"] = true })),
    new DbRepository(Connect, "article") { AutoCreateSqlite = true });

await node.RunAsync(int.Parse(Env("PORT") ?? "9090"));

[EruptModel("Category")]
internal sealed class Category
{
    [Pk] public long Id { get; set; }
    [Field("Name", Search = true, NotNull = true)] public string? Name { get; set; }
    [Field("Parent Id")] public long? Parent { get; set; }
}

[EruptModel("Publish Options")]
internal sealed class PublishForm
{
    [Field("Publish Date", NotNull = true)] public DateOnly? PublishDate { get; set; }
}

[EruptModel("Article", OrderBy = "id desc")]
internal sealed class Article
{
    [Pk] public long Id { get; set; }
    [Field("Title", Search = true, NotNull = true, Sortable = true)] public string? Title { get; set; }
    [Field("Category", Search = true)] public Category? Category { get; set; }
    [Field("Topic", Tree = "parent", Table = false)] public Category? Topic { get; set; }
    [Field("Status", Search = true), Choice("draft", "Draft"), Choice("published", "Published")] public string? Status { get; set; }
    [Field("Views", Sortable = true)] public long? Views { get; set; }
    [Field("Featured", Search = true)] public bool? Featured { get; set; }
    [Field("Publish Date", Search = true)] public DateOnly? PublishDate { get; set; }
    [Field("Review At", Sortable = true)] public DateTime? ReviewAt { get; set; }
    [Field("Body", Type = EditType.TEXTAREA, Table = false)] public string? Body { get; set; }
}
