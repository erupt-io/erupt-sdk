//! A blog admin served from Rust, stored in SQLite: the showcase model of SHOWCASE.md. Create the node on the
//! erupt server first, then:
//!
//! ```text
//! ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 cargo run --features sqlite --example blog
//! ```
//!
//! `ERUPT_NODE_NAME` (default blog), `PORT` (9090) and `ERUPT_DB` (blog.db) are optional.
use erupt::types::RowOperationMode;
use erupt::{
    Dialect, Field, Model, Node, Operation, Query, Record, Repository, SqlRepository,
    SqliteExecutor,
};
use serde_json::{json, Value};

/// A JSON object literal as a record
fn record(value: Value) -> Record {
    value.as_object().cloned().unwrap_or_default()
}

fn main() -> erupt::Result<()> {
    let category = Model::new("Category", "Category")
        .field("id", Field::pk())
        .field("name", Field::input("Name").search().not_null().sortable())
        .field("parent", Field::number("Parent Id"))
        .field("sort", Field::number("Sort").sortable())
        .build()?;
    let publish_form = Model::new("PublishForm", "Publish Options")
        .field("publish_date", Field::date("Publish Date").not_null())
        .build()?;
    // Edit types without a shortcut are declared as their storage type (input, textarea, number) and turned
    // into the real type by a raw @Edit.
    let article = Model::new("Article", "Article")
        .order_by("id desc")
        .power(json!({"importable": true}))
        .field("id", Field::pk())
        .field(
            "title",
            Field::input("Title")
                .search()
                .not_null()
                .sortable()
                .edit(json!({"inputType": {"length": 60}})),
        )
        .field(
            "summary",
            Field::textarea("Summary")
                .hide_table()
                .edit(json!({"textareaType": {"length": 200}})),
        )
        .field("category", Field::reference(&category, "Category").search())
        .field(
            "topic",
            Field::reference(&category, "Topic")
                .tree("parent")
                .hide_table(),
        )
        .field(
            "status",
            Field::choice(
                "Status",
                &[
                    ("draft", "Draft"),
                    ("review", "In Review"),
                    ("published", "Published"),
                ],
            )
            .search(),
        )
        .field(
            "tags",
            Field::input("Tags").edit(
                json!({"type": "TAGS", "tagsType": {"allowExtension": true, "joinSeparator": ","}}),
            ),
        )
        .field(
            "views",
            Field::number("Views")
                .sortable()
                .edit(json!({"numberType": {"min": 0}})),
        )
        .field(
            "price",
            Field::number("Price")
                .edit(json!({"numberType": {"min": 0, "precision": 2, "prefix": "$"}})),
        )
        .field(
            "rating",
            Field::number("Rating")
                .edit(json!({"type": "RATE", "rateType": {"count": 5, "allowHalf": true}})),
        )
        .field(
            "progress",
            Field::number("Progress")
                .edit(json!({"type": "SLIDER", "sliderType": {"min": 0, "max": 100, "step": 5}})),
        )
        .field("featured", Field::boolean("Featured").search())
        .field(
            "color",
            Field::input("Theme Color").edit(json!({"type": "COLOR"})),
        )
        .field(
            "icon",
            Field::input("Icon")
                .hide_table()
                .edit(json!({"type": "ICON"})),
        )
        .field("publish_date", Field::date("Publish Date").search())
        .field("review_at", Field::date_time("Review At").sortable())
        .field(
            "content",
            Field::textarea("Content")
                .hide_table()
                .edit(json!({"type": "HTML_EDITOR"})),
        )
        .field(
            "notes",
            Field::textarea("Notes")
                .hide_table()
                .edit(json!({"type": "MARKDOWN"})),
        )
        .field(
            "meta",
            Field::textarea("Meta (JSON)")
                .hide_table()
                .edit(json!({"type": "CODE_EDITOR", "codeEditType": {"language": "json"}})),
        )
        .operation(
            Operation::new("publish", "Publish")
                .icon("fa fa-paper-plane")
                .form(&publish_form)
                .if_expr("item.status !== 'published'")
                .handler(|op| {
                    let date = op
                        .param
                        .as_ref()
                        .and_then(|p| p.get("publish_date"))
                        .cloned()
                        .unwrap_or_default();
                    for row in &op.rows {
                        op.repo.update(
                            &row["id"],
                            record(json!({"status": "published", "publish_date": date})),
                        )?;
                    }
                    Ok(None)
                }),
        )
        .operation(
            Operation::new("feature", "Feature")
                .mode(RowOperationMode::Single)
                .icon("fa fa-star")
                .confirm("Feature this article on the home page?")
                .handler(|op| {
                    op.repo
                        .update(&op.rows[0]["id"], record(json!({"featured": true})))?;
                    Ok(None)
                }),
        )
        .build()?;

    // every component that needs no extra endpoint: transient fields are in the build only, json() fields are
    // JSON arrays / objects
    let component = Model::new("Component", "Component")
        .field("id", Field::pk())
        .field("name", Field::input("Name").search().not_null())
        .field(
            "intro",
            Field::input("Guide").transient().edit(json!({"type": "CALLOUT", "calloutType": {
                "value": "Every component a node can declare without extra endpoints.", "style": "INFO"}})),
        )
        .field("basic", Field::input("Basic").transient().edit(json!({"type": "DIVIDE"})))
        .field("code", Field::input("Code").hide_table().edit(json!({"type": "HIDDEN"})))
        .field(
            "roles",
            Field::choice("Roles", &[("ADMIN", "Admin"), ("USER", "User"), ("GUEST", "Guest")])
                .json()
                .edit(json!({"type": "MULTI_CHOICE", "multiChoiceType": {"type": "CHECKBOX"}})),
        )
        .field(
            "langs",
            Field::choice(
                "Languages",
                &[("JAVA", "Java"), ("PYTHON", "Python"), ("GO", "Go"), ("RUST", "Rust")],
            )
            .json()
            .edit(json!({"type": "MULTI_CHOICE", "multiChoiceType": {"type": "SELECT"}})),
        )
        .field(
            "attrs",
            Field::input("Attributes").json().edit(json!({"type": "KEY_VALUE",
                "keyValueType": {"keyPlaceholder": "Key", "valuePlaceholder": "Value"}})),
        )
        .field("spacer", Field::input("").transient().edit(json!({"type": "EMPTY"})))
        .field("extra", Field::input("Extra").transient().edit(json!({"type": "DIVIDE"})))
        .field("location", Field::input("Location").edit(json!({"type": "MAP"})))
        .field(
            "signature",
            Field::input("Signature").hide_table().edit(json!({"type": "SIGNATURE"})),
        )
        .field(
            "place",
            Field::input("Place & Sign").transient().edit(json!({"type": "GROUP",
                "groupType": {"fields": ["location", "signature"]}})),
        )
        .build()?;

    let env =
        |name: &str, fallback: &str| std::env::var(name).unwrap_or_else(|_| fallback.to_string());
    let db = env("ERUPT_DB", "blog.db");
    let sqlite = |table: &str| -> erupt::Result<SqlRepository> {
        Ok(SqlRepository::new(SqliteExecutor::open(&db)?, table, Dialect::Sqlite).auto_create())
    };
    let mut node = Node::new(
        &env("ERUPT_NODE_NAME", "blog"),
        &env("ERUPT_ACCESS_TOKEN", ""),
        [env("ERUPT_SERVER", "http://localhost:8080")],
    );
    // bound to their models here, the same way register binds them, so the seed can write before serving
    let mut categories = sqlite("category")?;
    categories.bind(category.clone())?;
    let mut articles = sqlite("article")?;
    articles.bind(article.clone())?;
    seed(&categories, &articles)?;
    let mut components = sqlite("component")?;
    components.bind(component.clone())?;
    seed_components(&components)?;
    node.register(&category, sqlite("category")?)?;
    node.register(&article, sqlite("article")?)?;
    node.register(&component, sqlite("component")?)?;
    node.serve("0.0.0.0", env("PORT", "9090").parse().expect("PORT"))
}

/// Fills empty tables with the showcase records; references are stored as the key only.
fn seed(categories: &impl Repository, articles: &impl Repository) -> erupt::Result<()> {
    let one = Query {
        limit: 1,
        ..Query::default()
    };
    if categories.page(&one)?.0 > 0 {
        return Ok(());
    }
    for c in [
        json!({"name": "Tech", "parent": null, "sort": 1}),
        json!({"name": "Python", "parent": 1, "sort": 2}),
        json!({"name": "Go", "parent": 1, "sort": 3}),
        json!({"name": "Life", "parent": null, "sort": 4}),
        json!({"name": "Travel", "parent": 4, "sort": 5}),
    ] {
        categories.add(record(c))?;
    }
    for a in [
        json!({"title": "Hello Erupt", "summary": "A first look at erupt nodes.", "category": 2, "topic": 2,
            "status": "published", "tags": "intro,erupt", "views": 120, "price": 9.9, "rating": 4.5,
            "progress": 100, "featured": true, "color": "#1677ff", "icon": "fa fa-book",
            "publish_date": "2026-10-01", "review_at": "2026-10-02T10:00:00", "content": "<p>Hello</p>",
            "notes": "# Hello", "meta": "{\"a\":1}"}),
        json!({"title": "Go Tips", "category": 3, "topic": 3, "status": "review", "tags": "go", "views": 30,
            "price": 0, "rating": 3, "progress": 60, "featured": false}),
        json!({"title": "Weekend Trip", "category": 5, "topic": 5, "status": "draft", "views": 0, "rating": 0,
            "progress": 10, "featured": false}),
    ] {
        articles.add(record(a))?;
    }
    Ok(())
}

fn seed_components(components: &impl Repository) -> erupt::Result<()> {
    let one = Query {
        limit: 1,
        ..Query::default()
    };
    if components.page(&one)?.0 > 0 {
        return Ok(());
    }
    for c in [
        json!({"name": "Sample A", "code": "C-001", "roles": ["ADMIN", "USER"], "langs": ["JAVA", "GO"],
            "attrs": {"env": "prod", "tier": "1"}}),
        json!({"name": "Sample B", "code": "C-002", "roles": ["GUEST"], "langs": ["PYTHON"], "attrs": {}}),
    ] {
        components.add(record(c))?;
    }
    Ok(())
}
