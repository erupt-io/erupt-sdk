use erupt::http::Request;
use erupt::signature::{sign, verify, WINDOW_SECONDS};
use erupt::{Error, Field, MemoryRepository, Model, Node};
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

fn node(require_signature: bool) -> Node {
    let post = Model::new("Post", "Post")
        .field("id", Field::pk())
        .field("title", Field::input("Title"))
        .build()
        .unwrap();
    let mut node = Node::new("n", TOKEN, ["http://127.0.0.1:1"])
        .require_signature(require_signature)
        // the server is unreachable: only an enforced power lets a write through
        .power_source(|_, _| Err(Error::Other("server down".into())));
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
    // `power` is enforced on the signed calls, so the build does not depend on the (down) server
    let n = node(false);
    // a valid signature stands for the access token
    assert_eq!(
        200,
        n.handle(&signed("GET", "/erupt-api/build/Post", Some("power"), ""))
            .status
    );
    // a signature that does not verify is refused even with the right token
    let tampered =
        signed("GET", "/erupt-api/build/Post", Some("power"), "").header("Erupt-Timestamp", "1");
    assert_eq!(
        403,
        n.handle(&tampered.header("Access-Token", TOKEN)).status
    );
    // unsigned: the token decides, unless signatures are required
    let plain = || {
        Request::new("GET", "/erupt-api/build/Post")
            .header("token", "t")
            .header("erupt", "Post")
            .header("Access-Token", TOKEN)
    };
    assert_eq!(200, n.handle(&plain()).status);
    assert_eq!(403, node(true).handle(&plain()).status);
    assert_eq!(
        200,
        node(true)
            .handle(&signed("GET", "/erupt-api/build/Post", Some("power"), ""))
            .status
    );
}

#[test]
fn enforced_power() {
    let n = node(false);
    let add = json!({"title": "a"}).to_string();
    let target = "/erupt-api/data/modify/Post";
    // signed `power`: the declared power applies without asking the (down) server
    assert_eq!(
        200,
        n.handle(&signed("POST", target, Some("power,record"), &add))
            .status
    );
    // signed without `power`: the callback fails closed
    assert_eq!(403, n.handle(&signed("POST", target, None, &add)).status);
    // an unsigned Erupt-Enforced is ignored
    let unsigned = Request::new("POST", target)
        .header("token", "t")
        .header("erupt", "Post")
        .header("Access-Token", TOKEN)
        .header("Erupt-Enforced", "power")
        .body(add.clone());
    assert_eq!(403, n.handle(&unsigned).status);
}
