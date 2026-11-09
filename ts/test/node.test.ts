import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, test } from "node:test";
import { type EruptRecord, Fail, field, MemoryRepository, model, Node, operation, type Repository, signRequest } from "../src/index.js";

const listen = (server: Server) => new Promise<string>((resolve) =>
  server.listen(0, "127.0.0.1", () => resolve(`http://127.0.0.1:${(server.address() as AddressInfo).port}`)));

const servers: Server[] = [];
after(() => servers.forEach((s) => s.close()));

/** What a v2 node requires in Erupt-Enforced for an endpoint (PROTOCOL.md §12.2). */
function required(method: string, path: string): string {
  if (method === "GET" && path.startsWith("/erupt-api/build/")) return "";
  if (path.startsWith("/erupt-api/data/table/")) return "power,query";
  if (path.startsWith("/erupt-api/data/modify/") && !path.endsWith("/delete")) return "power,record";
  return "power";
}

interface CallOptions {
  erupt?: string;
  /** Erupt-Enforced; the endpoint's own by default */
  enforced?: string;
  /** false sends the call unsigned, with the plain access token */
  signed?: boolean;
  secret?: string;
  account?: string;
}

/** Serve `node` and return a client that signs every call as the erupt server does. */
async function serve(node: Node, erupt: string) {
  const app = createServer(node.listener);
  servers.push(app);
  const base = await listen(app);
  return async (path: string, body?: unknown, o: CallOptions = {}) => {
    const method = body === undefined ? "GET" : "POST";
    const raw = Buffer.from(body === undefined ? "" : JSON.stringify(body));
    const user = Buffer.from(JSON.stringify({ account: o.account ?? "admin" })).toString("base64");
    const headers: Record<string, string> = { erupt: o.erupt ?? erupt, token: "t", user, "content-type": "application/json" };
    if (o.signed === false) {
      headers["access-token"] = "secret";
    } else {
      const ts = Math.floor(Date.now() / 1000);
      const enforced = o.enforced ?? required(method, path);
      Object.assign(headers, {
        "erupt-timestamp": String(ts), "erupt-enforced": enforced,
        "erupt-signature": signRequest(o.secret ?? "secret", method, path, ts, enforced, user, raw),
      });
    }
    const res = await fetch(base + path, { method, body: body === undefined ? undefined : raw, headers });
    return [res.status, (await res.json().catch(() => null)) as any] as const;
  };
}

test("every call is signed with the Erupt-Enforced its endpoint needs", async () => {
  const node = new Node("t", "secret", "http://127.0.0.1:1");
  node.register(model("Item", { id: field.pk(), name: field.input("Name", { notNull: true }) }), new MemoryRepository());
  const call = await serve(node, "Item");
  assert.deepEqual(await call("/erupt-api/data/modify/Item", { name: "a" }), [200, { success: true, status: "SUCCESS", message: null, data: null, promptWay: "MESSAGE" }]);
  const [, page] = await call("/erupt-api/data/table/Item", { pageIndex: 1, pageSize: 10 });
  assert.deepEqual(page.list, [{ id: 1, name: "a" }]);
  assert.equal((await call("/erupt-api/build/Item"))[0], 200);
  // unsigned: the plain access token no longer passes
  assert.equal((await call("/erupt-api/build/Item", undefined, { signed: false }))[0], 403);
  assert.equal((await call("/erupt-api/build/Item", undefined, { secret: "secreT" }))[0], 403);
  // an Erupt-Enforced short of what the endpoint needs
  assert.equal((await call("/erupt-api/data/table/Item", {}, { enforced: "power" }))[0], 403);
  assert.equal((await call("/erupt-api/data/modify/Item", { name: "b" }, { enforced: "power,query" }))[0], 403);
  assert.equal((await call("/erupt-api/data/modify/Item/update", { id: 1, name: "b" }, { enforced: "power" }))[0], 403);
  assert.equal((await call("/erupt-api/data/modify/Item/delete", [1], { enforced: "" }))[0], 403);
  assert.equal((await call("/erupt-api/data/Item/1", undefined, { enforced: "" }))[0], 403);
  assert.equal((await call("/erupt-api/data/init-value/Item", undefined, { enforced: "" }))[0], 403);
  assert.equal((await call("/erupt-api/invoke/Item/operation/x", {}, { enforced: "" }))[0], 403);
  assert.equal((await call("/erupt-api/data/table/Item", {}))[1].total, 1, "nothing written by a refused call");
  // what the node still checks itself
  assert.equal((await call("/erupt-api/build/Missing", undefined, { erupt: "Missing" }))[0], 404);
  assert.equal((await call("/erupt-api/build/Item", undefined, { erupt: "Other" }))[0], 404);
  assert.equal((await call("/erupt-api/nothing/here"))[0], 404);
});

test("the build declares only what the model sets", async () => {
  const node = new Node("t", "secret", "http://127.0.0.1:1");
  const category = model("Category", { id: field.pk(), name: field.input("Name"), parent: field.number("Parent") });
  node.register(category, new MemoryRepository());
  const Form = model("ShipForm", { note: field.input("Note", { notNull: true }) });
  node.register(model("Order", {
    id: field.pk(),
    title: field.input("Title", { search: true, notNull: true, sortable: true }),
    at: field.dateTime("At", { table: false }),
    day: field.date("Day", { form: false }),
    done: field.boolean("Done"),
    cat: field.ref(category, "Category", { search: true }),
    topic: field.ref(category, "Topic", { tree: "parent", view: { type: "TEXT" } }),
  }, {
    power: { delete: false },
    erupt: { layout: { pageSize: 30 }, drills: [{ title: "Same", link: { linkErupt: "Order", joinColumn: "cat", linkCondition: "1 = 1" } }] },
    operations: {
      ship: operation("Ship", { form: Form, icon: "fa fa-ship", confirm: false }, () => undefined),
      peek: operation("Peek", { mode: "SINGLE", confirm: "Sure?" }, () => undefined),
    },
  }), new MemoryRepository());
  const call = await serve(node, "Order");
  const [, build] = await call("/erupt-api/build/Order");
  assert.deepEqual(build.power, { delete: false, print: false, ai: false });
  const m = build.eruptModel;
  assert.deepEqual(m.eruptJson, {
    primaryKeyCol: "id",
    rowOperation: [
      { code: "ship", title: "Ship", mode: "MULTI", tip: "", ifExpr: "", eruptClass: "ShipForm", icon: "fa fa-ship", callHint: "" },
      { code: "peek", title: "Peek", mode: "SINGLE", tip: "", ifExpr: "", eruptClass: "void", callHint: "Sure?" },
    ],
    layout: { pageSize: 30 },
    // the whole link goes to the server, which turns the drill into a condition
    drills: [{ code: "Same", title: "Same", link: { linkErupt: "Order", joinColumn: "cat", linkCondition: "1 = 1" } }],
  });
  assert.deepEqual(m.eruptFieldModels, [
    { fieldName: "id", fieldReturnName: "number", componentValue: null, eruptFieldJson: { edit: { title: "", type: "NUMBER" } } },
    { fieldName: "title", fieldReturnName: "String", componentValue: null, eruptFieldJson: {
      edit: { title: "Title", type: "INPUT", notNull: true, search: { value: true } }, views: [{ title: "Title", sortable: true }] } },
    { fieldName: "at", fieldReturnName: "Date", componentValue: null, eruptFieldJson: {
      edit: { title: "At", type: "DATE", dateType: { type: "DATE_TIME" } }, views: [] } },
    { fieldName: "day", fieldReturnName: "Date", componentValue: null, eruptFieldJson: {
      edit: { title: "Day", type: "DATE", dateType: { type: "DATE" }, show: false }, views: [{ title: "Day" }] } },
    { fieldName: "done", fieldReturnName: "Boolean", componentValue: null, eruptFieldJson: {
      edit: { title: "Done", type: "BOOLEAN" }, views: [{ title: "Done" }] } },
    { fieldName: "cat", fieldReturnName: "Category", componentValue: null, eruptFieldJson: {
      edit: { title: "Category", type: "REFERENCE_TABLE", search: { value: true }, referenceTableType: { id: "id", label: "name" } },
      views: [{ title: "Category", column: "name" }] } },
    { fieldName: "topic", fieldReturnName: "Category", componentValue: null, eruptFieldJson: {
      edit: { title: "Topic", type: "REFERENCE_TREE", referenceTreeType: { id: "id", label: "name", pid: "parent" } },
      views: [{ title: "Topic", column: "name", type: "TEXT" }] } },
  ]);
  assert.deepEqual(build.operationErupts.ship.eruptJson, { primaryKeyCol: "id", rowOperation: [] });
});

test("virtual and JSON fields", async () => {
  const { mkdtempSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { SqliteRepository } = await import("../src/index.js");
  const db = join(mkdtempSync(join(tmpdir(), "erupt-ts-")), "w.db");
  for (const repo of [new MemoryRepository(), new SqliteRepository(db, "widget")]) {
    const node = new Node("t", "secret", "http://127.0.0.1:1");
    node.register(model("Widget", {
      id: field.pk(),
      name: field.input("Name"),
      basic: field.input("Basic", { virtual: true, edit: { type: "DIVIDE" } }),
      roles: field.json("Roles", { search: true, edit: { type: "MULTI_CHOICE" } }, { ADMIN: "Admin", USER: "User", GUEST: "Guest" }),
      attrs: field.json("Attributes", { edit: { type: "KEY_VALUE" } }),
    }), repo);
    const call = await serve(node, "Widget");
    const [, build] = await call("/erupt-api/build/Widget");
    const fields = build.eruptModel.eruptFieldModels;
    assert.deepEqual(fields.map((f: any) => [f.fieldName, f.eruptFieldJson.edit.type]),
      [["id", "NUMBER"], ["name", "INPUT"], ["basic", "DIVIDE"], ["roles", "MULTI_CHOICE"], ["attrs", "KEY_VALUE"]]);
    assert.deepEqual(fields[3].componentValue.map((o: any) => o.label), ["Admin", "User", "Guest"]);
    assert.equal((await call("/erupt-api/data/modify/Widget", { name: "A", roles: ["ADMIN", "USER"], attrs: { env: "prod" }, basic: "x" }))[1].success, true);
    assert.equal((await call("/erupt-api/data/modify/Widget", { name: "B", roles: ["GUEST"], attrs: {} }))[1].success, true);
    const [, page] = await call("/erupt-api/data/table/Widget", { pageIndex: 1, pageSize: 10 });
    assert.deepEqual(page.list[0], { id: 1, name: "A", roles: ["ADMIN", "USER"], attrs: { env: "prod" } });
    const [, found] = await call("/erupt-api/data/table/Widget", { condition: [{ key: "roles", expression: "IN", value: ["GUEST"] }] });
    assert.deepEqual(found.list.map((r: any) => r.name), ["B"]);
    const [, other] = await call("/erupt-api/data/table/Widget", { condition: [{ key: "roles", expression: "NOT_IN", value: ["GUEST"] }] });
    assert.deepEqual(other.list.map((r: any) => r.name), ["A"]);
    assert.deepEqual((await call("/erupt-api/data/Widget/1"))[1].attrs, { env: "prod" });
  }
});

test("data proxy", async () => {
  const node = new Node("t", "secret", "http://127.0.0.1:1");
  // the write hooks only record that they ran, with the text they saw
  const calls: [string, unknown][] = [];
  const write = (name: string) => (record: EruptRecord) => void calls.push([name, record.text]);
  node.register(model("Memo", { id: field.pk(), text: field.input("Text") }, {
    dataProxy: {
      searchCondition: (condition) => void (condition.text = "hi"),
      afterFetch: (rows) => rows.forEach((row) => (row.text = String(row.text).toUpperCase())),
      addBehavior: (record) => void (record.text = "new"),
      editBehavior: (record) => void (record.text += "?"),
      validate: (record) => {
        if (record.text === "forbidden") throw new Fail("forbidden text");
      },
      beforeAdd: write("beforeAdd"), afterAdd: write("afterAdd"),
      beforeUpdate: write("beforeUpdate"), afterUpdate: write("afterUpdate"),
      beforeDelete: write("beforeDelete"), afterDelete: write("afterDelete"),
    },
  }), new MemoryRepository());
  const call = await serve(node, "Memo");
  const body = async (path: string, b?: unknown) => (await call(path, b))[1];
  assert.deepEqual((await body("/erupt-api/build/Memo")).eruptModel.searchCondition, { text: "hi" });
  assert.equal((await body("/erupt-api/data/init-value/Memo")).text, "new");
  const refused = await body("/erupt-api/data/modify/Memo", { text: "forbidden" });
  assert.deepEqual([refused.success, refused.message], [false, "forbidden text"]);
  assert.equal((await body("/erupt-api/data/modify/Memo", { text: "a" })).success, true);
  const page = await body("/erupt-api/data/table/Memo", {});
  assert.deepEqual(page.list.map((row: any) => row.text), ["A"]);
  const pk = page.list[0].id;
  assert.equal((await body(`/erupt-api/data/Memo/${pk}`)).text, "a?");
  assert.equal((await body("/erupt-api/data/modify/Memo/update", { id: pk, text: "b" })).success, true);
  assert.equal((await body("/erupt-api/data/modify/Memo/delete", [pk])).success, true);
  assert.deepEqual(calls, [["beforeAdd", "a"], ["afterAdd", "a"], ["beforeUpdate", "b"], ["afterUpdate", "b"],
    ["beforeDelete", "b"], ["afterDelete", "b"]]);
});

test("link tree conditions arrive as plain conditions", async () => {
  const node = new Node("t", "secret", "http://127.0.0.1:1");
  const category = model("Category", { id: field.pk(), name: field.input("Name"), parent: field.number("Parent") });
  node.register(model("Doc", { id: field.pk(), title: field.input("Title"), topic: field.ref(category, "Topic", { tree: "parent" }) }, {
    erupt: { linkTree: { field: "topic", dependNode: true } },
  }), new MemoryRepository([{ title: "a", topic: 1 }, { title: "b", topic: 2 }, { title: "c", topic: 3 }]));
  const call = await serve(node, "Doc");
  const titles = async (body: unknown) => (await call("/erupt-api/data/table/Doc", body))[1].list.map((r: any) => r.title);
  // the server sends IN on the tree field, and NULL on the primary key while dependNode has nothing picked
  assert.deepEqual(await titles({ condition: [{ key: "id", expression: "NULL" }] }), []);
  assert.deepEqual(await titles({ condition: [{ key: "topic", expression: "IN", value: [2] }] }), ["b"]);
  assert.deepEqual(await titles({ condition: [{ key: "topic", expression: "IN", value: [1, 2] }] }), ["a", "b"]);
  // the node no longer reads linkTreeVal
  assert.deepEqual(await titles({ linkTreeVal: [2] }), ["a", "b", "c"]);
});

test("queries: stored field names, sort, page size", async () => {
  const node = new Node("t", "secret", "http://127.0.0.1:1");
  const category = model("Category", { id: field.pk(), name: field.input("Name") });
  node.register(category, new MemoryRepository([{ name: "x" }, { name: "y" }]));
  node.register(model("Post", {
    id: field.pk(), title: field.input("Title"), views: field.number("Views"), at: field.dateTime("At"), cat: field.ref(category, "Category"),
  }), new MemoryRepository(Array.from({ length: 1205 }, (_, i) => ({ title: `p${i}`, views: i, at: `2026-01-0${1 + (i % 3)}T10:00:00.000`, cat: 1 + (i % 2) }))));
  const call = await serve(node, "Post");
  const page = async (body: unknown) => (await call("/erupt-api/data/table/Post", body))[1];
  assert.equal((await page({ pageSize: 100000 })).pageSize, 1000, "page size capped");
  assert.equal((await page({ pageSize: 100000 })).list.length, 1000);
  // any stored field, searchable or not; values arrive as their stored JSON type
  assert.equal((await page({ condition: [{ key: "views", expression: "LT", value: 5 }] })).total, 5);
  assert.equal((await page({ condition: [{ key: "at", expression: "RANGE", value: ["2026-01-02 00:00:00", "2026-01-02 23:59:59"] }] })).total, 402);
  assert.equal((await page({ condition: [{ key: "cat", expression: "EQ", value: 2 }] })).total, 602);
  assert.equal((await page({ condition: [{ key: "title", expression: "LIKE", value: "p120" }] })).total, 6);
  // sort by any stored field; "field.column" orders by the reference's key
  assert.equal((await page({ sort: [{ field: "views", direction: "DESC" }], pageSize: 1 })).list[0].title, "p1204");
  assert.equal((await page({ sort: [{ field: "cat.name", direction: "DESC" }], pageSize: 1 })).list[0].cat, 2);
  for (const body of [
    { condition: [{ key: "title\" OR 1=1 --", expression: "EQ", value: 1 }] },
    { condition: [{ key: "constructor", expression: "EQ", value: 1 }] },
    { sort: [{ field: "title\" --", direction: "ASC" }] },
    // an unknown or missing operator fails, never matches everything
    { condition: [{ key: "title", expression: "DROP", value: 1 }] },
    { condition: [{ key: "title", value: "p1" }] },
  ]) assert.equal((await page(body)).success, false, JSON.stringify(body));
  assert.equal((await page({ condition: [{ key: "title", expression: "DROP", value: 1 }] })).message, "illegal operator 'DROP'");
});

test("field types and invoke", async () => {
  const node = new Node("t", "secret", "http://127.0.0.1:1");
  const category = model("Category", { id: field.pk(), name: field.input("Name"), parent: field.number("Parent") });
  node.register(category, new MemoryRepository());
  node.register(model("Order", {
    id: field.pk(),
    status: field.choice("Status", {}, { fetch: (form) => ({ new: "New", [form.note ?? "x"]: "From form" }) }),
    tags: field.of("TAGS", "Tags", { fetch: () => ["red", "blue"] }),
    qty: field.number("Qty", { onchange: (form) => ({ formData: { note: `${form.qty} items` } }) }),
    note: field.input("Note"),
    city: field.of("AUTO_COMPLETE", "City", { complete: async (_form, typed) => ["Paris", "Tokyo"].filter((c) => c.toLowerCase().includes(typed.toLowerCase())) }),
    body: field.of("MARKDOWN", "Body"),
    files: field.of("ATTACHMENT", "Files"),
    cats: field.checkbox(category, "Categories"),
    sections: field.tabTree(category, "Sections"),
    calc: field.button("Calc", () => ({ eval: "alert(1)", formData: { qty: 2 } })),
    stop: field.button("Stop", () => {
      throw new Fail("not now");
    }),
  }, {
    operations: {
      approve: operation("Approve", { form: model("ApproveForm", { reason: field.input("Reason") }) }, (op) => `approved:${op.param?.reason}`),
      single: operation("Single", { mode: "SINGLE" }, (op) => `rows:${op.rows.length}`),
      archive: operation("Archive", { mode: "BUTTON" }, () => undefined),
      hidden: operation("Hidden", { mode: "BUTTON", show: () => false }, () => undefined),
    },
  }), new MemoryRepository());
  const call = await serve(node, "Order");
  const [, build] = await call("/erupt-api/build/Order");
  const fields = Object.fromEntries(build.eruptModel.eruptFieldModels.map((f: any) => [f.fieldName, f]));
  const edit = (name: string) => fields[name].eruptFieldJson.edit;
  assert.deepEqual(edit("status").choiceType, { fetchHandler: ["invoke"] });
  assert.deepEqual(edit("tags").tagsType, { fetchHandler: ["invoke"] });
  assert.equal(edit("qty").onchange, "invoke");
  assert.deepEqual([edit("body").type, edit("files").type, edit("calc").type], ["MARKDOWN", "ATTACHMENT", "BUTTON"]);
  assert.deepEqual(fields.calc.eruptFieldJson.views, [], "a BUTTON has no table column");
  assert.deepEqual([fields.cats.fieldReturnName, fields.sections.fieldReturnName], ["Category", "Category"]);

  const invoke = async (kind: string, field: string, form: object = {}, value?: string) =>
    call(`/erupt-api/invoke/Order/${kind}/${field}`, { form, value });
  assert.deepEqual((await invoke("options", "status", { note: "n" }))[1].data, [{ value: "new", label: "New" }, { value: "n", label: "From form" }]);
  assert.deepEqual((await invoke("options", "tags"))[1].data, ["red", "blue"]);
  assert.deepEqual((await invoke("onchange", "qty", { qty: 3 }))[1].data, { formData: { note: "3 items" } });
  assert.deepEqual((await invoke("autocomplete", "city", {}, "pa"))[1].data, ["Paris"]);
  assert.equal((await invoke("button", "calc"))[1].data.eval, "alert(1)");
  const [, refused] = await invoke("button", "stop");
  assert.deepEqual([refused.success, refused.message], [false, "not now"]);
  assert.equal((await invoke("button", "qty"))[0], 404, "a field without that code");
  assert.equal((await invoke("options", "missing"))[0], 404);

  // picked records arrive as their keys (§12.4)
  assert.equal((await call("/erupt-api/data/modify/Order", { cats: [1, 2], sections: [3], tags: "[\"red\"]" }))[1].success, true);
  assert.equal((await call("/erupt-api/data/modify/Order", { note: "second" }))[1].success, true);
  const [, page] = await call("/erupt-api/data/table/Order", {});
  assert.deepEqual([page.list[0].cats, page.list[0].sections], [[1, 2], [3]]);
  assert.ok(!("calc" in page.list[0]));

  // a row operation and its form values run through invoke too, under the operation code
  const op = "/erupt-api/invoke/Order/operation/";
  assert.deepEqual((await call(op + "archive", { ids: null, param: null }))[1].message, "Executed successfully");
  assert.equal((await call(op + "approve", { ids: [1], param: { reason: "ok" } }))[1].data, "approved:ok");
  assert.equal((await call(op + "approve", { ids: [] }))[1].success, false, "MULTI needs a row");
  assert.equal((await call(op + "single", { ids: [1, 2] }))[1].success, false, "SINGLE needs exactly one row");
  assert.equal((await call(op + "single", { ids: ["1"] }))[1].data, "rows:1", "ids as the browser sent them");
  assert.equal((await call(op + "single", { ids: ["x"] }))[1].success, false, "an illegal id");
  assert.equal((await call(op + "hidden", {}))[0], 403);
  assert.equal((await call(op + "missing", {}))[0], 404);
  const form = "/erupt-api/invoke/Order/operation-form/";
  assert.deepEqual((await call(form + "approve", {}))[1].data, { reason: null });
  assert.equal((await call(form + "archive", {}))[1].data, null, "an operation without a form");
  assert.equal((await call("/erupt-api/data/Order/operator/archive", {}))[0], 404);
  assert.equal((await call("/erupt-api/data/Order/reference-table/cats", {}))[0], 404);
});

test("before fetch", async () => {
  const { mkdtempSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { currentUser, SqliteRepository } = await import("../src/index.js");
  const task = () => model("Task", {
    id: field.pk(), title: field.input("Title", { search: true }), owner: field.input("Owner"), done: field.boolean("Done"),
  }, {
    dataProxy: [{ beforeFetch: () => ["owner = ?", [currentUser()!.account]] }, { beforeFetch: () => "done = 0" }],
    erupt: { vis: [
      { code: "q", title: "Question", type: "TABLE", filter: "title = 'a?'" },
      { title: "Reversed", type: "TABLE", filter: ["1 = 1", "2 = 2"], orderBy: "title desc" },
    ] },
  });
  const start = async (repo: Repository) => {
    const node = new Node("t", "secret", "http://127.0.0.1:1");
    node.register(task(), repo);
    return serve(node, "Task");
  };
  const call = await start(new SqliteRepository(join(mkdtempSync(join(tmpdir(), "erupt-ts-")), "t.db"), "task"));
  for (const [title, owner, done] of [["a", "admin", false], ["b", "admin", true], ["c", "root", false], ["a?", "admin", false]]) {
    await call("/erupt-api/data/modify/Task", { title, owner, done });
  }
  const [, page] = await call("/erupt-api/data/table/Task", {});
  assert.deepEqual([page.total, page.list.map((r: any) => r.title)], [2, ["a", "a?"]]);
  const [, found] = await call("/erupt-api/data/table/Task", { condition: [{ key: "title", expression: "EQ", value: "a" }] }, { account: "root" });
  assert.deepEqual(found.list, []);
  // a view's own filter and order run on the node, and stay out of the build
  assert.deepEqual((await call("/erupt-api/data/table/Task", { vis: "q" }))[1].list.map((r: any) => r.title), ["a?"]);
  assert.deepEqual((await call("/erupt-api/data/table/Task", { vis: "Reversed" }))[1].list.map((r: any) => r.title), ["a?", "a"]);
  const vis = task().buildErupt().eruptJson.vis;
  assert.deepEqual(vis.map((v: any) => [v.code, v.title, v.type]), [["q", "Question", "TABLE"], ["Reversed", "Reversed", "TABLE"]]);
  assert.ok(!vis.some((v: any) => "filter" in v || "orderBy" in v));
  // the memory repository cannot run SQL: it refuses rather than shows every row
  assert.equal((await (await start(new MemoryRepository()))("/erupt-api/data/table/Task", {}))[0], 500);
});

const serveAuthorBook = async (bookRepo?: Repository) => {
  const node = new Node("blog", "secret", "http://127.0.0.1:1");
  const category = model("Category", { id: field.pk(), name: field.input("Name"), parent: field.number("Parent") });
  const author = model("Author", { id: field.pk(), name: field.input("Name") }, {
    erupt: { drills: [
      { title: "Books", link: { linkErupt: "Book", joinColumn: "author.id" } },
      { code: "early", title: "Early books", link: { linkErupt: "Book", joinColumn: "author", linkCondition: "title < 'b'" } },
    ] },
  });
  node.register(category, new MemoryRepository());
  node.register(author, new MemoryRepository([{ name: "Ann" }, { name: "Bob" }]));
  node.register(model("Book", {
    id: field.pk(),
    title: field.input("Title"),
    author: field.ref(author, "Author"),
    colour: field.of("COLOR", "Colour"),
    stars: field.of("RATE", "Stars"),
    secret: field.of("HIDDEN", "Secret"),
    readers: field.transfer(category, "Readers"),
    shelf: field.ref(category, "Shelf", { edit: { referenceTableType: { dependField: "author", dependColumn: "parent" } } }),
  }), bookRepo ?? new MemoryRepository([{ title: "a", author: 1 }, { title: "b", author: 2 }, { title: "c", author: 1 }]));
  return [node, await serve(node, "Book")] as const;
};

test("drill via the body", async () => {
  const [, call] = await serveAuthorBook();
  // the server sends the join as a condition and names the drill
  const join = [{ key: "author", expression: "EQ", value: 1 }];
  const [, page] = await call("/erupt-api/data/table/Book", { condition: join, drill: { erupt: "Author", code: "Books" } });
  assert.deepEqual(page.list.map((r: any) => r.title), ["a", "c"]);
  assert.equal((await call("/erupt-api/data/table/Book", { condition: join, drill: { erupt: "Author", code: "x" } }))[0], 403);
  assert.equal((await call("/erupt-api/data/table/Book", { condition: join, drill: { erupt: "Nobody", code: "Books" } }))[0], 403);
  assert.equal((await call("/erupt-api/data/table/Book", { condition: join, drill: "Books" }))[0], 403);
  // the old headers mean nothing now
  const [, all] = await call("/erupt-api/data/table/Book", {});
  assert.equal(all.total, 3);
  const [, build] = await call("/erupt-api/build/Author", undefined, { erupt: "Author" });
  const drills = build.eruptModel.eruptJson.drills;
  assert.deepEqual(drills.map((d: any) => [d.code, d.title, d.link]), [
    ["Books", "Books", { linkErupt: "Book", joinColumn: "author.id" }],
    ["early", "Early books", { linkErupt: "Book", joinColumn: "author", linkCondition: "title < 'b'" }],
  ]);
});

test("a drill's linkCondition is added by the node", async () => {
  const { mkdtempSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { SqliteRepository } = await import("../src/index.js");
  const [, call] = await serveAuthorBook(new SqliteRepository(join(mkdtempSync(join(tmpdir(), "erupt-ts-")), "b.db"), "book"));
  for (const [title, author] of [["a", 1], ["b", 2], ["c", 1]]) await call("/erupt-api/data/modify/Book", { title, author });
  const condition = [{ key: "author", expression: "EQ", value: 1 }];
  const [, page] = await call("/erupt-api/data/table/Book", { condition, drill: { erupt: "Author", code: "early" } });
  assert.deepEqual(page.list.map((r: any) => r.title), ["a"]);
});

test("simple types and dependColumn", async () => {
  const [, call] = await serveAuthorBook();
  const [, build] = await call("/erupt-api/build/Book");
  const edit = Object.fromEntries(build.eruptModel.eruptFieldModels.map((f: any) => [f.fieldName, f.eruptFieldJson.edit]));
  assert.deepEqual(["colour", "stars", "secret", "readers"].map((n) => edit[n].type), ["COLOR", "RATE", "HIDDEN", "TRANSFER"]);
  assert.deepEqual(edit.shelf.referenceTableType, { id: "id", label: "name", dependField: "author", dependColumn: "parent" },
    "the server reads dependColumn off the build");
  assert.equal((await call("/erupt-api/data/modify/Book", { title: "d", stars: 4, readers: [2] }))[1].success, true);
  const [, page] = await call("/erupt-api/data/table/Book", {});
  const row = page.list.at(-1);
  assert.deepEqual([row.stars, row.readers], [4, [2]]);
});

test("node config and user info", async () => {
  const [node] = await serveAuthorBook();
  const seen: [string, string | undefined][] = [];
  (node as any).serverText = async (path: string, headers: Record<string, string>) => {
    seen.push([path, headers.token]);
    return path.includes("userinfo") ? '{"account": "admin", "roles": ["r"]}' : "cfg";
  };
  assert.equal(await node.config(), "cfg");
  assert.equal(await node.groupConfig(), "cfg");
  assert.deepEqual(await node.userInfo(), { account: "admin", roles: ["r"] });
  assert.deepEqual(seen.map(([p]) => p), ["/erupt-cloud-api/node-config/blog", "/erupt-cloud-api/node-group-config/blog",
    "/erupt-cloud-api/userinfo/blog"]);
});

/** A fake erupt server answering register-node with `answer`; returns the registrations it received. */
async function registerWith(answer: string): Promise<Record<string, any>[]> {
  const registrations: Record<string, any>[] = [];
  const erupt = createServer(async (req, res) => {
    let body = "";
    for await (const chunk of req) body += chunk;
    if (req.url === "/erupt-cloud-api/register-node") registrations.push(JSON.parse(body));
    res.end(answer);
  });
  servers.push(erupt);
  const node = new Node("t", "secret", await listen(erupt), { address: "http://127.0.0.1:1", heartbeat: 0.05 });
  const errors: string[] = [];
  const error = console.error;
  console.error = (...args: unknown[]) => void errors.push(args.join(" "));
  try {
    node.startHeartbeat();
    await new Promise((resolve) => setTimeout(resolve, 300));
  } finally {
    await node.deregister();
    console.error = error;
  }
  if (answer === JSON.stringify({ protocolVersion: 2 })) assert.deepEqual(errors.filter((e) => e.includes("protocol")), []);
  else assert.ok(errors.some((e) => e.includes("does not speak node protocol v2: upgrade the erupt server; registration stopped")), errors.join("\n"));
  return registrations;
}

test("registration negotiates protocol v2", async () => {
  const v2 = await registerWith(JSON.stringify({ protocolVersion: 2 }));
  assert.ok(v2.length > 1, "a v2 server: the heartbeat goes on");
  assert.equal(v2[0].protocolVersion, 2);
  // an older server answers without a version: the node stops for good, no retry, no v1
  assert.equal((await registerWith("")).length, 1);
  assert.equal((await registerWith(JSON.stringify({ protocolVersion: 1 }))).length, 1);
});
