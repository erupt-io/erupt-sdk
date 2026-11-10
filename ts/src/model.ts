// Model declaration: `model()` with `field.*` columns and `operation()`s, compiled into erupt build JSON.
//
// Nothing here re-implements annotation semantics. The build carries only what a model declares; the server
// completes every annotation from its Java defaults and checks it (erupt-cloud/PROTOCOL.md §12.3, protocol v2).
import type { Awaitable, Cond, Repository } from "./repo.js";
import { type Drill, type Edit, type EditType, EditTypeValues, type Erupt, type Link, type ReferenceTableType, type RowOperation,
  type RowOperationMode, RowOperationModeValues, type View, type Vis } from "./types.js";

/** A record as repositories store it: field name -> value (a reference holds the referenced primary key). */
export type EruptRecord = Record<string, unknown>;

/** The acting user the server forwards with every request. */
export interface User {
  uid?: number;
  account?: string;
  name?: string;
  tenantId?: string | null;
}

export type Power = Record<string, boolean>;

type Json = Record<string, any>;

const IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_]*$/;

const REFERENCES = ["REFERENCE_TABLE", "REFERENCE_TREE"];
// many records of another model, stored as the JSON list of their keys
const COLLECTIONS = ["CHECKBOX", "TAB_TREE", "TRANSFER"];
// the edit attribute that names a fetchHandler, by the type that fetches options
const FETCHED: Record<string, string> = { CHOICE: "choiceType", MULTI_CHOICE: "multiChoiceType", TAGS: "tagsType" };
// fieldReturnName by edit type (PROTOCOL.md §7.1); a reference names its target, the rest are "String"
const RETURN_NAMES: Record<string, string> = { NUMBER: "number", RATE: "number", SLIDER: "number", BOOLEAN: "Boolean", DATE: "Date", DATE_TIME: "Date" };
// the edit types this SDK stores and serves (DATE_TIME is DATE with a date-time picker)
const SUPPORTED = ["ATTACHMENT", "AUTO_COMPLETE", "BOOLEAN", "BUTTON", "CHECKBOX", "CHOICE", "CODE_EDITOR", "COLOR", "DATE",
  "DATE_TIME", "HIDDEN", "HTML_EDITOR", "ICON", "INPUT", "MAP", "MARKDOWN", "MULTI_CHOICE", "NUMBER", "RATE",
  "REFERENCE_TABLE", "REFERENCE_TREE", "SIGNATURE", "SLIDER", "TAB_TREE", "TAGS", "TEXTAREA", "TRANSFER"];
// rights a model may switch off (@Erupt power, PowerObject)
const POWERS = ["add", "edit", "delete", "query", "viewDetails", "export", "importable", "print", "copy", "cellEdit",
  "batchEdit", "ai", "comment", "revision"];

/** A misspelt enum value fails where the model is declared; everything else the server checks (§12.3). */
function checkEnum(values: readonly string[], value: unknown, path: string): void {
  if (!values.includes(value as string)) throw new Error(`${path}: '${value}' is not one of ${values.join(", ")}`);
}

export const isObject = (v: unknown): v is Json => typeof v === "object" && v !== null && !Array.isArray(v);

function merge(target: Json, override: Json): Json {
  for (const [key, value] of Object.entries(override)) {
    if (isObject(value) && isObject(target[key])) merge(target[key], value);
    else target[key] = structuredClone(value);
  }
  return target;
}

export interface FieldOptions {
  /** offered in the search bar */
  search?: boolean;
  notNull?: boolean;
  sortable?: boolean;
  /** shown as a table column (default true) */
  table?: boolean;
  /** shown in the add / edit form (default true) */
  form?: boolean;
  /** raw @View attributes, checked by the erupt server */
  view?: View;
  /**
   * raw @Edit attributes, checked by the erupt server; `referenceTableType.dependColumn` (the picked model's
   * column holding the `dependField` value) is written into the build for the erupt server
   */
  edit?: Edit & { referenceTableType?: ReferenceTableType & { dependColumn?: string } };
  /** a form-only element (DIVIDE, CALLOUT, EMPTY, GROUP): in the build, never read or written */
  virtual?: boolean;
  // the field's own code, run by the node when the server invokes it with the form's values
  /** CHOICE / MULTI_CHOICE: the options, `{value: label}` or `[value, label]` pairs; TAGS: the tags */
  fetch?: (form: Json) => Awaitable<Record<string, string> | [unknown, string][] | string[]>;
  /** any field: run when its value changes in the form */
  onchange?: (form: Json) => Awaitable<{ formData?: Json; editExpr?: Json }>;
  /** AUTO_COMPLETE: the suggestions for what was typed */
  complete?: (form: Json, typed: string) => Awaitable<unknown[]>;
  /** BUTTON: run on a click; `eval` is executed as JavaScript in the browser, so only return code you wrote */
  click?: (form: Json) => Awaitable<{ eval?: string; formData?: Json; editExpr?: Json }>;
}

export interface RefOptions extends FieldOptions {
  /** the referenced model's field shown in the UI (default "name") */
  label?: string;
  /** the referenced model's parent field: turns the picker into a tree */
  tree?: string;
}

/** One column. Create it with the `field.*` factories. */
export class Field {
  name = "";
  /** holds a JSON value (MULTI_CHOICE array, KEY_VALUE object, picked keys): SQL repositories store it as JSON text */
  json = false;

  constructor(
    readonly title: string,
    /** null for the primary key */
    readonly type: string | null,
    readonly options: FieldOptions = {},
    readonly choices: Record<string, string> | null = null,
    readonly target: Model | null = null,
    readonly label = "name",
    readonly tree: string | null = null,
  ) {}

  get pk(): boolean {
    return this.type === null;
  }

  get search(): boolean {
    return !!this.options.search;
  }

  get sortable(): boolean {
    return !!this.options.sortable;
  }

  get notNull(): boolean {
    return !!this.options.notNull;
  }

  get form(): boolean {
    return this.options.form !== false;
  }

  get virtual(): boolean {
    return !!this.options.virtual || this.type === "BUTTON";
  }

  get isReference(): boolean {
    return REFERENCES.includes(this.type!);
  }

  get isCollection(): boolean {
    return COLLECTIONS.includes(this.type!);
  }

  /** The field as declared (PROTOCOL.md §12.3): the server completes the rest from Java's defaults. */
  build(): Json {
    if (this.pk) {
      return { fieldName: this.name, fieldReturnName: "number", componentValue: null, eruptFieldJson: { edit: { title: "", type: "NUMBER" } } };
    }
    const type = this.type!;
    // a DATE_TIME is a DATE whose dateType says so; a DATE says it too, as AUTO is the node's to resolve
    const edit: Json = { title: this.title, type: type === "DATE_TIME" ? "DATE" : type };
    if (type === "DATE" || type === "DATE_TIME") edit.dateType = { type };
    if (this.notNull) edit.notNull = true;
    if (!this.form) edit.show = false;
    if (this.search) edit.search = { value: true };
    const view: Json = { title: this.title };
    if (this.sortable) view.sortable = true;
    let returnName = RETURN_NAMES[type] ?? "String";
    if (type === "REFERENCE_TABLE") edit.referenceTableType = { id: this.target!.pk, label: this.label };
    else if (type === "REFERENCE_TREE") edit.referenceTreeType = { id: this.target!.pk, label: this.label, pid: this.tree };
    if (this.isReference || this.isCollection) {
      // the server lists a CHECKBOX by the view column, a TAB_TREE by the target's own tree
      returnName = this.target!.name;
      view.column = this.label;
    }
    if (this.options.fetch && FETCHED[type]) edit[FETCHED[type]] = { fetchHandler: ["invoke"] };
    if (this.options.onchange) edit.onchange = "invoke";
    merge(edit, (this.options.edit ?? {}) as Json);
    merge(view, (this.options.view ?? {}) as Json);
    // a BUTTON is a form element only: no table column
    const views = this.options.table !== false && type !== "BUTTON" ? [view] : [];
    // CHOICE, or MULTI_CHOICE over a JSON array
    const options = this.choices
      ? Object.entries(this.choices).map(([value, label]) => ({ value: String(value), label, desc: null, color: null, disable: false }))
      : null;
    return { fieldName: this.name, fieldReturnName: returnName, componentValue: options, eruptFieldJson: { edit, views } };
  }

  /**
   * A JSON value as the server sends it (PROTOCOL.md §12.4) to the value the repository stores: a date as its
   * wall-clock string, a key as its key type. The server has checked it; a key in a path segment, a delete body or
   * an operation's ids arrives as the browser sent it, so it may fail here.
   */
  coerce(value: unknown): unknown {
    if (this.isReference) return this.target!.fields[this.target!.pk!].coerce(value);
    if (this.isCollection) {
      if (value == null) return [];
      if (!Array.isArray(value)) throw new Error("must be a list");
      const pk = this.target!.fields[this.target!.pk!];
      return value.map((v) => pk.coerce(v));
    }
    if (value === null || value === undefined || value === "") return null;
    if (this.pk) return toInteger(value);
    if (this.json) return value;
    switch (this.type) {
      case "NUMBER":
      case "RATE":
      case "SLIDER":
        return toNumber(value);
      case "DATE_TIME":
        return formatDateTime(parseDateTime(value));
      case "DATE":
        return formatDateTime(parseDateTime(value)).slice(0, 10);
      default:
        return value;
    }
  }
}

function toInteger(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) return Math.trunc(value);
  if (typeof value === "boolean") return Number(value);
  if (typeof value === "string" && /^\s*[+-]?\d+\s*$/.test(value)) return Number.parseInt(value, 10);
  throw new Error(`illegal integer '${value}'`);
}

function toNumber(value: unknown): number {
  const number = typeof value === "string" && value.trim() ? Number(value) : typeof value === "boolean" ? Number(value) : value;
  if (typeof number !== "number" || !Number.isFinite(number)) throw new Error(`illegal number '${value}'`);
  return number;
}

interface WallClock {
  y: number;
  mo: number;
  d: number;
  h: number;
  mi: number;
  s: number;
  ms: number;
}

const DATE_INPUT = /^(\d{4})-(\d{1,2})-(\d{1,2})(?: (\d{1,2}):(\d{1,2})(?::(\d{1,2})(?:\.(\d{1,6}))?)?)?$/;

/** The inputs Python's SDK accepts: `YYYY-MM-DD[ HH:MM[:SS[.ffffff]]]`, `T` for the space, trailing `Z`. */
function parseDateTime(value: unknown): WallClock {
  const match = DATE_INPUT.exec(String(value).replaceAll("T", " ").replace(/Z+$/, ""));
  if (match) {
    const [y, mo, d, h, mi, s] = match.slice(1, 7).map((x) => Number(x ?? 0));
    const ms = Math.floor(Number((match[7] ?? "0").padEnd(6, "0")) / 1000);
    const days = new Date(Date.UTC(y, mo, 0)).getUTCDate();
    if (mo >= 1 && mo <= 12 && d >= 1 && d <= days && h < 24 && mi < 60 && s < 60) return { y, mo, d, h, mi, s, ms };
  }
  throw new Error(`illegal date '${value}'`);
}

const pad = (n: number, width = 2) => String(n).padStart(width, "0");

function formatDateTime(t: WallClock): string {
  return `${pad(t.y, 4)}-${pad(t.mo)}-${pad(t.d)}T${pad(t.h)}:${pad(t.mi)}:${pad(t.s)}.${pad(t.ms, 3)}`;
}

/** A stored value as the browser expects it; a Date is read as UTC wall-clock time. */
export function toJsonValue(value: unknown, type: string | null): unknown {
  if (value instanceof Date) {
    const iso = value.toISOString().slice(0, 23);
    return type === "DATE" ? iso.slice(0, 10) : iso;
  }
  return value;
}

/** Column factories. `title` labels both the table column and the form input. */
export const field = {
  pk: () => new Field("", null),
  /** any supported edit type; prefer the named factories */
  of: (type: EditType, title: string, options?: FieldOptions) => {
    checkEnum(EditTypeValues, type, `field ${title}.type`);
    return new Field(title, type, options);
  },
  input: (title: string, options?: FieldOptions) => new Field(title, "INPUT", options),
  textarea: (title: string, options?: FieldOptions) => new Field(title, "TEXTAREA", options),
  number: (title: string, options?: FieldOptions) => new Field(title, "NUMBER", options),
  boolean: (title: string, options?: FieldOptions) => new Field(title, "BOOLEAN", options),
  date: (title: string, options?: FieldOptions) => new Field(title, "DATE", options),
  dateTime: (title: string, options?: FieldOptions) => new Field(title, "DATE_TIME", options),
  /** a select over `{value: label}`, or over what `options.fetch` returns */
  choice: (title: string, choices: Record<string, string>, options?: FieldOptions) =>
    new Field(title, "CHOICE", options, pairs(choices)),
  /**
   * a JSON value: an array (MULTI_CHOICE, its options in `choices` or `options.fetch`) or an object (KEY_VALUE,
   * set the edit type in `options.edit`)
   */
  json: (title: string, options?: FieldOptions, choices?: Record<string, string>) => {
    const f = new Field(title, choices || options?.fetch ? "MULTI_CHOICE" : "INPUT", options, pairs(choices));
    f.json = true;
    return f;
  },
  /** a record of `target`: the repository stores its primary key, the UI shows `label` */
  ref: (target: Model, title: string, options: RefOptions = {}) =>
    new Field(title, options.tree ? "REFERENCE_TREE" : "REFERENCE_TABLE", options, null, target,
      options.label ?? "name", options.tree ?? null),
  /** records of `target` picked by checkboxes: the repository stores the JSON list of their keys */
  checkbox: (target: Model, title: string, options: RefOptions = {}) => collection("CHECKBOX", target, title, options),
  /** records of `target` picked in a transfer box, stored as `checkbox` stores them */
  transfer: (target: Model, title: string, options: RefOptions = {}) => collection("TRANSFER", target, title, options),
  /** records of `target` picked in its own tree (`erupt.tree`), stored as `checkbox` stores them */
  tabTree: (target: Model, title: string, options: RefOptions = {}) => collection("TAB_TREE", target, title, options),
  /** a form-only button whose `click` runs on the node */
  button: (title: string, click: NonNullable<FieldOptions["click"]>, options?: FieldOptions) =>
    new Field(title, "BUTTON", { ...options, click }),
};

const pairs = (choices?: Record<string, string>) => (choices && Object.keys(choices).length ? { ...choices } : null);

function collection(type: string, target: Model, title: string, options: RefOptions): Field {
  const f = new Field(title, type, options, null, target, options.label ?? "name");
  f.json = true;
  return f;
}

/** What an operation handler receives. */
export interface OperationContext {
  /** selected records as the repository returned them; empty for BUTTON mode */
  rows: EruptRecord[];
  /** coerced form values, or null without a form */
  param: EruptRecord | null;
  repo: Repository;
  model: Model;
  user: User | null;
}

/** A returned string is executed as JavaScript in the browser, so only return code you wrote. */
export type OperationHandler = (op: OperationContext) => unknown;

export interface OperationOptions {
  /** defaults to the key in `operations` */
  code?: string;
  /** SINGLE (row button), MULTI (row and toolbar, default), MULTI_ONLY (toolbar), BUTTON (toolbar, no rows) */
  mode?: RowOperationMode;
  icon?: string;
  tip?: string;
  /** false skips the confirm dialog, a string replaces its text */
  confirm?: boolean | string;
  /** a model whose fields are asked for before running */
  form?: Model;
  /** hides the operation and refuses to run it */
  show?: (user: User | null) => boolean;
  /** browser-side JS over `item` that disables (or hides) the row button */
  ifExpr?: string;
  /** raw @RowOperation attributes, checked by the erupt server */
  raw?: RowOperation;
}

export class Operation {
  code = "";

  constructor(readonly title: string, readonly options: OperationOptions, readonly handler: OperationHandler) {
    checkEnum(RowOperationModeValues, options.mode ?? "MULTI", `operation ${title}.mode`);
  }

  get mode(): RowOperationMode {
    return this.options.mode ?? "MULTI";
  }

  get form(): Model | null {
    return this.options.form ?? null;
  }

  visible(user: User | null): boolean {
    return !this.options.show || !!this.options.show(user);
  }

  build(): Json {
    const o = this.options;
    const tpl: Json = {
      code: this.code, title: this.title, mode: this.mode, tip: o.tip ?? "", ifExpr: o.ifExpr ?? "",
      eruptClass: this.form ? this.form.name : "void",
    };
    if (o.icon) tpl.icon = o.icon;
    if (o.confirm === false) tpl.callHint = ""; // the browser runs it without asking
    else if (typeof o.confirm === "string") tpl.callHint = o.confirm;
    return merge(tpl, (o.raw ?? {}) as Json);
  }
}

/** Declare a row operation; pass it in `model(..., { operations })`. */
export function operation(title: string, handler: OperationHandler): Operation;
export function operation(title: string, options: OperationOptions, handler: OperationHandler): Operation;
export function operation(title: string, a: OperationOptions | OperationHandler, b?: OperationHandler): Operation {
  return typeof a === "function" ? new Operation(title, {}, a) : new Operation(title, a, b!);
}

/**
 * Hooks around a model's data, as erupt's Java `DataProxy`: implement what you need and pass it as
 * `model(..., { dataProxy })`. A record is what the repository stores, a row what the browser reads; change them
 * in place. Throw `Fail` to refuse with a message.
 */
export interface DataProxy {
  /** default values of the search bar, `condition[field] = value` */
  searchCondition?(condition: Record<string, unknown>): void;
  /**
   * SQL ANDed to a table page's WHERE, as written: `"status <> 'deleted'"`, or with its values bound,
   * `["owner = ?", [uid]]`. `conditions` are the search bar's. Only SQL repositories apply it.
   */
  beforeFetch?(conditions: Cond[]): Awaitable<string | [string, unknown[]] | void>;
  /** the rows of a table page, before they are sent */
  afterFetch?(rows: EruptRecord[]): Awaitable<void>;
  /** the values a new record's form opens with */
  addBehavior?(record: EruptRecord): Awaitable<void>;
  /** a record read by its key, for the edit form or the detail view */
  editBehavior?(record: EruptRecord): Awaitable<void>;
  /** a record about to be added or updated */
  validate?(record: EruptRecord): Awaitable<void>;
  beforeAdd?(record: EruptRecord): Awaitable<void>;
  afterAdd?(record: EruptRecord): Awaitable<void>;
  beforeUpdate?(record: EruptRecord): Awaitable<void>;
  afterUpdate?(record: EruptRecord): Awaitable<void>;
  beforeDelete?(record: EruptRecord): Awaitable<void>;
  afterDelete?(record: EruptRecord): Awaitable<void>;
}

/**
 * A `@Vis` view as declared. `filter` (one SQL string or several, ANDed as written) and `orderBy` (as the
 * model's) are applied by the node when the table is read for that view, and kept out of the build, as Java
 * keeps them `@Transient`. A view without a `code` is addressed by its title.
 */
export type ModelVis = Vis & { filter?: string | string[]; orderBy?: string };

/**
 * A drill as declared: a button on each row opening `link.linkErupt` filtered to the rows whose `link.joinColumn`
 * holds the row's `link.column` (`id` by default). The erupt server reads the source row and sends that join as a
 * condition (PROTOCOL.md §12.4); `link.linkCondition` adds SQL as written, applied by the node. A drill without a
 * `code` is addressed by its title.
 */
export type ModelDrill = Omit<Drill, "link"> & { link: Link & { linkErupt: string; column?: string; joinColumn: string } };

export interface ModelOptions {
  /** display name; not sent to the browser (the menu names the page) */
  title?: string;
  /** switch features off: `{ delete: false }`; the erupt server enforces them */
  power?: Power;
  /** default table order, applied by the node: `"views desc, id"` */
  orderBy?: string;
  /** raw @Erupt attributes (`{ layout: { pageSize: 30 } }`), completed and checked by the erupt server */
  erupt?: Omit<Erupt, "vis" | "drills"> & { vis?: ModelVis[]; drills?: ModelDrill[] };
  operations?: Record<string, Operation>;
  /** one DataProxy or several, run around every read and write of the model */
  dataProxy?: DataProxy | DataProxy[];
}

export class Model {
  /** stored and served */
  readonly fields: Record<string, Field> = {};
  /** every field in order, virtual ones included, for the build */
  readonly declared: Field[] = [];
  readonly operations: Record<string, Operation> = {};
  /** the rights the model switches off */
  readonly power: Power;
  /** null: only usable as an operation form */
  readonly pk: string | null;
  readonly orderBy: [string, boolean][];
  readonly proxies: DataProxy[];
  /** view code -> the filters and order the node applies to that view's table */
  readonly vis = new Map<string, [[string, unknown[]][], [string, boolean][]]>();
  /** drill code -> its linkCondition, which the node adds to a drilled table */
  readonly drills = new Map<string, string>();
  /** the declared @Erupt attributes, views without their node-only `filter` and `orderBy` */
  private readonly erupt: Erupt;

  constructor(readonly name: string, fields: Record<string, Field>, readonly options: ModelOptions = {}) {
    if (!IDENTIFIER.test(name)) throw new Error(`erupt name '${name}' must be an identifier`);
    const unknown = Object.keys(options.power ?? {}).filter((right) => !POWERS.includes(right));
    if (unknown.length) throw new Error(`model ${name}.power: no right ${unknown.join(", ")}, expected some of ${POWERS.join(", ")}`);
    this.power = { ...options.power };
    const { vis, drills, ...erupt } = options.erupt ?? {};
    const views = (vis ?? []).map(({ filter, orderBy, ...view }) => [{ code: view.title ?? "", ...view }, filter, orderBy] as const);
    this.erupt = vis ? { ...erupt, vis: views.map(([view]) => view) } : erupt;
    if (drills) this.erupt.drills = drills.map((d) => this.pullDrill(d));
    for (const [attr, f] of Object.entries(fields)) {
      if (!(f instanceof Field)) throw new Error(`${name}.${attr}: not a field`);
      if (!IDENTIFIER.test(attr)) throw new Error(`field '${attr}' must be an identifier`);
      const path = `${name}.${attr}`;
      f.name = attr;
      if (f.type !== null && !SUPPORTED.includes(f.type)) throw new Error(`${path}: edit type ${f.type} is not supported yet`);
      // a list of keys matched as text never finds a number: refused instead of searching for nothing
      if (f.search && f.isCollection) throw new Error(`${path}: a ${f.type} holds keys and cannot be searched`);
      if (f.options.edit?.type !== undefined) checkEnum(EditTypeValues, f.options.edit.type, `${path}.edit.type`);
      if (f.isReference || f.isCollection) this.checkReference(f);
      const { fetch, complete, click } = f.options;
      if ((fetch && !FETCHED[f.type!]) || (complete && f.type !== "AUTO_COMPLETE") || (click && f.type !== "BUTTON")) {
        throw new Error(`${path}: fetch, complete and click belong to CHOICE / MULTI_CHOICE / TAGS, AUTO_COMPLETE and BUTTON`);
      }
      this.declared.push(f);
      if (!f.virtual) this.fields[attr] = f;
    }
    for (const [key, op] of Object.entries(options.operations ?? {})) {
      if (!(op instanceof Operation)) throw new Error(`${name}.${key}: not an operation`);
      op.code = op.options.code ?? key;
      if (op.code in this.operations) throw new Error(`${name}: operation code '${op.code}' declared twice`);
      if (op.form && !(op.form instanceof Model)) throw new Error(`${name}.${op.code}: form must be a model`);
      this.operations[op.code] = op;
    }
    const pks = Object.values(this.fields).filter((f) => f.pk);
    if (pks.length > 1) throw new Error(`${name}: at most one field.pk()`);
    this.pk = pks[0]?.name ?? null;
    this.orderBy = this.parseOrder(options.orderBy);
    // the server filters by the tree beside the table (§12.4); the field it names is checked here, where it is written
    const treeField = erupt.linkTree?.field;
    if (treeField && !this.fields[treeField]?.isReference) throw new Error(`${name}: linkTree.field '${treeField}' must be a reference field`);
    for (const [view, filter, orderBy] of views) this.vis.set(view.code, [[filter ?? []].flat().map((sql) => [sql, []]), this.parseOrder(orderBy)]);
    this.proxies = [options.dataProxy ?? []].flat();
    if (!this.proxies.every(isObject)) throw new Error(`${name}: dataProxy must be a DataProxy`);
  }

  /**
   * A drill's `link` goes to the server whole: it reads the source row and joins on `column` / `joinColumn`
   * (§12.4). Its `linkCondition` is the node's query language: kept here, applied to a drilled table.
   */
  private pullDrill(entry: ModelDrill): Drill {
    const link = entry.link ?? {};
    if (!link.joinColumn || !link.linkErupt) throw new Error(`drill '${entry.title}' needs link.linkErupt and link.joinColumn`);
    const drill = { code: entry.title ?? "", ...entry } as Drill;
    this.drills.set(drill.code!, link.linkCondition ?? "");
    return drill;
  }

  /** Run one DataProxy hook on every proxy, in declaration order. */
  async hook(name: Exclude<keyof DataProxy, "searchCondition" | "beforeFetch">, arg: EruptRecord | EruptRecord[]): Promise<void> {
    for (const p of this.proxies) await p[name]?.(arg as never);
  }

  /** The SQL every proxy's `beforeFetch` adds, as `[sql, params]`. */
  async filters(conditions: Cond[]): Promise<[string, unknown[]][]> {
    const filters: [string, unknown[]][] = [];
    for (const p of this.proxies) {
      const sql = await p.beforeFetch?.(conditions);
      if (sql) filters.push(typeof sql === "string" ? [sql, []] : [sql[0], [...sql[1]]]);
    }
    return filters;
  }

  /** `"views desc, id"` -> `[["views", true], ["id", false]]`, fields checked against the model. */
  private parseOrder(orderBy = ""): [string, boolean][] {
    return orderBy.split(",").map((p) => p.trim()).filter(Boolean).map((part) => {
      const words = part.split(/\s+/);
      const direction = words[1]?.toLowerCase();
      if (words.length > 2 || !(words[0] in this.fields) || (direction && direction !== "asc" && direction !== "desc")) {
        throw new Error(`${this.name}: illegal orderBy '${part}'`);
      }
      return [words[0], direction === "desc"];
    });
  }

  private checkReference(f: Field): void {
    const target = f.target;
    if (!(target instanceof Model)) throw new Error(`${this.name}.${f.name}: ref target must be a model`);
    if (target.pk === null) throw new Error(`${this.name}.${f.name}: ${target.name} has no primary key`);
    for (const key of [f.label, ...(f.tree ? [f.tree] : [])]) {
      if (!(key in target.fields)) throw new Error(`${this.name}.${f.name}: ${target.name} has no field '${key}'`);
    }
  }

  buildErupt(operations: Operation[] = []): Json {
    const eruptJson = merge({ primaryKeyCol: this.pk ?? "id", rowOperation: operations.map((op) => op.build()) }, this.erupt as Json);
    return {
      eruptName: this.name,
      eruptJson,
      eruptFieldModels: this.declared.map((f) => f.build()),
      searchCondition: this.searchCondition(),
      extraRow: false,
      tags: {},
    };
  }

  private searchCondition(): Json {
    const condition = {};
    for (const p of this.proxies) p.searchCondition?.(condition);
    return condition;
  }

  buildModel(power: Power, user: User | null): Json {
    const operations = Object.values(this.operations).filter((op) => op.visible(user));
    const forms = Object.fromEntries(operations.filter((op) => op.form).map((op) => [op.code, op.form!.buildErupt()]));
    return {
      eruptModel: this.buildErupt(operations),
      power,
      tabErupts: null,
      combineErupts: null,
      operationErupts: Object.keys(forms).length ? forms : null,
    };
  }
}

/** Declare an erupt model. `name` is what the server addresses (`node.Name`); fields keep their order. */
export function model(name: string, fields: Record<string, Field>, options?: ModelOptions): Model {
  return new Model(name, fields, options);
}
