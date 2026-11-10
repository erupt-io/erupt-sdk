using System.Globalization;
using System.Reflection;
using System.Text.Json.Nodes;

namespace Erupt;

/// <summary>A declared column: its edit type, flags and raw overrides.</summary>
internal sealed class FieldDef
{
    private static readonly Type[] Numbers =
        [typeof(int), typeof(long), typeof(short), typeof(byte), typeof(sbyte), typeof(uint), typeof(ulong), typeof(ushort),
         typeof(float), typeof(double), typeof(decimal)];

    internal const string DateTimeType = "DATE_TIME"; // not an EditType: a DATE with a time of day

    // the edit types this SDK stores and serves
    private static readonly HashSet<string> Supported =
    [
        "ATTACHMENT", "AUTO_COMPLETE", "BOOLEAN", "BUTTON", "CHECKBOX", "CHOICE", "CODE_EDITOR", "COLOR", "DATE", DateTimeType, "HIDDEN",
        "HTML_EDITOR", "ICON", "INPUT", "MAP", "MARKDOWN", "MULTI_CHOICE", "NUMBER", "RATE", "REFERENCE_TABLE", "REFERENCE_TREE",
        "SIGNATURE", "SLIDER", "TAB_TREE", "TAGS", "TEXTAREA", "TRANSFER",
    ];

    // fieldReturnName by edit type (PROTOCOL.md §7.1); a reference names its target, the rest are "String"
    private static readonly Dictionary<string, string> ReturnNames = new()
    {
        ["NUMBER"] = "number", ["RATE"] = "number", ["SLIDER"] = "number", ["BOOLEAN"] = "Boolean", ["DATE"] = "Date", [DateTimeType] = "Date",
    };

    // many records of another model, stored as the JSON list of their keys
    private static readonly string[] Collections = ["CHECKBOX", "TAB_TREE", "TRANSFER"];

    // the edit attribute that names a fetchHandler, by the type that fetches options
    private static readonly Dictionary<string, string> Fetched = new() { ["CHOICE"] = "choiceType", ["MULTI_CHOICE"] = "multiChoiceType", ["TAGS"] = "tagsType" };

    internal required EruptModel Model { get; init; }
    internal required PropertyInfo Property { get; init; }
    internal required string Name { get; init; }
    internal required string Title { get; init; }
    internal bool IsPk { get; init; }

    /// <summary>An EditType name, or DATE_TIME; null for the primary key.</summary>
    internal string? Type { get; init; }

    internal bool Search { get; init; }
    internal bool NotNull { get; init; }
    internal bool Sortable { get; init; }
    internal bool Table { get; init; } = true;
    internal bool Form { get; init; } = true;

    /// <summary>In the build only: no column, never read or written.</summary>
    internal bool Virtual { get; init; }

    /// <summary>A list or dictionary property (MULTI_CHOICE, KEY_VALUE): a JSON value, kept as JSON text by <see cref="DbRepository"/>.</summary>
    internal bool IsJson { get; init; }

    internal List<(string Value, string Label)>? Choices { get; init; }
    internal Type? Ref { get; init; }
    internal string Label { get; init; } = "name";
    internal string? Tree { get; init; }

    /// <summary>referenceTableType.dependColumn, <c>@Transient</c> in Java: written into the build here.</summary>
    internal string? DependColumn { get; init; }

    internal JsonObject EditRaw { get; } = [];
    internal JsonObject ViewRaw { get; } = [];

    /// <summary>The field's own code by invoke kind (options, onchange, autocomplete, button): form and typed value to the answer.</summary>
    internal Dictionary<string, Func<Record, string, Task<JsonNode?>>> Invoked { get; } = [];

    internal bool IsReference => Type is "REFERENCE_TABLE" or "REFERENCE_TREE";

    internal bool IsCollection => Collections.Contains(Type);

    internal bool IsNumber => Type is "NUMBER" or "RATE" or "SLIDER";

    /// <summary>Name and primary key of the referenced model, read from its declaration.</summary>
    internal (string Name, string Pk) Target
    {
        get
        {
            var target = Ref!;
            var attribute = target.GetCustomAttribute<EruptModelAttribute>()!;
            var pk = EruptModel.Properties(target).First(p => p.GetCustomAttribute<PkAttribute>() is not null);
            return (attribute.Name ?? target.Name, EruptModel.WireName(pk)!);
        }
    }

    internal static FieldDef? From(EruptModel model, PropertyInfo property)
    {
        var name = EruptModel.WireName(property);
        if (name is null) return null;
        var path = $"{model.Name}.{name}";
        if (!EruptModel.Identifier().IsMatch(name)) throw new ArgumentException($"field '{name}' must be an identifier");
        if (property.GetCustomAttribute<PkAttribute>() is not null)
            return new FieldDef { Model = model, Property = property, Name = name, Title = "", IsPk = true };
        var a = property.GetCustomAttribute<FieldAttribute>()!;
        if (!Enum.IsDefined(a.Type)) throw new ArgumentException($"{path}.type: '{(int)a.Type}' is not an EditType");
        var clr = Nullable.GetUnderlyingType(property.PropertyType) ?? property.PropertyType;
        var choices = property.GetCustomAttributes<ChoiceAttribute>().Select(c => (c.Value, c.Label)).ToList();
        var reference = a.Ref ?? (clr.GetCustomAttribute<EruptModelAttribute>() is not null ? clr : null);
        var json = clr != typeof(string) && typeof(System.Collections.IEnumerable).IsAssignableFrom(clr);
        string type;
        if (Collections.Contains(a.Type.ToString())) type = a.Type.ToString();
        else if (reference is not null) type = a.Tree is null ? "REFERENCE_TABLE" : "REFERENCE_TREE";
        else if (a.Type != EditType.AUTO) type = a.Type.ToString();
        else if (choices.Count > 0) type = json ? "MULTI_CHOICE" : "CHOICE";
        else if (clr == typeof(bool)) type = "BOOLEAN";
        else if (Numbers.Contains(clr)) type = "NUMBER";
        else if (clr == typeof(DateTime) || clr == typeof(DateTimeOffset)) type = DateTimeType;
        else if (clr == typeof(DateOnly)) type = "DATE";
        else type = "INPUT";
        if (!Supported.Contains(type)) throw new ArgumentException($"{path}: edit type {type} is not supported yet");
        var isVirtual = a.Virtual || type == "BUTTON"; // a BUTTON is a form element only
        if (isVirtual && (a.Search || a.Sortable || a.NotNull)) throw new ArgumentException($"{path}: a virtual field cannot be searched, sorted or required");
        // a MULTI_CHOICE is searched by the values it holds (EruptNode.Condition); other JSON values are not searched
        if (json && (a.Sortable || (a.Search && choices.Count == 0)))
            throw new ArgumentException($"{path}: a JSON field cannot be sorted, and only a MULTI_CHOICE one searched");
        var field = new FieldDef
        {
            Model = model, Property = property, Name = name, Title = a.Title, Type = type,
            Search = a.Search, NotNull = a.NotNull, Sortable = a.Sortable, Table = a.Table, Form = a.Form, Virtual = isVirtual, IsJson = json || Collections.Contains(type),
            Choices = choices.Count > 0 ? choices : null, Ref = reference, Label = a.Label, Tree = a.Tree, DependColumn = a.DependColumn,
        };
        if (a.DependColumn is not null && type != "REFERENCE_TABLE") throw new ArgumentException($"{path}: DependColumn belongs to a REFERENCE_TABLE");
        if (reference is not null) field.CheckReference(path);
        else if (field.IsCollection) throw new ArgumentException($"{path}: a {type} needs Ref");
        return field;
    }

    private void CheckReference(string path)
    {
        var target = Ref!;
        if (target.GetCustomAttribute<EruptModelAttribute>() is null) throw new ArgumentException($"{path}: Ref {target.Name} is not marked with [EruptModel]");
        var props = EruptModel.Properties(target).ToList();
        if (!props.Any(p => p.GetCustomAttribute<PkAttribute>() is not null)) throw new ArgumentException($"{path}: {target.Name} has no [Pk]");
        var names = props.Select(EruptModel.WireName).Where(n => n is not null).ToHashSet();
        foreach (var key in Tree is null ? [Label] : new[] { Label, Tree })
            if (!names.Contains(key)) throw new ArgumentException($"{path}: {target.Name} has no field '{key}'");
    }

    /// <summary>The field as declared (PROTOCOL.md §12.3): the server completes the rest from Java's defaults.</summary>
    internal JsonObject Build()
    {
        if (IsPk)
        {
            return new JsonObject
            {
                ["fieldName"] = Name, ["fieldReturnName"] = "number", ["componentValue"] = null,
                ["eruptFieldJson"] = new JsonObject { ["edit"] = new JsonObject { ["title"] = "", ["type"] = "NUMBER" } },
            };
        }
        // a DATE_TIME is a DATE whose dateType says so; a DATE says it too, as AUTO is the node's to resolve
        var edit = new JsonObject { ["title"] = Title, ["type"] = Type == DateTimeType ? "DATE" : Type };
        if (Type is "DATE" or DateTimeType) edit["dateType"] = new JsonObject { ["type"] = Type };
        if (NotNull) edit["notNull"] = true;
        if (!Form) edit["show"] = false;
        if (Search) edit["search"] = new JsonObject { ["value"] = true };
        var view = new JsonObject { ["title"] = Title };
        if (Sortable) view["sortable"] = true;
        var returnName = ReturnNames.GetValueOrDefault(Type!, "String");
        if (Type == "REFERENCE_TABLE")
        {
            edit["referenceTableType"] = new JsonObject { ["id"] = Target.Pk, ["label"] = Label };
            if (DependColumn is not null) edit["referenceTableType"]!["dependColumn"] = DependColumn;
        }
        else if (Type == "REFERENCE_TREE") edit["referenceTreeType"] = new JsonObject { ["id"] = Target.Pk, ["label"] = Label, ["pid"] = Tree };
        if (IsReference || IsCollection)
        {
            // the server lists a CHECKBOX by the view column, a TAB_TREE by the target's own tree
            returnName = Target.Name;
            view["column"] = Label;
        }
        if (Invoked.ContainsKey("options")) edit[Fetched[Type!]] = new JsonObject { ["fetchHandler"] = new JsonArray("invoke") };
        if (Invoked.ContainsKey("onchange")) edit["onchange"] = "invoke";
        Json.Merge(edit, EditRaw);
        Json.Merge(view, ViewRaw);
        // a CHOICE, or a MULTI_CHOICE by raw edit type: the options travel as componentValue
        var options = Choices is null ? null : new JsonArray(Choices.Select(c => (JsonNode)new JsonObject
        {
            ["value"] = c.Value, ["label"] = c.Label, ["desc"] = null, ["color"] = null, ["disable"] = false,
        }).ToArray());
        return new JsonObject
        {
            ["fieldName"] = Name, ["fieldReturnName"] = returnName, ["componentValue"] = options,
            // a BUTTON is a form element only: no table column
            ["eruptFieldJson"] = new JsonObject { ["edit"] = edit, ["views"] = Table && Type != "BUTTON" ? new JsonArray(view) : new JsonArray() },
        };
    }

    /// <summary>
    /// A JSON value as the server sends it (PROTOCOL.md §12.4) to the value the repository stores: a date as
    /// <see cref="DateOnly"/> / <see cref="DateTime"/>, a key as its key type. The server has checked it; a key in a path
    /// segment, a delete body or an operation's ids arrives as the browser sent it, so it may fail here.
    /// </summary>
    internal object? Coerce(object? value)
    {
        if (IsReference || IsPk) return CoercePk(value);
        if (IsCollection) return value is IList<object?> items ? items.Select(CoercePk).ToList() : new List<object?>();
        if (value is null || value is "") return null;
        if (IsJson) return value;
        switch (Type)
        {
            case "BOOLEAN":
                return value is bool b ? b : throw new FormatException($"illegal boolean '{Values.Str(value)}'");
            case "NUMBER" or "RATE" or "SLIDER":
                if (!double.TryParse(Values.Str(value), NumberStyles.Float, CultureInfo.InvariantCulture, out var number) || !double.IsFinite(number))
                    throw new FormatException($"illegal number '{Values.Str(value)}'");
                return Values.Number(number);
            case DateTimeType:
                return Values.ParseDateTime(value);
            case "DATE":
                return DateOnly.FromDateTime(Values.ParseDateTime(value));
            default:
                return Values.Str(value);
        }
    }

    internal static object? CoercePk(object? value)
    {
        if (value is null || value is "") return null;
        switch (Values.Normalize(value))
        {
            case long l:
                return l;
            case double d when Math.Floor(d) == d:
                return (long)d;
            case string s when long.TryParse(s, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var parsed):
                return parsed;
            default:
                throw new FormatException($"illegal id '{Values.Str(value)}'");
        }
    }
}

/// <summary>What a field's onchange or BUTTON code answers.</summary>
public sealed class FieldUpdate
{
    /// <summary>A BUTTON only: JavaScript run in the browser, so only return code you wrote.</summary>
    public string? Eval { get; init; }

    /// <summary>Values put into the form, by field name.</summary>
    public Record? FormData { get; init; }

    /// <summary>Browser-side expressions run on the form, by field name (<c>edit.desc="..."</c>).</summary>
    public Dictionary<string, string>? EditExpr { get; init; }

    internal JsonObject ToJson(bool button)
    {
        // only what the code set: an onchange that changes nothing answers {}
        var json = new JsonObject();
        if (button && Eval is not null) json["eval"] = Eval;
        if (FormData is { Count: > 0 }) json["formData"] = Values.ToJson(FormData);
        if (EditExpr is { Count: > 0 }) json["editExpr"] = Values.ToJson(EditExpr);
        return json;
    }
}

/// <summary>What a row operation is declared with.</summary>
public sealed class OperationOptions
{
    public required string Title { get; init; }

    /// <summary>SINGLE (row button), MULTI (row and toolbar), MULTI_ONLY (toolbar), BUTTON (toolbar, no rows).</summary>
    public RowOperationMode Mode { get; init; } = RowOperationMode.MULTI;

    public string? Icon { get; init; }

    public string Tip { get; init; } = "";

    /// <summary>False runs the operation without the confirm dialog.</summary>
    public bool Confirm { get; init; } = true;

    /// <summary>Replaces the confirm dialog's text.</summary>
    public string? ConfirmText { get; init; }

    /// <summary>A model (without repository) whose fields are asked for before running.</summary>
    public EruptModel? Form { get; init; }

    /// <summary>Hides the operation from a user and refuses to run it for them.</summary>
    public Func<EruptUser?, bool>? Show { get; init; }

    /// <summary>Browser-side JavaScript over <c>item</c> that disables (or hides) the row button.</summary>
    public string IfExpr { get; init; } = "";

    /// <summary>Raw <c>@RowOperation</c> attributes, merged on top; the server checks them.</summary>
    public RowOperation? Raw { get; init; }
}

/// <summary>What an operation handler receives.</summary>
public sealed class OperationContext
{
    /// <summary>Selected records as the repository returned them; empty for BUTTON mode.</summary>
    public required IReadOnlyList<Record> Rows { get; init; }

    /// <summary>Coerced form values, or null without a form.</summary>
    public Record? Param { get; init; }

    public required IRepository Repo { get; init; }

    public required EruptModel Model { get; init; }

    public EruptUser? User { get; init; }

    public CancellationToken CancellationToken { get; init; }
}

internal sealed class OperationDef
{
    private readonly OperationOptions _options;
    private readonly JsonObject _raw;

    internal OperationDef(string code, OperationOptions options, Func<OperationContext, Task<string?>> handler, string path)
    {
        Code = code;
        _options = options;
        Handler = handler;
        if (!Enum.IsDefined(options.Mode)) throw new ArgumentException($"{path}.mode: '{(int)options.Mode}' is not a RowOperationMode");
        _raw = Json.Declared(options.Raw);
    }

    internal string Code { get; }
    internal Func<OperationContext, Task<string?>> Handler { get; }
    internal RowOperationMode Mode => _options.Mode;
    internal EruptModel? Form => _options.Form;

    internal bool Visible(EruptUser? user) => _options.Show is null || _options.Show(user);

    internal JsonObject Build()
    {
        var tpl = new JsonObject
        {
            ["code"] = Code, ["title"] = _options.Title, ["mode"] = _options.Mode.ToString(), ["tip"] = _options.Tip,
            ["ifExpr"] = _options.IfExpr, ["eruptClass"] = _options.Form?.Name ?? "void",
        };
        if (_options.Icon is not null) tpl["icon"] = _options.Icon;
        if (!_options.Confirm) tpl["callHint"] = ""; // the browser runs it without asking
        else if (_options.ConfirmText is not null) tpl["callHint"] = _options.ConfirmText;
        return Json.Merge(tpl, _raw);
    }
}
