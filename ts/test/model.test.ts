import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { field, model, operation } from "../src/index.js";

const declare = (fields: Record<string, ReturnType<typeof field.pk>> = {}, options: object = {}) =>
  model("Bad", { id: field.pk(), ...fields }, options);

test("rejects what only the declaration can tell", () => {
  const cases: [() => unknown, RegExp][] = [
    [() => field.of("INPUTT" as never, "T"), /'INPUTT' is not one of/],
    [() => declare({ t: field.input("T", { edit: { type: "INPUTT" } as never }) }), /Bad.t.edit.type: 'INPUTT' is not one of/],
    [() => field.of("PASSWORD", "T") && declare({ t: field.of("PASSWORD", "T") }), /PASSWORD is not supported yet/],
    [() => declare({}, { orderBy: "missing desc" }), /illegal orderBy/],
    [() => declare({}, { erupt: { vis: [{ title: "V", orderBy: "missing" }] } }), /illegal orderBy/],
    [() => operation("Go", { mode: "ALL" as never }, () => undefined), /'ALL' is not one of/],
    [() => declare({ c: field.ref(declare(), "C", { label: "title" }) }), /has no field 'title'/],
    [() => declare({ t: field.input("T", { fetch: () => ({}) }) }), /fetch, complete and click belong to/],
    [() => declare({ t: field.input("T", { click: () => ({}) }) }), /fetch, complete and click belong to/],
    [() => declare({}, { power: { remove: false } }), /no right remove/],
    [() => declare({ t: field.input("T") }, { erupt: { linkTree: { field: "t" } } }), /must be a reference field/],
    [() => declare({}, { erupt: { drills: [{ title: "D", link: { linkErupt: "X" } as never }] } }), /needs link.linkErupt and link.joinColumn/],
    [() => model("bad name", {}), /must be an identifier/],
    [() => model("Two", { a: field.pk(), b: field.pk() }), /at most one/],
  ];
  for (const [fn, message] of cases) assert.throws(fn, message);
});

test("attributes the server checks pass through", () => {
  // an unknown attribute is the server's to refuse (PROTOCOL.md §12.3)
  const m = declare({ title: field.input("T", { edit: { inputType: { length: 9 }, colour: "red" } as never }) },
    { erupt: { layout: { pageSize: 30 } } });
  const built = m.buildErupt();
  assert.equal(built.eruptJson.layout.pageSize, 30);
  assert.deepEqual(built.eruptFieldModels[1].eruptFieldJson.edit, { title: "T", type: "INPUT", inputType: { length: 9 }, colour: "red" });
});

test("converts normalized values to storage types", () => {
  const target = model("Target", { id: field.pk(), name: field.input("Name") });
  const m = model("Values", {
    id: field.pk(), d: field.date("D"), t: field.dateTime("T"), n: field.number("N"), b: field.boolean("B"),
    c: field.choice("C", { a: "A" }), r: field.ref(target, "R"), k: field.checkbox(target, "K"),
  });
  const f = m.fields;
  assert.equal(f.t.coerce("2026-01-05 10:30:00"), "2026-01-05T10:30:00.000");
  assert.equal(f.t.coerce("2026-01-05T10:30:00.123456Z"), "2026-01-05T10:30:00.123");
  assert.equal(f.d.coerce("2026-03-01"), "2026-03-01");
  assert.throws(() => f.d.coerce("someday"), /illegal date/);
  assert.equal(f.n.coerce(3), 3);
  assert.equal(f.n.coerce(2.5), 2.5);
  assert.equal(f.b.coerce(false), false);
  // the server checked the choice; the node stores what it sent
  assert.equal(f.c.coerce("b"), "b");
  assert.equal(f.r.coerce(2), 2);
  assert.deepEqual(f.k.coerce([1, 2]), [1, 2]);
  // a key in a path segment arrives as the browser sent it
  assert.equal(f.id.coerce("42"), 42);
  assert.throws(() => f.id.coerce("4x"), /illegal integer/);
  assert.equal(f.n.coerce(""), null);
});

test("generated types are current", async () => {
  const gen = await import(new URL("../../tools/gen-types.mjs", import.meta.url).href);
  const schema = JSON.parse(readFileSync(new URL("../../../schema/erupt-annotations.schema.json", import.meta.url), "utf8"));
  assert.equal(gen.generate(schema), readFileSync(new URL("../../src/types.ts", import.meta.url), "utf8"));
});
