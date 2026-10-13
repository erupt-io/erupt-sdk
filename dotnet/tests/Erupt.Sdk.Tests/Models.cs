namespace Erupt.Tests;

[EruptModel("Category")]
public sealed class Category
{
    [Pk] public long Id { get; set; }
    [Field("Name", Search = true)] public string? Name { get; set; }
    [Field("Parent")] public long? Parent { get; set; }
}

[EruptModel("Publish Options")]
public sealed class PublishForm
{
    [Field("Note", NotNull = true)] public string? Note { get; set; }
}

[EruptModel("Article", OrderBy = "id desc")]
public sealed class Article
{
    [Pk] public long Id { get; set; }
    [Field("Title", Search = true, NotNull = true, Sortable = true)] public string? Title { get; set; }
    [Field("Status", Search = true), Choice("draft", "Draft"), Choice("published", "Published")] public string? Status { get; set; }
    [Field("Views", Sortable = true)] public long? Views { get; set; }
    [Field("Featured", Search = true)] public bool? Featured { get; set; }
    [Field("Publish Date", Search = true)] public DateOnly? PublishDate { get; set; }
    [Field("Review At")] public DateTime? ReviewAt { get; set; }
    [Field("Body", Type = EditType.TEXTAREA, Table = false)] public string? Body { get; set; }
    [Field("Category", Search = true)] public Category? Category { get; set; }
    [Field("Topic", Tree = "parent")] public Category? Topic { get; set; }
}

[EruptModel("Bad")]
public sealed class TwoPks
{
    [Pk] public long Id { get; set; }
    [Pk(Name = "other")] public long Other { get; set; }
}

[EruptModel("Bad")]
public sealed class UnsupportedType
{
    [Pk] public long Id { get; set; }
    [Field("Html", Type = EditType.HTML_EDITOR)] public string? Html { get; set; }
}

[EruptModel("Bad")]
public sealed class MissingLabel
{
    [Pk] public long Id { get; set; }
    [Field("Category", Label = "title")] public Category? Category { get; set; }
}

[EruptModel("Bad", OrderBy = "missing desc")]
public sealed class BadOrder
{
    [Pk] public long Id { get; set; }
}

[EruptModel("Bad", Name = "Bad-Name")]
public sealed class BadName
{
    [Pk] public long Id { get; set; }
}

public sealed class NotAModel
{
    [Pk] public long Id { get; set; }
}
