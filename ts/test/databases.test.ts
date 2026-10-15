// SqlRepository against real PostgreSQL and MySQL. Runs only when ERUPT_TEST_DATABASES is set (the databases
// workflow starts both as service containers); connection settings come from the standard PG* variables and
// MYSQL_HOST / MYSQL_PORT / MYSQL_USER / MYSQL_DATABASE. pg and mysql2 are dev dependencies only.
import assert from "node:assert/strict";
import { test } from "node:test";
import { field, model, type Query, type SqlDialect, type SqlExecutor, SqlRepository, mysqlExecutor, pgExecutor } from "../src/index.js";

const enabled = Boolean(process.env.ERUPT_TEST_DATABASES);
const env = (name: string, fallback: string) => process.env[name] || fallback;

const DbPost = model("DbPost", {
  id: field.pk(), title: field.input("Title", { search: true }), views: field.number("Views"), live: field.boolean("Live"),
  day: field.date("Day"), at: field.dateTime("At"),
});

const ddl: Record<string, string[]> = {
  postgres: ['DROP TABLE IF EXISTS "db_post"',
    'CREATE TABLE "db_post" ("id" SERIAL PRIMARY KEY, "title" VARCHAR(255), "views" INTEGER, "live" BOOLEAN, "day" DATE, "at" TIMESTAMP(3))'],
  mysql: ["DROP TABLE IF EXISTS `db_post`",
    "CREATE TABLE `db_post` (`id` INT AUTO_INCREMENT PRIMARY KEY, `title` VARCHAR(255), `views` INT, `live` BOOLEAN, `day` DATE, `at` DATETIME(3))"],
};

async function scenario(dialect: SqlDialect, executor: SqlExecutor) {
  for (const sql of ddl[dialect]) await executor.execute(sql, []);
  const repo = new SqlRepository(executor, "db_post", { dialect });
  repo.bind(DbPost);
  await repo.add({ title: "100% pure", views: 3, live: true, day: "2026-01-05", at: "2026-01-05T10:30:00.123" });
  await repo.add({ title: "wow!", views: 1, live: false, day: "2026-03-01", at: null });
  await repo.add({ title: "a_b", views: null, live: false, day: null, at: null });
  const titles = async (q: Partial<Query> = {}) =>
    (await repo.page({ conditions: [], sort: [["title", false]], offset: 0, limit: 10, ...q }))[1].map((r) => r.title);

  assert.deepEqual(await titles({ sort: [] }), ["100% pure", "wow!", "a_b"], "default order is primary key ascending");
  assert.deepEqual(await titles({ conditions: [{ field: "title", op: "LIKE", value: "%" }] }), ["100% pure"], "LIKE escapes %");
  assert.deepEqual(await titles({ conditions: [{ field: "title", op: "LIKE", value: "!" }] }), ["wow!"], "LIKE escapes !");
  assert.deepEqual(await titles({ conditions: [{ field: "title", op: "LIKE", value: "_" }] }), ["a_b"], "LIKE escapes _");
  assert.deepEqual(await titles({ conditions: [{ field: "title", op: "NOT_LIKE", value: "pure" }] }), ["a_b", "wow!"], "NOT_LIKE");
  assert.deepEqual(await titles({ conditions: [{ field: "views", op: "IN", value: [1, 3] }] }), ["100% pure", "wow!"], "IN");
  assert.deepEqual(await titles({ conditions: [{ field: "views", op: "IN", value: [] }] }), [], "empty IN");
  assert.deepEqual(await titles({ conditions: [{ field: "day", op: "RANGE", value: ["2026-02-01", "2026-12-31"] }] }), ["wow!"], "RANGE");
  assert.deepEqual(await titles({ conditions: [{ field: "live", op: "EQ", value: true }] }), ["100% pure"], "boolean");
  assert.deepEqual(await titles({ conditions: [{ field: "views", op: "GT", value: 2 }] }), ["100% pure"], "GT");
  assert.deepEqual(await titles({ conditions: [{ field: "views", op: "NULL" }] }), ["a_b"], "NULL");
  const [total, page] = await repo.page({ conditions: [], sort: [["views", true]], offset: 1, limit: 1 });
  assert.deepEqual([total, page.length], [3, 1], "total and page size");

  assert.deepEqual(await repo.get(1), { id: 1, title: "100% pure", views: 3, live: true, day: "2026-01-05", at: "2026-01-05T10:30:00.123" },
    "round trip");
  await repo.update(1, { title: "renamed", live: false });
  const updated = await repo.get(1);
  assert.deepEqual([updated!.title, updated!.live], ["renamed", false], "update");
  await repo.delete([1, 2]);
  assert.deepEqual(await titles(), ["a_b"], "delete");
  assert.equal(await repo.get(1), null);
}

test("postgres", { skip: !enabled && "set ERUPT_TEST_DATABASES" }, async () => {
  const pg = await import("pg");
  // DATE and TIMESTAMP as the text the server sends: the SDK keeps wall-clock strings, never a shifted Date
  for (const oid of [1082, 1114]) pg.default.types.setTypeParser(oid, (v: string) => v);
  const pool = new pg.default.Pool(); // the PG* variables configure the connection
  try {
    await scenario("postgres", pgExecutor(pool));
  } finally {
    await pool.end();
  }
});

test("mysql", { skip: !enabled && "set ERUPT_TEST_DATABASES" }, async () => {
  const mysql = await import("mysql2/promise");
  const pool = mysql.createPool({
    host: env("MYSQL_HOST", "127.0.0.1"), port: Number(env("MYSQL_PORT", "3306")), user: env("MYSQL_USER", "root"),
    password: env("MYSQL_PASSWORD", ""), database: env("MYSQL_DATABASE", "erupt"), dateStrings: true,
  });
  try {
    await scenario("mysql", mysqlExecutor(pool));
  } finally {
    await pool.end();
  }
});
