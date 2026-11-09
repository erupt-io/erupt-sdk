use erupt::http::Request;
use erupt::signature::{sign, verify, WINDOW_SECONDS};
use erupt::{Field, MemoryRepository, Model, Node};
use serde_json::{json, Value};
use std::time::{SystemTime, UNIX_EPOCH};

const TOKEN: &str = "node-secret";

#[test]
fn vectors() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../conformance/signature-vectors.json"
    );
    let file: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let token = file["accessToken"].as_str().unwrap();
    for v in file["vectors"].as_array().unwrap() {
        let case = v["case"].as_str().unwrap();
        let ts = v["timestamp"].as_i64().unwrap();
        let body = v["body"].as_str().map(str::as_bytes);
        let (method, pq) = (
            v["method"].as_str().unwrap(),
            v["pathAndQuery"].as_str().unwrap(),
        );
        let (enforced, user) = (v["enforced"].as_str(), v["user"].as_str());
        let expected = v["signature"].as_str().unwrap();
        assert_eq!(
            expected,
            sign(token, method, pq, ts, enforced, user, body),
            "{case}"
        );
        let check = |now: i64, signature: &str| {
            let ts = ts.to_string();
            verify(
                token,
                method,
                pq,
                Some(&ts),
                enforced,
                user,
                body,
                signature,
                now,
            )
        };
        assert!(check(ts + WINDOW_SECONDS, expected), "{case}");
        assert!(check(ts - WINDOW_SECONDS, expected), "{case}");
        assert!(!check(ts + WINDOW_SECONDS + 1, expected), "{case}");
        assert!(!check(ts, &expected.replace(&expected[..1], "x")), "{case}");
        assert!(
            !verify(token, method, pq, None, enforced, user, body, expected, ts),
            "{case}"
        );
    }
}

fn node() -> Node {
    let post = Model::new("Post", "Post")
        .field("id", Field::pk())
        .field("title", Field::input("Title"))
        .build()
        .unwrap();
    let mut node = Node::new("n", TOKEN, ["http://127.0.0.1:1"]);
    node.register(&post, MemoryRepository::new()).unwrap();
    node
}

fn signed(method: &str, target: &str, enforced: Option<&str>, body: &str) -> Request {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let body_bytes = Some(body.as_bytes());
    let mut request = Request::new(method, target)
        .header("token", "t")
        .header("erupt", "Post")
        .header("Erupt-Timestamp", &ts.to_string())
        .header(
            "Erupt-Signature",
            &sign(TOKEN, method, target, ts, enforced, None, body_bytes),
        );
    if let Some(enforced) = enforced {
        request = request.header("Erupt-Enforced", enforced);
    }
    if method == "POST" {
        request = request.body(body);
    }
    request
}

#[test]
fn authentication() {
    let n = node();
    assert_eq!(
        200,
        n.handle(&signed("GET", "/erupt-api/build/Post", None, ""))
            .status
    );
    assert_eq!(
        200,
        n.handle(&signed("GET", "/erupt-api/build/Post?_probe=1", None, ""))
            .status
    );
    // a signature that does not verify is refused even with the right token
    let tampered = signed("GET", "/erupt-api/build/Post", None, "").header("Erupt-Timestamp", "1");
    assert_eq!(
        403,
        n.handle(&tampered.header("Access-Token", TOKEN)).status
    );
    // unsigned: refused whatever the token (PROTOCOL.md §12.2)
    let plain = Request::new("GET", "/erupt-api/build/Post")
        .header("token", "t")
        .header("erupt", "Post")
        .header("Access-Token", TOKEN);
    assert_eq!(403, n.handle(&plain).status);
    // the body is signed
    let query = r#"{"pageIndex": 1}"#;
    let altered = signed(
        "POST",
        "/erupt-api/data/table/Post",
        Some("power,query"),
        query,
    )
    .body(r#"{"pageIndex": 2}"#);
    assert_eq!(403, n.handle(&altered).status);
}

#[test]
fn enforced() {
    let n = node();
    let add = json!({"title": "a"}).to_string();
    let target = "/erupt-api/data/modify/Post";
    // what the server vouched for decides: an add needs power and record
    assert_eq!(
        200,
        n.handle(&signed("POST", target, Some("power,record"), &add))
            .status
    );
    assert_eq!(
        403,
        n.handle(&signed("POST", target, Some("power"), &add))
            .status
    );
    assert_eq!(403, n.handle(&signed("POST", target, None, &add)).status);
    // an Erupt-Enforced added after signing does not verify
    let forged = signed("POST", target, None, &add).header("Erupt-Enforced", "power,record");
    assert_eq!(403, n.handle(&forged).status);
}
