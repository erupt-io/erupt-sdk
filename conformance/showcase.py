"""Scenario checks for every language's showcase (SHOWCASE.md): one run per scenario a user can click through.

    python conformance/showcase.py -- <command that starts examples/showcase>

The command starts the SDK's `examples/showcase` against a fresh SQLite file; this script plays a protocol v2 erupt
server (as conformance/run.py does) and walks every capability of the showcase: builds, seeds, references and
collections, invoke (onchange, fetched options, auto-complete, buttons), views, drills, the link tree, every data
proxy hook, every row operation and the read-only audit log. Standard library only.
"""
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from http.server import ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import annotations  # noqa: E402
import run  # noqa: E402  (the fake server, the signed v2 client and the assertion helpers)
from run import eq, fail_r, ok_r  # noqa: E402

MODELS = ["Article", "AuditLog", "Author", "Category", "Component", "Playground", "Tag"]
SCENARIOS = []


def scenario(fn):
    SCENARIOS.append(fn)
    return fn


def build(n, name, account="admin"):
    status, b = n.call("GET", f"/erupt-api/build/{name}", erupt=name, account=account)
    eq(200, status, f"build {name}")
    annotations.check_declared(b, f"declared {name}")
    return annotations.complete(b)


def table(n, name="Article", condition=(), sort=(), size=50, account="admin", **extra):
    status, page = n.call("POST", f"/erupt-api/data/table/{name}",
                          {"pageIndex": 1, "pageSize": size, "condition": list(condition), "sort": list(sort), **extra},
                          erupt=name, account=account)
    eq(200, status, f"table {name} {condition} -> {page}")
    return page


def titles(page):
    return sorted(r["title"] for r in page["list"])


def by_title(n, title):
    return next(r for r in table(n)["list"] if r["title"] == title)


def invoke(n, kind, field, form=None, value=None, name="Article"):
    status, r = n.call("POST", f"/erupt-api/invoke/{name}/{kind}/{field}", {"form": form or {}, "value": value}, erupt=name)
    eq(200, status, f"invoke {kind} {field}")
    return ok_r((status, r), f"invoke {kind} {field}")["data"]


def operate(n, code, ids=None, param=None, account="admin"):
    return n.call("POST", f"/erupt-api/invoke/Article/operation/{code}", {"ids": ids, "param": param}, account=account)


def audits(n):
    return table(n, "AuditLog", sort=[{"field": "id", "direction": "ASC"}])["list"]


# ---------------------------------------------------------------- scenarios

@scenario
def builds_complete_and_valid(n):
    for name in MODELS:
        b = build(n, name, account="admin")
        for m in annotations.models(b):
            annotations.check("Erupt", m["eruptJson"], m["eruptName"], partial=False)
            for f in m["eruptFieldModels"]:
                annotations.check("EruptField", f["eruptFieldJson"], f"{m['eruptName']}.{f['fieldName']}", partial=False)


@scenario
def article_fields(n):
    f = {x["fieldName"]: x for x in build(n, "Article")["eruptModel"]["eruptFieldModels"]}
    edit = {k: v["eruptFieldJson"]["edit"] for k, v in f.items()}
    expected = {"title": "INPUT", "summary": "TEXTAREA", "author": "REFERENCE_TABLE", "category": "REFERENCE_TABLE",
                "sub_category": "REFERENCE_TABLE", "topic": "REFERENCE_TREE", "tag_ids": "CHECKBOX", "reviewers": "TRANSFER",
                "sections": "TAB_TREE", "status": "CHOICE", "level": "CHOICE", "labels": "TAGS", "city": "AUTO_COMPLETE",
                "cover": "ATTACHMENT", "views": "NUMBER", "price": "NUMBER", "rating": "RATE", "progress": "SLIDER",
                "featured": "BOOLEAN", "color": "COLOR", "icon": "ICON", "publish_date": "DATE", "review_at": "DATE",
                "content": "HTML_EDITOR", "notes": "MARKDOWN", "meta": "CODE_EDITOR", "preview": "BUTTON"}
    eq(expected, {k: edit[k]["type"] for k in expected}, "edit types")
    eq("DATE_TIME", edit["review_at"]["dateType"]["type"], "review_at is a date time")
    eq({"dependField": "category", "dependColumn": "parent"},
       {k: edit["sub_category"]["referenceTableType"].get(k) for k in ("dependField", "dependColumn")}, "dependent picker")
    eq(["invoke"], edit["level"]["choiceType"]["fetchHandler"], "level fetches its options")
    eq(["invoke"], edit["labels"]["tagsType"]["fetchHandler"], "labels fetch their options")
    eq("invoke", edit["title"]["onchange"], "title onchange")
    eq("IMAGE", edit["cover"]["attachmentType"]["type"], "cover is an image")
    eq(("Author", "Tag", "Category"), (f["reviewers"]["fieldReturnName"], f["tag_ids"]["fieldReturnName"],
                                       f["sections"]["fieldReturnName"]), "collection targets")
    eq([], f["preview"]["eruptFieldJson"]["views"], "a button has no column")
    eq("RANGE", edit["publish_date"]["search"]["operator"], "date range search")
    eq({"draft", "review", "published", "archived"}, {o["value"] for o in f["status"]["componentValue"]}, "status options")


@scenario
def model_extras(n):
    category = build(n, "Category")["eruptModel"]["eruptJson"]
    eq(("parent", "sort"), (category["tree"]["pid"], category["dragSort"]["field"]), "category tree and drag sort")
    eq(["Articles"], [d["code"] for d in category["drills"]], "category drill")
    article = build(n, "Article")["eruptModel"]["eruptJson"]
    eq("category", article["linkTree"]["field"], "link tree")
    eq(["Drafts", "Board", "Calendar", "Cards", "Timeline"], [v["code"] for v in article["vis"]], "views")
    eq(["TABLE", "BOARD", "CALENDAR", "CARD", "TIMELINE"], [v["type"] for v in article["vis"]], "view types")
    if any("filter" in v or "orderBy" in v for v in article["vis"]):
        raise AssertionError("a view's filter / orderBy run on the node and stay out of the build")
    power = build(n, "AuditLog")["power"]
    eq((False, False, False), (power["add"], power["edit"], power["delete"]), "audit log is read-only")
    eq(True, build(n, "Article")["power"]["importable"], "articles import")


@scenario
def operations_per_user(n):
    codes = [o["code"] for o in build(n, "Article")["eruptModel"]["eruptJson"]["rowOperation"]]
    eq(["publish", "feature", "archive", "stats"], [c.lower() for c in codes], "operations for admin")
    modes = {o["code"].lower(): o["mode"] for o in build(n, "Article")["eruptModel"]["eruptJson"]["rowOperation"]}
    eq({"publish": "MULTI", "feature": "SINGLE", "archive": "MULTI_ONLY", "stats": "BUTTON"}, modes, "operation modes")
    other = [o["code"].lower() for o in build(n, "Article", account="guest")["eruptModel"]["eruptJson"]["rowOperation"]]
    eq(["publish", "feature", "archive"], other, "stats is the admin's")


@scenario
def seeds(n):
    eq({"Category": 5, "Author": 3, "Tag": 3, "Article": 3, "Component": 2},
       {name: table(n, name)["total"] for name in ("Category", "Author", "Tag", "Article", "Component")}, "seeded rows")
    hello = by_title(n, "Hello Erupt")
    eq((1, 2, 2, [1, 2], [2], [1, 2]), (hello["author"], hello["category"], hello["topic"], sorted(hello["tag_ids"]),
                                         hello["reviewers"], sorted(hello["sections"])), "references and collections as keys")
    eq(("2026-10-01", "2026-10-02T10:00:00.000", 9.9, 4.5, True), (hello["publish_date"], hello["review_at"], hello["price"],
                                                                   hello["rating"], hello["featured"]), "typed values")
    a = next(r for r in table(n, "Component")["list"] if r["name"] == "Sample A")
    eq((["ADMIN", "USER"], {"env": "prod", "tier": "1"}), (a["roles"], a["attrs"]), "JSON-valued components")
    for virtual in ("intro", "basic", "spacer", "extra", "place"):
        if virtual in a:
            raise AssertionError(f"a virtual field is never stored: {virtual}")


@scenario
def searches(n):
    eq(["Go Tips"], titles(table(n, condition=[{"key": "author", "expression": "EQ", "value": 2}])), "by reference")
    eq(["Hello Erupt"], titles(table(n, condition=[{"key": "publish_date", "expression": "RANGE",
                                                    "value": ["2026-09-01", "2026-10-31"]}])), "date range")
    eq(["Hello Erupt"], titles(table(n, condition=[{"key": "title", "expression": "LIKE", "value": "erupt"}])), "like")
    eq(["Sample B"], sorted(r["name"] for r in table(n, "Component", condition=[{"key": "roles", "expression": "IN",
                                                                                  "value": ["GUEST"]}])["list"]), "JSON array search")
    top = [r["title"] for r in table(n, sort=[{"field": "views", "direction": "DESC"}])["list"]]
    eq("Hello Erupt", top[0], "sort")


@scenario
def invoke_code(n):
    eq({"summary": "About Rust"}, invoke(n, "onchange", "title", {"title": "Rust"})["formData"], "onchange fills the summary")
    eq({}, invoke(n, "onchange", "title", {"title": "Rust", "summary": "kept"}) or {}, "onchange keeps a summary")
    eq(["beginner", "advanced"], [o["value"] for o in invoke(n, "options", "level", {"views": 10})], "level options")
    eq(["beginner", "advanced", "expert"], [o["value"] for o in invoke(n, "options", "level", {"views": 1000})], "expert level")
    eq(["hot", "new", "classic"], invoke(n, "options", "labels"), "label options")
    eq(["Tokyo", "Lisbon"], invoke(n, "autocomplete", "city", value="o"), "auto-complete")
    eq('alert("Preview: Hi")', invoke(n, "button", "preview", {"title": "Hi"})["eval"].replace("'", '"'), "button")


@scenario
def views_and_tree(n):
    eq(["Weekend Trip"], titles(table(n, vis="Drafts")), "the Drafts view filters on the node")
    eq(["Go Tips"], titles(table(n, condition=[{"key": "category", "expression": "IN", "value": [3]}])), "link tree pick")
    eq(["Hello Erupt"], titles(table(n, condition=[{"key": "category", "expression": "EQ", "value": 2}],
                                     drill={"erupt": "Category", "code": "Articles"})), "category drill")
    # the author drill adds its linkCondition: published articles only
    eq([], titles(table(n, condition=[{"key": "author", "expression": "EQ", "value": 2}],
                        drill={"erupt": "Author", "code": "Articles"})), "author drill keeps published only")
    eq(["Hello Erupt"], titles(table(n, condition=[{"key": "author", "expression": "EQ", "value": 1}],
                                     drill={"erupt": "Author", "code": "Articles"})), "author drill")


@scenario
def data_proxy(n):
    status, b = n.call("GET", "/erupt-api/build/Article")
    eq({"status": "published"}, b["eruptModel"]["searchCondition"], "search_condition")
    status, init = n.call("GET", "/erupt-api/data/init-value/Article")
    eq(("draft", 0, 0), (init.get("status"), init.get("views"), init.get("progress")), "add_behavior")
    fail_r(n.call("POST", "/erupt-api/data/modify/Article", {"title": "forbidden"}), "validate refuses")
    before = len(audits(n))
    ok_r(n.call("POST", "/erupt-api/data/modify/Article", {"title": "Draft One", "status": "review"}, account="ann"), "add")
    row = by_title(n, "Draft One")
    if not row.get("review_at"):
        raise AssertionError("before_add stamps review_at on an article in review")
    log = audits(n)[before:]
    eq([("add", "Draft One", "ann")], [(a["action"], a["article"], a["account"]) for a in log], "after_add writes the audit log")
    ok_r(n.call("POST", "/erupt-api/data/modify/Article/update", {**row, "review_at": None, "title": "Draft Two", "status": "draft"}),
         "update")
    fail_r(n.call("POST", "/erupt-api/data/modify/Article/delete", [by_title(n, "Hello Erupt")["id"]]), "published is kept")
    ok_r(n.call("POST", "/erupt-api/data/modify/Article/delete", [row["id"]]), "delete")
    eq(["add", "update", "delete"], [a["action"] for a in audits(n)[before:]], "every write is audited")


@scenario
def row_operations(n):
    trip, tips = by_title(n, "Weekend Trip"), by_title(n, "Go Tips")
    ok_r(operate(n, "publish", [trip["id"]], {"publish_date": "2026-11-01"}), "publish")
    eq(("published", "2026-11-01"), (by_title(n, "Weekend Trip")["status"], by_title(n, "Weekend Trip")["publish_date"]), "published")
    ok_r(operate(n, "feature", [tips["id"]]), "feature")
    eq(True, by_title(n, "Go Tips")["featured"], "featured")
    fail_r(operate(n, "feature", [tips["id"], trip["id"]]), "feature takes one row")
    r = ok_r(operate(n, "stats"), "stats")
    eq(f"alert('{table(n)['total']} articles')", r["data"], "stats script")
    eq(403, operate(n, "stats", account="guest")[0], "stats is the admin's")
    ok_r(operate(n, "archive", [tips["id"]]), "archive")
    eq(["Hello Erupt", "Weekend Trip"], titles(table(n)), "archived articles leave the table (before_fetch)")


@scenario
def buttons_and_forms(n):
    b = build(n, "Playground")
    eq(False, b["power"]["export"], "export switched off")
    eq((20, 1), (b["eruptModel"]["eruptJson"]["layout"]["pageSize"], b["eruptModel"]["eruptJson"]["layout"]["tableLeftFixed"]), "layout")
    f = {x["fieldName"]: x["eruptFieldJson"] for x in b["eruptModel"]["eruptFieldModels"]}
    name = f["name"]["edit"]
    eq(("LIKE", True, ["@"], [".dev", ".io"], "a short name"), (name["search"]["operator"], name["search"]["lockOperator"],
       [a["value"] for a in name["inputType"]["prefix"]], [a["value"] for a in name["inputType"]["suffix"]],
       name["placeHolder"]), "input options")
    eq(("kind", ["invoke"]), (f["level"]["edit"]["choiceType"]["dependField"], f["level"]["edit"]["choiceType"]["fetchHandler"]),
       "cascading choice")
    eq(("kind", "value === 'advanced'", "SHOW", "HIDE"), tuple(f["note"]["edit"]["dynamic"][k] for k in
       ("dependField", "condition", "match", "noMatch")), "dynamic visibility")
    eq((False, True), (f["code"]["edit"]["readOnly"]["add"], f["code"]["edit"]["readOnly"]["edit"]), "read-only on edit")
    eq(("SUM", "AVG"), (f["amount"]["views"][0]["statistic"], f["score"]["views"][0]["statistic"]), "column statistics")
    eq(("MULTI_CHOICE", ["invoke"]), (f["skills"]["edit"]["type"], f["skills"]["edit"]["multiChoiceType"]["fetchHandler"]), "fetched multi choice")
    eq((3, ["pdf", "txt", "md"]), (f["files"]["edit"]["attachmentType"]["maxLimit"], f["files"]["edit"]["attachmentType"]["fileTypes"]), "files")
    eq(("primary", True, True), (f["fill"]["edit"]["buttonType"]["style"], f["reset"]["edit"]["buttonType"]["danger"],
       f["whoami"]["edit"]["buttonType"]["fullSpan"]), "button styles")
    ops = {o["code"].lower().replace("_", ""): o for o in b["eruptModel"]["eruptJson"]["rowOperation"]}
    eq(("SINGLE", "Give the row a new name", "RenameForm"), (ops["rename"]["mode"], ops["rename"]["tip"], ops["rename"]["eruptClass"]), "rename")
    eq(("item.amount > 0", "HIDE"), (ops["double"]["ifExpr"], ops["double"]["ifExprBehavior"]), "double hides itself")
    eq(True, ops["resetamounts"]["fold"], "reset is folded")
    eq("BUTTON", ops["nodeinfo"]["mode"], "node info needs no row")
    eq(3, table(n, "Playground")["total"], "seeded")
    eq(["low", "mid"], [o["value"] for o in invoke(n, "options", "level", {"kind": "simple"}, name="Playground")], "simple levels")
    eq(["high", "expert"], [o["value"] for o in invoke(n, "options", "level", {"kind": "advanced"}, name="Playground")], "advanced levels")
    eq(["java", "python", "go"], [o["value"] for o in invoke(n, "options", "skills", name="Playground")], "skills")
    eq({"name": "sample", "kind": "advanced", "amount": 42, "score": 4}, invoke(n, "button", "fill", name="Playground")["formData"], "fill")
    eq({"name": "", "amount": 0, "score": 0}, invoke(n, "button", "reset", name="Playground")["formData"], "clear")
    eq('alert("admin")', invoke(n, "button", "whoami", name="Playground")["eval"].replace("'", '"'), "who am I")
    rows = {r["name"]: r for r in table(n, "Playground")["list"]}
    path = "/erupt-api/invoke/Playground/operation/"
    def op(code, ids=None, param=None):
        return n.call("POST", path + code, {"ids": ids, "param": param}, erupt="Playground")
    codes = {c.lower().replace("_", ""): c for c in (o["code"] for o in b["eruptModel"]["eruptJson"]["rowOperation"])}
    ok_r(op(codes["rename"], [rows["alpha"]["id"]], {"name": "alpha2"}), "rename")
    ok_r(op(codes["double"], [rows["gamma"]["id"]]), "double")
    after = {r["name"]: r for r in table(n, "Playground")["list"]}
    eq((True, 50), ("alpha2" in after, after["gamma"]["amount"]), "rename and double")
    ok_r(op(codes["resetamounts"], [after["gamma"]["id"]]), "reset")
    eq(0, {r["name"]: r for r in table(n, "Playground")["list"]}["gamma"]["amount"], "reset amounts")
    r = ok_r(op(codes["nodeinfo"]), "node info")
    eq("alert(\"admin: 2 roles, config 16 chars\")", r["data"].replace("'", '"'), "node info calls the server back")


# ---------------------------------------------------------------- runner

def main():
    if "--" not in sys.argv:
        sys.exit(__doc__)
    command = sys.argv[sys.argv.index("--") + 1:]
    run.V2 = True
    server = ThreadingHTTPServer(("127.0.0.1", run.free_port()), run.FakeServer)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    db = Path(tempfile.mkdtemp()) / "showcase.db"
    env = {**os.environ, "ERUPT_ACCESS_TOKEN": run.ACCESS_TOKEN, "ERUPT_NODE_NAME": run.NODE_NAME, "PORT": str(run.free_port()),
           "ERUPT_SERVER": f"http://127.0.0.1:{server.server_address[1]}", "ERUPT_DB": str(db)}
    node = subprocess.Popen(command, env=env)
    failed = 0
    try:
        deadline = time.time() + 120
        while not run.FakeServer.registrations:
            if node.poll() is not None or time.time() > deadline:
                sys.exit("the showcase did not register")
            time.sleep(0.2)
        info = run.FakeServer.registrations[0]
        if info.get("protocolVersion") != 2:
            sys.exit("the showcase must speak protocol v2")
        print(f"registered: {info['nodeName']} {info['version']} erupts={sorted(info['erupts'])}")
        try:
            eq(MODELS, sorted(info["erupts"]), "registered models")
        except AssertionError as e:
            failed += 1
            print(f"  FAIL  models: {e}")
        n = run.Node(info["nodeAddress"][0])
        for fn in SCENARIOS:
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
    finally:
        if node.poll() is None:
            node.kill()
        server.shutdown()
    print(f"{len(SCENARIOS) - failed}/{len(SCENARIOS)} scenarios passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
