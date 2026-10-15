import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, test } from "node:test";
import { field, MemoryRepository, model, Node } from "../src/index.js";

const listen = (server: Server) => new Promise<string>((resolve) =>
  server.listen(0, "127.0.0.1", () => resolve(`http://127.0.0.1:${(server.address() as AddressInfo).port}`)));

const servers: Server[] = [];
after(() => servers.forEach((s) => s.close()));

test("listener serves a model behind any http server", async () => {
  // the erupt server only answers erupt-power here
  const erupt = createServer((_req, res) => res.end(JSON.stringify({ add: true, edit: true, delete: true, viewDetails: true })));
  servers.push(erupt);
  const node = new Node("t", "secret", await listen(erupt));
  node.register(model("Item", { id: field.pk(), name: field.input("Name", { notNull: true }) }), new MemoryRepository());
  const app = createServer(node.listener);
  servers.push(app);
  const base = await listen(app);
  const call = async (path: string, body?: unknown, headers: Record<string, string> = {}) => {
    const res = await fetch(base + path, {
      method: body === undefined ? "GET" : "POST", body: body === undefined ? undefined : JSON.stringify(body),
      headers: { "access-token": "secret", erupt: "Item", token: "t", ...headers },
    });
    return [res.status, (await res.json().catch(() => null)) as any] as const;
  };
  assert.deepEqual(await call("/erupt-api/data/modify/Item", { name: "a" }), [200, { success: true, status: "SUCCESS", message: null, data: null, promptWay: "MESSAGE" }]);
  assert.equal((await call("/erupt-api/data/modify/Item", {}))[1].message, "Name cannot be empty");
  const [, page] = await call("/erupt-api/data/table/Item", { pageIndex: 1, pageSize: 10 });
  assert.deepEqual(page.list, [{ id: 1, name: "a" }]);
  assert.equal((await call("/erupt-api/build/Item", undefined, { "access-token": "secreT" }))[0], 403);
});

test("virtual and JSON fields", async () => {
  const { mkdtempSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { SqliteRepository } = await import("../src/index.js");
  const erupt = createServer((_req, res) => res.end(JSON.stringify({ add: true, edit: true, delete: true, viewDetails: true })));
  servers.push(erupt);
  const db = join(mkdtempSync(join(tmpdir(), "erupt-ts-")), "w.db");
  const server = await listen(erupt);
  for (const repo of [new MemoryRepository(), new SqliteRepository(db, "widget")]) {
    const node = new Node("t", "secret", server);
    node.register(model("Widget", {
      id: field.pk(),
      name: field.input("Name"),
      basic: field.input("Basic", { virtual: true, edit: { type: "DIVIDE" } }),
      roles: field.json("Roles", { search: true, edit: { type: "MULTI_CHOICE" } }, { ADMIN: "Admin", USER: "User", GUEST: "Guest" }),
      attrs: field.json("Attributes", { edit: { type: "KEY_VALUE" } }),
    }), repo);
    const app = createServer(node.listener);
    servers.push(app);
    const base = await listen(app);
    const call = async (path: string, body?: unknown) => {
      const res = await fetch(base + path, {
        method: body === undefined ? "GET" : "POST", body: body === undefined ? undefined : JSON.stringify(body),
        headers: { "access-token": "secret", erupt: "Widget", token: "t" },
      });
      return (await res.json()) as any;
    };
    const build = await call("/erupt-api/build/Widget");
    const fields = build.eruptModel.eruptFieldModels;
    assert.deepEqual(fields.map((f: any) => [f.fieldName, f.eruptFieldJson.edit.type]),
      [["id", "NUMBER"], ["name", "INPUT"], ["basic", "DIVIDE"], ["roles", "MULTI_CHOICE"], ["attrs", "KEY_VALUE"]]);
    assert.deepEqual(fields[3].componentValue.map((o: any) => o.label), ["Admin", "User", "Guest"]);
    assert.equal((await call("/erupt-api/data/modify/Widget", { name: "A", roles: ["ADMIN", "USER"], attrs: { env: "prod" }, basic: "x" })).success, true);
    assert.equal((await call("/erupt-api/data/modify/Widget", { name: "B", roles: ["GUEST"], attrs: {} })).success, true);
    assert.equal((await call("/erupt-api/data/modify/Widget", { name: "C", roles: ["ROOT"] })).success, false);
    const page = await call("/erupt-api/data/table/Widget", { pageIndex: 1, pageSize: 10 });
    assert.deepEqual(page.list[0], { id: 1, name: "A", roles: ["ADMIN", "USER"], attrs: { env: "prod" } });
    const found = await call("/erupt-api/data/table/Widget", { condition: [{ key: "roles", expression: "IN", value: ["GUEST"] }] });
    assert.deepEqual(found.list.map((r: any) => r.name), ["B"]);
    assert.deepEqual((await call("/erupt-api/data/Widget/1")).attrs, { env: "prod" });
  }
});
