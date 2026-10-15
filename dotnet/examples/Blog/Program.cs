// A blog admin served from .NET, covering the field types of SHOWCASE.md. Create the node on the erupt server
// first, then:
//
//   ERUPT_NODE_NAME=blog ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 dotnet run --project examples/Blog
using Erupt;
using Microsoft.Data.Sqlite;

static string? Env(string name) => Environment.GetEnvironmentVariable(name);

var node = new EruptNode(new NodeOptions
{
    Name = Env("ERUPT_NODE_NAME") ?? "blog",
    AccessToken = Env("ERUPT_ACCESS_TOKEN") ?? throw new InvalidOperationException("set ERUPT_ACCESS_TOKEN"),
    Servers = [Env("ERUPT_SERVER") ?? "http://localhost:8080"],
});

var db = Env("ERUPT_DB") ?? "blog.db";
SqliteConnection Connect() => new($"Data Source={db}");
var categories = new DbRepository(Connect, "category") { AutoCreateSqlite = true };
var articles = new DbRepository(Connect, "article") { AutoCreateSqlite = true };
var components = new DbRepository(Connect, "component") { AutoCreateSqlite = true };

node.Register<Category>(categories);
node.Register(EruptModel.Of<Article>()
    .Power(new Power { Importable = true })
    // types the shortcuts do not infer: the stored value keeps the property's type, the editor is raw @Edit
    .Edit(a => a.Title, new Edit { InputType = new InputType { Length = 60 } })
    .Edit(a => a.Summary, new Edit { TextareaType = new TextareaType { Length = 200 } })
    .Edit(a => a.Tags, new Edit { Type = EditType.TAGS, TagsType = new TagsType { AllowExtension = true, JoinSeparator = "," } })
    .Edit(a => a.Views, new Edit { NumberType = new NumberType { Min = 0 } })
    .Edit(a => a.Price, new Edit { NumberType = new NumberType { Min = 0, Precision = 2, Prefix = "$" } })
    .Edit(a => a.Rating, new Edit { Type = EditType.RATE, RateType = new RateType { Count = 5, AllowHalf = true } })
    .Edit(a => a.Progress, new Edit { Type = EditType.SLIDER, SliderType = new SliderType { Min = 0, Max = 100, Step = 5 } })
    .Edit(a => a.Color, new Edit { Type = EditType.COLOR })
    .Edit(a => a.Icon, new Edit { Type = EditType.ICON })
    .Edit(a => a.Content, new Edit { Type = EditType.HTML_EDITOR })
    .Edit(a => a.Notes, new Edit { Type = EditType.MARKDOWN })
    .Edit(a => a.Meta, new Edit { Type = EditType.CODE_EDITOR, CodeEditType = new CodeEditorType { Language = "json" } })
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
    articles);

// every component that needs no extra endpoint: virtual fields are in the build only, list / dictionary
// properties are JSON values
node.Register(EruptModel.Of<Component>()
    .Edit(c => c.Intro, new Edit
    {
        Type = EditType.CALLOUT,
        CalloutType = new CalloutType { Value = "Every component a node can declare without extra endpoints.", Style = CalloutTypeStyle.INFO },
    })
    .Edit(c => c.Basic, new Edit { Type = EditType.DIVIDE })
    .Edit(c => c.Code, new Edit { Type = EditType.HIDDEN })
    .Edit(c => c.Roles, new Edit { Type = EditType.MULTI_CHOICE, MultiChoiceType = new MultiChoiceType { Type = MultiChoiceTypeType.CHECKBOX } })
    .Edit(c => c.Langs, new Edit { Type = EditType.MULTI_CHOICE, MultiChoiceType = new MultiChoiceType { Type = MultiChoiceTypeType.SELECT } })
    .Edit(c => c.Attrs, new Edit { Type = EditType.KEY_VALUE, KeyValueType = new KeyValueType { KeyPlaceholder = "Key", ValuePlaceholder = "Value" } })
    .Edit(c => c.Spacer, new Edit { Type = EditType.EMPTY })
    .Edit(c => c.Extra, new Edit { Type = EditType.DIVIDE })
    .Edit(c => c.Location, new Edit { Type = EditType.MAP })
    .Edit(c => c.Signature, new Edit { Type = EditType.SIGNATURE })
    .Edit(c => c.Place, new Edit { Type = EditType.GROUP, GroupType = new GroupType { Fields = ["location", "signature"] } }),
    components);

await Seed();
await node.RunAsync(int.Parse(Env("PORT") ?? "9090"));

// A few records to look at, on an empty database only
async Task Seed()
{
    if ((await categories.PageAsync(new Query { Limit = 1 })).Total == 0)
    {
        foreach (var (name, parent, sort) in new (string, long?, long)[] { ("Tech", null, 1), ("Python", 1, 2), ("Go", 1, 3), ("Life", null, 4), ("Travel", 4, 5) })
            await categories.AddAsync(new Record { ["name"] = name, ["parent"] = parent, ["sort"] = sort });
    }
    if ((await components.PageAsync(new Query { Limit = 1 })).Total == 0)
    {
        await components.AddAsync(new Record
        {
            ["name"] = "Sample A", ["code"] = "C-001", ["roles"] = new List<object?> { "ADMIN", "USER" }, ["langs"] = new List<object?> { "JAVA", "GO" },
            ["attrs"] = new Dictionary<string, object?> { ["env"] = "prod", ["tier"] = "1" },
        });
        await components.AddAsync(new Record
        {
            ["name"] = "Sample B", ["code"] = "C-002", ["roles"] = new List<object?> { "GUEST" }, ["langs"] = new List<object?> { "PYTHON" },
            ["attrs"] = new Dictionary<string, object?>(),
        });
    }
    if ((await articles.PageAsync(new Query { Limit = 1 })).Total > 0) return;
    await articles.AddAsync(new Record
    {
        ["title"] = "Hello Erupt", ["summary"] = "A first article", ["category"] = 2L, ["topic"] = 2L, ["status"] = "published",
        ["tags"] = "intro,erupt", ["views"] = 120L, ["price"] = 9.9, ["rating"] = 4.5, ["progress"] = 100L, ["featured"] = true,
        ["color"] = "#1677ff", ["icon"] = "fa fa-book", ["publish_date"] = new DateOnly(2026, 10, 1),
        ["review_at"] = new DateTime(2026, 10, 2, 10, 0, 0), ["content"] = "<p>Hello</p>", ["notes"] = "# Hello", ["meta"] = "{\"a\":1}",
    });
    await articles.AddAsync(new Record
    {
        ["title"] = "Go Tips", ["category"] = 3L, ["topic"] = 3L, ["status"] = "review", ["tags"] = "go",
        ["views"] = 30L, ["price"] = 0L, ["rating"] = 3L, ["progress"] = 60L, ["featured"] = false,
    });
    await articles.AddAsync(new Record
    {
        ["title"] = "Weekend Trip", ["category"] = 5L, ["topic"] = 5L, ["status"] = "draft",
        ["views"] = 0L, ["rating"] = 0L, ["progress"] = 10L, ["featured"] = false,
    });
}

[EruptModel("Category")]
internal sealed class Category
{
    [Pk] public long Id { get; set; }
    [Field("Name", Search = true, NotNull = true, Sortable = true)] public string? Name { get; set; }
    [Field("Parent Id")] public long? Parent { get; set; }
    [Field("Sort", Sortable = true)] public long? Sort { get; set; }
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
    [Field("Summary", Type = EditType.TEXTAREA, Table = false)] public string? Summary { get; set; }
    [Field("Category", Search = true)] public Category? Category { get; set; }
    [Field("Topic", Tree = "parent", Table = false)] public Category? Topic { get; set; }
    [Field("Status", Search = true), Choice("draft", "Draft"), Choice("review", "In Review"), Choice("published", "Published")]
    public string? Status { get; set; }
    [Field("Tags")] public string? Tags { get; set; }
    [Field("Views", Sortable = true)] public long? Views { get; set; }
    [Field("Price")] public decimal? Price { get; set; }
    [Field("Rating")] public double? Rating { get; set; }
    [Field("Progress")] public long? Progress { get; set; }
    [Field("Featured", Search = true)] public bool? Featured { get; set; }
    [Field("Theme Color")] public string? Color { get; set; }
    [Field("Icon", Table = false)] public string? Icon { get; set; }
    [Field("Publish Date", Search = true)] public DateOnly? PublishDate { get; set; }
    [Field("Review At", Sortable = true)] public DateTime? ReviewAt { get; set; }
    [Field("Content", Table = false)] public string? Content { get; set; }
    [Field("Notes", Table = false)] public string? Notes { get; set; }
    [Field("Meta (JSON)", Table = false)] public string? Meta { get; set; }
}

[EruptModel("Component")]
internal sealed class Component
{
    [Pk] public long Id { get; set; }
    [Field("Name", Search = true, NotNull = true)] public string? Name { get; set; }
    [Field("Guide", Virtual = true)] public string? Intro { get; set; }
    [Field("Basic", Virtual = true)] public string? Basic { get; set; }
    [Field("Code", Table = false)] public string? Code { get; set; }
    [Field("Roles"), Choice("ADMIN", "Admin"), Choice("USER", "User"), Choice("GUEST", "Guest")] public List<string>? Roles { get; set; }
    [Field("Languages"), Choice("JAVA", "Java"), Choice("PYTHON", "Python"), Choice("GO", "Go"), Choice("RUST", "Rust")]
    public List<string>? Langs { get; set; }
    [Field("Attributes")] public Dictionary<string, string>? Attrs { get; set; }
    [Field("", Virtual = true)] public string? Spacer { get; set; }
    [Field("Extra", Virtual = true)] public string? Extra { get; set; }
    [Field("Location")] public string? Location { get; set; }
    [Field("Signature", Table = false)] public string? Signature { get; set; }
    [Field("Place & Sign", Virtual = true)] public string? Place { get; set; }
}
