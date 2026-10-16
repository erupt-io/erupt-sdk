use erupt::http::{Request, Response};
use erupt::{Error, Field, MemoryRepository, Model, Node, Operation};
use serde_json::{json, Map, Value};

const TOKEN: &str = "node-secret";

fn node() -> Node {
    let post = Model::new("Post", "Post")
        .field("id", Field::pk())
        .field("title", Field::input("Title").search().not_null())
        .operation(
            Operation::new("ping", "Ping")
                .handler(|op| Ok(Some(format!("alert({})", op.rows.len())))),
        )
        .build()
        .unwrap();
    let mut node =
        Node::new("n", TOKEN, ["http://127.0.0.1:1"]).power_source(|token, _| match token {
            "t1" => Ok(
                json!({"add": true, "edit": true, "delete": true, "viewDetails": true})
                    .as_object()
                    .cloned()
                    .unwrap(),
            ),
            _ => Err(Error::Other("server down".into())),
        });
    node.register(&post, MemoryRepository::new()).unwrap();
    node
}

fn call(
    node: &Node,
    method: &str,
    path: &str,
    body: Option<Value>,
    headers: &[(&str, &str)],
) -> (u16, Value) {
    let mut request = Request::new(method, path)
        .header("Access-Token", TOKEN)
        .header("token", "t1")
        .header("erupt", "Post");
    for (name, value) in headers {
        request = request.header(name, value);
    }
    if let Some(body) = body {
        request = request.body(body.to_string());
    }
    let Response { status, body, .. } = node.handle(&request);
    (
        status,
        serde_json::from_slice(&body)
            .unwrap_or_else(|_| Value::String(String::from_utf8_lossy(&body).into_owned())),
    )
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
    assert_eq!(
        403,
        call(
            &n,
            "GET",
            "/erupt-api/build/Post",
            None,
            &[("Access-Token", "bad")]
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
        call(&n, "GET", "/node-health", None, &[("Access-Token", "")])
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
    let (_, r) = call(
        &n,
        "POST",
        "/erupt-api/data/modify/Post",
        Some(json!({})),
        &[],
    );
    assert_eq!(json!("Title cannot be empty"), r["message"]);
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
        "/erupt-api/data/Post/operator/ping",
        Some(json!({"ids": [1], "param": null})),
        &[],
    );
    assert_eq!(json!("alert(1)"), r["data"]);
    let (_, r) = call(
        &n,
        "POST",
        "/erupt-api/data/table/Post",
        Some(json!({"condition": [{"key": "title\" OR 1=1", "value": 1}]})),
        &[],
    );
    assert_eq!(json!(false), r["success"]);
    let raw = Request::new("POST", "/erupt-api/data/modify/Post")
        .header("Access-Token", TOKEN)
        .header("token", "t1")
        .header("erupt", "Post")
        .body("{not json");
    let r: Value = serde_json::from_slice(&n.handle(&raw).body).unwrap();
    assert_eq!(
        (json!(false), json!("malformed JSON body")),
        (r["success"].clone(), r["message"].clone())
    );
}

#[test]
fn power_fails_closed() {
    let n = node();
    assert_eq!(
        403,
        call(
            &n,
            "POST",
            "/erupt-api/data/modify/Post",
            Some(json!({"title": "a"})),
            &[("token", "t-down")]
        )
        .0
    );
    let (_, build) = call(
        &n,
        "GET",
        "/erupt-api/build/Post",
        None,
        &[("token", "t-down")],
    );
    let power: &Map<String, Value> = build["power"].as_object().unwrap();
    assert_eq!(Some(&json!(false)), power.get("add"));
    assert_eq!(Some(&json!(false)), power.get("export"));
    assert_eq!(Some(&json!(true)), power.get("cellEdit")); // the server edits the cell
}
