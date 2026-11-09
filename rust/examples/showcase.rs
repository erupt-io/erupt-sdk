//! The showcase admin served from Rust that uses every capability of the SDK, as SHOWCASE.md describes it, stored in
//! SQLite. Create the node on the erupt server first, then:
//!
//! ```text
//! ERUPT_NODE_NAME=showcase ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 \
//!     cargo run --features sqlite --example showcase
//! ```
//!
//! `PORT` (default 9090) and `ERUPT_DB` (default showcase.db) are optional. Edit types without a constructor are
//! declared as the storage type they hold with the edit type in a raw `.edit(...)`; form-only elements are
//! `transient()`; MULTI_CHOICE / KEY_VALUE hold JSON. Models: Category, Author, Tag, Article, Component, AuditLog
//! and Playground ("Buttons & Forms"); PublishForm and RenameForm are operation forms only.
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use erupt::types::{EditType, RowOperationMode};
use erupt::{
    current_user, Cond, DataProxy, Dialect, Error, Field, Filter, Model, Node, Operation, Query,
    Record, Repository, SqlRepository, SqliteExecutor,
};
use serde_json::{json, Value};

/// A JSON object literal as a record
fn record(value: Value) -> Record {
    value.as_object().cloned().unwrap_or_default()
}

/// A text value of a form or record, empty when missing
fn str_of<'a>(record: &'a Record, key: &str) -> &'a str {
    record.get(key).and_then(Value::as_str).unwrap_or("")
}

/// The wall clock as the SDK's date time text (UTC; std has no time zones)
fn now() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let (days, rest) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // civil from days (Howard Hinnant)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

fn one() -> Query {
    Query {
        limit: 1,
        ..Query::default()
    }
}

// ---------------------------------------------------------------- the node's own code (invoke)

const CITIES: [&str; 4] = ["Paris", "Tokyo", "Lisbon", "Austin"];

/// title onchange: suggest a summary while there is none.
fn summary_from_title(form: &Record) -> erupt::Result<Value> {
    let title = str_of(form, "title");
    if !title.is_empty() && str_of(form, "summary").is_empty() {
        return Ok(json!({"formData": {"summary": format!("About {title}")}}));
    }
    Ok(json!({}))
}

/// level options: an expert level once the article is read a lot.
fn levels(form: &Record) -> erupt::Result<Vec<(String, String)>> {
    let mut options = vec![
        ("beginner".to_string(), "Beginner".to_string()),
        ("advanced".to_string(), "Advanced".to_string()),
    ];
    let views = form
        .get("views")
        .and_then(erupt::values::as_f64)
        .unwrap_or(0.0);
    if views >= 1000.0 {
        options.push(("expert".to_string(), "Expert".to_string()));
    }
    Ok(options)
}

/// preview click: the title, escaped as a JS string literal.
fn preview(form: &Record) -> erupt::Result<Value> {
    let message = Value::String(format!("Preview: {}", str_of(form, "title")));
    Ok(json!({"eval": format!("alert({message})")}))
}

/// Every hook of a data proxy; `audit` is the Audit Log repository.
struct ArticleProxy {
    audit: Arc<dyn Repository>,
    fetched: AtomicUsize,
}

impl ArticleProxy {
    fn stamp_review(record: &mut Record) {
        let empty = record.get("review_at").is_none_or(Value::is_null);
        if str_of(record, "status") == "review" && empty {
            record.insert("review_at".into(), json!(now()));
        }
    }

    fn log(&self, action: &str, article: &Record) -> erupt::Result<()> {
        let account = current_user()
            .and_then(|u| u.get("account").cloned())
            .unwrap_or(Value::Null);
        self.audit.add(record(json!({"action": action,
            "article": article.get("title").cloned().unwrap_or(Value::Null), "account": account, "at": now()})))
    }
}

impl DataProxy for ArticleProxy {
    fn search_condition(&self, condition: &mut Record) {
        condition.insert("status".into(), json!("published"));
    }

    fn before_fetch(&self, _conditions: &[Cond]) -> erupt::Result<Option<Filter>> {
        Ok(Some("status <> 'archived'".into()))
    }

    fn after_fetch(&self, rows: &mut [Record]) -> erupt::Result<()> {
        let total = self.fetched.fetch_add(rows.len(), Ordering::Relaxed) + rows.len();
        if std::env::var_os("ERUPT_DEBUG").is_some() {
            eprintln!("rows fetched so far: {total}");
        }
        Ok(())
    }

    fn add_behavior(&self, record: &mut Record) -> erupt::Result<()> {
        record.insert("status".into(), json!("draft"));
        record.insert("views".into(), json!(0));
        record.insert("progress".into(), json!(0));
        Ok(())
    }

    fn edit_behavior(&self, _record: &mut Record) -> erupt::Result<()> {
        Ok(())
    }

    fn validate(&self, record: &Record) -> erupt::Result<()> {
        if str_of(record, "title") == "forbidden" {
            return Err(Error::fail("This title is not allowed"));
        }
        Ok(())
    }

    fn before_add(&self, record: &mut Record) -> erupt::Result<()> {
        Self::stamp_review(record);
        Ok(())
    }

    fn after_add(&self, record: &Record) -> erupt::Result<()> {
        self.log("add", record)
    }

    fn before_update(&self, record: &mut Record) -> erupt::Result<()> {
        Self::stamp_review(record);
        Ok(())
    }

    fn after_update(&self, record: &Record) -> erupt::Result<()> {
        self.log("update", record)
    }

    fn before_delete(&self, record: &Record) -> erupt::Result<()> {
        if str_of(record, "status") == "published" {
            return Err(Error::fail("Unpublish it first"));
        }
        Ok(())
    }

    fn after_delete(&self, record: &Record) -> erupt::Result<()> {
        self.log("delete", record)
    }
}

// ---------------------------------------------------------------- models

fn main() -> erupt::Result<()> {
    let env =
        |name: &str, fallback: &str| std::env::var(name).unwrap_or_else(|_| fallback.to_string());
    let db = env("ERUPT_DB", "showcase.db");
    let sqlite = |table: &str| -> erupt::Result<SqlRepository> {
        Ok(SqlRepository::new(SqliteExecutor::open(&db)?, table, Dialect::Sqlite).auto_create())
    };

    let category = Model::new("Category", "Category")
        .raw(json!({
            "tree": {"pid": "parent"},
            "dragSort": {"field": "sort"},
            "drills": [{"title": "Articles", "code": "Articles",
                        "link": {"linkErupt": "Article", "joinColumn": "category"}}],
        }))
        .field("id", Field::pk())
        .field("name", Field::input("Name").search().not_null().sortable())
        .field("parent", Field::number("Parent Id"))
        .field("sort", Field::number("Sort").sortable())
        .build()?;

    let author = Model::new("Author", "Author")
        .raw(json!({"drills": [{"title": "Articles", "code": "Articles",
            "link": {"linkErupt": "Article", "joinColumn": "author", "linkCondition": "status = 'published'"}}]}))
        .field("id", Field::pk())
        .field("name", Field::input("Name").search().not_null())
        .field(
            "email",
            Field::input("Email").edit(json!({"inputType": {"regex": r"^[^@\s]+@[^@\s]+\.[^@\s]+$"}})),
        )
        .field("active", Field::boolean("Active").search().not_null())
        .build()?;

    let tag = Model::new("Tag", "Tag")
        .field("id", Field::pk())
        .field("name", Field::input("Name").search().not_null())
        .field("color", Field::of(EditType::Color, "Color"))
        .build()?;

    let publish_form = Model::new("PublishForm", "Publish Options")
        .field("publish_date", Field::date("Publish Date").not_null())
        .build()?;

    let audit_log = Model::new("AuditLog", "Audit Log")
        .order_by("id desc")
        .power(json!({"add": false, "edit": false, "delete": false}))
        .field("id", Field::pk())
        .field(
            "action",
            Field::choice(
                "Action",
                &[("add", "Add"), ("update", "Update"), ("delete", "Delete")],
            )
            .search(),
        )
        .field("article", Field::input("Article"))
        .field("account", Field::input("By").search())
        .field("at", Field::date_time("At").sortable())
        .build()?;

    // the proxy writes the audit log through a repository of its own on the same database
    let mut audit = sqlite("audit_log")?;
    audit.bind(audit_log.clone())?;
    let proxy = ArticleProxy {
        audit: Arc::new(audit),
        fetched: AtomicUsize::new(0),
    };

    let article = Model::new("Article", "Article")
        .order_by("id desc")
        .power(json!({"importable": true}))
        .data_proxy(proxy)
        .raw(json!({
            "linkTree": {"field": "category"},
            "vis": [
                {"title": "Drafts", "code": "Drafts", "type": "TABLE", "filter": "status = 'draft'", "orderBy": "views desc"},
                {"title": "Board", "code": "Board", "type": "BOARD", "boardView": {"groupField": "status", "sumField": "views"}},
                {"title": "Calendar", "code": "Calendar", "type": "CALENDAR", "calendarView": {"dateField": "publish_date"}},
                {"title": "Cards", "code": "Cards", "type": "CARD", "cardView": {"coverField": "cover"}},
                {"title": "Timeline", "code": "Timeline", "type": "TIMELINE", "timelineView": {"dateField": "review_at"}},
            ],
        }))
        .field("id", Field::pk())
        .field(
            "title",
            Field::input("Title")
                .search()
                .not_null()
                .sortable()
                .edit(json!({"inputType": {"length": 60}}))
                .onchange(summary_from_title),
        )
        .field(
            "summary",
            Field::textarea("Summary")
                .hide_table()
                .edit(json!({"textareaType": {"length": 200}})),
        )
        .field("author", Field::reference(&author, "Author").search())
        .field("category", Field::reference(&category, "Category").search())
        .field(
            "sub_category",
            Field::reference(&category, "Sub Category")
                .hide_table()
                .edit(json!({"referenceTableType": {"dependField": "category", "dependColumn": "parent"}})),
        )
        .field(
            "topic",
            Field::reference(&category, "Topic")
                .tree("parent")
                .hide_table(),
        )
        .field(
            "tag_ids",
            Field::checkbox(&tag, "Tags (checkbox)").hide_table(),
        )
        .field(
            "reviewers",
            Field::transfer(&author, "Reviewers").hide_table(),
        )
        .field(
            "sections",
            Field::tab_tree(&category, "Sections").hide_table(),
        )
        .field(
            "status",
            Field::choice(
                "Status",
                &[
                    ("draft", "Draft"),
                    ("review", "In Review"),
                    ("published", "Published"),
                    ("archived", "Archived"),
                ],
            )
            .search(),
        )
        .field("level", Field::choice("Level", &[]).fetch(levels))
        .field(
            "labels",
            Field::of(EditType::Tags, "Labels")
                .fetch_tags(|_| Ok(vec!["hot".into(), "new".into(), "classic".into()]))
                .edit(json!({"tagsType": {"allowExtension": true, "joinSeparator": ","}})),
        )
        .field(
            "city",
            Field::of(EditType::AutoComplete, "City")
                .edit(json!({"autoCompleteType": {"triggerLength": 1}}))
                .complete(|_, typed| {
                    let typed = typed.to_lowercase();
                    Ok(CITIES
                        .iter()
                        .filter(|c| c.to_lowercase().contains(&typed))
                        .map(|c| c.to_string())
                        .collect())
                }),
        )
        .field(
            "cover",
            Field::of(EditType::Attachment, "Cover")
                .edit(json!({"attachmentType": {"type": "IMAGE", "maxLimit": 1}})),
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
            Field::of(EditType::Rate, "Rating")
                .sortable()
                .edit(json!({"rateType": {"count": 5, "allowHalf": true}})),
        )
        .field(
            "progress",
            Field::of(EditType::Slider, "Progress")
                .edit(json!({"sliderType": {"min": 0, "max": 100, "step": 5}})),
        )
        .field("featured", Field::boolean("Featured").search())
        .field("color", Field::of(EditType::Color, "Theme Color"))
        .field("icon", Field::of(EditType::Icon, "Icon").hide_table())
        .field(
            "publish_date",
            Field::date("Publish Date")
                .search()
                .edit(json!({"search": {"operator": "RANGE"}})),
        )
        .field("review_at", Field::date_time("Review At").sortable())
        .field(
            "content",
            Field::of(EditType::HtmlEditor, "Content").hide_table(),
        )
        .field("notes", Field::of(EditType::Markdown, "Notes").hide_table())
        .field(
            "meta",
            Field::of(EditType::CodeEditor, "Meta (JSON)")
                .hide_table()
                .edit(json!({"codeEditType": {"language": "json"}})),
        )
        .field("preview", Field::of(EditType::Button, "Preview").click(preview))
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
                        .unwrap_or(Value::Null);
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
        .operation(
            Operation::new("archive", "Archive")
                .mode(RowOperationMode::MultiOnly)
                .icon("fa fa-archive")
                .no_confirm()
                .handler(|op| {
                    for row in &op.rows {
                        op.repo
                            .update(&row["id"], record(json!({"status": "archived"})))?;
                    }
                    Ok(None)
                }),
        )
        .operation(
            Operation::new("stats", "Stats")
                .mode(RowOperationMode::Button)
                .icon("fa fa-bar-chart")
                .show(|user| {
                    user.and_then(|u| u.get("account"))
                        .and_then(Value::as_str)
                        == Some("admin")
                })
                .handler(|op| {
                    let (total, _) = op.repo.page(&one())?;
                    Ok(Some(format!("alert('{total} articles')")))
                }),
        )
        .build()?;

    // layout and JSON-valued components: transient fields are in the build only
    let component = Model::new("Component", "Component")
        .field("id", Field::pk())
        .field("name", Field::input("Name").search().not_null())
        .field(
            "intro",
            Field::input("Guide")
                .transient()
                .edit(json!({"type": "CALLOUT", "calloutType": {
                "value": "Layout and JSON-valued components.", "style": "INFO"}})),
        )
        .field(
            "basic",
            Field::input("Basic")
                .transient()
                .edit(json!({"type": "DIVIDE"})),
        )
        .field("code", Field::of(EditType::Hidden, "Code").hide_table())
        .field(
            "roles",
            Field::multi_choice(
                "Roles",
                &[("ADMIN", "Admin"), ("USER", "User"), ("GUEST", "Guest")],
            )
            .search()
            .edit(json!({"multiChoiceType": {"type": "CHECKBOX"}})),
        )
        .field(
            "langs",
            Field::multi_choice(
                "Languages",
                &[
                    ("JAVA", "Java"),
                    ("PYTHON", "Python"),
                    ("GO", "Go"),
                    ("RUST", "Rust"),
                ],
            )
            .edit(json!({"multiChoiceType": {"type": "SELECT"}})),
        )
        .field(
            "attrs",
            Field::input("Attributes")
                .json()
                .edit(json!({"type": "KEY_VALUE",
                "keyValueType": {"keyPlaceholder": "Key", "valuePlaceholder": "Value"}})),
        )
        .field(
            "spacer",
            Field::input("").transient().edit(json!({"type": "EMPTY"})),
        )
        .field(
            "extra",
            Field::input("Extra")
                .transient()
                .edit(json!({"type": "DIVIDE"})),
        )
        .field("location", Field::of(EditType::Map, "Location"))
        .field(
            "signature",
            Field::of(EditType::Signature, "Signature").hide_table(),
        )
        .field(
            "place",
            Field::input("Place & Sign")
                .transient()
                .edit(json!({"type": "GROUP",
                "groupType": {"fields": ["location", "signature"]}})),
        )
        .build()?;

    let new_node = || {
        Node::new(
            &env("ERUPT_NODE_NAME", "showcase"),
            &env("ERUPT_ACCESS_TOKEN", ""),
            [env("ERUPT_SERVER", "http://localhost:8080")],
        )
    };
    // `serve` takes the node, so the Node Info operation calls the server back through a second handle of the
    // same node: no models, the same name, token and servers (user_info reads the request's token per thread)
    let playground = playground(Arc::new(new_node()))?;
    let mut node = new_node();
    let models = [
        (&category, "category", categories()),
        (&author, "author", authors()),
        (&tag, "tag", tags()),
        (&article, "article", articles()),
        (&component, "component", components()),
        (&audit_log, "audit_log", Vec::new()),
        (&playground, "playground", playground_rows()),
    ];
    for (model, table, rows) in models {
        // bound here as register binds them, so the seed can write before serving
        let mut seeder = sqlite(table)?;
        seeder.bind(model.clone())?;
        if seeder.page(&one())?.0 == 0 {
            for row in rows {
                seeder.add(record(row))?;
            }
        }
        node.register(model, sqlite(table)?)?;
    }
    node.serve("0.0.0.0", env("PORT", "9090").parse().expect("PORT"))
}

// ---------------------------------------------------------------- buttons, form behaviour, table display, server calls

/// level options follow the kind (choiceType.dependField).
fn levels_by_kind(form: &Record) -> erupt::Result<Vec<(String, String)>> {
    let options: &[(&str, &str)] = if str_of(form, "kind") == "advanced" {
        &[("high", "High"), ("expert", "Expert")]
    } else {
        &[("low", "Low"), ("mid", "Mid")]
    };
    Ok(options
        .iter()
        .map(|(v, l)| (v.to_string(), l.to_string()))
        .collect())
}

/// The acting user's account, empty without one.
fn account_of(user: Option<&Value>) -> String {
    user.and_then(|u| u.get("account"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

/// A script alerting `message`, escaped as a JS string literal.
fn alert(message: String) -> String {
    format!("alert({})", Value::String(message))
}

fn playground(server: Arc<Node>) -> erupt::Result<Arc<Model>> {
    let rename_form = Model::new("RenameForm", "Rename")
        .field("name", Field::input("New Name").not_null())
        .build()?;
    Model::new("Playground", "Buttons & Forms")
        .power(json!({"export": false}))
        .raw(json!({"layout": {"pageSize": 20, "tableLeftFixed": 1}}))
        .field("id", Field::pk())
        .field(
            "name",
            Field::input("Name").search().not_null().edit(json!({
                "search": {"operator": "LIKE", "lockOperator": true},
                "inputType": {"prefix": [{"value": "@", "label": "@"}],
                              "suffix": [{"value": ".dev", "label": ".dev"}, {"value": ".io", "label": ".io"}]},
                "placeHolder": "a short name", "desc": "Shown first in the table"})),
        )
        .field(
            "kind",
            Field::choice("Kind", &[("simple", "Simple"), ("advanced", "Advanced")]).search(),
        )
        .field(
            "level",
            Field::choice("Level", &[])
                .fetch(levels_by_kind)
                .edit(json!({"choiceType": {"dependField": "kind"}})),
        )
        .field(
            "note",
            Field::textarea("Advanced Note").hide_table().edit(json!({"dynamic": {
                "dependField": "kind", "condition": "value === 'advanced'", "match": "SHOW", "noMatch": "HIDE"}})),
        )
        .field(
            "code",
            Field::input("Code").edit(json!({"readOnly": {"add": false, "edit": true}})),
        )
        .field(
            "amount",
            Field::number("Amount")
                .edit(json!({"numberType": {"prefix": "$"}}))
                .view(json!({"statistic": "SUM", "className": "text-right", "width": "120px"})),
        )
        .field(
            "score",
            Field::number("Score").view(json!({"statistic": "AVG"})),
        )
        .field(
            "skills",
            Field::multi_choice("Skills", &[]).fetch(|_| {
                Ok([("java", "Java"), ("python", "Python"), ("go", "Go")]
                    .iter()
                    .map(|(v, l)| (v.to_string(), l.to_string()))
                    .collect())
            }),
        )
        .field(
            "files",
            Field::of(EditType::Attachment, "Files")
                .hide_table()
                .edit(json!({"attachmentType": {"type": "BASE", "maxLimit": 3, "fileTypes": ["pdf", "txt", "md"]}})),
        )
        .field(
            "fill",
            Field::of(EditType::Button, "Fill Sample")
                .edit(json!({"buttonType": {"style": "primary", "icon": "fa fa-magic"}}))
                .click(|_| {
                    Ok(json!({"formData": {"name": "sample", "kind": "advanced", "amount": 42, "score": 4}}))
                }),
        )
        .field(
            "reset",
            Field::of(EditType::Button, "Clear")
                .edit(json!({"buttonType": {"danger": true, "confirm": "Clear the form?"}}))
                .click(|_| Ok(json!({"formData": {"name": "", "amount": 0, "score": 0}}))),
        )
        .field(
            "whoami",
            Field::of(EditType::Button, "Who Am I")
                .edit(json!({"buttonType": {"fullSpan": true, "icon": "fa fa-user"}}))
                .click(|_| Ok(json!({"eval": alert(account_of(current_user().as_ref()))}))),
        )
        .operation(
            Operation::new("rename", "Rename")
                .mode(RowOperationMode::Single)
                .form(&rename_form)
                .tip("Give the row a new name")
                .handler(|op| {
                    let name = op
                        .param
                        .as_ref()
                        .and_then(|p| p.get("name"))
                        .cloned()
                        .unwrap_or(Value::Null);
                    op.repo
                        .update(&op.rows[0]["id"], record(json!({"name": name})))?;
                    Ok(None)
                }),
        )
        .operation(
            Operation::new("double", "Double")
                .if_expr("item.amount > 0")
                .raw(json!({"ifExprBehavior": "HIDE"}))
                .handler(|op| {
                    for row in &op.rows {
                        let amount = row
                            .get("amount")
                            .and_then(erupt::values::as_f64)
                            .unwrap_or(0.0);
                        op.repo.update(
                            &row["id"],
                            record(json!({"amount": erupt::values::number(amount * 2.0)})),
                        )?;
                    }
                    Ok(None)
                }),
        )
        .operation(
            Operation::new("reset_amounts", "Reset Amounts")
                .confirm("Reset the amounts?")
                .raw(json!({"fold": true}))
                .handler(|op| {
                    for row in &op.rows {
                        op.repo.update(&row["id"], record(json!({"amount": 0})))?;
                    }
                    Ok(None)
                }),
        )
        .operation(
            Operation::new("node_info", "Node Info")
                .mode(RowOperationMode::Button)
                .icon("fa fa-info-circle")
                .handler(move |op| {
                    let account = account_of(op.user.as_ref());
                    let roles = match server.user_info() {
                        Ok(Some(info)) => info
                            .get("roles")
                            .and_then(Value::as_array)
                            .map_or(0, Vec::len),
                        _ => 0,
                    };
                    let config = server.config().map_or(0, |c| c.chars().count());
                    Ok(Some(alert(format!(
                        "{account}: {roles} roles, config {config} chars"
                    ))))
                }),
        )
        .build()
}

// ---------------------------------------------------------------- seed data: references are stored as keys

fn playground_rows() -> Vec<Value> {
    vec![
        json!({"name": "alpha", "kind": "simple", "level": "low", "code": "A-1", "amount": 10, "score": 3,
            "skills": ["java"]}),
        json!({"name": "beta", "kind": "advanced", "level": "expert", "note": "deep dive", "code": "B-1",
            "amount": 0, "score": 5, "skills": ["python", "go"]}),
        json!({"name": "gamma", "kind": "simple", "level": "mid", "code": "G-1", "amount": 25, "score": 4,
            "skills": []}),
    ]
}

fn categories() -> Vec<Value> {
    vec![
        json!({"name": "Tech", "parent": null, "sort": 1}),
        json!({"name": "Python", "parent": 1, "sort": 2}),
        json!({"name": "Go", "parent": 1, "sort": 3}),
        json!({"name": "Life", "parent": null, "sort": 4}),
        json!({"name": "Travel", "parent": 4, "sort": 5}),
    ]
}

fn authors() -> Vec<Value> {
    vec![
        json!({"name": "Ann", "email": "ann@example.com", "active": true}),
        json!({"name": "Bob", "email": "bob@example.com", "active": true}),
        json!({"name": "Cy", "email": "cy@example.com", "active": false}),
    ]
}

fn tags() -> Vec<Value> {
    vec![
        json!({"name": "intro", "color": "#1677ff"}),
        json!({"name": "guide", "color": "#52c41a"}),
        json!({"name": "news", "color": "#fa8c16"}),
    ]
}

fn articles() -> Vec<Value> {
    vec![
        json!({"title": "Hello Erupt", "summary": "A first look at erupt nodes", "author": 1, "category": 2,
            "topic": 2, "tag_ids": [1, 2], "reviewers": [2], "sections": [1, 2], "status": "published",
            "level": "beginner", "labels": "hot,new", "city": "Paris", "views": 120, "price": 9.9, "rating": 4.5,
            "progress": 100, "featured": true, "color": "#1677ff", "icon": "fa fa-book",
            "publish_date": "2026-10-01", "review_at": "2026-10-02T10:00:00", "content": "<p>Hello</p>",
            "notes": "# Hello", "meta": "{\"a\":1}"}),
        json!({"title": "Go Tips", "author": 2, "category": 3, "topic": 3, "tag_ids": [2], "status": "review",
            "level": "advanced", "labels": "classic", "views": 30, "price": 0, "rating": 3, "progress": 60,
            "featured": false}),
        json!({"title": "Weekend Trip", "author": 3, "category": 5, "topic": 5, "status": "draft", "views": 0,
            "rating": 0, "progress": 10, "featured": false}),
    ]
}

fn components() -> Vec<Value> {
    vec![
        json!({"name": "Sample A", "code": "C-001", "roles": ["ADMIN", "USER"], "langs": ["JAVA", "GO"],
            "attrs": {"env": "prod", "tier": "1"}}),
        json!({"name": "Sample B", "code": "C-002", "roles": ["GUEST"], "langs": ["PYTHON"], "attrs": {}}),
    ]
}
