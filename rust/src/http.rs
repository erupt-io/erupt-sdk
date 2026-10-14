//! A small HTTP/1.1 layer on std::net: the request / response types `Node::handle` speaks, the built-in
//! server and the client for the calls back to the erupt server. Plain http only; put a TLS terminating
//! proxy in front when the server is reached over https.
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream, ToSocketAddrs};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

const MAX_HEAD: usize = 64 * 1024;
const MAX_BODY: usize = 16 * 1024 * 1024;
const TIMEOUT: Duration = Duration::from_secs(30);

/// An incoming request, framework neutral.
#[derive(Clone, Debug, Default)]
pub struct Request {
    pub method: String,
    /// path without the query string, still percent-encoded
    pub path: String,
    pub query: String,
    /// header names in lower case
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

impl Request {
    pub fn new(method: &str, target: &str) -> Self {
        let (path, query) = target.split_once('?').unwrap_or((target, ""));
        Request {
            method: method.to_string(),
            path: path.to_string(),
            query: query.to_string(),
            ..Default::default()
        }
    }

    pub fn header(mut self, name: &str, value: &str) -> Self {
        self.headers
            .insert(name.to_ascii_lowercase(), value.to_string());
        self
    }

    pub fn body(mut self, body: impl Into<Vec<u8>>) -> Self {
        self.body = body.into();
        self
    }

    pub fn get_header(&self, name: &str) -> Option<&str> {
        self.headers
            .get(&name.to_ascii_lowercase())
            .map(String::as_str)
    }

    /// The first value of a query parameter, decoded.
    pub fn query_param(&self, name: &str) -> Option<String> {
        self.query
            .split('&')
            .filter_map(|p| p.split_once('='))
            .find(|(k, _)| decode(k) == name)
            .map(|(_, v)| decode(v))
    }
}

/// An outgoing response.
#[derive(Clone, Debug, PartialEq)]
pub struct Response {
    pub status: u16,
    pub content_type: &'static str,
    pub body: Vec<u8>,
}

impl Response {
    pub fn json(status: u16, value: &serde_json::Value) -> Self {
        Response {
            status,
            content_type: "application/json; charset=utf-8",
            body: value.to_string().into_bytes(),
        }
    }

    pub fn text(status: u16, text: &str) -> Self {
        Response {
            status,
            content_type: "text/plain; charset=utf-8",
            body: text.as_bytes().to_vec(),
        }
    }
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        413 => "Payload Too Large",
        _ => "Internal Server Error",
    }
}

/// Percent-decoding (and `+` as space in query strings is left alone: erupt sends `%20`).
pub fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = |b: u8| (b as char).to_digit(16);
            if let (Some(h), Some(l)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Percent-encoding for query strings and forms.
pub fn encode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// Standard base64 (the `user` header).
pub fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let value = |c: u8| -> Option<u32> {
        Some(match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            _ => return None,
        } as u32)
    };
    let clean: Vec<u8> = text
        .bytes()
        .filter(|b| !b.is_ascii_whitespace() && *b != b'=')
        .collect();
    let mut out = Vec::with_capacity(clean.len() * 3 / 4);
    for chunk in clean.chunks(4) {
        let mut n = 0u32;
        for (i, c) in chunk.iter().enumerate() {
            n |= value(*c)? << (18 - 6 * i);
        }
        let bytes = [(n >> 16) as u8, (n >> 8) as u8, n as u8];
        match chunk.len() {
            4 => out.extend_from_slice(&bytes),
            3 => out.extend_from_slice(&bytes[..2]),
            2 => out.push(bytes[0]),
            _ => return None,
        }
    }
    Some(out)
}

/// First line, lower-cased headers and body of one HTTP message.
type Message = (String, HashMap<String, String>, Vec<u8>);

/// Head and body of one HTTP message from a stream.
fn read_message(reader: &mut impl BufRead) -> std::io::Result<Option<Message>> {
    let mut first = String::new();
    if reader.read_line(&mut first)? == 0 {
        return Ok(None);
    }
    let mut headers = HashMap::new();
    let mut size = first.len();
    loop {
        let mut line = String::new();
        let n = reader.read_line(&mut line)?;
        size += n;
        if n == 0 || size > MAX_HEAD {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "header too large or truncated",
            ));
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            headers.insert(name.trim().to_ascii_lowercase(), value.trim().to_string());
        }
    }
    let body = if headers
        .get("transfer-encoding")
        .map(|t| t.eq_ignore_ascii_case("chunked"))
        .unwrap_or(false)
    {
        read_chunked(reader)?
    } else if let Some(length) = headers.get("content-length") {
        let length: usize = length.parse().map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, "bad content-length")
        })?;
        if length > MAX_BODY {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "body too large",
            ));
        }
        let mut body = vec![0; length];
        reader.read_exact(&mut body)?;
        body
    } else {
        Vec::new()
    };
    Ok(Some((first.trim_end().to_string(), headers, body)))
}

fn read_chunked(reader: &mut impl BufRead) -> std::io::Result<Vec<u8>> {
    let mut body = Vec::new();
    loop {
        let mut line = String::new();
        reader.read_line(&mut line)?;
        let size = usize::from_str_radix(line.trim().split(';').next().unwrap_or(""), 16)
            .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "bad chunk size"))?;
        if body.len() + size > MAX_BODY {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "body too large",
            ));
        }
        let mut chunk = vec![0; size + 2];
        reader.read_exact(&mut chunk)?;
        if size == 0 {
            return Ok(body);
        }
        body.extend_from_slice(&chunk[..size]);
    }
}

fn serve_connection(stream: TcpStream, handler: &(dyn Fn(&Request) -> Response + Send + Sync)) {
    let _ = stream.set_read_timeout(Some(TIMEOUT));
    let _ = stream.set_write_timeout(Some(TIMEOUT));
    let Ok(read_half) = stream.try_clone() else {
        return;
    };
    let mut reader = BufReader::new(read_half);
    let response = match read_message(&mut reader) {
        Ok(Some((first, headers, body))) => {
            let mut parts = first.split_whitespace();
            let (method, target) = (parts.next().unwrap_or(""), parts.next().unwrap_or("/"));
            let mut request = Request::new(method, target);
            request.headers = headers;
            request.body = body;
            handler(&request)
        }
        Ok(None) => return,
        Err(e) => Response::text(
            if e.to_string().contains("too large") {
                413
            } else {
                400
            },
            "",
        ),
    };
    let mut stream = stream;
    let head = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        response.status,
        reason(response.status),
        response.content_type,
        response.body.len()
    );
    let _ = stream
        .write_all(head.as_bytes())
        .and_then(|_| stream.write_all(&response.body))
        .and_then(|_| stream.flush());
}

/// Serve `handler` on `addr` with `workers` threads, one request per connection. Blocks.
pub fn serve(
    addr: &str,
    workers: usize,
    handler: Arc<dyn Fn(&Request) -> Response + Send + Sync>,
) -> std::io::Result<()> {
    let listener = TcpListener::bind(addr)?;
    serve_listener(listener, workers, handler)
}

/// Like [`serve`] on an already bound listener.
pub fn serve_listener(
    listener: TcpListener,
    workers: usize,
    handler: Arc<dyn Fn(&Request) -> Response + Send + Sync>,
) -> std::io::Result<()> {
    let (tx, rx) = mpsc::channel::<TcpStream>();
    let rx = Arc::new(Mutex::new(rx));
    for _ in 0..workers.max(1) {
        let (rx, handler) = (rx.clone(), handler.clone());
        thread::spawn(move || loop {
            let next = rx.lock().expect("worker queue").recv();
            match next {
                Ok(stream) => serve_connection(stream, handler.as_ref()),
                Err(_) => return,
            }
        });
    }
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                if tx.send(stream).is_err() {
                    break;
                }
            }
            Err(_) => continue,
        }
    }
    Ok(())
}

/// One request to an `http://` URL; returns status and body.
pub fn fetch(
    method: &str,
    url: &str,
    headers: &[(&str, &str)],
    body: Option<&[u8]>,
    timeout: Duration,
) -> std::io::Result<(u16, Vec<u8>)> {
    let invalid = |m: &str| std::io::Error::new(std::io::ErrorKind::InvalidInput, m.to_string());
    let rest = url
        .strip_prefix("http://")
        .ok_or_else(|| invalid("only http:// URLs are supported; front https with a proxy"))?;
    let (authority, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let address = if authority
        .rsplit(':')
        .next()
        .map(|p| p.parse::<u16>().is_ok())
        .unwrap_or(false)
        && !authority.ends_with(']')
    {
        authority.to_string()
    } else {
        format!("{authority}:80")
    };
    let target = address
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| invalid("cannot resolve host"))?;
    let mut stream = TcpStream::connect_timeout(&target, timeout)?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;
    let mut head =
        format!("{method} {path} HTTP/1.1\r\nHost: {authority}\r\nConnection: close\r\n");
    for (name, value) in headers {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    if let Some(body) = body {
        head.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes())?;
    if let Some(body) = body {
        stream.write_all(body)?;
    }
    let mut reader = BufReader::new(stream);
    let (first, headers, mut body) =
        read_message(&mut reader)?.ok_or_else(|| invalid("empty response"))?;
    if !headers.contains_key("content-length") && !headers.contains_key("transfer-encoding") {
        reader.read_to_end(&mut body)?;
    }
    let status = first
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| invalid("bad status line"))?;
    Ok((status, body))
}
