//! A blog admin served from Rust, stored in SQLite. Create node "blog" on the erupt server first, then:
//!
//! ```text
//! ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 cargo run --features sqlite --example blog
//! ```
use erupt::types::RowOperationMode;
use erupt::{Dialect, Field, Model, Node, Operation, Record, SqlRepository, SqliteExecutor};
use serde_json::json;

fn main() -> erupt::Result<()> {
    let category = Model::new("Category", "Category")
        .field("id", Field::pk())
        .field("name", Field::input("Name").search().not_null())
        .field("parent", Field::number("Parent Id"))
        .build()?;
    let publish_form = Model::new("PublishForm", "Publish Options")
        .field("publish_date", Field::date("Publish Date").not_null())
        .build()?;
    let article = Model::new("Article", "Article")
        .order_by("id desc")
        .field("id", Field::pk())
        .field(
            "title",
            Field::input("Title").search().not_null().sortable(),
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
            Field::choice("Status", &[("draft", "Draft"), ("published", "Published")]).search(),
        )
        .field("views", Field::number("Views").sortable())
        .field("featured", Field::boolean("Featured").search())
        .field("publish_date", Field::date("Publish Date").search())
        .field("review_at", Field::date_time("Review At").sortable())
        .field("body", Field::textarea("Body").hide_table())
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
                        let change: Record = json!({"status": "published", "publish_date": date})
                            .as_object()
                            .cloned()
                            .unwrap_or_default();
                        op.repo.update(&row["id"], change)?;
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
                    let change: Record = json!({"featured": true})
                        .as_object()
                        .cloned()
                        .unwrap_or_default();
                    op.repo.update(&op.rows[0]["id"], change)?;
                    Ok(None)
                }),
        )
        .build()?;

    let env =
        |name: &str, fallback: &str| std::env::var(name).unwrap_or_else(|_| fallback.to_string());
    let mut node = Node::new(
        "blog",
        &env("ERUPT_ACCESS_TOKEN", ""),
        [env("ERUPT_SERVER", "http://localhost:8080")],
    );
    let sqlite = |table: &str| -> erupt::Result<SqlRepository> {
        Ok(
            SqlRepository::new(SqliteExecutor::open("blog.db")?, table, Dialect::Sqlite)
                .auto_create(),
        )
    };
    node.register(&category, sqlite("category")?)?;
    node.register(&article, sqlite("article")?)?;
    node.serve("0.0.0.0", env("PORT", "9090").parse().expect("PORT"))
}
