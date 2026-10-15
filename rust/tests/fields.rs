//! Transient fields are in the build only; JSON fields round-trip as arrays and objects.
use erupt::http::{Request, Response};
use erupt::{Field, MemoryRepository, Model, Node, Repository};
use serde_json::{json, Value};

const TOKEN: &str = "node-secret";

fn node(repo: impl Repository + 'static) -> Node {
    let widget = Model::new("Widget", "Widget")
        .field("id", Field::pk())
        .field("name", Field::input("Name"))
        .field(
            "note",
            Field::input("Note")
                .transient()
                .edit(json!({"type": "DIVIDE"})),
        )
        .field(
            "roles",
            Field::choice("Roles", &[("ADMIN", "Admin"), ("USER", "User")])
                .json()
                .edit(json!({"type": "MULTI_CHOICE"})),
        )
        .field(
            "attrs",
            Field::input("Attrs")
                .json()
                .edit(json!({"type": "KEY_VALUE"})),
        )
        .build()
        .unwrap();
    let mut node = Node::new("n", TOKEN, ["http://127.0.0.1:1"]).power_source(|_, _| {
        Ok(
            json!({"add": true, "edit": true, "delete": true, "viewDetails": true})
                .as_object()
                .cloned()
                .unwrap(),
        )
    });
    node.register(&widget, repo).unwrap();
    node
}

fn call(node: &Node, method: &str, path: &str, body: Option<Value>) -> (u16, Value) {
    let mut request = Request::new(method, path)
        .header("Access-Token", TOKEN)
        .header("token", "t1")
        .header("erupt", "Widget");
    if let Some(body) = body {
        request = request.body(body.to_string());
    }
    let Response { status, body, .. } = node.handle(&request);
    (status, serde_json::from_slice(&body).unwrap_or(Value::Null))
}

fn scenario(repo: impl Repository + 'static) {
    let n = node(repo);
    let (_, build) = call(&n, "GET", "/erupt-api/build/Widget", None);
    let fields = &build["eruptModel"]["eruptFieldModels"];
    assert_eq!(5, fields.as_array().unwrap().len());
    assert_eq!(json!("ADMIN"), fields[3]["componentValue"][0]["value"]);
    let (status, r) = call(
        &n,
        "POST",
        "/erupt-api/data/modify/Widget",
        Some(
            json!({"name": "A", "note": "ignored", "roles": ["ADMIN", "USER"], "attrs": {"env": "prod"}}),
        ),
    );
    assert_eq!((200, json!(true)), (status, r["success"].clone()));
    let (_, page) = call(
        &n,
        "POST",
        "/erupt-api/data/table/Widget",
        Some(json!({"pageIndex": 1, "pageSize": 10})),
    );
    let row = &page["list"][0];
    assert_eq!(json!(["ADMIN", "USER"]), row["roles"]);
    assert_eq!(json!({"env": "prod"}), row["attrs"]);
    assert!(row.get("note").is_none());
    let (_, r) = call(
        &n,
        "POST",
        "/erupt-api/data/modify/Widget",
        Some(json!({"name": "B", "roles": "ADMIN"})),
    );
    assert_eq!(json!(false), r["success"]);
}

#[test]
fn memory() {
    scenario(MemoryRepository::new());
}

#[cfg(feature = "sqlite")]
#[test]
fn sqlite() {
    use erupt::{Dialect, SqlRepository, SqliteExecutor};
    scenario(
        SqlRepository::new(
            SqliteExecutor::open(":memory:").unwrap(),
            "widget",
            Dialect::Sqlite,
        )
        .auto_create(),
    );
}

#[test]
fn transient_and_json_fields_refuse_search() {
    let built = Model::new("W", "W")
        .field("id", Field::pk())
        .field("note", Field::input("Note").transient().search())
        .build();
    assert!(built.is_err());
    let built = Model::new("W", "W")
        .field("id", Field::pk())
        .field("tags", Field::input("Tags").json().sortable())
        .build();
    assert!(built.is_err());
}
