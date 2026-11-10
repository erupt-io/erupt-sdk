// The showcase admin served from Node.js that uses every capability of the SDK, as SHOWCASE.md describes it. Create the
// node on the erupt server first, then:
//
//   npm run build && ERUPT_NODE_NAME=showcase ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 node dist/examples/showcase.js
//
// PORT (default 9090) and ERUPT_DB (SQLite file, default showcase.db) are read as well; NODE_DEBUG=showcase shows the
// debug log.
//
// Edit types without a named factory go through `field.of(type, ...)`; form-only elements are `virtual` and take
// their edit type from `edit.type`; MULTI_CHOICE / KEY_VALUE hold JSON (`field.json`).
import { debuglog } from "node:util";
import { currentUser, type DataProxy, type EruptRecord, Fail, field, model, Node, operation, type Repository,
  SqliteRepository } from "../src/index.js";

// ---------------------------------------------------------------- reference data

const Category = model("Category", {
  id: field.pk(),
  name: field.input("Name", { search: true, notNull: true, sortable: true }),
  parent: field.number("Parent Id"),
  sort: field.number("Sort", { sortable: true }),
}, {
  erupt: {
    tree: { pid: "parent" },
    dragSort: { field: "sort" },
    drills: [{ title: "Articles", code: "Articles", link: { linkErupt: "Article", joinColumn: "category" } }],
  },
});

const Author = model("Author", {
  id: field.pk(),
  name: field.input("Name", { search: true, notNull: true }),
  email: field.input("Email", { edit: { inputType: { regex: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$" } } }),
  active: field.boolean("Active", { search: true, notNull: true }),
}, {
  erupt: {
    drills: [{
      title: "Articles", code: "Articles",
      link: { linkErupt: "Article", joinColumn: "author", linkCondition: "status = 'published'" },
    }],
  },
});

const Tag = model("Tag", {
  id: field.pk(),
  name: field.input("Name", { search: true, notNull: true }),
  color: field.of("COLOR", "Color"),
});

const PublishForm = model("PublishForm", {
  publish_date: field.date("Publish Date", { notNull: true }),
}, { title: "Publish Options" });

const AuditLog = model("AuditLog", {
  id: field.pk(),
  action: field.choice("Action", { add: "Add", update: "Update", delete: "Delete" }, { search: true }),
  article: field.input("Article"),
  account: field.input("By", { search: true }),
  at: field.dateTime("At", { sortable: true }),
}, { title: "Audit Log", orderBy: "id desc", power: { add: false, edit: false, delete: false } });

// ---------------------------------------------------------------- the node's own code (invoke)

const CITIES = ["Paris", "Tokyo", "Lisbon", "Austin"];

/** The local wall clock as a DATE_TIME value, to the second. */
function now(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.000`;
}

/** title onchange: suggest a summary while there is none. */
function summaryFromTitle(form: Record<string, any>) {
  return form.title && !form.summary ? { formData: { summary: "About " + form.title } } : {};
}

/** level options: an expert level once the article is read a lot. */
function levels(form: Record<string, any>): Record<string, string> {
  const options: Record<string, string> = { beginner: "Beginner", advanced: "Advanced" };
  if (Number(form.views ?? 0) >= 1000) options.expert = "Expert";
  return options;
}

function preview(form: Record<string, any>) {
  return { eval: "alert(" + JSON.stringify("Preview: " + (form.title ?? "")) + ")" };
}

const debug = debuglog("showcase");

// table rows served so far (after_fetch)
let fetched = 0;

function stampReview(record: EruptRecord): void {
  if (record.status === "review" && !record.review_at) record.review_at = now();
}

// an Audit Log row; `repos` is created with the node below
async function audit(action: string, record: EruptRecord): Promise<void> {
  await repos.AuditLog.add({ action, article: record.title, account: currentUser()?.account ?? null, at: now() });
}

/** Every hook of a data proxy. */
const articleProxy: DataProxy = {
  searchCondition(condition) {
    condition.status = "published";
  },
  beforeFetch() {
    return "status <> 'archived'";
  },
  afterFetch(rows) {
    fetched += rows.length;
    debug("rows fetched so far: %d", fetched);
  },
  addBehavior(record) {
    Object.assign(record, { status: "draft", views: 0, progress: 0 });
  },
  editBehavior() {},
  validate(record) {
    if (record.title === "forbidden") throw new Fail("This title is not allowed");
  },
  beforeAdd: stampReview,
  beforeUpdate: stampReview,
  afterAdd: (record) => audit("add", record),
  afterUpdate: (record) => audit("update", record),
  beforeDelete(record) {
    if (record.status === "published") throw new Fail("Unpublish it first");
  },
  afterDelete: (record) => audit("delete", record),
};

// ---------------------------------------------------------------- the article: every field type and behaviour

const Article = model("Article", {
  id: field.pk(),
  title: field.input("Title", { search: true, notNull: true, sortable: true, edit: { inputType: { length: 60 } }, onchange: summaryFromTitle }),
  summary: field.textarea("Summary", { table: false, edit: { textareaType: { length: 200 } } }),
  author: field.ref(Author, "Author", { search: true }),
  category: field.ref(Category, "Category", { search: true }),
  sub_category: field.ref(Category, "Sub Category", {
    table: false, edit: { referenceTableType: { dependField: "category", dependColumn: "parent" } },
  }),
  topic: field.ref(Category, "Topic", { tree: "parent", table: false }),
  tag_ids: field.checkbox(Tag, "Tags (checkbox)", { table: false }),
  reviewers: field.transfer(Author, "Reviewers", { table: false }),
  sections: field.tabTree(Category, "Sections", { table: false }),
  status: field.choice("Status", { draft: "Draft", review: "In Review", published: "Published", archived: "Archived" }, { search: true }),
  level: field.choice("Level", {}, { fetch: levels }),
  labels: field.of("TAGS", "Labels", { fetch: () => ["hot", "new", "classic"], edit: { tagsType: { allowExtension: true, joinSeparator: "," } } }),
  city: field.of("AUTO_COMPLETE", "City", {
    edit: { autoCompleteType: { triggerLength: 1 } },
    complete: (_form, typed) => CITIES.filter((c) => c.toLowerCase().includes(typed.toLowerCase())),
  }),
  cover: field.of("ATTACHMENT", "Cover", { edit: { attachmentType: { type: "IMAGE", maxLimit: 1 } } }),
  views: field.number("Views", { sortable: true, edit: { numberType: { min: 0 } } }),
  price: field.number("Price", { edit: { numberType: { min: 0, precision: 2, prefix: "$" } } }),
  rating: field.of("RATE", "Rating", { sortable: true, edit: { rateType: { count: 5, allowHalf: true } } }),
  progress: field.of("SLIDER", "Progress", { edit: { sliderType: { min: 0, max: 100, step: 5 } } }),
  featured: field.boolean("Featured", { search: true }),
  color: field.of("COLOR", "Theme Color"),
  icon: field.of("ICON", "Icon", { table: false }),
  publish_date: field.date("Publish Date", { search: true, edit: { search: { value: true, operator: "RANGE" } } }),
  review_at: field.dateTime("Review At", { sortable: true }),
  content: field.of("HTML_EDITOR", "Content", { table: false }),
  notes: field.of("MARKDOWN", "Notes", { table: false }),
  meta: field.of("CODE_EDITOR", "Meta (JSON)", { table: false, edit: { codeEditType: { language: "json" } } }),
  preview: field.button("Preview", preview),
}, {
  orderBy: "id desc",
  power: { importable: true },
  dataProxy: articleProxy,
  erupt: {
    linkTree: { field: "category" },
    vis: [
      { title: "Drafts", code: "Drafts", type: "TABLE", filter: "status = 'draft'", orderBy: "views desc" },
      { title: "Board", code: "Board", type: "BOARD", boardView: { groupField: "status", sumField: "views" } },
      { title: "Calendar", code: "Calendar", type: "CALENDAR", calendarView: { dateField: "publish_date" } },
      { title: "Cards", code: "Cards", type: "CARD", cardView: { coverField: "cover" } },
      { title: "Timeline", code: "Timeline", type: "TIMELINE", timelineView: { dateField: "review_at" } },
    ],
  },
  operations: {
    publish: operation("Publish", { icon: "fa fa-paper-plane", form: PublishForm, ifExpr: "item.status !== 'published'" },
      async (op) => {
        for (const row of op.rows) await op.repo.update(row.id, { status: "published", publish_date: op.param!.publish_date });
      }),
    feature: operation("Feature", { mode: "SINGLE", icon: "fa fa-star", confirm: "Feature this article on the home page?" },
      async (op) => {
        await op.repo.update(op.rows[0].id, { featured: true });
      }),
    archive: operation("Archive", { mode: "MULTI_ONLY", icon: "fa fa-archive", confirm: false },
      async (op) => {
        for (const row of op.rows) await op.repo.update(row.id, { status: "archived" });
      }),
    stats: operation("Stats", { mode: "BUTTON", icon: "fa fa-bar-chart", show: (user) => user?.account === "admin" },
      async (op) => {
        const [total] = await op.repo.page({ conditions: [], sort: [], offset: 0, limit: 1 });
        return `alert('${total} articles')`;
      }),
  },
});

// Layout and JSON-valued components: form-only elements are `virtual`, MULTI_CHOICE and KEY_VALUE hold a JSON value
const Component = model("Component", {
  id: field.pk(),
  name: field.input("Name", { search: true, notNull: true }),
  intro: field.input("Guide", {
    virtual: true, edit: { type: "CALLOUT", calloutType: { value: "Layout and JSON-valued components.", style: "INFO" } },
  }),
  basic: field.input("Basic", { virtual: true, edit: { type: "DIVIDE" } }),
  code: field.of("HIDDEN", "Code", { table: false }),
  roles: field.json("Roles", { search: true, edit: { type: "MULTI_CHOICE", multiChoiceType: { type: "CHECKBOX" } } },
    { ADMIN: "Admin", USER: "User", GUEST: "Guest" }),
  langs: field.json("Languages", { edit: { type: "MULTI_CHOICE", multiChoiceType: { type: "SELECT" } } },
    { JAVA: "Java", PYTHON: "Python", GO: "Go", RUST: "Rust" }),
  attrs: field.json("Attributes", { edit: { type: "KEY_VALUE", keyValueType: { keyPlaceholder: "Key", valuePlaceholder: "Value" } } }),
  spacer: field.input("", { virtual: true, edit: { type: "EMPTY" } }),
  extra: field.input("Extra", { virtual: true, edit: { type: "DIVIDE" } }),
  location: field.of("MAP", "Location"),
  signature: field.of("SIGNATURE", "Signature", { table: false }),
  place: field.input("Place & Sign", { virtual: true, edit: { type: "GROUP", groupType: { fields: ["location", "signature"] } } }),
});

// ---------------------------------------------------------------- buttons, form behaviour, table display, server calls

/** level options follow the kind (choiceType.dependField). */
function levelsByKind(form: Record<string, any>): Record<string, string> {
  return form.kind === "advanced" ? { high: "High", expert: "Expert" } : { low: "Low", mid: "Mid" };
}

function whoami() {
  return { eval: "alert(" + JSON.stringify(currentUser()?.account ?? "") + ")" };
}

const RenameForm = model("RenameForm", {
  name: field.input("New Name", { notNull: true }),
}, { title: "Rename" });

const Playground = model("Playground", {
  id: field.pk(),
  name: field.input("Name", {
    search: true, notNull: true,
    edit: {
      search: { value: true, operator: "LIKE", lockOperator: true },
      inputType: { prefix: [{ value: "@", label: "@" }], suffix: [{ value: ".dev", label: ".dev" }, { value: ".io", label: ".io" }] },
      placeHolder: "a short name", desc: "Shown first in the table",
    },
  }),
  kind: field.choice("Kind", { simple: "Simple", advanced: "Advanced" }, { search: true }),
  level: field.choice("Level", {}, { fetch: levelsByKind, edit: { choiceType: { dependField: "kind" } } }),
  note: field.textarea("Advanced Note", {
    table: false, edit: { dynamic: { dependField: "kind", condition: "value === 'advanced'", match: "SHOW", noMatch: "HIDE" } },
  }),
  code: field.input("Code", { edit: { readOnly: { add: false, edit: true } } }),
  amount: field.number("Amount", { edit: { numberType: { prefix: "$" } }, view: { statistic: "SUM", className: "text-right", width: "120px" } }),
  score: field.number("Score", { view: { statistic: "AVG" } }),
  skills: field.json("Skills", { fetch: () => ({ java: "Java", python: "Python", go: "Go" }) }),
  files: field.of("ATTACHMENT", "Files", { table: false, edit: { attachmentType: { type: "BASE", maxLimit: 3, fileTypes: ["pdf", "txt", "md"] } } }),
  fill: field.button("Fill Sample", () => ({ formData: { name: "sample", kind: "advanced", amount: 42, score: 4 } }),
    { edit: { buttonType: { style: "primary", icon: "fa fa-magic" } } }),
  reset: field.button("Clear", () => ({ formData: { name: "", amount: 0, score: 0 } }),
    { edit: { buttonType: { danger: true, confirm: "Clear the form?" } } }),
  whoami: field.button("Who Am I", whoami, { edit: { buttonType: { fullSpan: true, icon: "fa fa-user" } } }),
}, {
  title: "Buttons & Forms",
  power: { export: false },
  erupt: { layout: { pageSize: 20, tableLeftFixed: 1 } },
  operations: {
    rename: operation("Rename", { mode: "SINGLE", form: RenameForm, tip: "Give the row a new name" }, async (op) => {
      await op.repo.update(op.rows[0].id, { name: op.param!.name });
    }),
    double: operation("Double", { ifExpr: "item.amount > 0", raw: { ifExprBehavior: "HIDE" } }, async (op) => {
      for (const row of op.rows) await op.repo.update(row.id, { amount: Number(row.amount ?? 0) * 2 });
    }),
    reset_amounts: operation("Reset Amounts", { confirm: "Reset the amounts?", raw: { fold: true } }, async (op) => {
      for (const row of op.rows) await op.repo.update(row.id, { amount: 0 });
    }),
    // calls the server back; `node` is created below
    node_info: operation("Node Info", { mode: "BUTTON", icon: "fa fa-info-circle" }, async (op) => {
      const account = op.user?.account ?? "";
      const roles = await node.userInfo().then((info) => (Array.isArray(info?.roles) ? info.roles.length : 0), () => 0);
      const config = await node.config().then((text) => text.length, () => 0);
      return "alert(" + JSON.stringify(`${account}: ${roles} roles, config ${config} chars`) + ")";
    }),
  },
});

// ---------------------------------------------------------------- seed data

const CATEGORIES = [
  { name: "Tech", parent: null, sort: 1 }, { name: "Python", parent: 1, sort: 2 }, { name: "Go", parent: 1, sort: 3 },
  { name: "Life", parent: null, sort: 4 }, { name: "Travel", parent: 4, sort: 5 },
];

const AUTHORS = [
  { name: "Ann", email: "ann@example.com", active: true },
  { name: "Bob", email: "bob@example.com", active: true },
  { name: "Cy", email: "cy@example.com", active: false },
];

const TAGS = [{ name: "intro", color: "#1677ff" }, { name: "guide", color: "#52c41a" }, { name: "news", color: "#fa8c16" }];

const ARTICLES = [
  {
    title: "Hello Erupt", summary: "A first look at erupt nodes", author: 1, category: 2, topic: 2, tag_ids: [1, 2], reviewers: [2],
    sections: [1, 2], status: "published", level: "beginner", labels: "hot,new", city: "Paris", views: 120, price: 9.9, rating: 4.5,
    progress: 100, featured: true, color: "#1677ff", icon: "fa fa-book", publish_date: "2026-10-01",
    review_at: "2026-10-02T10:00:00.000", content: "<p>Hello</p>", notes: "# Hello", meta: "{\"a\":1}",
  },
  {
    title: "Go Tips", author: 2, category: 3, topic: 3, tag_ids: [2], status: "review", level: "advanced", labels: "classic",
    views: 30, price: 0, rating: 3, progress: 60, featured: false,
  },
  { title: "Weekend Trip", author: 3, category: 5, topic: 5, status: "draft", views: 0, rating: 0, progress: 10, featured: false },
];

const PLAYGROUND = [
  { name: "alpha", kind: "simple", level: "low", code: "A-1", amount: 10, score: 3, skills: ["java"] },
  { name: "beta", kind: "advanced", level: "expert", note: "deep dive", code: "B-1", amount: 0, score: 5, skills: ["python", "go"] },
  { name: "gamma", kind: "simple", level: "mid", code: "G-1", amount: 25, score: 4, skills: [] },
];

const COMPONENTS = [
  { name: "Sample A", code: "C-001", roles: ["ADMIN", "USER"], langs: ["JAVA", "GO"], attrs: { env: "prod", tier: "1" } },
  { name: "Sample B", code: "C-002", roles: ["GUEST"], langs: ["PYTHON"], attrs: {} },
];

async function seed(repo: Repository, records: EruptRecord[]): Promise<void> {
  const [total] = await repo.page({ conditions: [], sort: [], offset: 0, limit: 1 });
  if (total === 0) for (const record of records) await repo.add(record);
}

const env = process.env;
const db = env.ERUPT_DB ?? "showcase.db";
const repos = {
  Category: new SqliteRepository(db, "category"),
  Author: new SqliteRepository(db, "author"),
  Tag: new SqliteRepository(db, "tag"),
  Article: new SqliteRepository(db, "article"),
  Component: new SqliteRepository(db, "component"),
  AuditLog: new SqliteRepository(db, "audit_log"),
  Playground: new SqliteRepository(db, "playground"),
};
const node = new Node(env.ERUPT_NODE_NAME ?? "showcase", env.ERUPT_ACCESS_TOKEN!, env.ERUPT_SERVER ?? "http://localhost:8080");
for (const m of [Category, Author, Tag, Article, Component, AuditLog, Playground]) node.register(m, repos[m.name as keyof typeof repos]);
await seed(repos.Category, CATEGORIES);
await seed(repos.Author, AUTHORS);
await seed(repos.Tag, TAGS);
await seed(repos.Article, ARTICLES);
await seed(repos.Component, COMPONENTS);
await seed(repos.Playground, PLAYGROUND);
await node.serve(Number(env.PORT ?? 9090));
