//! Calls as a protocol v2 server makes them: signed, with the `Erupt-Enforced` each endpoint needs.
#![allow(dead_code)]
use std::time::{SystemTime, UNIX_EPOCH};

use erupt::http::Request;
use erupt::signature::sign;

pub const TOKEN: &str = "node-secret";

/// What a node requires in `Erupt-Enforced` for an endpoint (PROTOCOL.md §12.2).
pub fn required(method: &str, path: &str) -> &'static str {
    let path = path.split('?').next().unwrap_or(path);
    if method == "GET" && path.starts_with("/erupt-api/build/") {
        ""
    } else if path.starts_with("/erupt-api/data/table/") {
        "power,query"
    } else if path.starts_with("/erupt-api/data/modify/") && !path.ends_with("/delete") {
        "power,record"
    } else {
        "power"
    }
}

/// Sign a request as it stands (method, path and query, user header, body) with `enforced`; `None` sends no
/// `Erupt-Enforced`.
pub fn sign_with(request: Request, enforced: Option<&str>) -> Request {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let target = if request.query.is_empty() {
        request.path.clone()
    } else {
        format!("{}?{}", request.path, request.query)
    };
    let signature = sign(
        TOKEN,
        &request.method,
        &target,
        ts,
        enforced,
        request.get_header("user"),
        Some(&request.body),
    );
    let mut request = request
        .header("Erupt-Timestamp", &ts.to_string())
        .header("Erupt-Signature", &signature);
    if let Some(enforced) = enforced {
        request = request.header("Erupt-Enforced", enforced);
    }
    request
}

/// Sign a request with what its endpoint needs.
pub fn signed(request: Request) -> Request {
    let enforced = required(&request.method, &request.path);
    sign_with(request, Some(enforced).filter(|e| !e.is_empty()))
}
