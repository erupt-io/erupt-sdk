using System.Text.Json.Nodes;
using Erupt.GenTypes;

namespace Erupt.Tests;

public class DeclarationTests
{
    [Fact]
    public void BuildsDeclaredAttributesOnly()
    {
        var model = EruptModel.Of<Article>().Edit(a => a.Title, new Edit { InputType = new InputType { Length = 64 } });
        var json = model.BuildErupt();
        var fields = json["eruptFieldModels"]!.AsArray().ToDictionary(f => f!["fieldName"]!.GetValue<string>(), f => f!.ToJsonString());
        Assert.Equal(["id", "title", "status", "views", "featured", "publish_date", "review_at", "body", "category", "topic"], fields.Keys);
        Assert.Equal("""{"fieldName":"id","fieldReturnName":"number","componentValue":null,"eruptFieldJson":{"edit":{"title":"","type":"NUMBER"}}}""", fields["id"]);
        // a typed override carries only what it sets
        Assert.Equal("""{"fieldName":"title","fieldReturnName":"String","componentValue":null,"eruptFieldJson":{"edit":{"title":"Title","type":"INPUT","notNull":true,"search":{"value":true},"inputType":{"length":64}},"views":[{"title":"Title","sortable":true}]}}""", fields["title"]);
        Assert.Equal("""{"fieldName":"views","fieldReturnName":"number","componentValue":null,"eruptFieldJson":{"edit":{"title":"Views","type":"NUMBER"},"views":[{"title":"Views","sortable":true}]}}""", fields["views"]);
        Assert.Equal("""{"fieldName":"featured","fieldReturnName":"Boolean","componentValue":null,"eruptFieldJson":{"edit":{"title":"Featured","type":"BOOLEAN","search":{"value":true}},"views":[{"title":"Featured"}]}}""", fields["featured"]);
        Assert.Equal("""{"fieldName":"review_at","fieldReturnName":"Date","componentValue":null,"eruptFieldJson":{"edit":{"title":"Review At","type":"DATE","dateType":{"type":"DATE_TIME"}},"views":[{"title":"Review At"}]}}""", fields["review_at"]);
        Assert.Equal("""{"fieldName":"publish_date","fieldReturnName":"Date","componentValue":null,"eruptFieldJson":{"edit":{"title":"Publish Date","type":"DATE","dateType":{"type":"DATE"},"search":{"value":true}},"views":[{"title":"Publish Date"}]}}""", fields["publish_date"]);
        Assert.Equal("""{"fieldName":"body","fieldReturnName":"String","componentValue":null,"eruptFieldJson":{"edit":{"title":"Body","type":"TEXTAREA"},"views":[]}}""", fields["body"]);
        Assert.Equal("""{"fieldName":"category","fieldReturnName":"Category","componentValue":null,"eruptFieldJson":{"edit":{"title":"Category","type":"REFERENCE_TABLE","search":{"value":true},"referenceTableType":{"id":"id","label":"name"}},"views":[{"title":"Category","column":"name"}]}}""", fields["category"]);
        Assert.Equal("""{"fieldName":"topic","fieldReturnName":"Category","componentValue":null,"eruptFieldJson":{"edit":{"title":"Topic","type":"REFERENCE_TREE","referenceTreeType":{"id":"id","label":"name","pid":"parent"}},"views":[{"title":"Topic","column":"name"}]}}""", fields["topic"]);
        Assert.Contains("""{"value":"draft","label":"Draft","desc":null,"color":null,"disable":false}""", fields["status"]);
        Assert.Equal("""{"primaryKeyCol":"id","rowOperation":[]}""", json["eruptJson"]!.ToJsonString());
    }

    [Fact]
    public void BuildsOperationsAndOptionsAsDeclared()
    {
        var model = EruptModel.Of<Article>()
            .Options(new EruptOptions { Layout = new Layout { PageSize = 30 } })
            .Power(new Power { Delete = false })
            .Operation("publish", new OperationOptions { Title = "Publish", Form = EruptModel.Of<PublishForm>() }, _ => Task.CompletedTask)
            .Operation("go", new OperationOptions { Title = "Go", Icon = "fa fa-play", Confirm = false, Raw = new RowOperation { Tip = "raw" } }, _ => Task.CompletedTask);
        var built = model.BuildModel(model.PowerJson, null);
        var erupt = built["eruptModel"]!["eruptJson"]!;
        Assert.Equal("""{"primaryKeyCol":"id","rowOperation":[{"code":"publish","title":"Publish","mode":"MULTI","tip":"","ifExpr":"","eruptClass":"PublishForm"},{"code":"go","title":"Go","mode":"MULTI","tip":"raw","ifExpr":"","eruptClass":"void","icon":"fa fa-play","callHint":""}],"layout":{"pageSize":30}}""",
            erupt.ToJsonString());
        Assert.Equal("""{"delete":false}""", built["power"]!.ToJsonString());
        Assert.Equal("PublishForm", built["operationErupts"]!["publish"]!["eruptName"]!.GetValue<string>());
    }

    [Theory]
    [InlineData(typeof(TwoPks), "at most one [Pk]")]
    [InlineData(typeof(UnsupportedType), "edit type TPL is not supported yet")]
    [InlineData(typeof(MissingLabel), "has no field 'title'")]
    [InlineData(typeof(BadOrder), "illegal OrderBy 'missing desc'")]
    [InlineData(typeof(BadName), "must be an identifier")]
    [InlineData(typeof(NotAModel), "is not marked with [EruptModel]")]
    [InlineData(typeof(BadEditType), "is not an EditType")]
    public void RejectsIllegalDeclarations(Type type, string message)
    {
        var of = typeof(EruptModel).GetMethod(nameof(EruptModel.Of))!.MakeGenericMethod(type);
        var e = Assert.Throws<System.Reflection.TargetInvocationException>(() => of.Invoke(null, null));
        Assert.Contains(message, Assert.IsType<ArgumentException>(e.InnerException).Message);
    }

    [Fact]
    public void RejectsIllegalOperations()
    {
        var model = EruptModel.Of<Article>().Operation("go", new OperationOptions { Title = "Go" }, _ => Task.CompletedTask);
        Assert.Contains("declared twice", Assert.Throws<ArgumentException>(() =>
            model.Operation("go", new OperationOptions { Title = "Again" }, _ => Task.CompletedTask)).Message);
        Assert.Contains("is not a RowOperationMode", Assert.Throws<ArgumentException>(() =>
            model.Operation("odd", new OperationOptions { Title = "Odd", Mode = (RowOperationMode)42 }, _ => Task.CompletedTask)).Message);
    }

    [Fact]
    public void RejectsIllegalDrills()
    {
        Assert.Contains("needs Link.LinkErupt", Assert.Throws<ArgumentException>(() =>
            EruptModel.Of<Author>().Drill(new Drill { Title = "Books", Link = new Link() }, "author")).Message);
        Assert.Contains("needs Link.LinkErupt", Assert.Throws<ArgumentException>(() =>
            EruptModel.Of<Author>().Drill(new Drill { Title = "Books", Link = new Link { LinkErupt = "Book" } }, "")).Message);
        Assert.Contains("declared twice", Assert.Throws<ArgumentException>(() => EruptModel.Of<Author>()
            .Drill(new Drill { Title = "Books", Link = new Link { LinkErupt = "Book" } }, "author")
            .Drill(new Drill { Title = "Books", Link = new Link { LinkErupt = "Book" } }, "author")).Message);
        Assert.Contains("cannot be sorted", Assert.Throws<ArgumentException>(() => EruptModel.Of<SortedJson>()).Message);
        Assert.Contains("only a MULTI_CHOICE one searched", Assert.Throws<ArgumentException>(() => EruptModel.Of<SearchedKeyValue>()).Message);
        Assert.Equal("""{"value":true}""", EruptModel.Of<Palette>().BuildErupt()["eruptFieldModels"]![2]!["eruptFieldJson"]!["edit"]!["search"]!.ToJsonString());
        Assert.Contains("through Drill(...)", Assert.Throws<ArgumentException>(() =>
            EruptModel.Of<Author>().Options(new EruptOptions { Drills = [] })).Message);
    }

    [Fact]
    public void GeneratedTypesAreCurrent()
    {
        var library = Path.Combine(Root(), "src", "Erupt.Sdk");
        var schema = File.ReadAllText(Path.Combine(Root(), "..", "schema", Generator.Schema));
        Assert.Equal(Generator.Generate(schema), File.ReadAllText(Path.Combine(library, "Types.g.cs")));
    }

    [Fact]
    public void CoercesToStorageTypes()
    {
        var model = EruptModel.Of<Article>();
        object? Coerce(string field, object? value) => model.FieldMap[field].Coerce(value);
        Assert.Equal(3L, Coerce("views", 3L));
        Assert.Equal(3L, Coerce("views", "3"));
        Assert.Equal(2.5, Coerce("views", 2.5));
        Assert.Throws<FormatException>(() => Coerce("views", "many"));
        Assert.Equal(new DateOnly(2026, 1, 5), Coerce("publish_date", "2026-01-05"));
        Assert.Equal(new DateTime(2026, 1, 5, 10, 30, 0), Coerce("review_at", "2026-01-05 10:30:00"));
        Assert.Equal(DateTimeKind.Unspecified, ((DateTime)Coerce("review_at", "2026-01-05 10:30:00")!).Kind);
        Assert.Throws<FormatException>(() => Coerce("publish_date", "someday"));
        Assert.Equal(true, Coerce("featured", true));
        Assert.Equal("deleted", Coerce("status", "deleted")); // the server checked the options
        Assert.Equal(2L, Coerce("category", 2L));
        Assert.Equal(2L, Coerce("category", "2"));
        Assert.Throws<FormatException>(() => Coerce("category", "x"));
        Assert.Null(Coerce("title", ""));
    }

    internal static string Root()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "src", "Erupt.Sdk"))) dir = dir.Parent;
        return dir?.FullName ?? throw new InvalidOperationException("dotnet/ not found");
    }
}
