// The showcase admin served from .NET that uses every capability of the SDK, as SHOWCASE.md describes it (the Python
// reference is python/examples/showcase.py). Create the node on the erupt server first, then:
//
//   ERUPT_NODE_NAME=showcase ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 dotnet run --project examples/Showcase
//
// Rows live in SQLite (ERUPT_DB, default showcase.db) through DbRepository, so the SQL parts of the spec (the Drafts
// view filter, BeforeFetch, the author drill's linkCondition) all run. Edit types the property type does not infer are
// set with [Field(Type = ...)]; layout elements (CALLOUT, DIVIDE, EMPTY, GROUP) and KEY_VALUE have no shortcut, so
// they are declared as their storage type and get the edit type through a raw Edit(...). Form-only elements are
// Virtual; MULTI_CHOICE (a list) and KEY_VALUE (a dictionary) hold JSON.
using System.Text.Json;
using Erupt;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging;

static string? Env(string name) => Environment.GetEnvironmentVariable(name);

var node = new EruptNode(new NodeOptions
{
    Name = Env("ERUPT_NODE_NAME") ?? "showcase",
    AccessToken = Env("ERUPT_ACCESS_TOKEN") ?? throw new InvalidOperationException("set ERUPT_ACCESS_TOKEN"),
    Servers = [Env("ERUPT_SERVER") ?? "http://localhost:8080"],
});

var db = Env("ERUPT_DB") ?? "showcase.db";
SqliteConnection Connect() => new($"Data Source={db}");
DbRepository Table(string name) => new(Connect, name) { AutoCreateSqlite = true };
var categories = Table("category");
var authors = Table("author");
var tags = Table("tag");
var articles = Table("article");
var components = Table("component");
var auditLog = Table("audit_log");
var playground = Table("playground");
ArticleProxy.Audit = auditLog;
ArticleProxy.Log = LoggerFactory.Create(b => b.AddConsole()).CreateLogger("showcase");

string[] cities = ["Paris", "Tokyo", "Lisbon", "Austin"];

// ---------------------------------------------------------------- reference data

node.Register(EruptModel.Of<Category>()
    .Options(new EruptOptions { Tree = new Tree { Pid = "parent" }, DragSort = new DragSort { Field = "sort" } })
    .Drill(new Drill { Title = "Articles", Code = "Articles", Link = new Link { LinkErupt = "Article" } }, joinColumn: "category"),
    categories);

node.Register(EruptModel.Of<Author>()
    .Edit(a => a.Email, new Edit { InputType = new InputType { Regex = @"^[^@\s]+@[^@\s]+\.[^@\s]+$" } })
    .Drill(new Drill
    {
        Title = "Articles", Code = "Articles", Link = new Link { LinkErupt = "Article", LinkCondition = "status = 'published'" },
    }, joinColumn: "author"),
    authors);

node.Register<Tag>(tags);

node.Register(EruptModel.Of<AuditLog>().Power(new Power { Add = false, Edit = false, Delete = false }), auditLog);

// ---------------------------------------------------------------- the article: every field type and behaviour

node.Register(EruptModel.Of<Article>()
    .Power(new Power { Importable = true })
    .Options(new EruptOptions { LinkTree = new LinkTree { Field = "category" } })
    .Vis(new Vis { Title = "Drafts", Code = "Drafts", Type = VisType.TABLE }, "views desc", "status = 'draft'")
    .Vis(new Vis { Title = "Board", Code = "Board", Type = VisType.BOARD, BoardView = new BoardView { GroupField = "status", SumField = "views" } })
    .Vis(new Vis { Title = "Calendar", Code = "Calendar", Type = VisType.CALENDAR, CalendarView = new CalendarView { DateField = "publish_date" } })
    .Vis(new Vis { Title = "Cards", Code = "Cards", Type = VisType.CARD, CardView = new CardView { CoverField = "cover" } })
    .Vis(new Vis { Title = "Timeline", Code = "Timeline", Type = VisType.TIMELINE, TimelineView = new TimelineView { DateField = "review_at" } })
    .Edit(a => a.Title, new Edit { InputType = new InputType { Length = 60 } })
    .Edit(a => a.Summary, new Edit { TextareaType = new TextareaType { Length = 200 } })
    .Edit(a => a.SubCategory, new Edit { ReferenceTableType = new ReferenceTableType { DependField = "category" } })
    .Edit(a => a.Labels, new Edit { TagsType = new TagsType { AllowExtension = true, JoinSeparator = "," } })
    .Edit(a => a.City, new Edit { AutoCompleteType = new AutoCompleteType { TriggerLength = 1 } })
    .Edit(a => a.Cover, new Edit { AttachmentType = new AttachmentType { Type = AttachmentTypeType.IMAGE, MaxLimit = 1 } })
    .Edit(a => a.Views, new Edit { NumberType = new NumberType { Min = 0 } })
    .Edit(a => a.Price, new Edit { NumberType = new NumberType { Min = 0, Precision = 2, Prefix = "$" } })
    .Edit(a => a.Rating, new Edit { RateType = new RateType { Count = 5, AllowHalf = true } })
    .Edit(a => a.Progress, new Edit { SliderType = new SliderType { Min = 0, Max = 100, Step = 5 } })
    .Edit(a => a.PublishDate, new Edit { Search = new Search { Operator = QueryExpression.RANGE } })
    .Edit(a => a.Meta, new Edit { CodeEditType = new CodeEditorType { Language = "json" } })
    // the node's own code (invoke, PROTOCOL.md §5.5)
    .OnChange(a => a.Title, form => form.GetValueOrDefault("title") is string { Length: > 0 } title
                                    && form.GetValueOrDefault("summary") is null or ""
        ? new FieldUpdate { FormData = new Record { ["summary"] = "About " + title } }
        : new FieldUpdate())
    .Fetch(a => a.Level, form =>
    {
        // an expert level once the article is read a lot
        var options = new List<(string, string)> { ("beginner", "Beginner"), ("advanced", "Advanced") };
        if (Convert.ToDouble(form.GetValueOrDefault("views") ?? 0L) >= 1000) options.Add(("expert", "Expert"));
        return options;
    })
    .Fetch(a => a.Labels, _ => ["hot", "new", "classic"])
    .Complete(a => a.City, (_, typed) => cities.Where(c => c.Contains(typed, StringComparison.OrdinalIgnoreCase)))
    // a JSON string literal is a JavaScript one too, so the title cannot break out of it
    .Click(a => a.Preview, form => new FieldUpdate { Eval = $"alert({JsonSerializer.Serialize("Preview: " + (form.GetValueOrDefault("title") ?? ""))})" })
    // row operations
    .Operation("publish", new OperationOptions
    {
        Title = "Publish", Icon = "fa fa-paper-plane", Form = EruptModel.Of<PublishForm>(), IfExpr = "item.status !== 'published'",
    }, async op =>
    {
        foreach (var row in op.Rows)
            await op.Repo.UpdateAsync(row["id"]!, new Record { ["status"] = "published", ["publish_date"] = op.Param!["publish_date"] }, op.CancellationToken);
    })
    .Operation("feature", new OperationOptions
    {
        Title = "Feature", Mode = RowOperationMode.SINGLE, Icon = "fa fa-star", ConfirmText = "Feature this article on the home page?",
    }, op => op.Repo.UpdateAsync(op.Rows[0]["id"]!, new Record { ["featured"] = true }, op.CancellationToken))
    .Operation("archive", new OperationOptions
    {
        Title = "Archive", Mode = RowOperationMode.MULTI_ONLY, Icon = "fa fa-archive", Confirm = false,
    }, async op =>
    {
        foreach (var row in op.Rows) await op.Repo.UpdateAsync(row["id"]!, new Record { ["status"] = "archived" }, op.CancellationToken);
    })
    .Operation("stats", new OperationOptions
    {
        Title = "Stats", Mode = RowOperationMode.BUTTON, Icon = "fa fa-bar-chart", Show = user => user?.Account == "admin",
    }, async op => $"alert('{(await op.Repo.PageAsync(new Query { Limit = 1 }, op.CancellationToken)).Total} articles')"),
    articles);

// ---------------------------------------------------------------- layout and JSON-valued components

node.Register(EruptModel.Of<Component>()
    .Edit(c => c.Intro, new Edit
    {
        Type = EditType.CALLOUT, CalloutType = new CalloutType { Value = "Layout and JSON-valued components.", Style = CalloutTypeStyle.INFO },
    })
    .Edit(c => c.Basic, new Edit { Type = EditType.DIVIDE })
    .Edit(c => c.Roles, new Edit { MultiChoiceType = new MultiChoiceType { Type = MultiChoiceTypeType.CHECKBOX } })
    .Edit(c => c.Langs, new Edit { MultiChoiceType = new MultiChoiceType { Type = MultiChoiceTypeType.SELECT } })
    .Edit(c => c.Attrs, new Edit { Type = EditType.KEY_VALUE, KeyValueType = new KeyValueType { KeyPlaceholder = "Key", ValuePlaceholder = "Value" } })
    .Edit(c => c.Spacer, new Edit { Type = EditType.EMPTY })
    .Edit(c => c.Extra, new Edit { Type = EditType.DIVIDE })
    .Edit(c => c.Place, new Edit { Type = EditType.GROUP, GroupType = new GroupType { Fields = ["location", "signature"] } }),
    components);

// ---------------------------------------------------------------- buttons, form behaviour, table display, server calls

node.Register(EruptModel.Of<Playground>()
    .Power(new Power { Export = false })
    .Options(new EruptOptions { Layout = new Layout { PageSize = 20, TableLeftFixed = 1 } })
    .Edit(p => p.Name, new Edit
    {
        Search = new Search { Operator = QueryExpression.LIKE, LockOperator = true },
        InputType = new InputType
        {
            Prefix = [new VL { Value = "@", Label = "@" }],
            Suffix = [new VL { Value = ".dev", Label = ".dev" }, new VL { Value = ".io", Label = ".io" }],
        },
        PlaceHolder = "a short name", Desc = "Shown first in the table",
    })
    .Edit(p => p.Level, new Edit { ChoiceType = new ChoiceType { DependField = "kind" } })
    .Edit(p => p.Note, new Edit
    {
        Dynamic = new Dynamic { DependField = "kind", Condition = "value === 'advanced'", Match = DynamicCtrl.SHOW, NoMatch = DynamicCtrl.HIDE },
    })
    .Edit(p => p.Code, new Edit { ReadOnly = new Readonly { Add = false, Edit = true } })
    .Edit(p => p.Amount, new Edit { NumberType = new NumberType { Prefix = "$" } })
    .View(p => p.Amount, new View { Statistic = ViewStatistic.SUM, ClassName = "text-right", Width = "120px" })
    .View(p => p.Score, new View { Statistic = ViewStatistic.AVG })
    .Edit(p => p.Files, new Edit { AttachmentType = new AttachmentType { Type = AttachmentTypeType.BASE, MaxLimit = 3, FileTypes = ["pdf", "txt", "md"] } })
    .Edit(p => p.Fill, new Edit { ButtonType = new ButtonType { Style = "primary", Icon = "fa fa-magic" } })
    .Edit(p => p.Reset, new Edit { ButtonType = new ButtonType { Danger = true, Confirm = "Clear the form?" } })
    .Edit(p => p.Whoami, new Edit { ButtonType = new ButtonType { FullSpan = true, Icon = "fa fa-user" } })
    // the level options follow the kind (choiceType.dependField)
    .Fetch(p => p.Level, form => form.GetValueOrDefault("kind") as string == "advanced"
        ? [("high", "High"), ("expert", "Expert")]
        : new (string, string)[] { ("low", "Low"), ("mid", "Mid") })
    .Fetch(p => p.Skills, _ => new (string, string)[] { ("java", "Java"), ("python", "Python"), ("go", "Go") })
    .Click(p => p.Fill, _ => new FieldUpdate { FormData = new Record { ["name"] = "sample", ["kind"] = "advanced", ["amount"] = 42L, ["score"] = 4L } })
    .Click(p => p.Reset, _ => new FieldUpdate { FormData = new Record { ["name"] = "", ["amount"] = 0L, ["score"] = 0L } })
    .Click(p => p.Whoami, _ => new FieldUpdate { Eval = $"alert({JsonSerializer.Serialize(EruptNode.CurrentUser?.Account ?? "")})" })
    .Operation("rename", new OperationOptions
    {
        Title = "Rename", Mode = RowOperationMode.SINGLE, Form = EruptModel.Of<RenameForm>(), Tip = "Give the row a new name",
    }, op => op.Repo.UpdateAsync(op.Rows[0]["id"]!, new Record { ["name"] = op.Param!["name"] }, op.CancellationToken))
    .Operation("double", new OperationOptions
    {
        Title = "Double", IfExpr = "item.amount > 0", Raw = new RowOperation { IfExprBehavior = RowOperationIfExprBehavior.HIDE },
    }, async op =>
    {
        foreach (var row in op.Rows)
            await op.Repo.UpdateAsync(row["id"]!, new Record { ["amount"] = Convert.ToDouble(row.GetValueOrDefault("amount") ?? 0L) * 2 }, op.CancellationToken);
    })
    .Operation("reset_amounts", new OperationOptions
    {
        Title = "Reset Amounts", ConfirmText = "Reset the amounts?", Raw = new RowOperation { Fold = true },
    }, async op =>
    {
        foreach (var row in op.Rows) await op.Repo.UpdateAsync(row["id"]!, new Record { ["amount"] = 0L }, op.CancellationToken);
    })
    .Operation("node_info", new OperationOptions
    {
        Title = "Node Info", Mode = RowOperationMode.BUTTON, Icon = "fa fa-info-circle",
    }, async op =>
    {
        // calls the erupt server back: the acting user's info and this node's config text, 0 when a call fails
        int roles, config;
        try
        {
            roles = (await node.UserInfoAsync(op.CancellationToken))?["roles"] is System.Text.Json.Nodes.JsonArray list ? list.Count : 0;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or JsonException)
        {
            roles = 0;
        }
        try
        {
            config = (await node.ConfigAsync(op.CancellationToken)).Length;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            config = 0;
        }
        return $"alert({JsonSerializer.Serialize($"{op.User?.Account ?? ""}: {roles} roles, config {config} chars")})";
    }),
    playground);

await Seed();
await node.RunAsync(int.Parse(Env("PORT") ?? "9090"));

// ---------------------------------------------------------------- seed data, each model only when its table is empty

async Task Seed()
{
    static List<object?> Keys(params long[] keys) => [.. keys.Cast<object?>()];
    await SeedTable(categories,
        new Record { ["name"] = "Tech", ["parent"] = null, ["sort"] = 1L },
        new Record { ["name"] = "Python", ["parent"] = 1L, ["sort"] = 2L },
        new Record { ["name"] = "Go", ["parent"] = 1L, ["sort"] = 3L },
        new Record { ["name"] = "Life", ["parent"] = null, ["sort"] = 4L },
        new Record { ["name"] = "Travel", ["parent"] = 4L, ["sort"] = 5L });
    await SeedTable(authors,
        new Record { ["name"] = "Ann", ["email"] = "ann@example.com", ["active"] = true },
        new Record { ["name"] = "Bob", ["email"] = "bob@example.com", ["active"] = true },
        new Record { ["name"] = "Cy", ["email"] = "cy@example.com", ["active"] = false });
    await SeedTable(tags,
        new Record { ["name"] = "intro", ["color"] = "#1677ff" },
        new Record { ["name"] = "guide", ["color"] = "#52c41a" },
        new Record { ["name"] = "news", ["color"] = "#fa8c16" });
    await SeedTable(articles,
        new Record
        {
            ["title"] = "Hello Erupt", ["summary"] = "A first look at erupt nodes", ["author"] = 1L, ["category"] = 2L, ["topic"] = 2L,
            ["tag_ids"] = Keys(1, 2), ["reviewers"] = Keys(2), ["sections"] = Keys(1, 2), ["status"] = "published", ["level"] = "beginner",
            ["labels"] = "hot,new", ["city"] = "Paris", ["views"] = 120L, ["price"] = 9.9, ["rating"] = 4.5, ["progress"] = 100L,
            ["featured"] = true, ["color"] = "#1677ff", ["icon"] = "fa fa-book", ["publish_date"] = new DateOnly(2026, 10, 1),
            ["review_at"] = new DateTime(2026, 10, 2, 10, 0, 0), ["content"] = "<p>Hello</p>", ["notes"] = "# Hello", ["meta"] = "{\"a\":1}",
        },
        new Record
        {
            ["title"] = "Go Tips", ["author"] = 2L, ["category"] = 3L, ["topic"] = 3L, ["tag_ids"] = Keys(2), ["status"] = "review",
            ["level"] = "advanced", ["labels"] = "classic", ["views"] = 30L, ["price"] = 0L, ["rating"] = 3L, ["progress"] = 60L, ["featured"] = false,
        },
        new Record
        {
            ["title"] = "Weekend Trip", ["author"] = 3L, ["category"] = 5L, ["topic"] = 5L, ["status"] = "draft", ["views"] = 0L,
            ["rating"] = 0L, ["progress"] = 10L, ["featured"] = false,
        });
    await SeedTable(components,
        new Record
        {
            ["name"] = "Sample A", ["code"] = "C-001", ["roles"] = new List<object?> { "ADMIN", "USER" },
            ["langs"] = new List<object?> { "JAVA", "GO" }, ["attrs"] = new Dictionary<string, object?> { ["env"] = "prod", ["tier"] = "1" },
        },
        new Record
        {
            ["name"] = "Sample B", ["code"] = "C-002", ["roles"] = new List<object?> { "GUEST" },
            ["langs"] = new List<object?> { "PYTHON" }, ["attrs"] = new Dictionary<string, object?>(),
        });
    await SeedTable(playground,
        new Record
        {
            ["name"] = "alpha", ["kind"] = "simple", ["level"] = "low", ["code"] = "A-1", ["amount"] = 10L, ["score"] = 3L,
            ["skills"] = new List<object?> { "java" },
        },
        new Record
        {
            ["name"] = "beta", ["kind"] = "advanced", ["level"] = "expert", ["note"] = "deep dive", ["code"] = "B-1", ["amount"] = 0L,
            ["score"] = 5L, ["skills"] = new List<object?> { "python", "go" },
        },
        new Record
        {
            ["name"] = "gamma", ["kind"] = "simple", ["level"] = "mid", ["code"] = "G-1", ["amount"] = 25L, ["score"] = 4L,
            ["skills"] = new List<object?>(),
        });
}

static async Task SeedTable(IRepository repo, params Record[] records)
{
    if ((await repo.PageAsync(new Query { Limit = 1 })).Total > 0) return;
    foreach (var record in records) await repo.AddAsync(record);
}

// ---------------------------------------------------------------- models

[EruptModel("Category")]
internal sealed class Category
{
    [Pk] public long Id { get; set; }
    [Field("Name", Search = true, NotNull = true, Sortable = true)] public string? Name { get; set; }
    [Field("Parent Id")] public long? Parent { get; set; }
    [Field("Sort", Sortable = true)] public long? Sort { get; set; }
}

[EruptModel("Author")]
internal sealed class Author
{
    [Pk] public long Id { get; set; }
    [Field("Name", Search = true, NotNull = true)] public string? Name { get; set; }
    [Field("Email")] public string? Email { get; set; }
    [Field("Active", Search = true, NotNull = true)] public bool? Active { get; set; }
}

[EruptModel("Tag")]
internal sealed class Tag
{
    [Pk] public long Id { get; set; }
    [Field("Name", Search = true, NotNull = true)] public string? Name { get; set; }
    [Field("Color", Type = EditType.COLOR)] public string? Color { get; set; }
}

/// <summary>The Publish operation's form: not registered.</summary>
[EruptModel("Publish Options")]
internal sealed class PublishForm
{
    [Field("Publish Date", NotNull = true)] public DateOnly? PublishDate { get; set; }
}

[EruptModel("Audit Log", OrderBy = "id desc")]
internal sealed class AuditLog
{
    [Pk] public long Id { get; set; }
    [Field("Action", Search = true), Choice("add", "Add"), Choice("update", "Update"), Choice("delete", "Delete")]
    public string? Action { get; set; }
    [Field("Article")] public string? Article { get; set; }
    [Field("By", Search = true)] public string? Account { get; set; }
    [Field("At", Sortable = true)] public DateTime? At { get; set; }
}

[EruptModel("Article", OrderBy = "id desc", DataProxy = [typeof(ArticleProxy)])]
internal sealed class Article
{
    [Pk] public long Id { get; set; }
    [Field("Title", Search = true, NotNull = true, Sortable = true)] public string? Title { get; set; }
    [Field("Summary", Type = EditType.TEXTAREA, Table = false)] public string? Summary { get; set; }
    [Field("Author", Search = true)] public Author? Author { get; set; }
    [Field("Category", Search = true)] public Category? Category { get; set; }
    [Field("Sub Category", Table = false, DependColumn = "parent")] public Category? SubCategory { get; set; }
    [Field("Topic", Tree = "parent", Table = false)] public Category? Topic { get; set; }
    [Field("Tags (checkbox)", Type = EditType.CHECKBOX, Ref = typeof(Tag), Table = false)] public List<long>? TagIds { get; set; }
    [Field("Reviewers", Type = EditType.TRANSFER, Ref = typeof(Author), Table = false)] public List<long>? Reviewers { get; set; }
    [Field("Sections", Type = EditType.TAB_TREE, Ref = typeof(Category), Table = false)] public List<long>? Sections { get; set; }
    [Field("Status", Search = true), Choice("draft", "Draft"), Choice("review", "In Review"), Choice("published", "Published"), Choice("archived", "Archived")]
    public string? Status { get; set; }
    [Field("Level", Type = EditType.CHOICE)] public string? Level { get; set; }
    [Field("Labels", Type = EditType.TAGS)] public string? Labels { get; set; }
    [Field("City", Type = EditType.AUTO_COMPLETE)] public string? City { get; set; }
    [Field("Cover", Type = EditType.ATTACHMENT)] public string? Cover { get; set; }
    [Field("Views", Sortable = true)] public long? Views { get; set; }
    [Field("Price")] public decimal? Price { get; set; }
    [Field("Rating", Type = EditType.RATE)] public double? Rating { get; set; }
    [Field("Progress", Type = EditType.SLIDER)] public long? Progress { get; set; }
    [Field("Featured", Search = true)] public bool? Featured { get; set; }
    [Field("Theme Color", Type = EditType.COLOR)] public string? Color { get; set; }
    [Field("Icon", Type = EditType.ICON, Table = false)] public string? Icon { get; set; }
    [Field("Publish Date", Search = true)] public DateOnly? PublishDate { get; set; }
    [Field("Review At", Sortable = true)] public DateTime? ReviewAt { get; set; }
    [Field("Content", Type = EditType.HTML_EDITOR, Table = false)] public string? Content { get; set; }
    [Field("Notes", Type = EditType.MARKDOWN, Table = false)] public string? Notes { get; set; }
    [Field("Meta (JSON)", Type = EditType.CODE_EDITOR, Table = false)] public string? Meta { get; set; }
    [Field("Preview", Type = EditType.BUTTON)] public string? Preview { get; set; }
}

[EruptModel("Component")]
internal sealed class Component
{
    [Pk] public long Id { get; set; }
    [Field("Name", Search = true, NotNull = true)] public string? Name { get; set; }
    [Field("Guide", Virtual = true)] public string? Intro { get; set; }
    [Field("Basic", Virtual = true)] public string? Basic { get; set; }
    [Field("Code", Type = EditType.HIDDEN, Table = false)] public string? Code { get; set; }
    [Field("Roles", Search = true), Choice("ADMIN", "Admin"), Choice("USER", "User"), Choice("GUEST", "Guest")]
    public List<string>? Roles { get; set; }
    [Field("Languages"), Choice("JAVA", "Java"), Choice("PYTHON", "Python"), Choice("GO", "Go"), Choice("RUST", "Rust")]
    public List<string>? Langs { get; set; }
    [Field("Attributes")] public Dictionary<string, string>? Attrs { get; set; }
    [Field("", Virtual = true)] public string? Spacer { get; set; }
    [Field("Extra", Virtual = true)] public string? Extra { get; set; }
    [Field("Location", Type = EditType.MAP)] public string? Location { get; set; }
    [Field("Signature", Type = EditType.SIGNATURE, Table = false)] public string? Signature { get; set; }
    [Field("Place & Sign", Virtual = true)] public string? Place { get; set; }
}

/// <summary>The Rename operation's form: not registered.</summary>
[EruptModel("Rename")]
internal sealed class RenameForm
{
    [Field("New Name", NotNull = true)] public string? Name { get; set; }
}

[EruptModel("Buttons & Forms")]
internal sealed class Playground
{
    [Pk] public long Id { get; set; }
    [Field("Name", Search = true, NotNull = true)] public string? Name { get; set; }
    [Field("Kind", Search = true), Choice("simple", "Simple"), Choice("advanced", "Advanced")] public string? Kind { get; set; }
    [Field("Level", Type = EditType.CHOICE)] public string? Level { get; set; }
    [Field("Advanced Note", Type = EditType.TEXTAREA, Table = false)] public string? Note { get; set; }
    [Field("Code")] public string? Code { get; set; }
    [Field("Amount")] public double? Amount { get; set; }
    [Field("Score")] public double? Score { get; set; }
    [Field("Skills", Type = EditType.MULTI_CHOICE)] public List<string>? Skills { get; set; }
    [Field("Files", Type = EditType.ATTACHMENT, Table = false)] public string? Files { get; set; }
    [Field("Fill Sample", Type = EditType.BUTTON)] public string? Fill { get; set; }
    [Field("Clear", Type = EditType.BUTTON)] public string? Reset { get; set; }
    [Field("Who Am I", Type = EditType.BUTTON)] public string? Whoami { get; set; }
}

/// <summary>Every hook of a data proxy. <see cref="Audit"/> is the Audit Log repository, set when the node starts.</summary>
internal sealed class ArticleProxy : IDataProxy
{
    internal static IRepository Audit = null!;
    internal static ILogger Log = null!;
    private static long _fetched;

    // the search bar opens on published articles
    public void SearchCondition(Record condition) => condition["status"] = "published";

    // archived articles leave every table
    public SqlFilter? BeforeFetch(IReadOnlyList<Cond> conditions) => "status <> 'archived'";

    public void AfterFetch(IReadOnlyList<System.Text.Json.Nodes.JsonObject> rows) =>
        Log.LogDebug("rows fetched so far: {Fetched}", Interlocked.Add(ref _fetched, rows.Count));

    public void AddBehavior(Record record)
    {
        record["status"] = "draft";
        record["views"] = 0L;
        record["progress"] = 0L;
    }

    public void EditBehavior(Record record)
    {
    }

    public void Validate(Record record)
    {
        if (record.GetValueOrDefault("title") as string == "forbidden") throw new EruptFailure("This title is not allowed");
    }

    public void BeforeAdd(Record record) => StampReview(record);

    public void BeforeUpdate(Record record) => StampReview(record);

    public void AfterAdd(Record record) => Write("add", record);

    public void AfterUpdate(Record record) => Write("update", record);

    public void BeforeDelete(Record record)
    {
        if (record.GetValueOrDefault("status") as string == "published") throw new EruptFailure("Unpublish it first");
    }

    public void AfterDelete(Record record) => Write("delete", record);

    private static void StampReview(Record record)
    {
        if (record.GetValueOrDefault("status") as string == "review" && record.GetValueOrDefault("review_at") is null)
            record["review_at"] = Now();
    }

    private static DateTime Now()
    {
        var now = DateTime.Now;
        return now.AddTicks(-(now.Ticks % TimeSpan.TicksPerSecond));
    }

    // hooks are synchronous; the audit row is written before the request answers
    private static void Write(string action, Record record) =>
        Audit.AddAsync(new Record
        {
            ["action"] = action, ["article"] = record.GetValueOrDefault("title"), ["account"] = EruptNode.CurrentUser?.Account,
            ["at"] = Now(),
        }).GetAwaiter().GetResult();
}
