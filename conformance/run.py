"""Protocol conformance suite: one set of HTTP checks every language's node SDK must pass.

    python conformance/run.py -- <command that starts the fixture node>

The command must start the fixture described in conformance/README.md, reading ERUPT_ACCESS_TOKEN,
ERUPT_SERVER and PORT from the environment. This script plays the erupt server: it accepts the
registration (probing /node-health like the real one), answers erupt-power per session token, then sends
the requests the real server would forward and checks the answers. Standard library only.

A node registering with ``protocolVersion: 2`` is checked as a thin node (PROTOCOL.md §12): every call signed with
the Erupt-Enforced its endpoint needs, values normalized, drills and searches sent as plain conditions, and the
build declaring only what the node sets. Any other node is checked against protocol v1.
"""
import base64
import hashlib
import hmac
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import annotations  # noqa: E402  (the schema check and the server's build completion, from schema/)

NODE_NAME = "conformance"
ACCESS_TOKEN = "conformance-access-token"
FULL = {"add": True, "edit": True, "delete": True, "viewDetails": True, "export": True, "importable": True}
# session token -> what /erupt-power answers; "t-down" makes the server fail
POWERS = {"t1": FULL, "t-noadd": {**FULL, "add": False}}


VECTORS = Path(__file__).resolve().parent / "signature-vectors.json"

# the protocol the node registered with; v2 answers every register call (PROTOCOL.md §12.2)
V2 = False
SERVER_PROTOCOL = 2


def required_enforced(method, path):
    """What a v2 node requires in Erupt-Enforced for an endpoint (PROTOCOL.md §12.2)."""
    path = path.split("?")[0]
    if method == "GET" and path.startswith("/erupt-api/build/"):
        return ""
    if path.startswith("/erupt-api/data/table/"):
        return "power,query"
    if path.startswith("/erupt-api/data/modify/") and not path.endswith("/delete"):
        return "power,record"
    return "power"


def sign(method, path_and_query, timestamp, enforced, user, body):
    """Erupt-Signature, written here independently of every SDK and checked against the Java vectors."""
    canonical = "\n".join([method.upper(), path_and_query, str(timestamp), enforced or "",
                           hashlib.sha256((user or "").encode()).hexdigest(),
                           "UNSIGNED-PAYLOAD" if body is None else hashlib.sha256(body).hexdigest()])
    return hmac.new(ACCESS_TOKEN.encode(), canonical.encode(), hashlib.sha256).hexdigest()


def check_vectors():
    doc = json.loads(VECTORS.read_text("utf-8"))
    assert doc["accessToken"] == ACCESS_TOKEN
    for v in doc["vectors"]:
        body = None if v["body"] is None else v["body"].encode()
        if sign(v["method"], v["pathAndQuery"], v["timestamp"], v["enforced"], v["user"], body) != v["signature"]:
            sys.exit(f"conformance signer disagrees with the Java vectors: {v['case']}")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class FakeServer(BaseHTTPRequestHandler):
    registrations, deregistrations, power_calls = [], [], []

    def log_message(self, *args):
        pass

    def reply(self, status, body=b""):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/erupt-cloud-api/register-node":
            info = json.loads(body)
            ok = info.get("nodeName") == NODE_NAME and info.get("accessToken") == ACCESS_TOKEN
            for address in info.get("nodeAddress") or []:
                try:
                    with urllib.request.urlopen(address + "/node-health", timeout=2) as r:
                        ok = ok and r.read().decode() == NODE_NAME
                except Exception:
                    ok = False
            if not ok:
                return self.reply(500)
            FakeServer.registrations.append(info)
            return self.reply(200, json.dumps({"protocolVersion": SERVER_PROTOCOL}).encode())
        if self.path == "/erupt-cloud-api/remove-instance-node":
            FakeServer.deregistrations.append(urllib.parse.parse_qs(body.decode()))
            return self.reply(200)
        self.reply(404)

    # what a node reads back from the server: its config text and the acting user's info (PROTOCOL.md §6)
    NODE_CONFIG = '{"theme":"dark"}'
    USER_INFO = {"account": "admin", "roles": ["editor", "viewer"]}

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path == f"/erupt-cloud-api/node-config/{NODE_NAME}":
            ok = self.headers.get("Access-Token") == ACCESS_TOKEN
            return self.reply(200 if ok else 403, FakeServer.NODE_CONFIG.encode() if ok else b"")
        if url.path == f"/erupt-cloud-api/userinfo/{NODE_NAME}":
            ok = self.headers.get("Access-Token") == ACCESS_TOKEN
            return self.reply(200 if ok else 403, json.dumps(FakeServer.USER_INFO).encode() if ok else b"")
        if url.path == "/erupt-cloud-api/erupt-power":
            FakeServer.power_calls.append(urllib.parse.parse_qs(url.query))
            power = POWERS.get(self.headers.get("token"))
            if power is None:
                return self.reply(500, b"server error")
            return self.reply(200, json.dumps(power).encode())
        self.reply(404)


class Node:
    def __init__(self, address):
        self.address = address

    def call(self, method, path, body=None, erupt="Article", token="t1", account="admin", headers=None,
             signed=None, enforced=None, signed_body=None, timestamp=None):
        """``signed`` sends Erupt-Signature (and Erupt-Enforced) instead of the plain Access-Token, as erupt
        2.3.x servers do; ``signed_body`` / ``timestamp`` sign something other than what is sent. A v2 node is
        called signed by default, with the Erupt-Enforced its endpoint needs (``enforced=""`` sends none)."""
        if signed is None:
            signed = V2
        if enforced is None and V2:
            enforced = required_enforced(method, path)
        raw = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        h = {"Access-Token": ACCESS_TOKEN, "token": token, "Content-Type": "application/json",
             "user": base64.b64encode(json.dumps({"uid": 1, "account": account, "name": account, "tenantId": None}).encode()).decode()}
        if erupt:
            h["erupt"] = erupt
        if signed:
            ts = int(time.time()) if timestamp is None else timestamp
            del h["Access-Token"]
            h["Erupt-Timestamp"] = str(ts)
            if enforced:
                h["Erupt-Enforced"] = enforced
            h["Erupt-Signature"] = sign(method, path, ts, enforced, h["user"], (raw or b"") if signed_body is None else signed_body)
        h.update(headers or {})
        h = {k: v for k, v in h.items() if v is not None}
        req = urllib.request.Request(self.address + path, data=raw, method=method, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                status, text = r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            status, text = e.code, e.read().decode()
        try:
            return status, json.loads(text) if text else None
        except ValueError:
            return status, text


CHECKS = []


def check(fn):
    CHECKS.append(fn)
    return fn


def eq(expected, actual, what=""):
    if expected != actual:
        raise AssertionError(f"{what}: expected {json.dumps(expected, ensure_ascii=False)}, got {json.dumps(actual, ensure_ascii=False)}")


def ok_r(r, what=""):
    status, body = r
    if status != 200 or not isinstance(body, dict) or body.get("success") is not True:
        raise AssertionError(f"{what}: expected a successful R, got {status} {body}")
    return body


def fail_r(r, what=""):
    status, body = r
    if status != 200 or not isinstance(body, dict) or body.get("success") is not False or not body.get("message"):
        raise AssertionError(f"{what}: expected a failed R with a message, got {status} {body}")
    return body


def table(n, condition=(), sort=(), size=10, erupt="Article", headers=None, **extra):
    status, page = n.call("POST", f"/erupt-api/data/table/{erupt}",
                          {"pageIndex": 1, "pageSize": size, "condition": list(condition), "sort": list(sort), **extra},
                          erupt=erupt, headers=headers)
    eq(200, status, f"table {condition} {sort} -> {page}")
    return page


def titles(page):
    return [r["title"] for r in page["list"]]


def clear_articles(n):
    ids = [r["id"] for r in table(n, size=1000)["list"]]
    if ids:
        ok_r(n.call("POST", "/erupt-api/data/modify/Article/delete", ids), "clear")


def add(n, **row):
    ok_r(n.call("POST", "/erupt-api/data/modify/Article", row), f"add {row}")


# ---------------------------------------------------------------- checks

@check
def health(n):
    eq((200, NODE_NAME), n.call("GET", "/node-health", erupt=None, headers={"Access-Token": None, "token": None, "user": None}), "health")


@check
def guards(n):
    eq(403, n.call("GET", "/erupt-api/build/Article", headers={"Origin": "http://evil"})[0], "origin")
    if V2:
        # a v2 node takes signed calls only, each with the Erupt-Enforced its endpoint needs (§12.2)
        eq(403, n.call("GET", "/erupt-api/build/Article", signed=False)[0], "plain Access-Token")
        eq(403, n.call("POST", "/erupt-api/data/table/Article", {}, enforced="power")[0], "table without query")
        eq(403, n.call("POST", "/erupt-api/data/modify/Article", {"title": "x"}, enforced="power")[0], "add without record")
        eq(403, n.call("POST", "/erupt-api/data/modify/Article/update", {"id": 1}, enforced="power,query")[0], "update without record")
        eq(403, n.call("POST", "/erupt-api/data/modify/Article/delete", [1], enforced="")[0], "delete without power")
        eq(403, n.call("GET", "/erupt-api/data/Article/1", enforced="")[0], "get without power")
    else:
        eq(403, n.call("GET", "/erupt-api/build/Article", headers={"Access-Token": "bad"})[0], "bad token")
        eq(403, n.call("GET", "/erupt-api/build/Article", headers={"Access-Token": None})[0], "no token")
    eq(404, n.call("GET", "/erupt-api/build/Missing", erupt="Missing")[0], "unknown erupt")
    eq(404, n.call("GET", "/erupt-api/build/Article", erupt="Note")[0], "header / path mismatch")
    eq(404, n.call("GET", "/erupt-api/build/Article", erupt=None)[0], "no erupt header")
    eq(404, n.call("GET", "/erupt-api/build/Article", headers={"eruptParent": f"{NODE_NAME}.Note"})[0], "foreign parent")
    eq(200, n.call("GET", "/erupt-api/build/Article", headers={"eruptParent": f"{NODE_NAME}.Article"})[0], "self parent")
    eq(404, n.call("GET", "/erupt-api/nothing/here")[0], "unknown path")


def read_build(n, name="Article", account="admin"):
    """A build as the browser reads it: a v2 node's declaration is checked, then completed as the server does."""
    status, b = n.call("GET", f"/erupt-api/build/{name}", erupt=name, account=account)
    eq(200, status, f"build {name}")
    if V2:
        annotations.check_declared(b, "declared build")
        b = annotations.complete(b)
    return b


@check
def build(n):
    if V2:
        status, declared = n.call("GET", "/erupt-api/build/Category", erupt="Category")
        link = declared["eruptModel"]["eruptJson"]["drills"][0]["link"]
        # the server turns a drill into a condition, so a v2 node declares the link's columns (§12.3)
        eq(("Article", "category"), (link.get("linkErupt"), link.get("joinColumn")), "drill link sent to the server")
        eq("id", link.get("column", "id"), "drill link column")
        f = {x["fieldName"]: x for x in n.call("GET", "/erupt-api/build/Article")[1]["eruptModel"]["eruptFieldModels"]}
        for name, field in f.items():
            if (field["eruptFieldJson"].get("edit") or {}).get("type", "AUTO") == "AUTO" and name != "id":
                raise AssertionError(f"declared build: {name} leaves edit.type AUTO, which the node resolves")
    b = read_build(n)
    m = b["eruptModel"]
    eq("Article", m["eruptName"], "eruptName")
    for key in ("name", "orderBy"):
        if key in m["eruptJson"]:
            raise AssertionError(f"eruptJson must not carry the @Transient '{key}'")
    eq("id", m["eruptJson"]["primaryKeyCol"], "primaryKeyCol")
    f = {x["fieldName"]: x for x in m["eruptFieldModels"]}
    eq(["id", "title", "status", "views", "featured", "publish_date", "review_at", "body", "category", "topic"],
       [x["fieldName"] for x in m["eruptFieldModels"]], "field order")
    eq({"id": "NUMBER", "title": "INPUT", "status": "CHOICE", "views": "NUMBER", "featured": "BOOLEAN", "publish_date": "DATE",
        "review_at": "DATE", "body": "TEXTAREA", "category": "REFERENCE_TABLE", "topic": "REFERENCE_TREE"},
       {k: v["eruptFieldJson"]["edit"]["type"] for k, v in f.items()}, "edit types")
    eq({"id": "number", "title": "String", "status": "String", "views": "number", "featured": "Boolean", "publish_date": "Date",
        "review_at": "Date", "body": "String", "category": "Category", "topic": "Category"},
       {k: v["fieldReturnName"] for k, v in f.items()}, "fieldReturnName")
    eq("DATE_TIME", f["review_at"]["eruptFieldJson"]["edit"]["dateType"]["type"], "review_at dateType")
    eq("DATE", f["publish_date"]["eruptFieldJson"]["edit"]["dateType"]["type"], "publish_date dateType")
    eq("DATE", f["publish_date"]["eruptFieldJson"]["views"][0]["type"], "publish_date view type")
    eq([], f["body"]["eruptFieldJson"]["views"], "body hidden from the table")
    eq([], f["id"]["eruptFieldJson"]["views"], "pk hidden")
    eq("Title", f["title"]["eruptFieldJson"]["edit"]["title"], "edit title")
    eq("Title", f["title"]["eruptFieldJson"]["views"][0]["title"], "view title")
    eq(True, f["title"]["eruptFieldJson"]["edit"]["notNull"], "notNull")
    eq(True, f["title"]["eruptFieldJson"]["edit"]["search"]["value"], "searchable")
    eq(False, f["views"]["eruptFieldJson"]["edit"]["search"]["value"], "not searchable")
    eq(True, f["views"]["eruptFieldJson"]["views"][0]["sortable"], "sortable")
    eq(64, f["title"]["eruptFieldJson"]["edit"]["inputType"]["length"], "raw edit override")
    eq([{"value": "draft", "label": "Draft", "desc": None, "color": None, "disable": False},
        {"value": "published", "label": "Published", "desc": None, "color": None, "disable": False}],
       f["status"]["componentValue"], "choice options")
    eq({"dependField": "", "id": "id", "label": "name"}, f["category"]["eruptFieldJson"]["edit"]["referenceTableType"], "referenceTableType")
    eq("name", f["category"]["eruptFieldJson"]["views"][0]["column"], "reference view column")
    eq("parent", f["topic"]["eruptFieldJson"]["edit"]["referenceTreeType"]["pid"], "referenceTreeType.pid")
    ops = {o["code"]: o for o in m["eruptJson"]["rowOperation"]}
    eq(["publish", "feature"], list(ops), "operations visible to admin")
    eq(("MULTI", "PublishForm", "fa fa-paper-plane"), (ops["publish"]["mode"], ops["publish"]["eruptClass"], ops["publish"]["icon"]), "publish")
    eq(("SINGLE", "void", ""), (ops["feature"]["mode"], ops["feature"]["eruptClass"], ops["feature"]["callHint"]), "feature")
    eq("item.status !== 'published'", ops["publish"]["ifExpr"], "ifExpr")
    eq(["publish"], list(b["operationErupts"] or {}), "operationErupts")
    eq(["note"], [x["fieldName"] for x in b["operationErupts"]["publish"]["eruptFieldModels"]], "form fields")
    eq((True, True), (b["power"]["export"], b["power"]["cellEdit"]), "export and cell editing pass: the server does them for every node")
    eq(True, b["power"]["add"], "add")
    b = read_build(n, account="root")
    eq(["publish", "feature", "rebuild"], [o["code"] for o in b["eruptModel"]["eruptJson"]["rowOperation"]], "operations visible to root")


@check
def signature(n):
    eq(200, n.call("GET", "/erupt-api/build/Article", signed=True)[0], "signed, no Access-Token")
    eq(200, n.call("GET", "/erupt-api/build/Article?_probe=1", signed=True)[0], "signed with a query string")
    query = {"pageIndex": 1, "pageSize": 10}
    table_enforced = "power,query" if V2 else None
    eq(200, n.call("POST", "/erupt-api/data/table/Article", query, signed=True, enforced=table_enforced)[0], "signed body")
    eq(403, n.call("POST", "/erupt-api/data/table/Article", query, signed=True, enforced=table_enforced, signed_body=b"{}")[0], "body altered after signing")
    eq(403, n.call("GET", "/erupt-api/build/Article", signed=True, headers={"Erupt-Signature": "00" * 32})[0], "wrong signature")
    eq(403, n.call("GET", "/erupt-api/build/Article", signed=True, timestamp=int(time.time()) - 301)[0], "outside the 300 s window")
    eq(403, n.call("GET", "/erupt-api/build/Article", signed=True, headers={"Erupt-Enforced": "power"})[0], "Erupt-Enforced added after signing")


@check
def enforced_power(n):
    if V2:
        # the server enforces every right of a v2 node: it never asks back (§12.2), so t-down changes nothing
        ok_r(n.call("POST", "/erupt-api/data/modify/Article", {"title": "enforced"}, token="t-down"), "add")
        eq(200, n.call("GET", "/erupt-api/build/Note", erupt="Note", token="t-down")[0], "build")
        return
    calls = len(FakeServer.power_calls)
    # with power enforced by the server, the node must not ask it (t-down would fail closed) ...
    s, b = n.call("GET", "/erupt-api/build/Article", token="t-down", signed=True, enforced="power")
    eq((200, True), (s, b["power"]["add"]), "build without the erupt-power callback")
    ok_r(n.call("POST", "/erupt-api/data/modify/Article", {"title": "enforced"}, token="t-down", signed=True, enforced="power,record"), "add")
    eq(calls, len(FakeServer.power_calls), "erupt-power calls while the server enforces power")
    # ... while the model's own declared power still holds
    eq(403, n.call("POST", "/erupt-api/data/modify/Note/delete", [1], erupt="Note", token="t-down", signed=True, enforced="power")[0], "declared delete off")
    # Erupt-Enforced is trusted only under a valid signature
    eq(403, n.call("POST", "/erupt-api/data/modify/Article", {"title": "x"}, token="t-down", headers={"Erupt-Enforced": "power"})[0], "unsigned Erupt-Enforced ignored")
    eq(403, n.call("POST", "/erupt-api/data/modify/Article", {"title": "x"}, token="t-down", signed=True)[0], "signed without power: still asks, fails closed")


@check
def build_matches_schema(n):
    for name in ("Article", "Note", "Category"):
        b = read_build(n, name, account="root")
        for m in annotations.models(b):
            annotations.check("Erupt", m["eruptJson"], m["eruptName"], partial=False)
            for op in m["eruptJson"]["rowOperation"]:
                annotations.check("RowOperation", op, f"{m['eruptName']}.{op['code']}", partial=False)
            for fm in m["eruptFieldModels"]:
                annotations.check("EruptField", fm["eruptFieldJson"], f"{m['eruptName']}.{fm['fieldName']}", partial=False)


@check
def power(n):
    status, b = n.call("GET", "/erupt-api/build/Note", erupt="Note")
    eq(False, b["power"]["delete"], "declared power")
    if V2:
        # the declared rights are the server's to enforce (§12.5); the node never asks for erupt-power
        eq([], FakeServer.power_calls, "no erupt-power callback from a v2 node")
        return
    eq(403, n.call("POST", "/erupt-api/data/modify/Article", {"title": "x"}, token="t-noadd")[0], "server denies add")
    eq(403, n.call("POST", "/erupt-api/data/modify/Article", {"title": "x"}, token="t-down")[0], "fails closed")
    eq(403, n.call("POST", "/erupt-api/data/modify/Note/delete", [1], erupt="Note")[0], "declared delete off")
    if not FakeServer.power_calls:
        raise AssertionError("the node never asked the server for erupt-power")
    eq([NODE_NAME], FakeServer.power_calls[-1].get("nodeName"), "erupt-power nodeName")


def wire_date_time(value):
    """A row's DATE_TIME as the server normalizes it on the way back in (§12.4): seconds, a space, no fraction."""
    return value.replace("T", " ")[:19] if isinstance(value, str) else value


@check
def crud(n):
    clear_articles(n)
    add(n, title="Hello erupt", status="published", views=10, featured=True, publish_date="2026-01-05",
        review_at="2026-01-05 10:30:00", body="...")
    add(n, title="Second", status="draft", views=3 if V2 else "3", featured=False, publish_date="2026-03-01")
    page = table(n)
    eq((2, 1), (page["total"], page["totalPage"]), "total")
    eq(["Second", "Hello erupt"], titles(page), "default order id desc")
    first = next(r for r in page["list"] if r["title"] == "Hello erupt")
    eq(("2026-01-05", "2026-01-05T10:30:00.000", 10, True), (first["publish_date"], first["review_at"], first["views"], first["featured"]), "row values")
    eq(["Hello erupt"], titles(table(n, [{"key": "title", "expression": "LIKE", "value": "hello"}])), "LIKE")
    eq(["Second"], titles(table(n, [{"key": "status", "expression": "EQ", "value": "draft"}])), "EQ choice")
    eq(["Hello erupt"], titles(table(n, [{"key": "featured", "expression": "EQ", "value": True}])), "EQ boolean")
    eq(["Second"], titles(table(n, [{"key": "publish_date", "expression": "RANGE", "value": ["2026-02-01", "2026-12-31"]}])), "RANGE date")
    eq(["Hello erupt", "Second"], titles(table(n, [{"key": "title", "expression": "IN", "value": ["Second", "Hello erupt"]}], sort=[{"field": "title", "direction": "ASC"}])), "IN")
    eq(["Second", "Hello erupt"], titles(table(n, sort=[{"field": "views", "direction": "ASC"}])), "sort")
    eq(1, len(table(n, size=1)["list"]), "page size")
    if V2:
        eq(["Hello erupt"], titles(table(n, [{"key": "review_at", "expression": "RANGE",
                                                  "value": ["2026-01-05 10:00:00", "2026-01-05 11:00:00"]}])), "RANGE date time")
        eq(["Second"], titles(table(n, [{"key": "views", "expression": "LT", "value": 5}])), "LT number")
    pk = first["id"]
    status, row = n.call("GET", f"/erupt-api/data/Article/{pk}")
    eq((200, "Hello erupt"), (status, row["title"]), "get")
    if V2:
        # the server sends the stored row patched with the edit, normalized
        row = {**row, "review_at": wire_date_time(row["review_at"])}
    ok_r(n.call("POST", "/erupt-api/data/modify/Article/update", {**row, "title": "Renamed"}), "update")
    renamed = n.call("GET", f"/erupt-api/data/Article/{pk}")[1]
    eq(("Renamed", "2026-01-05T10:30:00.000"), (renamed["title"], renamed["review_at"]), "updated")
    ok_r(n.call("POST", "/erupt-api/data/modify/Article/delete", [pk]), "delete")
    eq(1, table(n)["total"], "deleted")
    status, init = n.call("GET", "/erupt-api/data/init-value/Article")
    eq(200, status, "init-value")


@check
def like_is_literal(n):
    if not V2:
        return
    clear_articles(n)
    add(n, title="50% off")
    add(n, title="500 off")
    add(n, title="a_b")
    add(n, title="axb")
    # the node adds the wildcards; a % or _ the user typed is a literal (§12.4, §10)
    eq(["50% off"], titles(table(n, [{"key": "title", "expression": "LIKE", "value": "50%"}])), "LIKE with %")
    eq(["a_b"], titles(table(n, [{"key": "title", "expression": "LIKE", "value": "a_"}])), "LIKE with _")


@check
def data_proxy(n):
    status, init = n.call("GET", "/erupt-api/data/init-value/Note", erupt="Note")
    eq((200, "new"), (status, init.get("text")), "add_behavior fills the new form")
    status, r = n.call("POST", "/erupt-api/data/modify/Note", {"text": "forbidden"}, erupt="Note")
    eq((200, False, "forbidden text"), (status, r.get("success"), r.get("message")), "validate refuses with its message")
    ok_r(n.call("POST", "/erupt-api/data/modify/Note", {"text": "fine"}, erupt="Note"), "validate lets a record through")


def invoked():
    """Whether the node serves invoke (PROTOCOL.md §5.5); a Java node keeps the Java endpoints. A v2 node always does
    (§12.4)."""
    return V2 or "invoke" in (FakeServer.registrations[0].get("capabilities") or [])


@check
def invoke(n):
    if not invoked():
        return
    status, r = n.call("POST", "/erupt-api/invoke/Note/button/ping", {"form": {"text": "hi"}}, erupt="Note")
    eq((200, True, "pong:hi"), (status, r.get("success"), (r.get("data") or {}).get("eval")), "button")
    eq(404, n.call("POST", "/erupt-api/invoke/Note/button/text", {"form": {}}, erupt="Note")[0], "a field without that code")


@check
def references(n):
    clear_articles(n)
    query = {"pageIndex": 1, "pageSize": 10, "condition": [{"key": "name", "expression": "LIKE", "value": "py"}]}
    if invoked():
        # the server reads the picker off the referenced model's own table
        status, page = n.call("POST", "/erupt-api/data/table/Category", query, erupt="Category")
        eq((200, [{"id": 2, "name": "Python", "parent": 1}]), (status, page["list"]), "picker")
        eq(404, n.call("POST", "/erupt-api/data/Article/reference-table/category", query)[0], "reference-table is the server's")
    else:
        status, page = n.call("POST", "/erupt-api/data/Article/reference-table/category?tabRef=false", query)
        eq((200, [{"id": 2, "name": "Python", "parent": 1}]), (status, page["list"]), "picker")
        eq(404, n.call("POST", "/erupt-api/data/Article/reference-table/topic", {})[0], "table picker on a tree field")
    if V2:
        # a reference arrives as the referenced key alone, typed like the target's primary key (§12.4)
        add(n, title="Ref", category=2, topic=1)
    else:
        add(n, title="Ref", category={"id": "2", "name": "Python"}, topic={"id": 1, "name": "Tech"})
    row = table(n)["list"][0]
    # a reference travels as its key: the server resolves the label and the flattened column
    eq((2, 1), (row["category"], row["topic"]), "reference row: the key")
    for flattened in ("category_name", "topic_name"):
        if flattened in row:
            raise AssertionError(f"reference row: {flattened} is the server's to add")
    eq(2, n.call("GET", f"/erupt-api/data/Article/{row['id']}")[1]["category"], "reference get: the key")
    if V2:
        eq(1, table(n, [{"key": "category", "expression": "EQ", "value": 2}])["total"], "search by reference")
        eq(0, table(n, [{"key": "category", "expression": "IN", "value": [1, 3]}])["total"], "IN by reference")
        return
    eq(1, table(n, [{"key": "category", "expression": "EQ", "value": {"id": 2, "name": "Python"}}])["total"], "search by reference")
    eq(0, table(n, [{"key": "category", "expression": "IN", "value": [{"id": 1}, {"id": 3}]}])["total"], "IN by reference")
    fail_r(n.call("POST", "/erupt-api/data/table/Article", {"condition": [{"key": "category", "expression": "LIKE", "value": "x"}]}), "LIKE on a reference")


@check
def drill(n):
    clear_articles(n)
    add(n, title="Py", category=2 if V2 else {"id": 2, "name": "Python"})
    add(n, title="Other", category=3 if V2 else {"id": 3, "name": "Life"})
    if V2:
        # the server reads the source row and sends the join as a condition; the body names the drill so the node
        # adds its linkCondition (§12.4)
        drilled = {"erupt": "Category", "code": "Articles"}
        eq(["Py"], titles(table(n, [{"key": "category", "expression": "EQ", "value": 2}], drill=drilled)), "the rows of the drilled category")
        status, _ = n.call("POST", "/erupt-api/data/table/Article", {"drill": {"erupt": "Category", "code": "nope"}})
        eq(403, status, "an undeclared drill")
        return
    headers = {"Drill": "Articles", "DrillSourceErupt": "Category", "DrillValue": "2"}
    eq(["Py"], [r["title"] for r in table(n, headers=headers)["list"]], "the rows of the drilled category")
    eq(403, n.call("POST", "/erupt-api/data/table/Article", {}, headers={**headers, "Drill": "nope"})[0], "an undeclared drill")


@check
def trusted_query(n):
    if not invoked():
        return
    # a condition the server added after checking the browser's: taken on a field the search bar does not have
    status, page = n.call("POST", "/erupt-api/data/table/Article", {"condition": [{"key": "views", "expression": "EQ", "value": 1}]},
                          signed=True, enforced="power,query")
    eq(200, status, "signed query")
    if not isinstance(page, dict) or "list" not in page:
        raise AssertionError(f"signed query: expected a page, got {page}")
    if V2:
        # the primary key too: a link tree with nothing picked under dependNode (§12.4)
        eq(0, table(n, [{"key": "id", "expression": "NULL"}])["total"], "NULL on the primary key")


@check
def reference_tree(n):
    # the server builds reference trees from the referenced model's rows
    eq(404, n.call("GET", "/erupt-api/data/Article/reference-tree/topic")[0], "reference-tree is the server's")


@check
def operations(n):
    clear_articles(n)
    add(n, title="A")
    add(n, title="B")
    ids = [r["id"] for r in table(n)["list"]]
    # a node serving invoke runs operations through it, under the operation code
    path = "/erupt-api/invoke/Article/operation/" if invoked() else "/erupt-api/data/Article/operator/"
    if not V2:
        # a v2 node receives a param the server checked against the form (§12.4)
        fail_r(n.call("POST", path + "publish", {"ids": ids, "param": {}}), "form validation")
    r = ok_r(n.call("POST", path + "publish", {"ids": ids, "param": {"note": "go"}}), "publish")
    eq("Executed successfully", r["message"], "publish message")
    eq(["published", "published"], [x["status"] for x in table(n)["list"]], "publish effect")
    fail_r(n.call("POST", path + "feature", {"ids": ids, "param": None}), "SINGLE takes one row")
    eq("alert('featured')", ok_r(n.call("POST", path + "feature", {"ids": ids[:1], "param": None}))["data"], "script result")
    fail_r(n.call("POST", path + "publish", {"ids": [], "param": {"note": "go"}}), "no rows")
    eq(403, n.call("POST", path + "rebuild", {"ids": None, "param": None})[0], "hidden operation")
    ok_r(n.call("POST", path + "rebuild", {"ids": None, "param": None}, account="root"), "BUTTON operation")
    eq(404, n.call("POST", path + "missing", {})[0], "unknown operation")
    if invoked():
        eq({"note": None}, ok_r(n.call("POST", "/erupt-api/invoke/Article/operation-form/publish", {}), "form-value")["data"], "form-value")
        eq(None, ok_r(n.call("POST", "/erupt-api/invoke/Article/operation-form/feature", {}))["data"], "form-value without a form")
        eq(404, n.call("POST", "/erupt-api/data/Article/operator/publish", {"ids": ids})[0], "operator is invoke's")
    else:
        eq((200, {"note": None}), n.call("POST", path + "publish/form-value?ids=" + str(ids[0])), "form-value")
        eq(404, n.call("POST", path + "feature/form-value")[0], "form-value without a form")


@check
def illegal_input(n):
    if not V2:
        # a v2 node receives records and queries the server checked (§12.7)
        fail_r(n.call("POST", "/erupt-api/data/modify/Article", {"status": "draft"}), "notNull")
        fail_r(n.call("POST", "/erupt-api/data/modify/Article", {"title": "x", "status": "deleted"}), "illegal choice")
        fail_r(n.call("POST", "/erupt-api/data/modify/Article", {"title": "x", "views": "many"}), "illegal number")
        fail_r(n.call("POST", "/erupt-api/data/modify/Article", {"title": "x", "publish_date": "someday"}), "illegal date")
        fail_r(n.call("POST", "/erupt-api/data/table/Article", {"condition": [{"key": "views", "expression": "EQ", "value": 1}]}), "not searchable")
        fail_r(n.call("POST", "/erupt-api/data/table/Article", {"sort": [{"field": "body", "direction": "ASC"}]}), "not sortable")
        fail_r(n.call("POST", "/erupt-api/data/table/Article", {"condition": [{"key": "title", "expression": "DROP", "value": 1}]}), "illegal operator")
    # what a node checks whoever calls it: names it puts into a query, the shape of a body, its own keys (§12.6)
    fail_r(n.call("POST", "/erupt-api/data/table/Article", {"condition": [{"key": "title\" OR 1=1 --", "expression": "EQ", "value": 1}]}), "injected key")
    fail_r(n.call("POST", "/erupt-api/data/table/Article", {"sort": [{"field": "title\" --", "direction": "ASC"}]}), "injected sort")
    fail_r(n.call("POST", "/erupt-api/data/modify/Article", b"{not json"), "malformed body")
    fail_r(n.call("POST", "/erupt-api/data/modify/Article/delete", {"id": 1}), "delete needs a list")
    status, body = n.call("GET", "/erupt-api/data/Article/abc")
    if status == 200 and body.get("success") is not False:
        raise AssertionError(f"illegal id: {status} {body}")
    if V2:
        # an operator goes into a query like a field name: an unknown one fails, it never matches every row
        fail_r(n.call("POST", "/erupt-api/data/table/Article", {"condition": [{"key": "title", "expression": "DROP", "value": 1}]}), "unknown operator")
        page = table(n, size=100000)
        if page["pageSize"] >= 100000:
            raise AssertionError(f"page size: a v2 node still caps it, got {page['pageSize']}")


# ---------------------------------------------------------------- runner

def main():
    if "--" not in sys.argv:
        sys.exit(__doc__)
    command = sys.argv[sys.argv.index("--") + 1:]
    check_vectors()
    server = ThreadingHTTPServer(("127.0.0.1", free_port()), FakeServer)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {**os.environ, "ERUPT_ACCESS_TOKEN": ACCESS_TOKEN, "PORT": str(free_port()),
           "ERUPT_SERVER": f"http://127.0.0.1:{server.server_address[1]}"}
    node = subprocess.Popen(command, env=env)
    failed = 0
    try:
        deadline = time.time() + 60
        while not FakeServer.registrations:
            if node.poll() is not None or time.time() > deadline:
                sys.exit("the node did not register")
            time.sleep(0.2)
        info = FakeServer.registrations[0]
        global V2
        V2 = info.get("protocolVersion") == 2
        print(f"registered: {info['nodeName']} {info['version']} {info['nodeAddress']} erupts={info['erupts']} "
              f"protocol v{2 if V2 else 1}")
        eq(["Article", "Category", "Note"], sorted(info["erupts"]), "registered erupts (forms are not registered)")
        n = Node(info["nodeAddress"][0])
        for fn in CHECKS:
            try:
                fn(n)
                print(f"  ok    {fn.__name__}")
            except Exception as e:
                failed += 1
                print(f"  FAIL  {fn.__name__}: {e}")
                if os.environ.get("CONFORMANCE_TRACE"):
                    traceback.print_exc()
        node.send_signal(signal.SIGINT)
        try:
            node.wait(15)
        except subprocess.TimeoutExpired:
            node.kill()
        if FakeServer.deregistrations and FakeServer.deregistrations[-1].get("nodeName") == [NODE_NAME]:
            print("  ok    deregister")
        else:
            failed += 1
            print("  FAIL  deregister: no remove-instance-node after SIGINT")
    finally:
        if node.poll() is None:
            node.kill()
        server.shutdown()
    print(f"{len(CHECKS) + 1 - failed}/{len(CHECKS) + 1} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
