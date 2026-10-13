import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { field, MemoryRepository, model, type Query, type Repository, SqliteRepository } from "../src/index.js";

const Item = model("Item", {
  id: field.pk(), name: field.input("Name", { search: true }), n: field.number("N"), ok: field.boolean("Ok"), d: field.date("D"),
});

const dir = mkdtempSync(join(tmpdir(), "erupt-ts-"));
after(() => rmSync(dir, { recursive: true, force: true }));

const query = (q: Partial<Query> = {}): Query => ({ conditions: [], sort: [["id", false]], offset: 0, limit: 100, ...q });

for (const [kind, create] of [
  ["memory", () => new MemoryRepository()],
  ["sqlite", () => new SqliteRepository(join(dir, `t${Math.random()}.db`), "item")],
] as [string, () => Repository][]) {
  test(`${kind} repository`, async () => {
    const repo = create();
    repo.bind(Item);
    for (const r of [
      { name: "100% pure", n: 1, ok: true, d: "2026-01-01" },
      { name: "100 points", n: 2, ok: false, d: "2026-02-01" },
      { name: "under_score", n: null, ok: null, d: null },
    ]) await repo.add(r);
    const names = async (q: Partial<Query>) => (await repo.page(query(q)))[1].map((r) => r.name);
    assert.deepEqual(await names({ conditions: [{ field: "name", op: "LIKE", value: "100%" }] }), ["100% pure"]);
    assert.deepEqual(await names({ conditions: [{ field: "name", op: "LIKE", value: "r_s" }] }), ["under_score"]);
    assert.deepEqual(await names({ conditions: [{ field: "name", op: "NOT_LIKE", value: "100" }] }), ["under_score"]);
    assert.deepEqual(await names({ conditions: [{ field: "n", op: "IN", value: [2, 3] }] }), ["100 points"]);
    assert.deepEqual(await names({ conditions: [{ field: "n", op: "IN", value: [] }] }), []);
    assert.deepEqual(await names({ conditions: [{ field: "n", op: "NULL" }] }), ["under_score"]);
    assert.deepEqual(await names({ conditions: [{ field: "n", op: "GTE", value: 2 }] }), ["100 points"]);
    assert.deepEqual(await names({ conditions: [{ field: "d", op: "RANGE", value: ["2026-01-15", "2026-12-31"] }] }), ["100 points"]);
    assert.deepEqual(await names({ conditions: [{ field: "ok", op: "EQ", value: true }] }), ["100% pure"]);
    assert.deepEqual(await names({ sort: [["n", true]], conditions: [{ field: "n", op: "NOT_NULL" }] }), ["100 points", "100% pure"]);
    const [total, page] = await repo.page(query({ offset: 1, limit: 1 }));
    assert.deepEqual([total, page.map((r) => r.name)], [3, ["100 points"]]);
    assert.equal((await repo.get(1))!.ok, true);
    await repo.update(1, { name: "renamed" });
    assert.deepEqual(await repo.get(1), { id: 1, name: "renamed", n: 1, ok: true, d: "2026-01-01" });
    await repo.delete([1, 2]);
    assert.deepEqual(await names({}), ["under_score"]);
    assert.equal(await repo.get(1), null);
  });
}
