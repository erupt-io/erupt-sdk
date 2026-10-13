// Erupt cloud node runtime: registers with the server, then answers the requests it forwards.
// The wire contract is erupt-cloud/PROTOCOL.md in the erupt repository.
import { AsyncLocalStorage } from "node:async_hooks";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { createSocket } from "node:dgram";
import { type EruptRecord, type Field, isObject, type Model, type Operation, type Power, toJsonValue, type User } from "./model.js";
import type { Cond, Operator, Query, Repository } from "./repo.js";

export const VERSION = "0.1.0";

const userStore = new AsyncLocalStorage<User | null>();

/** The acting user of the request being served: `{uid, account, name, tenantId}`. */
export function currentUser(): User | null {
  return userStore.getStore() ?? null;
}

// Features whose endpoints this SDK does not serve yet: hidden from the UI instead of failing there
const UNSUPPORTED_POWER: Power = { export: false, importable: false, cellEdit: false, print: false, ai: false };

// Rights the server decides per user; the node ANDs them onto the declared power
const SERVER_POWER = ["add", "edit", "delete", "viewDetails", "export", "importable"];

const OPS = new Set(["EQ", "NEQ", "GT", "GTE", "LT", "LTE", "LIKE", "NOT_LIKE", "RANGE", "IN", "NOT_IN", "NULL", "NOT_NULL"]);

const MAX_PAGE_SIZE = 1000;

const MAX_TREE_NODES = 10000;

const MAX_BODY = 16 * 1024 * 1024;

/** A protocol status with an empty or JSON body. */
class Reply extends Error {
  constructor(readonly status: number, readonly body: unknown = "") {
    super(String(status));
  }
}

/** A business error shown to the user as an R message. */
class Fail extends Error {}

const r = (success = true, message: string | null = null, data: unknown = null) =>
  ({ success, status: success ? "SUCCESS" : "ERROR", message, data, promptWay: "MESSAGE" });

interface Request {
  method: string;
  path: string;
  query: URLSearchParams;
  headers: IncomingMessage["headers"];
  body: Buffer;
}

type Handler = (model: Model, repo: Repository, req: Request, ...args: string[]) => Promise<unknown>;

export interface NodeOptions {
  /** the address the server calls back; defaults to http://<interface ip>:<port> */
  address?: string;
  /** heartbeat period in seconds (default 15) */
  heartbeat?: number;
}

export class Node {
  readonly servers: string[];
  readonly models = new Map<string, [Model, Repository]>();
  address: string | null;
  private serverIndex = 0;
  private readonly powerCache = new Map<string, [number, Power]>();
  private readonly instanceId = randomBytes(3).toString("hex");
  private readonly routes: [string, RegExp, Handler][];
  private timer: NodeJS.Timeout | null = null;
  private stopped = false;

  constructor(readonly name: string, private readonly accessToken: string, servers: string | string[], private readonly options: NodeOptions = {}) {
    if (!accessToken) throw new Error("accessToken is required");
    this.servers = (Array.isArray(servers) ? servers : [servers]).map((s) => s.replace(/\/+$/, ""));
    this.address = options.address?.replace(/\/+$/, "") ?? null;
    this.routes = [
      ["GET", /^\/erupt-api\/build\/([^/]+)$/, this.build],
      ["GET", /^\/erupt-api\/build\/([^/]+)\/([^/]+)$/, this.buildByField],
      ["POST", /^\/erupt-api\/data\/table\/([^/]+)$/, this.table],
      ["POST", /^\/erupt-api\/data\/([^/]+)\/reference-table\/([^/]+)$/, this.referenceTable],
      ["GET", /^\/erupt-api\/data\/([^/]+)\/reference-tree\/([^/]+)$/, this.referenceTree],
      ["POST", /^\/erupt-api\/data\/([^/]+)\/operator\/([^/]+)\/form-value$/, this.operationFormValue],
      ["POST", /^\/erupt-api\/data\/([^/]+)\/operator\/([^/]+)$/, this.operation],
      ["GET", /^\/erupt-api\/data\/init-value\/([^/]+)$/, this.initValue],
      ["GET", /^\/erupt-api\/data\/([^/]+)\/([^/]+)$/, this.get],
      ["POST", /^\/erupt-api\/data\/modify\/([^/]+)$/, this.add],
      ["POST", /^\/erupt-api\/data\/modify\/([^/]+)\/update$/, this.update],
      ["POST", /^\/erupt-api\/data\/modify\/([^/]+)\/delete$/, this.delete],
    ];
  }

  register(model: Model, repository: Repository): this {
    if (this.models.has(model.name)) throw new Error(`erupt '${model.name}' registered twice`);
    if (model.pk === null) throw new Error(`${model.name} has no field.pk(); only an operation form may omit it`);
    repository.bind(model);
    this.models.set(model.name, [model, repository]);
    return this;
  }

  private repoOf(target: Model): Repository {
    const entry = this.models.get(target.name);
    if (!entry || entry[0] !== target) throw new Error(`referenced erupt '${target.name}' is not registered on this node`);
    return entry[1];
  }

  // ---------------------------------------------------------------- HTTP

  /** A request listener for any node:http server. */
  readonly listener = (req: IncomingMessage, res: ServerResponse): void => {
    void this.respond(req, res);
  };

  private async respond(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url ?? "/", "http://node");
    let status: number;
    let body: unknown;
    try {
      const chunks: Buffer[] = [];
      let size = 0;
      for await (const chunk of req) {
        size += chunk.length;
        if (size > MAX_BODY) throw new Reply(413);
        chunks.push(chunk);
      }
      [status, body] = await this.dispatch({ method: req.method ?? "GET", path: url.pathname, query: url.searchParams, headers: req.headers, body: Buffer.concat(chunks) });
    } catch (e) {
      if (e instanceof Reply) [status, body] = [e.status, e.body];
      else if (e instanceof Fail) [status, body] = [200, r(false, e.message)];
      else {
        // never leak internals: message only, the stack stays in the node log
        console.error("erupt node error", e);
        [status, body] = [500, { path: url.pathname, status: 500, error: "erupt exception", message: e instanceof Error ? e.message : String(e) }];
      }
    }
    const text = typeof body === "string";
    const payload = Buffer.from(text ? (body as string) : JSON.stringify(body));
    res.writeHead(status, {
      "Content-Type": text ? "text/plain; charset=utf-8" : "application/json; charset=utf-8",
      "Content-Length": payload.length,
    });
    res.end(payload);
  }

  private async dispatch(req: Request): Promise<[number, unknown]> {
    if (req.path === "/node-health") return [200, this.name];
    if (!req.path.startsWith("/erupt-api/")) throw new Reply(404);
    // server-to-server only: an Origin header means a browser reached the node directly
    if (req.headers.origin) throw new Reply(403);
    if (!sameSecret(header(req, "access-token") ?? "", this.accessToken)) throw new Reply(403);
    const erupt = header(req, "erupt");
    for (const [verb, pattern, handler] of this.routes) {
      const match = pattern.exec(req.path);
      if (verb !== req.method || !match) continue;
      let name: string, args: string[];
      try {
        [name, ...args] = match.slice(1).map(decodeURIComponent);
      } catch {
        throw new Reply(404);
      }
      const entry = this.models.get(name);
      if (erupt !== name || !entry) throw new Reply(404);
      const parent = header(req, "eruptparent") || req.query.get("_eruptParent");
      // nesting is not supported yet, so a parent can only vouch for itself
      if (parent && parent.split(".").pop() !== name) throw new Reply(404);
      const user = header(req, "user");
      const acting = user ? (JSON.parse(Buffer.from(user, "base64").toString("utf8")) as User) : null;
      return userStore.run(acting, async () => [200, await handler.call(this, entry[0], entry[1], req, ...args)]);
    }
    throw new Reply(404);
  }

  // ---------------------------------------------------------------- endpoints

  private async build(model: Model, _repo: Repository, req: Request): Promise<unknown> {
    return model.buildModel(await this.power(model, req), currentUser());
  }

  // the reference picker: build of the referenced model, requested under the host model's name
  private async buildByField(model: Model, _repo: Repository, req: Request, field: string): Promise<unknown> {
    const target = referenceField(model, field).target!;
    return target.buildModel(await this.power(target, req), currentUser());
  }

  private async table(model: Model, repo: Repository, req: Request): Promise<unknown> {
    await this.require(model, req, "query");
    return this.page(model, repo, objectBody(req));
  }

  private async referenceTable(model: Model, _repo: Repository, req: Request, field: string): Promise<unknown> {
    const target = referenceField(model, field, "REFERENCE_TABLE").target!;
    return this.page(target, this.repoOf(target), objectBody(req));
  }

  private async referenceTree(model: Model, _repo: Repository, _req: Request, field: string): Promise<unknown> {
    const f = referenceField(model, field, "REFERENCE_TREE");
    const target = f.target!;
    const [, records] = await this.repoOf(target).page({ conditions: [], sort: [], offset: 0, limit: MAX_TREE_NODES });
    interface TreeNode { id: string; label: string | null; pid: string | null; root: boolean; level: number; children: TreeNode[] | null }
    const str = (v: unknown) => (v == null ? null : String(v));
    const nodes = new Map<string, TreeNode>();
    for (const rec of records) {
      const id = String(rec[target.pk!]);
      nodes.set(id, { id, label: str(rec[f.label]), pid: str(rec[f.tree!]), root: false, level: 1, children: null });
    }
    const roots: TreeNode[] = [];
    for (const node of nodes.values()) {
      const parent = node.pid === null ? undefined : nodes.get(node.pid);
      if (!parent || parent === node) {
        node.root = true;
        roots.push(node);
      } else {
        parent.children = [...(parent.children ?? []), node];
      }
    }
    const seen = new Set<TreeNode>();
    const level = (list: TreeNode[], depth: number): void => {
      for (const n of list) {
        if (seen.has(n)) continue; // a pid cycle would otherwise recurse forever
        seen.add(n);
        n.level = depth;
        level(n.children ?? [], depth + 1);
      }
    };
    level(roots, 1);
    return roots;
  }

  private async page(model: Model, repo: Repository, body: Record<string, any>): Promise<unknown> {
    const pageIndex = Math.max(Math.trunc(Number(body.pageIndex)) || 1, 1);
    const pageSize = Math.min(Math.max(Math.trunc(Number(body.pageSize)) || 10, 1), MAX_PAGE_SIZE);
    const query: Query = { conditions: [], sort: [], offset: (pageIndex - 1) * pageSize, limit: pageSize };
    for (const c of asList(body.condition)) query.conditions.push(condition(model, c));
    for (const s of asList(body.sort)) {
      const f = isObject(s) ? model.fields[s.field] : undefined;
      if (!f || !(f.sortable || f.pk)) throw new Fail(`illegal sort field '${isObject(s) ? s.field : s}'`);
      query.sort.push([f.name, String((s as Record<string, unknown>).direction ?? "ASC").toUpperCase() === "DESC"]);
    }
    if (!query.sort.length) query.sort = [...model.orderBy];
    const [total, records] = await repo.page(query);
    return {
      pageIndex, pageSize, total, totalPage: Math.ceil(total / pageSize), list: await this.rows(model, records),
      sort: null, alert: null, extraContent: null,
    };
  }

  private async initValue(model: Model, _repo: Repository, req: Request): Promise<unknown> {
    await this.require(model, req, "add");
    return Object.fromEntries(Object.keys(model.fields).map((name) => [name, null]));
  }

  private async get(model: Model, repo: Repository, req: Request, pk: string): Promise<unknown> {
    const power = await this.power(model, req);
    if (!(power.edit || power.viewDetails)) throw new Reply(403);
    const record = await repo.get(primaryKey(model, pk));
    if (!record) throw new Fail("record not found");
    return (await this.rows(model, [record]))[0];
  }

  private async add(model: Model, repo: Repository, req: Request): Promise<unknown> {
    await this.require(model, req, "add");
    await repo.add(coerceRecord(model, objectBody(req)));
    return r();
  }

  private async update(model: Model, repo: Repository, req: Request): Promise<unknown> {
    await this.require(model, req, "edit");
    const body = objectBody(req);
    const pk = primaryKey(model, body[model.pk!]);
    if (!(await repo.get(pk))) throw new Fail("record not found");
    await repo.update(pk, coerceRecord(model, body));
    return r();
  }

  private async delete(model: Model, repo: Repository, req: Request): Promise<unknown> {
    await this.require(model, req, "delete");
    const body = readJson(req);
    if (!Array.isArray(body)) throw new Fail("a list of ids is required");
    await repo.delete(body.map((pk) => primaryKey(model, pk)));
    return r();
  }

  /**
   * Records to browser rows. A reference becomes {<id>: "1", <label>: "News"} for the form plus the
   * flattened <field>_<label> column the table reads.
   */
  private async rows(model: Model, records: EruptRecord[]): Promise<EruptRecord[]> {
    const fields = Object.values(model.fields);
    const refs = fields.filter((f) => f.isReference);
    const cache = new Map<string, EruptRecord>();
    const rows: EruptRecord[] = [];
    for (const record of records) {
      const row: EruptRecord = {};
      for (const f of fields) row[f.name] = toJsonValue(record[f.name] ?? null, f.type);
      for (const f of refs) {
        const rid = record[f.name];
        if (rid == null) {
          row[f.name] = null;
          continue;
        }
        const target = f.target!;
        const key = `${target.name}\u0000${String(rid)}`;
        if (!cache.has(key)) cache.set(key, (await this.repoOf(target).get(rid)) ?? {});
        const label = toJsonValue(cache.get(key)![f.label] ?? null, target.fields[f.label].type);
        row[f.name] = { [target.pk!]: String(rid), [f.label]: label };
        row[`${f.name}_${f.label}`] = label;
      }
      rows.push(row);
    }
    return rows;
  }

  private operationOf(model: Model, code: string): Operation {
    const op = model.operations[code];
    // a hidden operation does not exist for this user, exactly like the Java proxy filters it out
    if (!op || !op.visible(currentUser())) throw new Reply(op ? 403 : 404);
    return op;
  }

  private async operationFormValue(model: Model, _repo: Repository, _req: Request, code: string): Promise<unknown> {
    const op = this.operationOf(model, code);
    if (!op.form) throw new Reply(404); // the browser ignores a 404 here and opens an empty form
    return Object.fromEntries(Object.keys(op.form.fields).map((name) => [name, null]));
  }

  private async operation(model: Model, repo: Repository, req: Request, code: string): Promise<unknown> {
    const op = this.operationOf(model, code);
    const body = objectBody(req);
    const param = op.form ? coerceRecord(op.form, isObject(body.param) ? body.param : {}) : null;
    const rows: EruptRecord[] = [];
    if (op.mode !== "BUTTON") {
      const ids = body.ids;
      if (!Array.isArray(ids) || !ids.length) throw new Fail("select at least one row");
      if (op.mode === "SINGLE" && ids.length !== 1) throw new Fail("select exactly one row");
      for (const pk of ids) {
        const record = await repo.get(primaryKey(model, pk));
        if (!record) throw new Fail(`record '${pk}' not found`);
        rows.push(record);
      }
    }
    const result = await op.handler({ rows, param, repo, model, user: currentUser() });
    return typeof result === "string" && result ? r(true, null, result) : r(true, "Executed successfully");
  }

  // ---------------------------------------------------------------- permissions (PROTOCOL.md §6.1)

  private async require(model: Model, req: Request, right: string): Promise<void> {
    if (!(await this.power(model, req))[right]) throw new Reply(403);
  }

  private async power(model: Model, req: Request): Promise<Power> {
    const token = header(req, "token") ?? "";
    const key = `${token}\u0000${model.name}`;
    const cached = this.powerCache.get(key);
    if (cached && cached[0] > Date.now()) return cached[1];
    const power: Power = { ...model.power, ...UNSUPPORTED_POWER };
    let remote: Record<string, unknown> = {};
    try {
      const params = new URLSearchParams({ nodeName: this.name, eruptName: model.name });
      const res = await fetch(`${this.nextServer()}/erupt-cloud-api/erupt-power?${params}`,
        { headers: { token }, signal: AbortSignal.timeout(5000) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const json: unknown = await res.json();
      if (isObject(json)) remote = json;
    } catch (e) {
      // fail closed: without the server's verdict nothing is writable
      console.warn(`erupt-power unavailable: ${e instanceof Error ? e.message : e}`);
    }
    for (const right of SERVER_POWER) power[right] = power[right] && !!remote[right];
    if (this.powerCache.size > 10000) this.powerCache.clear();
    this.powerCache.set(key, [Date.now() + 5000, power]);
    return power;
  }

  // ---------------------------------------------------------------- server calls

  private nextServer(): string {
    return this.servers[this.serverIndex++ % this.servers.length];
  }

  private nodeInfo() {
    return {
      instanceId: this.instanceId, nodeName: this.name, accessToken: this.accessToken, version: `ts-${VERSION}`,
      nodeAddress: [this.address], eruptModules: [], erupts: [...this.models.keys()], resources: {},
    };
  }

  private async heartbeat(failing = false): Promise<void> {
    if (this.stopped) return;
    const server = this.nextServer();
    let next = (this.options.heartbeat ?? 15) * 1000;
    try {
      const res = await fetch(`${server}/erupt-cloud-api/register-node`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(this.nodeInfo()),
        signal: AbortSignal.timeout(10000),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      if (failing) console.info(`${server} -> connection success`);
      failing = false;
    } catch (e) {
      failing = true;
      next /= 2;
      console.error(`${server} -> register failed: ${e instanceof Error ? e.message : e}`);
    }
    if (!this.stopped) this.timer = setTimeout(() => void this.heartbeat(failing), next);
  }

  /** Start registering with the server; call once `address` answers /node-health. */
  startHeartbeat(): void {
    this.stopped = false;
    void this.heartbeat();
  }

  /** Stop the heartbeat and tell the server this instance is gone. */
  async deregister(): Promise<void> {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    try {
      await fetch(`${this.nextServer()}/erupt-cloud-api/remove-instance-node`, {
        method: "POST",
        body: new URLSearchParams({ nodeName: this.name, accessToken: this.accessToken, locations: this.address ?? "" }),
        signal: AbortSignal.timeout(5000),
      });
    } catch (e) {
      console.error(`deregister failed: ${e instanceof Error ? e.message : e}`);
    }
  }

  /**
   * Serve until SIGINT / SIGTERM: HTTP first (the server probes /node-health while registering), then the
   * heartbeat; on a signal deregister and close.
   */
  async serve(port = 9090, host = "0.0.0.0"): Promise<Server> {
    this.address ??= `http://${await localIp(this.servers[0])}:${port}`;
    const server = createServer(this.listener);
    await new Promise<void>((resolve) => server.listen(port, host, resolve));
    console.info(`erupt node '${this.name}' at ${this.address} -> ${this.servers.join(", ")}`);
    this.startHeartbeat();
    const stop = async () => {
      await this.deregister();
      server.close();
      server.closeAllConnections();
    };
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
    return server;
  }
}

// ---------------------------------------------------------------- helpers

function header(req: Request, name: string): string | undefined {
  const value = req.headers[name];
  return Array.isArray(value) ? value[0] : value;
}

function sameSecret(given: string, expected: string): boolean {
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  // timingSafeEqual needs equal lengths; comparing b with itself keeps the time independent of `given`
  return timingSafeEqual(a.length === b.length ? a : b, b) && a.length === b.length;
}

function readJson(req: Request): unknown {
  if (!req.body.length) return undefined;
  try {
    return JSON.parse(req.body.toString("utf8"));
  } catch {
    throw new Fail("malformed JSON body");
  }
}

function objectBody(req: Request): Record<string, any> {
  const body = readJson(req);
  return isObject(body) ? body : {};
}

const asList = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);

function referenceField(model: Model, field: string, editType?: string): Field {
  const f = model.fields[field];
  if (!f || !f.isReference || (editType && f.type !== editType)) throw new Reply(404);
  return f;
}

function condition(model: Model, c: unknown): Cond {
  const key = isObject(c) ? c.key : undefined;
  const f = typeof key === "string" ? model.fields[key] : undefined;
  if (!f || f.pk || !f.search) throw new Fail(`illegal search field '${key}'`);
  const op = String((c as Record<string, unknown>).expression || "EQ");
  if (!OPS.has(op)) throw new Fail(`illegal operator '${op}'`);
  const value = (c as Record<string, unknown>).value;
  const cond = (v?: unknown): Cond => ({ field: f.name, op: op as Operator, value: v });
  if (op === "NULL" || op === "NOT_NULL") return cond();
  if (f.isReference && !["EQ", "NEQ", "IN", "NOT_IN"].includes(op)) throw new Fail(`illegal operator '${op}' for a reference`);
  if (op === "LIKE" || op === "NOT_LIKE") return cond(String(value));
  try {
    if (op === "RANGE") {
      if (!Array.isArray(value) || value.length !== 2) throw new Error("range needs two values");
      return cond(value.map((v) => f.coerce(v)));
    }
    if (op === "IN" || op === "NOT_IN") return cond((Array.isArray(value) ? value : [value]).map((v) => f.coerce(v)));
    return cond(f.coerce(value));
  } catch (e) {
    throw new Fail((e as Error).message);
  }
}

function primaryKey(model: Model, value: unknown): unknown {
  try {
    return model.fields[model.pk!].coerce(value);
  } catch {
    throw new Fail(`illegal id '${value}'`);
  }
}

function coerceRecord(model: Model, body: Record<string, unknown>): EruptRecord {
  const record: EruptRecord = {};
  for (const f of Object.values(model.fields)) {
    if (f.pk || !f.form) continue;
    let value: unknown;
    try {
      value = f.coerce(body[f.name]);
    } catch (e) {
      throw new Fail(`${f.title}: ${(e as Error).message}`);
    }
    if (f.notNull && value == null) throw new Fail(`${f.title} cannot be empty`);
    record[f.name] = value;
  }
  return record;
}

/** The interface address the server would see us on. */
function localIp(server: string): Promise<string> {
  return new Promise((resolve) => {
    const socket = createSocket("udp4");
    const done = (ip: string) => {
      socket.close();
      resolve(ip);
    };
    socket.on("error", () => done("127.0.0.1"));
    try {
      socket.connect(80, new URL(server).hostname || "127.0.0.1", () => done(socket.address().address));
    } catch {
      done("127.0.0.1");
    }
  });
}
