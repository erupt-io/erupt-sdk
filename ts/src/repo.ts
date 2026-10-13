// Storage adapters. A repository only sees field names the node has already checked against the model,
// so it may use them as identifiers; values always travel as parameters.
import type { DatabaseSync } from "node:sqlite";
import type { EruptRecord, Model } from "./model.js";

export type Operator = "EQ" | "NEQ" | "GT" | "GTE" | "LT" | "LTE" | "LIKE" | "NOT_LIKE" | "RANGE" | "IN" | "NOT_IN" | "NULL" | "NOT_NULL";

export interface Cond {
  field: string;
  op: Operator;
  value?: unknown;
}

export interface Query {
  conditions: Cond[];
  /** [field, descending] */
  sort: [string, boolean][];
  offset: number;
  limit: number;
}

type Awaitable<T> = T | Promise<T>;

/** Implement these methods to put an erupt model on any storage; each may be async. */
export interface Repository {
  /** called once by `Node.register` with the model this repository stores */
  bind(model: Model): void;
  /** `[total, records]`; a record is keyed by field name */
  page(query: Query): Awaitable<[number, EruptRecord[]]>;
  get(pk: unknown): Awaitable<EruptRecord | null>;
  add(record: EruptRecord): Awaitable<void>;
  update(pk: unknown, record: EruptRecord): Awaitable<void>;
  delete(pks: unknown[]): Awaitable<void>;
}

type Comparable = string | number | boolean;

function match(value: unknown, cond: Cond): boolean {
  const expect = cond.value as Comparable;
  if (cond.op === "NULL") return value == null;
  if (cond.op === "NOT_NULL") return value != null;
  if (value == null) return false;
  const v = value as Comparable;
  switch (cond.op) {
    case "EQ":
      return v === expect;
    case "NEQ":
      return v !== expect;
    case "LIKE":
      return String(v).toLowerCase().includes(String(expect).toLowerCase());
    case "NOT_LIKE":
      return !String(v).toLowerCase().includes(String(expect).toLowerCase());
    case "IN":
      return (cond.value as unknown[]).includes(v);
    case "NOT_IN":
      return !(cond.value as unknown[]).includes(v);
    case "RANGE": {
      const [low, high] = cond.value as Comparable[];
      return low <= v && v <= high;
    }
    case "GT":
      return v > expect;
    case "GTE":
      return v >= expect;
    case "LT":
      return v < expect;
    case "LTE":
      return v <= expect;
  }
}

function compare(a: unknown, b: unknown): number {
  // nulls last, like the Python repository
  if (a == null || b == null) return a == null ? (b == null ? 0 : 1) : -1;
  return a < b ? -1 : a > b ? 1 : 0;
}

export class MemoryRepository implements Repository {
  private model!: Model;
  private readonly rows = new Map<number, EruptRecord>();
  private seq = 0;

  /** `records` are added (with fresh ids 1, 2, ...) once the repository is registered */
  constructor(private readonly seed: EruptRecord[] = []) {}

  bind(model: Model): void {
    this.model = model;
    for (const record of this.seed) this.add(record);
  }

  page(query: Query): [number, EruptRecord[]] {
    const rows = [...this.rows.values()].filter((r) => query.conditions.every((c) => match(r[c.field], c)));
    rows.sort((a, b) => {
      for (const [name, desc] of query.sort) {
        const c = compare(a[name], b[name]);
        if (c) return desc ? -c : c;
      }
      return 0;
    });
    return [rows.length, rows.slice(query.offset, query.offset + query.limit).map((r) => ({ ...r }))];
  }

  get(pk: unknown): EruptRecord | null {
    const row = this.rows.get(pk as number);
    return row ? { ...row } : null;
  }

  add(record: EruptRecord): void {
    const id = ++this.seq;
    this.rows.set(id, { ...record, [this.model.pk!]: id });
  }

  update(pk: unknown, record: EruptRecord): void {
    const row = this.rows.get(pk as number);
    if (row) Object.assign(row, record, { [this.model.pk!]: pk });
  }

  delete(pks: unknown[]): void {
    for (const pk of pks) this.rows.delete(pk as number);
  }
}

const SQL_OPS: Partial<Record<Operator, string>> = { EQ: "=", NEQ: "<>", GT: ">", GTE: ">=", LT: "<", LTE: "<=" };

const SQLITE_TYPES: Record<string, string> = {
  NUMBER: "NUMERIC", BOOLEAN: "INTEGER", DATE: "TEXT", DATE_TIME: "TEXT", REFERENCE_TABLE: "INTEGER", REFERENCE_TREE: "INTEGER",
};

type SqlValue = null | number | bigint | string;

// node:sqlite binds no booleans
const sqlValue = (v: unknown): SqlValue => (typeof v === "boolean" ? Number(v) : (v as SqlValue) ?? null);

/** A SQLite table via node:sqlite (Node >= 22.5), created on first use when missing. */
export class SqliteRepository implements Repository {
  private model!: Model;
  private db: DatabaseSync | null = null;

  constructor(private readonly path: string, private readonly table: string) {}

  private static q(identifier: string): string {
    return '"' + identifier.replaceAll('"', '""') + '"';
  }

  private conn(): DatabaseSync {
    if (!this.db) {
      // loaded lazily: node:sqlite warns as experimental on import, which an app using only memory should not see
      const { DatabaseSync } = process.getBuiltinModule("node:sqlite") as typeof import("node:sqlite");
      this.db = new DatabaseSync(this.path);
    }
    return this.db;
  }

  bind(model: Model): void {
    this.model = model;
    const q = SqliteRepository.q;
    const cols = Object.values(model.fields).map((f) =>
      f.pk ? `${q(f.name)} INTEGER PRIMARY KEY AUTOINCREMENT` : `${q(f.name)} ${SQLITE_TYPES[f.type!] ?? "TEXT"}`);
    this.conn().exec(`CREATE TABLE IF NOT EXISTS ${q(this.table)} (${cols.join(", ")})`);
  }

  private where(conditions: Cond[]): [string, SqlValue[]] {
    const q = SqliteRepository.q;
    const clauses: string[] = [];
    const params: SqlValue[] = [];
    for (const c of conditions) {
      const col = q(c.field);
      const values = Array.isArray(c.value) ? c.value.map(sqlValue) : [];
      if (SQL_OPS[c.op]) {
        clauses.push(`${col} ${SQL_OPS[c.op]} ?`);
        params.push(sqlValue(c.value));
      } else if (c.op === "LIKE" || c.op === "NOT_LIKE") {
        clauses.push(`${col} ${c.op === "NOT_LIKE" ? "NOT " : ""}LIKE ? ESCAPE '\\'`);
        params.push(`%${String(c.value).replace(/[\\%_]/g, (ch) => "\\" + ch)}%`);
      } else if (c.op === "RANGE") {
        clauses.push(`${col} BETWEEN ? AND ?`);
        params.push(...values.slice(0, 2));
      } else if (c.op === "IN" || c.op === "NOT_IN") {
        if (!values.length) {
          clauses.push(c.op === "IN" ? "1=0" : "1=1");
          continue;
        }
        clauses.push(`${col} ${c.op === "NOT_IN" ? "NOT " : ""}IN (${values.map(() => "?").join(", ")})`);
        params.push(...values);
      } else if (c.op === "NULL" || c.op === "NOT_NULL") {
        clauses.push(`${col} IS ${c.op === "NOT_NULL" ? "NOT " : ""}NULL`);
      }
    }
    return [clauses.length ? " WHERE " + clauses.join(" AND ") : "", params];
  }

  private record(row: Record<string, unknown>): EruptRecord {
    const record: EruptRecord = { ...row };
    for (const f of Object.values(this.model.fields)) {
      if (f.type === "BOOLEAN" && record[f.name] != null) record[f.name] = !!record[f.name];
    }
    return record;
  }

  page(query: Query): [number, EruptRecord[]] {
    const q = SqliteRepository.q;
    const [where, params] = this.where(query.conditions);
    const table = q(this.table);
    const total = Number((this.conn().prepare(`SELECT COUNT(*) AS n FROM ${table}${where}`).get(...params) as { n: number }).n);
    const order = query.sort.map(([n, d]) => `${q(n)} ${d ? "DESC" : "ASC"}`).join(", ") || `${q(this.model.pk!)} DESC`;
    const rows = this.conn().prepare(`SELECT * FROM ${table}${where} ORDER BY ${order} LIMIT ? OFFSET ?`)
      .all(...params, query.limit, query.offset) as Record<string, unknown>[];
    return [total, rows.map((r) => this.record(r))];
  }

  get(pk: unknown): EruptRecord | null {
    const q = SqliteRepository.q;
    const row = this.conn().prepare(`SELECT * FROM ${q(this.table)} WHERE ${q(this.model.pk!)} = ?`).get(sqlValue(pk));
    return row ? this.record(row as Record<string, unknown>) : null;
  }

  add(record: EruptRecord): void {
    const q = SqliteRepository.q;
    const entries = Object.entries(record).filter(([k]) => k !== this.model.pk);
    this.conn().prepare(`INSERT INTO ${q(this.table)} (${entries.map(([k]) => q(k)).join(", ")}) VALUES (${entries.map(() => "?").join(", ")})`)
      .run(...entries.map(([, v]) => sqlValue(v)));
  }

  update(pk: unknown, record: EruptRecord): void {
    const q = SqliteRepository.q;
    const entries = Object.entries(record).filter(([k]) => k !== this.model.pk);
    if (!entries.length) return;
    this.conn().prepare(`UPDATE ${q(this.table)} SET ${entries.map(([k]) => `${q(k)} = ?`).join(", ")} WHERE ${q(this.model.pk!)} = ?`)
      .run(...entries.map(([, v]) => sqlValue(v)), sqlValue(pk));
  }

  delete(pks: unknown[]): void {
    if (!pks.length) return;
    const q = SqliteRepository.q;
    this.conn().prepare(`DELETE FROM ${q(this.table)} WHERE ${q(this.model.pk!)} IN (${pks.map(() => "?").join(", ")})`)
      .run(...pks.map(sqlValue));
  }

  /** Close the database file. */
  close(): void {
    this.db?.close();
    this.db = null;
  }
}
