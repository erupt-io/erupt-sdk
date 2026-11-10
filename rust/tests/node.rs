use erupt::http::{Request, Response};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use erupt::types::EditType;
use erupt::{
    current_user, Cond, DataProxy, Error, Field, Filter, MemoryRepository, Model, Node, Operation,
    Record,
};
use serde_json::{json, Map, Value};

mod common;
use common::{sign_with, signed, TOKEN};

fn node() -> Node {
    let form = Model::new("PublishForm", "Publish")
        .field("note", Field::input("Note"))
        .build()
        .unwrap();
    let post = Model::new("Post", "Post")
        .field("id", Field::pk())
        .field("title", Field::input("Title").search().not_null())
        .operation(
            Operation::new("ping", "Ping")
                .handler(|op| Ok(Some(format!("alert({})", op.rows.len())))),
        )
        .operation(
            Operation::new("publish", "Publish")
                .form(&form)
                .handler(|_| Ok(None)),
        )
        .build()
        .unwrap();
    let mut node = Node::new("n", TOKEN, ["http://127.0.0.1:1"]);
    node.register(&post, MemoryRepository::new()).unwrap();
    node
}

fn request(method: &str, path: &str, body: Option<Value>, headers: &[(&str, &str)]) -> Request {
    let mut request = Request::new(method, path)
        .header("token", "t1")
        .header("erupt", "Post");
    for (name, value) in headers {
        request = request.header(name, value);
    }
    if let Some(body) = body {
        request = request.body(body.to_string());
    }
    request
}

fn answer(node: &Node, request: &Request) -> (u16, Value) {
    let Response { status, body, .. } = node.handle(request);
    (
        status,
        serde_json::from_slice(&body)
            .unwrap_or_else(|_| Value::String(String::from_utf8_lossy(&body).into_owned())),
    )
}

/// A call as the server makes it: signed, with the endpoint's Erupt-Enforced.
fn call(
    node: &Node,
    method: &str,
    path: &str,
    body: Option<Value>,
    headers: &[(&str, &str)],
) -> (u16, Value) {
    answer(node, &signed(request(method, path, body, headers)))
}

#[test]
fn guards() {
    let n = node();
    assert_eq!(
        403,
        call(
            &n,
            "GET",
            "/erupt-api/build/Post",
            None,
            &[("Origin", "http://evil")]
        )
        .0
    );
    // unsigned: the access token alone no longer passes (PROTOCOL.md §12.2)
    let plain = request(
        "GET",
        "/erupt-api/build/Post",
        None,
        &[("Access-Token", TOKEN)],
    );
    assert_eq!(403, answer(&n, &plain).0);
    // signed, but without what the endpoint needs in Erupt-Enforced
    let table = |enforced: Option<&str>| {
        let r = request("POST", "/erupt-api/data/table/Post", Some(json!({})), &[]);
        answer(&n, &sign_with(r, enforced)).0
    };
    assert_eq!(403, table(None));
    assert_eq!(403, table(Some("power")));
    assert_eq!(403, table(Some("query")));
    assert_eq!(200, table(Some("power,query")));
    let add = |enforced: Option<&str>| {
        let r = request(
            "POST",
            "/erupt-api/data/modify/Post",
            Some(json!({"title": "a"})),
            &[],
        );
        answer(&n, &sign_with(r, enforced)).0
    };
    assert_eq!(403, add(Some("power,query")));
    assert_eq!(200, add(Some("power,record")));
    let get = request("GET", "/erupt-api/data/Post/1", None, &[]);
    assert_eq!(403, answer(&n, &sign_with(get.clone(), None)).0);
    assert_eq!(200, answer(&n, &sign_with(get, Some("power"))).0);
    let delete = request(
        "POST",
        "/erupt-api/data/modify/Post/delete",
        Some(json!([1])),
        &[],
    );
    assert_eq!(403, answer(&n, &sign_with(delete, Some("record"))).0);
    let ping = request(
        "POST",
        "/erupt-api/invoke/Post/operation/ping",
        Some(json!({"ids": [1]})),
        &[],
    );
    assert_eq!(403, answer(&n, &sign_with(ping, None)).0);
    // a build needs nothing: the server reads it on its own account
    let build = request("GET", "/erupt-api/build/Post", None, &[]);
    assert_eq!(200, answer(&n, &sign_with(build, None)).0);
    assert_eq!(
        404,
        call(
            &n,
            "GET",
            "/erupt-api/build/Post",
            None,
            &[("erupt", "Other")]
        )
        .0
    );
    assert_eq!(
        404,
        call(
            &n,
            "GET",
            "/erupt-api/build/Post",
            None,
            &[("eruptParent", "n.Other")]
        )
        .0
    );
    assert_eq!(
        200,
        call(
            &n,
            "GET",
            "/erupt-api/build/Post",
            None,
            &[("eruptParent", "n.Post")]
        )
        .0
    );
    assert_eq!(404, call(&n, "GET", "/erupt-api/nothing", None, &[]).0);
    assert_eq!(
        (200, json!("n")),
        answer(&n, &Request::new("GET", "/node-health"))
    );
}

#[test]
fn crud_and_operations() {
    let n = node();
    let (_, r) = call(
        &n,
        "POST",
        "/erupt-api/data/modify/Post",
        Some(json!({"title": "a"})),
        &[],
    );
    assert_eq!(json!(true), r["success"]);
    let (_, page) = call(
        &n,
        "POST",
        "/erupt-api/data/table/Post",
        Some(json!({"pageIndex": 1, "pageSize": 10})),
        &[],
    );
    assert_eq!(json!([{"id": 1, "title": "a"}]), page["list"]);
    let (_, r) = call(
        &n,
        "POST",
        "/erupt-api/invoke/Post/operation/ping",
        Some(json!({"ids": [1], "param": null})),
        &[],
    );
    assert_eq!(json!("alert(1)"), r["data"]);
    let invoke = |path: &str| call(&n, "POST", path, Some(json!({})), &[]);
    assert_eq!(404, invoke("/erupt-api/invoke/Post/operation/missing").0);
    let form = "/erupt-api/invoke/Post/operation-form/";
    assert_eq!(
        json!({"note": null}),
        invoke(&format!("{form}publish")).1["data"]
    );
    // an operation without a form
    let (status, r) = invoke(&format!("{form}ping"));
    assert_eq!(
        (200, json!(true), Value::Null),
        (status, r["success"].clone(), r["data"].clone())
    );
    assert_eq!(404, invoke(&format!("{form}missing")).0);
    // the picker and the operations are the server's and invoke's
    assert_eq!(404, invoke("/erupt-api/data/Post/operator/ping").0);
    assert_eq!(
        404,
        invoke("/erupt-api/data/Post/operator/publish/form-value").0
    );
    assert_eq!(404, invoke("/erupt-api/data/Post/reference-table/title").0);
    let (_, r) = call(
        &n,
        "POST",
        "/erupt-api/data/table/Post",
        Some(json!({"condition": [{"key": "title\" OR 1=1", "expression": "EQ", "value": 1}]})),
        &[],
    );
    assert_eq!(json!(false), r["success"]);
    let raw = Request::new("POST", "/erupt-api/data/modify/Post")
        .header("token", "t1")
        .header("erupt", "Post")
        .body("{not json");
    let r: Value = serde_json::from_slice(&n.handle(&signed(raw)).body).unwrap();
    assert_eq!(
        (json!(false), json!("malformed JSON body")),
        (r["success"].clone(), r["message"].clone())
    );
}

#[test]
fn build_power_is_declared_only() {
    let note = Model::new("Note", "Note")
        .power(json!({"delete": false}))
        .field("id", Field::pk())
        .build()
        .unwrap();
    let mut n = node();
    n.register(&note, MemoryRepository::new()).unwrap();
    // the rights the model switches off and the features this SDK does not serve; the server enforces the rest
    let (_, build) = call(&n, "GET", "/erupt-api/build/Post", None, &[]);
    assert_eq!(json!({"print": false, "ai": false}), build["power"]);
    let (_, build) = call(
        &n,
        "GET",
        "/erupt-api/build/Note",
        None,
        &[("erupt", "Note")],
    );
    assert_eq!(
        json!({"delete": false, "print": false, "ai": false}),
        build["power"]
    );
    // the server refuses the delete; a call it vouches for runs
    let (_, r) = call(
        &n,
        "POST",
        "/erupt-api/data/modify/Note/delete",
        Some(json!([1])),
        &[("erupt", "Note")],
    );
    assert_eq!(json!(true), r["success"]);
}

#[test]
fn build_is_declared_only() {
    let category = Model::new("Category", "Category")
        .field("id", Field::pk())
        .field("name", Field::input("Name"))
        .build()
        .unwrap();
    let event = Model::new("Event", "Event")
        .field("id", Field::pk())
        .field(
            "title",
            Field::input("Title").search().not_null().sortable(),
        )
        .field("at", Field::date_time("At").hide_form())
        .field("day", Field::date("Day").hide_table())
        .field(
            "count",
            Field::number("Count").view(json!({"type": "TEXT"})),
        )
        .field("done", Field::boolean("Done"))
        .field("category", Field::reference(&category, "Category"))
        .operation(
            Operation::new("go", "Go")
                .no_confirm()
                .handler(|_| Ok(None)),
        )
        .build()
        .unwrap();
    let mut n = node();
    n.register(&event, MemoryRepository::new()).unwrap();
    let (_, build) = call(
        &n,
        "GET",
        "/erupt-api/build/Event",
        None,
        &[("erupt", "Event")],
    );
    let model = &build["eruptModel"];
    assert_eq!(
        json!({"primaryKeyCol": "id", "rowOperation": [{"code": "go", "title": "Go", "mode": "MULTI", "tip": "",
               "ifExpr": "", "eruptClass": "void", "callHint": ""}]}),
        model["eruptJson"]
    );
    let fields: Map<String, Value> = model["eruptFieldModels"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| (f["fieldName"].as_str().unwrap().to_string(), f.clone()))
        .collect();
    assert_eq!(
        json!({"fieldName": "id", "fieldReturnName": "number", "componentValue": null,
               "eruptFieldJson": {"edit": {"title": "", "type": "NUMBER"}}}),
        fields["id"]
    );
    assert_eq!(
        json!({"fieldName": "title", "fieldReturnName": "String", "componentValue": null,
               "eruptFieldJson": {
                   "edit": {"title": "Title", "type": "INPUT", "notNull": true, "search": {"value": true}},
                   "views": [{"title": "Title", "sortable": true}]}}),
        fields["title"]
    );
    assert_eq!(
        (
            json!("Date"),
            json!({"title": "At", "type": "DATE", "dateType": {"type": "DATE_TIME"}, "show": false}),
            json!([{"title": "At"}])
        ),
        (
            fields["at"]["fieldReturnName"].clone(),
            fields["at"]["eruptFieldJson"]["edit"].clone(),
            fields["at"]["eruptFieldJson"]["views"].clone()
        )
    );
    assert_eq!(
        (
            json!({"title": "Day", "type": "DATE", "dateType": {"type": "DATE"}}),
            json!([])
        ),
        (
            fields["day"]["eruptFieldJson"]["edit"].clone(),
            fields["day"]["eruptFieldJson"]["views"].clone()
        )
    );
    // a view type only when the declaration sets one: the server resolves AUTO
    assert_eq!(
        (json!("number"), json!([{"title": "Count", "type": "TEXT"}])),
        (
            fields["count"]["fieldReturnName"].clone(),
            fields["count"]["eruptFieldJson"]["views"].clone()
        )
    );
    assert_eq!(json!("Boolean"), fields["done"]["fieldReturnName"]);
    assert_eq!(
        json!({"fieldName": "category", "fieldReturnName": "Category", "componentValue": null,
               "eruptFieldJson": {
                   "edit": {"title": "Category", "type": "REFERENCE_TABLE",
                            "referenceTableType": {"id": "id", "label": "name"}},
                   "views": [{"title": "Category", "column": "name"}]}}),
        fields["category"]
    );
}

#[test]
fn page_size_is_capped() {
    let n = node();
    let (_, page) = call(
        &n,
        "POST",
        "/erupt-api/data/table/Post",
        Some(json!({"pageIndex": 1, "pageSize": 100000})),
        &[],
    );
    assert_eq!(json!(1000), page["pageSize"]);
}

/// Every hook; the write hooks only record that they ran, with the text they saw.
struct MemoProxy(Arc<Mutex<Vec<(&'static str, String)>>>);

impl MemoProxy {
    fn log(&self, hook: &'static str, record: &Record) -> erupt::Result<()> {
        let text = record["text"].as_str().unwrap_or_default().to_string();
        self.0.lock().unwrap().push((hook, text));
        Ok(())
    }
}

impl DataProxy for MemoProxy {
    fn search_condition(&self, condition: &mut Record) {
        condition.insert("text".into(), json!("hi"));
    }
    fn after_fetch(&self, rows: &mut [Record]) -> erupt::Result<()> {
        for row in rows {
            let upper = row["text"].as_str().unwrap_or_default().to_uppercase();
            row.insert("text".into(), json!(upper));
        }
        Ok(())
    }
    fn add_behavior(&self, record: &mut Record) -> erupt::Result<()> {
        record.insert("text".into(), json!("new"));
        Ok(())
    }
    fn edit_behavior(&self, record: &mut Record) -> erupt::Result<()> {
        let text = format!("{}?", record["text"].as_str().unwrap_or_default());
        record.insert("text".into(), json!(text));
        Ok(())
    }
    fn validate(&self, record: &Record) -> erupt::Result<()> {
        if record["text"] == json!("forbidden") {
            return Err(Error::fail("forbidden text"));
        }
        Ok(())
    }
    fn before_add(&self, record: &mut Record) -> erupt::Result<()> {
        self.log("before_add", record)
    }
    fn after_add(&self, record: &Record) -> erupt::Result<()> {
        self.log("after_add", record)
    }
    fn before_update(&self, record: &mut Record) -> erupt::Result<()> {
        self.log("before_update", record)
    }
    fn after_update(&self, record: &Record) -> erupt::Result<()> {
        self.log("after_update", record)
    }
    fn before_delete(&self, record: &Record) -> erupt::Result<()> {
        self.log("before_delete", record)
    }
    fn after_delete(&self, record: &Record) -> erupt::Result<()> {
        self.log("after_delete", record)
    }
}

#[test]
fn data_proxy() {
    let calls = Arc::new(Mutex::new(Vec::new()));
    let memo = Model::new("Memo", "Memo")
        .data_proxy(MemoProxy(calls.clone()))
        .field("id", Field::pk())
        .field("text", Field::input("Text"))
        .build()
        .unwrap();
    let mut n = node();
    n.register(&memo, MemoryRepository::new()).unwrap();
    let memo_call = |method: &str, path: &str, body: Option<Value>| {
        call(&n, method, path, body, &[("erupt", "Memo")]).1
    };
    let build = memo_call("GET", "/erupt-api/build/Memo", None);
    assert_eq!(
        json!({"text": "hi"}),
        build["eruptModel"]["searchCondition"]
    );
    let init = memo_call("GET", "/erupt-api/data/init-value/Memo", None);
    assert_eq!(json!("new"), init["text"]);
    let r = memo_call(
        "POST",
        "/erupt-api/data/modify/Memo",
        Some(json!({"text": "forbidden"})),
    );
    assert_eq!(
        (json!(false), json!("forbidden text")),
        (r["success"].clone(), r["message"].clone())
    );
    let r = memo_call(
        "POST",
        "/erupt-api/data/modify/Memo",
        Some(json!({"text": "a"})),
    );
    assert_eq!(json!(true), r["success"]);
    let page = memo_call("POST", "/erupt-api/data/table/Memo", Some(json!({})));
    assert_eq!(json!([{"id": 1, "text": "A"}]), page["list"]);
    let r = memo_call("GET", "/erupt-api/data/Memo/1", None);
    assert_eq!(json!("a?"), r["text"]);
    let r = memo_call(
        "POST",
        "/erupt-api/data/modify/Memo/update",
        Some(json!({"id": 1, "text": "b"})),
    );
    assert_eq!(json!(true), r["success"]);
    let r = memo_call(
        "POST",
        "/erupt-api/data/modify/Memo/delete",
        Some(json!([1])),
    );
    assert_eq!(json!(true), r["success"]);
    let expected: Vec<(&str, String)> = [
        ("before_add", "a"),
        ("after_add", "a"),
        ("before_update", "b"),
        ("after_update", "b"),
        ("before_delete", "b"),
        ("after_delete", "b"),
    ]
    .iter()
    .map(|(h, t)| (*h, t.to_string()))
    .collect();
    assert_eq!(expected, *calls.lock().unwrap());
}

struct TaskProxy;

impl DataProxy for TaskProxy {
    fn before_fetch(&self, _: &[Cond]) -> erupt::Result<Option<Filter>> {
        let account = current_user().map(|u| u["account"].clone());
        Ok(Some(Filter::new(
            "owner = ?",
            vec![account.unwrap_or_default()],
        )))
    }
}

struct OpenProxy;

impl DataProxy for OpenProxy {
    fn before_fetch(&self, _: &[Cond]) -> erupt::Result<Option<Filter>> {
        Ok(Some("done = 0".into()))
    }
}

fn task() -> Arc<Model> {
    Model::new("Task", "Task")
        .data_proxy(TaskProxy)
        .data_proxy(OpenProxy)
        .field("id", Field::pk())
        .field("title", Field::input("Title").search())
        .field("owner", Field::input("Owner"))
        .field("done", Field::boolean("Done"))
        .raw(json!({"vis": [
            {"code": "q", "title": "Question", "type": "TABLE", "filter": "title = 'a?'"},
            {"title": "Reversed", "type": "TABLE", "filter": ["1 = 1", "2 = 2"], "orderBy": "title desc"},
        ]}))
        .build()
        .unwrap()
}

// the user header, {"uid":1,"account":"admin"}
const ADMIN: &str = "eyJ1aWQiOjEsImFjY291bnQiOiJhZG1pbiJ9";

#[cfg(feature = "sqlite")]
#[test]
fn before_fetch() {
    use erupt::{Dialect, SqlRepository, SqliteExecutor};
    const ROOT: &str = "eyJ1aWQiOjEsImFjY291bnQiOiJyb290In0="; // {"uid":1,"account":"root"}
    let mut n = node();
    let repo = SqlRepository::new(
        SqliteExecutor::open(":memory:").unwrap(),
        "task",
        Dialect::Sqlite,
    )
    .auto_create();
    n.register(&task(), repo).unwrap();
    let task_call = |path: &str, body: Value, user: &str| {
        call(
            &n,
            "POST",
            path,
            Some(body),
            &[("erupt", "Task"), ("user", user)],
        )
        .1
    };
    for (title, owner, done) in [
        ("a", "admin", false),
        ("b", "admin", true),
        ("c", "root", false),
        ("a?", "admin", false),
    ] {
        let record = json!({"title": title, "owner": owner, "done": done});
        assert_eq!(
            json!(true),
            task_call("/erupt-api/data/modify/Task", record, ADMIN)["success"]
        );
    }
    let page = task_call("/erupt-api/data/table/Task", json!({}), ADMIN);
    let titles: Vec<&Value> = page["list"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| &r["title"])
        .collect();
    assert_eq!(vec![&json!("a"), &json!("a?")], titles);
    assert_eq!(json!(2), page["total"]);
    let search = json!({"condition": [{"key": "title", "expression": "EQ", "value": "a"}]});
    let page = task_call("/erupt-api/data/table/Task", search, ROOT);
    assert_eq!(json!([]), page["list"]);
    // a view's own filter and order run on the node, and stay out of the build
    let titles = |vis: &str| {
        let page = task_call("/erupt-api/data/table/Task", json!({"vis": vis}), ADMIN);
        page["list"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["title"].clone())
            .collect::<Vec<_>>()
    };
    assert_eq!(vec![json!("a?")], titles("q"));
    assert_eq!(vec![json!("a?"), json!("a")], titles("Reversed"));
    let (_, build) = call(
        &n,
        "GET",
        "/erupt-api/build/Task",
        None,
        &[("erupt", "Task"), ("user", ADMIN)],
    );
    let vis = build["eruptModel"]["eruptJson"]["vis"].as_array().unwrap();
    let codes: Vec<&Value> = vis.iter().map(|v| &v["code"]).collect();
    assert_eq!(vec![&json!("q"), &json!("Reversed")], codes);
    assert!(vis
        .iter()
        .all(|v| v.get("filter").is_none() && v.get("orderBy").is_none()));
}

#[test]
fn before_fetch_needs_sql() {
    let mut n = node();
    n.register(&task(), MemoryRepository::new()).unwrap();
    let (status, _) = call(
        &n,
        "POST",
        "/erupt-api/data/table/Task",
        Some(json!({})),
        &[("erupt", "Task"), ("user", ADMIN)],
    );
    assert_eq!(500, status);
}

#[test]
fn link_tree() {
    let category = Model::new("Category", "Category")
        .field("id", Field::pk())
        .field("name", Field::input("Name"))
        .field("parent", Field::number("Parent Id"))
        .build()
        .unwrap();
    let doc = Model::new("Doc", "Doc")
        .raw(json!({"linkTree": {"field": "topic", "dependNode": true}}))
        .field("id", Field::pk())
        .field("title", Field::input("Title"))
        .field("topic", Field::reference(&category, "Topic").tree("parent"))
        .build()
        .unwrap();
    let mut n = node();
    let docs = [("a", 1), ("b", 2), ("c", 3)].map(|(title, topic)| {
        json!({"title": title, "topic": topic})
            .as_object()
            .cloned()
            .unwrap()
    });
    n.register(&doc, MemoryRepository::seeded(docs.to_vec()))
        .unwrap();
    let titles = |body: Value| {
        let (_, page) = call(
            &n,
            "POST",
            "/erupt-api/data/table/Doc",
            Some(body),
            &[("erupt", "Doc")],
        );
        page["list"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["title"].clone())
            .collect::<Vec<_>>()
    };
    // the server turns the picked tree keys into IN on the tree field ...
    let picked =
        |keys: Value| json!({"condition": [{"key": "topic", "expression": "IN", "value": keys}]});
    assert_eq!(vec![json!("b")], titles(picked(json!([2]))));
    assert_eq!(vec![json!("a"), json!("b")], titles(picked(json!([1, 2]))));
    // ... and, under dependNode with nothing picked, NULL on the primary key, which no row matches
    let none = json!({"condition": [{"key": "id", "expression": "NULL"}]});
    assert_eq!(Vec::<Value>::new(), titles(none));
    // the node no longer reads linkTreeVal: every row
    assert_eq!(3, titles(json!({"linkTreeVal": [2]})).len());
}

#[test]
fn field_types_and_invoke() {
    let category = Model::new("Category", "Category")
        .field("id", Field::pk())
        .field("name", Field::input("Name"))
        .build()
        .unwrap();
    let order = Model::new("Order", "Order")
        .field("id", Field::pk())
        .field(
            "status",
            Field::choice("Status", &[]).fetch(|form| {
                let note = form.get("note").and_then(Value::as_str).unwrap_or("x");
                Ok(vec![
                    ("new".into(), "New".into()),
                    (note.into(), "From form".into()),
                ])
            }),
        )
        .field(
            "tags",
            Field::of(EditType::Tags, "Tags").fetch_tags(|_| Ok(vec!["red".into(), "blue".into()])),
        )
        .field(
            "qty",
            Field::number("Qty").onchange(|form| {
                Ok(json!({"formData": {"note": format!("{} items", form["qty"])}}))
            }),
        )
        .field("note", Field::input("Note"))
        .field(
            "city",
            Field::of(EditType::AutoComplete, "City").complete(|_, typed| {
                Ok(["Paris", "Tokyo"]
                    .iter()
                    .filter(|c| c.to_lowercase().contains(&typed.to_lowercase()))
                    .map(|c| c.to_string())
                    .collect())
            }),
        )
        .field("body", Field::of(EditType::Markdown, "Body"))
        .field("files", Field::of(EditType::Attachment, "Files"))
        .field(
            "roles",
            Field::multi_choice("Roles", &[]).fetch(|_| Ok(vec![("a".into(), "A".into())])),
        )
        .field("cats", Field::checkbox(&category, "Categories"))
        .field("sections", Field::tab_tree(&category, "Sections"))
        .field(
            "calc",
            Field::of(EditType::Button, "Calc")
                .click(|_| Ok(json!({"eval": "alert(1)", "formData": {"qty": 2}}))),
        )
        .field(
            "stop",
            Field::of(EditType::Button, "Stop").click(|_| Err(Error::fail("not now"))),
        )
        .build()
        .unwrap();
    let mut n = node();
    n.register(&order, MemoryRepository::new()).unwrap();
    let call = |method: &str, path: &str, body: Value| {
        call(&n, method, path, Some(body), &[("erupt", "Order")])
    };

    let (_, build) = call("GET", "/erupt-api/build/Order", Value::Null);
    let fields: Map<String, Value> = build["eruptModel"]["eruptFieldModels"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| (f["fieldName"].as_str().unwrap().to_string(), f.clone()))
        .collect();
    let edit = |name: &str| fields[name]["eruptFieldJson"]["edit"].clone();
    assert_eq!(
        json!(["invoke"]),
        edit("status")["choiceType"]["fetchHandler"]
    );
    assert_eq!(json!(["invoke"]), edit("tags")["tagsType"]["fetchHandler"]);
    assert_eq!(
        json!(["invoke"]),
        edit("roles")["multiChoiceType"]["fetchHandler"]
    );
    assert_eq!(json!("invoke"), edit("qty")["onchange"]);
    assert_eq!(
        ("MARKDOWN", "ATTACHMENT", "BUTTON"),
        (
            edit("body")["type"].as_str().unwrap(),
            edit("files")["type"].as_str().unwrap(),
            edit("calc")["type"].as_str().unwrap()
        )
    );
    assert_eq!(json!([]), fields["calc"]["eruptFieldJson"]["views"]);
    assert_eq!(
        (json!("Category"), json!("Category")),
        (
            fields["cats"]["fieldReturnName"].clone(),
            fields["sections"]["fieldReturnName"].clone()
        )
    );

    let invoke = |kind: &str, field: &str, form: Value, value: Value| {
        call(
            "POST",
            &format!("/erupt-api/invoke/Order/{kind}/{field}"),
            json!({"form": form, "value": value}),
        )
    };
    assert_eq!(
        json!([{"value": "new", "label": "New"}, {"value": "n", "label": "From form"}]),
        invoke("options", "status", json!({"note": "n"}), Value::Null).1["data"]
    );
    assert_eq!(
        json!(["red", "blue"]),
        invoke("options", "tags", json!({}), Value::Null).1["data"]
    );
    assert_eq!(
        json!({"formData": {"note": "3 items"}}),
        invoke("onchange", "qty", json!({"qty": 3}), Value::Null).1["data"]
    );
    assert_eq!(
        json!(["Paris"]),
        invoke("autocomplete", "city", json!({}), json!("pa")).1["data"]
    );
    assert_eq!(
        json!("alert(1)"),
        invoke("button", "calc", json!({}), Value::Null).1["data"]["eval"]
    );
    let (_, refused) = invoke("button", "stop", json!({}), Value::Null);
    assert_eq!(
        (json!(false), json!("not now")),
        (refused["success"].clone(), refused["message"].clone())
    );
    // a field without that code, an unknown field
    assert_eq!(404, invoke("button", "qty", json!({}), Value::Null).0);
    assert_eq!(404, invoke("options", "missing", json!({}), Value::Null).0);

    // picked records arrive as their keys and are stored typed like the target's key
    let (_, added) = call(
        "POST",
        "/erupt-api/data/modify/Order",
        json!({"cats": [1, "2"], "sections": [3], "tags": "red"}),
    );
    assert_eq!(json!(true), added["success"]);
    let (_, page) = call("POST", "/erupt-api/data/table/Order", json!({}));
    let row = &page["list"][0];
    assert_eq!(
        (json!([1, 2]), json!([3])),
        (row["cats"].clone(), row["sections"].clone())
    );
    assert!(row.get("calc").is_none());
}

fn author_and_book() -> (Arc<Model>, Arc<Model>) {
    let author = Model::new("Author", "Author")
        .raw(json!({"drills": [{"title": "Books", "link": {"linkErupt": "Book", "joinColumn": "author.id"}}]}))
        .field("id", Field::pk())
        .field("name", Field::input("Name"))
        .build()
        .unwrap();
    let category = Model::new("Category", "Category")
        .field("id", Field::pk())
        .field("name", Field::input("Name"))
        .field("parent", Field::number("Parent"))
        .build()
        .unwrap();
    let book = Model::new("Book", "Book")
        .field("id", Field::pk())
        .field("title", Field::input("Title"))
        .field("author", Field::reference(&author, "Author"))
        .field("colour", Field::of(EditType::Color, "Colour"))
        .field("stars", Field::of(EditType::Rate, "Stars"))
        .field("secret", Field::of(EditType::Hidden, "Secret"))
        .field("readers", Field::transfer(&category, "Readers"))
        .field(
            "shelf",
            Field::reference(&category, "Shelf").edit(
                json!({"referenceTableType": {"dependField": "author", "dependColumn": "parent"}}),
            ),
        )
        .build()
        .unwrap();
    (author, book)
}

fn records(rows: Value) -> Vec<Record> {
    rows.as_array()
        .unwrap()
        .iter()
        .map(|r| r.as_object().cloned().unwrap())
        .collect()
}

fn library() -> Node {
    let (author, book) = author_and_book();
    let mut n = node();
    n.register(
        &author,
        MemoryRepository::seeded(records(json!([{"name": "Ann"}, {"name": "Bob"}]))),
    )
    .unwrap();
    n.register(
        &book,
        MemoryRepository::seeded(records(json!([
            {"title": "a", "author": 1}, {"title": "b", "author": 2}, {"title": "c", "author": 1}
        ]))),
    )
    .unwrap();
    n
}

#[test]
fn drill() {
    let n = library();
    // the server reads the source row and sends the join as a condition; the body names the drill
    let table = |drill: Value| {
        let body = json!({"condition": [{"key": "author", "expression": "EQ", "value": 1}], "drill": drill});
        call(
            &n,
            "POST",
            "/erupt-api/data/table/Book",
            Some(body),
            &[("erupt", "Book")],
        )
    };
    let (_, page) = table(json!({"erupt": "Author", "code": "Books"}));
    let titles: Vec<&Value> = page["list"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| &r["title"])
        .collect();
    assert_eq!(vec![&json!("a"), &json!("c")], titles);
    assert_eq!(403, table(json!({"erupt": "Author", "code": "x"})).0);
    assert_eq!(403, table(json!({"erupt": "Nobody", "code": "Books"})).0);

    let (_, build) = call(
        &n,
        "GET",
        "/erupt-api/build/Author",
        None,
        &[("erupt", "Author")],
    );
    // the link goes to the server whole: it joins on column / joinColumn
    assert_eq!(
        json!([{"code": "Books", "title": "Books", "link": {"linkErupt": "Book", "joinColumn": "author.id"}}]),
        build["eruptModel"]["eruptJson"]["drills"]
    );
}

#[test]
fn drill_condition() {
    let author = Model::new("Author", "Author")
        .raw(
            json!({"drills": [{"code": "recent", "title": "Recent", "link": {
            "linkErupt": "Book", "joinColumn": "author", "linkCondition": "title <> 'b'"}}]}),
        )
        .field("id", Field::pk())
        .build()
        .unwrap();
    let mut n = node();
    n.register(&author, MemoryRepository::new()).unwrap();
    n.register(&author_and_book().1, MemoryRepository::new())
        .unwrap();
    // a linkCondition is SQL: a memory repository refuses it, which shows the node applied it
    let body = json!({"drill": {"erupt": "Author", "code": "recent"}});
    let (status, _) = call(
        &n,
        "POST",
        "/erupt-api/data/table/Book",
        Some(body),
        &[("erupt", "Book")],
    );
    assert_eq!(500, status);
}

#[test]
fn simple_types_and_depend_column() {
    let n = library();
    let call = |method: &str, path: &str, body: Option<Value>| {
        call(&n, method, path, body, &[("erupt", "Book")])
    };
    let (_, build) = call("GET", "/erupt-api/build/Book", None);
    let edit: Map<String, Value> = build["eruptModel"]["eruptFieldModels"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| {
            (
                f["fieldName"].as_str().unwrap().to_string(),
                f["eruptFieldJson"]["edit"].clone(),
            )
        })
        .collect();
    assert_eq!(
        ["COLOR", "RATE", "HIDDEN", "TRANSFER"],
        ["colour", "stars", "secret", "readers"].map(|n| edit[n]["type"].as_str().unwrap())
    );
    // the server reads it off the build
    assert_eq!(
        json!("parent"),
        edit["shelf"]["referenceTableType"]["dependColumn"]
    );
    let (_, added) = call(
        "POST",
        "/erupt-api/data/modify/Book",
        Some(json!({"title": "d", "stars": 4, "readers": [2]})),
    );
    assert_eq!(json!(true), added["success"]);
    let (_, page) = call("POST", "/erupt-api/data/table/Book", Some(json!({})));
    let row = page["list"].as_array().unwrap().last().unwrap();
    assert_eq!(
        (json!(4), json!([2])),
        (row["stars"].clone(), row["readers"].clone())
    );
}

#[test]
fn node_config_and_user_info() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let server = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = seen.clone();
    std::thread::spawn(move || {
        erupt::http::serve_listener(
            listener,
            1,
            Arc::new(move |req: &Request| {
                log.lock().unwrap().push((
                    req.path.clone(),
                    req.get_header("access-token").unwrap_or("").to_string(),
                ));
                if req.path.contains("userinfo") {
                    Response::text(200, r#"{"account": "admin", "roles": ["r"]}"#)
                } else {
                    Response::text(200, "cfg")
                }
            }),
        )
    });
    let n = Node::new("blog", TOKEN, [server]);
    assert_eq!("cfg", n.config().unwrap());
    assert_eq!("cfg", n.group_config().unwrap());
    assert_eq!(
        Some(json!({"account": "admin", "roles": ["r"]})),
        n.user_info().unwrap()
    );
    assert_eq!(
        vec![
            "/erupt-cloud-api/node-config/blog",
            "/erupt-cloud-api/node-group-config/blog",
            "/erupt-cloud-api/userinfo/blog"
        ],
        seen.lock()
            .unwrap()
            .iter()
            .map(|(path, token)| {
                assert_eq!(TOKEN, token);
                path.as_str()
            })
            .collect::<Vec<_>>()
    );
}

/// A fake erupt server answering every register call with `answer`; counts the calls and keeps the last body.
fn register_server(answer: &'static str) -> (String, Arc<Mutex<Vec<Value>>>) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let server = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = seen.clone();
    std::thread::spawn(move || {
        erupt::http::serve_listener(
            listener,
            2,
            Arc::new(move |req: &Request| {
                if req.path == "/erupt-cloud-api/register-node" {
                    log.lock()
                        .unwrap()
                        .push(serde_json::from_slice(&req.body).unwrap_or(Value::Null));
                }
                Response::text(200, answer)
            }),
        )
    });
    (server, seen)
}

fn heartbeats(answer: &'static str) -> (Arc<Node>, Arc<Mutex<Vec<Value>>>) {
    let (server, seen) = register_server(answer);
    let node = Arc::new(
        Node::new("n", TOKEN, [server])
            .address("http://127.0.0.1:1")
            .heartbeat_interval(Duration::from_millis(30)),
    );
    node.start_heartbeat();
    std::thread::sleep(Duration::from_millis(400));
    (node, seen)
}

#[test]
fn registers_with_a_v2_server() {
    let (node, seen) = heartbeats(r#"{"protocolVersion": 2}"#);
    let calls = seen.lock().unwrap().clone();
    assert!(
        calls.len() > 1,
        "the heartbeat goes on: {} calls",
        calls.len()
    );
    assert_eq!(json!(2), calls[0]["protocolVersion"]);
    assert!(node.register_once().is_ok());
}

#[test]
fn an_older_server_stops_the_heartbeat() {
    for answer in ["", "{}", r#"{"protocolVersion": 1}"#] {
        let (node, seen) = heartbeats(answer);
        // no retry, no v1 fallback
        assert_eq!(1, seen.lock().unwrap().len(), "answer {answer:?}");
        let error = node.register_once().unwrap_err().to_string();
        assert!(
            error.contains("does not speak node protocol v2: upgrade the erupt server"),
            "{error}"
        );
    }
}

#[test]
fn unknown_operators_fail() {
    let n = node();
    call(
        &n,
        "POST",
        "/erupt-api/data/modify/Post",
        Some(json!({"title": "a"})),
        &[],
    );
    // an operator the node does not know never turns into "no condition" (every row)
    for expression in [json!("DROP"), json!("AUTO"), json!(""), Value::Null] {
        let body = json!({"condition": [{"key": "title", "expression": expression, "value": "x"}]});
        let (status, r) = call(&n, "POST", "/erupt-api/data/table/Post", Some(body), &[]);
        assert_eq!(
            (200, json!(false)),
            (status, r["success"].clone()),
            "{expression}"
        );
    }
}
