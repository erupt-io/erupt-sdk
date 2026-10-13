"""Protocol conformance suite: one set of HTTP checks every language's node SDK must pass.

    python conformance/run.py -- <command that starts the fixture node>

The command must start the fixture described in conformance/README.md, reading ERUPT_ACCESS_TOKEN,
ERUPT_SERVER and PORT from the environment. This script plays the erupt server: it accepts the
registration (probing /node-health like the real one), answers erupt-power per session token, then sends
the requests the real server would forward and checks the answers. Standard library only.
"""
import base64
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

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "python" / "src"))
from erupt import _schema  # noqa: E402  (the validator generated from the same schema/)

NODE_NAME = "conformance"
ACCESS_TOKEN = "conformance-access-token"
FULL = {"add": True, "edit": True, "delete": True, "viewDetails": True, "export": True, "importable": True}
# session token -> what /erupt-power answers; "t-down" makes the server fail
POWERS = {"t1": FULL, "t-noadd": {**FULL, "add": False}}


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
            if ok:
                FakeServer.registrations.append(info)
            return self.reply(200 if ok else 500)
        if self.path == "/erupt-cloud-api/remove-instance-node":
            FakeServer.deregistrations.append(urllib.parse.parse_qs(body.decode()))
            return self.reply(200)
        self.reply(404)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
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

    def call(self, method, path, body=None, erupt="Article", token="t1", account="admin", headers=None):
        raw = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        h = {"Access-Token": ACCESS_TOKEN, "token": token, "Content-Type": "application/json",
             "user": base64.b64encode(json.dumps({"uid": 1, "account": account, "name": account, "tenantId": None}).encode()).decode()}
        if erupt:
            h["erupt"] = erupt
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


def table(n, condition=(), sort=(), size=10, erupt="Article"):
    status, page = n.call("POST", f"/erupt-api/data/table/{erupt}",
                          {"pageIndex": 1, "pageSize": size, "condition": list(condition), "sort": list(sort)}, erupt=erupt)
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
    eq(403, n.call("GET", "/erupt-api/build/Article", headers={"Access-Token": "bad"})[0], "bad token")
    eq(403, n.call("GET", "/erupt-api/build/Article", headers={"Access-Token": None})[0], "no token")
    eq(404, n.call("GET", "/erupt-api/build/Missing", erupt="Missing")[0], "unknown erupt")
    eq(404, n.call("GET", "/erupt-api/build/Article", erupt="Note")[0], "header / path mismatch")
    eq(404, n.call("GET", "/erupt-api/build/Article", erupt=None)[0], "no erupt header")
    eq(404, n.call("GET", "/erupt-api/build/Article", headers={"eruptParent": f"{NODE_NAME}.Note"})[0], "foreign parent")
    eq(200, n.call("GET", "/erupt-api/build/Article", headers={"eruptParent": f"{NODE_NAME}.Article"})[0], "self parent")
    eq(404, n.call("GET", "/erupt-api/nothing/here")[0], "unknown path")


@check
def build(n):
    status, b = n.call("GET", "/erupt-api/build/Article")
    eq(200, status, "build")
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
    eq(False, b["power"]["export"], "unsupported export hidden")
    eq(True, b["power"]["add"], "add")
    status, b = n.call("GET", "/erupt-api/build/Article", account="root")
    eq(["publish", "feature", "rebuild"], [o["code"] for o in b["eruptModel"]["eruptJson"]["rowOperation"]], "operations visible to root")


@check
def build_matches_schema(n):
    for name in ("Article", "Note", "Category"):
        status, b = n.call("GET", f"/erupt-api/build/{name}", erupt=name, account="root")
        eq(200, status, f"build {name}")
        for m in [b["eruptModel"], *(b.get("operationErupts") or {}).values()]:
            _schema.check("Erupt", m["eruptJson"], m["eruptName"], partial=False)
            for op in m["eruptJson"]["rowOperation"]:
                _schema.check("RowOperation", op, f"{m['eruptName']}.{op['code']}", partial=False)
            for fm in m["eruptFieldModels"]:
                _schema.check("EruptField", fm["eruptFieldJson"], f"{m['eruptName']}.{fm['fieldName']}", partial=False)


@check
def power(n):
    eq(403, n.call("POST", "/erupt-api/data/modify/Article", {"title": "x"}, token="t-noadd")[0], "server denies add")
    eq(403, n.call("POST", "/erupt-api/data/modify/Article", {"title": "x"}, token="t-down")[0], "fails closed")
    status, b = n.call("GET", "/erupt-api/build/Note", erupt="Note")
    eq(False, b["power"]["delete"], "declared power")
    eq(403, n.call("POST", "/erupt-api/data/modify/Note/delete", [1], erupt="Note")[0], "declared delete off")
    if not FakeServer.power_calls:
        raise AssertionError("the node never asked the server for erupt-power")
    eq([NODE_NAME], FakeServer.power_calls[-1].get("nodeName"), "erupt-power nodeName")


@check
def crud(n):
    clear_articles(n)
    add(n, title="Hello erupt", status="published", views=10, featured=True, publish_date="2026-01-05",
        review_at="2026-01-05 10:30:00", body="...")
    add(n, title="Second", status="draft", views="3", featured=False, publish_date="2026-03-01")
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
    pk = first["id"]
    status, row = n.call("GET", f"/erupt-api/data/Article/{pk}")
    eq((200, "Hello erupt"), (status, row["title"]), "get")
    ok_r(n.call("POST", "/erupt-api/data/modify/Article/update", {**row, "title": "Renamed"}), "update")
    eq("Renamed", n.call("GET", f"/erupt-api/data/Article/{pk}")[1]["title"], "updated")
    ok_r(n.call("POST", "/erupt-api/data/modify/Article/delete", [pk]), "delete")
    eq(1, table(n)["total"], "deleted")
    status, init = n.call("GET", "/erupt-api/data/init-value/Article")
    eq(200, status, "init-value")


@check
def references(n):
    clear_articles(n)
    status, b = n.call("GET", "/erupt-api/build/Article/category")
    eq((200, "Category"), (status, b["eruptModel"]["eruptName"]), "build by field")
    eq(404, n.call("GET", "/erupt-api/build/Article/title")[0], "build by a non-reference field")
    status, page = n.call("POST", "/erupt-api/data/Article/reference-table/category?tabRef=false",
                          {"pageIndex": 1, "pageSize": 10, "condition": [{"key": "name", "expression": "LIKE", "value": "py"}]})
    eq((200, [{"id": 2, "name": "Python", "parent": 1}]), (status, page["list"]), "picker")
    eq(404, n.call("POST", "/erupt-api/data/Article/reference-table/topic", {})[0], "table picker on a tree field")
    add(n, title="Ref", category={"id": "2", "name": "Python"}, topic={"id": 1, "name": "Tech"})
    row = table(n)["list"][0]
    eq(({"id": "2", "name": "Python"}, "Python", "Tech"), (row["category"], row["category_name"], row["topic_name"]), "reference row")
    eq({"id": "2", "name": "Python"}, n.call("GET", f"/erupt-api/data/Article/{row['id']}")[1]["category"], "reference get")
    eq(1, table(n, [{"key": "category", "expression": "EQ", "value": {"id": 2, "name": "Python"}}])["total"], "search by reference")
    eq(0, table(n, [{"key": "category", "expression": "IN", "value": [{"id": 1}, {"id": 3}]}])["total"], "IN by reference")
    fail_r(n.call("POST", "/erupt-api/data/table/Article", {"condition": [{"key": "category", "expression": "LIKE", "value": "x"}]}), "LIKE on a reference")


@check
def reference_tree(n):
    status, tree = n.call("GET", "/erupt-api/data/Article/reference-tree/topic")
    eq(200, status, "tree")
    eq(["Tech", "Life"], [x["label"] for x in tree], "roots")
    child = tree[0]["children"][0]
    eq(("Python", "2", "1", 2), (child["label"], child["id"], child["pid"], child["level"]), "child")
    eq(404, n.call("GET", "/erupt-api/data/Article/reference-tree/category")[0], "tree on a table field")


@check
def operations(n):
    clear_articles(n)
    add(n, title="A")
    add(n, title="B")
    ids = [r["id"] for r in table(n)["list"]]
    path = "/erupt-api/data/Article/operator/"
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
    eq((200, {"note": None}), n.call("POST", path + "publish/form-value?ids=" + str(ids[0])), "form-value")
    eq(404, n.call("POST", path + "feature/form-value")[0], "form-value without a form")


@check
def illegal_input(n):
    fail_r(n.call("POST", "/erupt-api/data/modify/Article", {"status": "draft"}), "notNull")
    fail_r(n.call("POST", "/erupt-api/data/modify/Article", {"title": "x", "status": "deleted"}), "illegal choice")
    fail_r(n.call("POST", "/erupt-api/data/modify/Article", {"title": "x", "views": "many"}), "illegal number")
    fail_r(n.call("POST", "/erupt-api/data/modify/Article", {"title": "x", "publish_date": "someday"}), "illegal date")
    fail_r(n.call("POST", "/erupt-api/data/table/Article", {"condition": [{"key": "views", "expression": "EQ", "value": 1}]}), "not searchable")
    fail_r(n.call("POST", "/erupt-api/data/table/Article", {"condition": [{"key": "title\" OR 1=1 --", "value": 1}]}), "injected key")
    fail_r(n.call("POST", "/erupt-api/data/table/Article", {"sort": [{"field": "body", "direction": "ASC"}]}), "not sortable")
    fail_r(n.call("POST", "/erupt-api/data/table/Article", {"condition": [{"key": "title", "expression": "DROP", "value": 1}]}), "illegal operator")
    fail_r(n.call("POST", "/erupt-api/data/modify/Article", b"{not json"), "malformed body")
    fail_r(n.call("POST", "/erupt-api/data/modify/Article/delete", {"id": 1}), "delete needs a list")
    status, body = n.call("GET", "/erupt-api/data/Article/abc")
    if status == 200 and body.get("success") is not False:
        raise AssertionError(f"illegal id: {status} {body}")


# ---------------------------------------------------------------- runner

def main():
    if "--" not in sys.argv:
        sys.exit(__doc__)
    command = sys.argv[sys.argv.index("--") + 1:]
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
        print(f"registered: {info['nodeName']} {info['version']} {info['nodeAddress']} erupts={info['erupts']}")
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
