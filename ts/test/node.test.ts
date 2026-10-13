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
