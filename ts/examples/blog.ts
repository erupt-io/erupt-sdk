// A blog admin served from Node.js, the shared showcase model (SHOWCASE.md). Create node 'blog' on the erupt
// server first, then:
//
//   npm run build && ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 node dist/examples/blog.js
//
// ERUPT_NODE_NAME (default blog), PORT (default 9090) and ERUPT_DB (default blog.db) are read as well.
import { field, model, Node, operation, type Repository, SqliteRepository } from "../src/index.js";

const Category = model("Category", {
  id: field.pk(),
  name: field.input("Name", { search: true, notNull: true, sortable: true }),
  parent: field.number("Parent Id"),
  sort: field.number("Sort", { sortable: true }),
});

const PublishForm = model("PublishForm", {
  publish_date: field.date("Publish Date", { notNull: true }),
}, { title: "Publish Options" });

// Edit types without a named factory: the storage follows the factory (text or number), the raw edit
// attributes switch the widget
const Article = model("Article", {
  id: field.pk(),
  title: field.input("Title", { search: true, notNull: true, sortable: true, edit: { inputType: { length: 60 } } }),
  summary: field.textarea("Summary", { table: false, edit: { textareaType: { length: 200 } } }),
  category: field.ref(Category, "Category", { search: true }),
  topic: field.ref(Category, "Topic", { tree: "parent", table: false }),
  status: field.choice("Status", { draft: "Draft", review: "In Review", published: "Published" }, { search: true }),
  tags: field.input("Tags", { edit: { type: "TAGS", tagsType: { allowExtension: true, joinSeparator: ",", maxTagCount: 0 } } }),
  views: field.number("Views", { sortable: true, edit: { numberType: { min: 0 } } }),
  price: field.number("Price", { edit: { numberType: { min: 0, precision: 2, prefix: "$" } } }),
  rating: field.number("Rating", { edit: { type: "RATE", rateType: { count: 5, allowHalf: true, character: "" } } }),
  progress: field.number("Progress", { edit: { type: "SLIDER", sliderType: { min: 0, max: 100, step: 5, dots: false, markPoints: [] } } }),
  featured: field.boolean("Featured", { search: true }),
  color: field.input("Theme Color", { edit: { type: "COLOR", colorType: { alpha: false, showText: true, presets: [] } } }),
  icon: field.input("Icon", { table: false, edit: { type: "ICON" } }),
  publish_date: field.date("Publish Date", { search: true }),
  review_at: field.dateTime("Review At", { sortable: true }),
  content: field.input("Content", { table: false, edit: { type: "HTML_EDITOR", htmlEditorType: { value: "CKEDITOR" } } }),
  notes: field.input("Notes", { table: false, edit: { type: "MARKDOWN" } }),
  meta: field.input("Meta (JSON)", { table: false, edit: { type: "CODE_EDITOR", codeEditType: { language: "json", height: 300, hints: [] } } }),
}, {
  orderBy: "id desc",
  power: { importable: true },
  operations: {
    publish: operation("Publish", { icon: "fa fa-paper-plane", form: PublishForm, ifExpr: "item.status !== 'published'" },
      async (op) => {
        for (const row of op.rows) await op.repo.update(row.id, { status: "published", publish_date: op.param!.publish_date });
      }),
    feature: operation("Feature", { mode: "SINGLE", icon: "fa fa-star", confirm: "Feature this article on the home page?" },
      async (op) => {
        await op.repo.update(op.rows[0].id, { featured: true });
      }),
  },
});

// Every component a node can declare without extra endpoints: form-only elements are `virtual`, MULTI_CHOICE and
// KEY_VALUE hold a JSON value (`field.json`)
const Component = model("Component", {
  id: field.pk(),
  name: field.input("Name", { search: true, notNull: true }),
  intro: field.input("Guide", {
    virtual: true,
    edit: { type: "CALLOUT", calloutType: { value: "Every component a node can declare without extra endpoints.", style: "INFO" } },
  }),
  basic: field.input("Basic", { virtual: true, edit: { type: "DIVIDE" } }),
  code: field.input("Code", { table: false, edit: { type: "HIDDEN" } }),
  roles: field.json("Roles", { search: true, edit: { type: "MULTI_CHOICE", multiChoiceType: { type: "CHECKBOX" } } },
    { ADMIN: "Admin", USER: "User", GUEST: "Guest" }),
  langs: field.json("Languages", { edit: { type: "MULTI_CHOICE", multiChoiceType: { type: "SELECT" } } },
    { JAVA: "Java", PYTHON: "Python", GO: "Go", RUST: "Rust" }),
  attrs: field.json("Attributes", { edit: { type: "KEY_VALUE", keyValueType: { keyPlaceholder: "Key", valuePlaceholder: "Value" } } }),
  spacer: field.input("", { virtual: true, edit: { type: "EMPTY" } }),
  extra: field.input("Extra", { virtual: true, edit: { type: "DIVIDE" } }),
  location: field.input("Location", { edit: { type: "MAP" } }),
  signature: field.input("Signature", { table: false, edit: { type: "SIGNATURE" } }),
  place: field.input("Place & Sign", { virtual: true, edit: { type: "GROUP", groupType: { fields: ["location", "signature"] } } }),
});

async function seed(repo: Repository, records: Record<string, unknown>[]) {
  const [total] = await repo.page({ conditions: [], sort: [], offset: 0, limit: 1 });
  if (total === 0) for (const record of records) await repo.add(record);
}

const env = process.env;
const db = env.ERUPT_DB ?? "blog.db";
const categories = new SqliteRepository(db, "category");
const articles = new SqliteRepository(db, "article");
const components = new SqliteRepository(db, "component");
const node = new Node(env.ERUPT_NODE_NAME ?? "blog", env.ERUPT_ACCESS_TOKEN!, env.ERUPT_SERVER ?? "http://localhost:8080");
node.register(Category, categories);
node.register(Article, articles);
node.register(Component, components);
await seed(categories, [
  { id: 1, name: "Tech", parent: null, sort: 1 },
  { id: 2, name: "Python", parent: 1, sort: 1 },
  { id: 3, name: "Go", parent: 1, sort: 2 },
  { id: 4, name: "Life", parent: null, sort: 2 },
  { id: 5, name: "Travel", parent: 4, sort: 1 },
]);
await seed(articles, [
  {
    title: "Hello Erupt", summary: "A first look at erupt nodes.", category: 2, topic: 2, status: "published", tags: "intro,erupt",
    views: 120, price: 9.9, rating: 4.5, progress: 100, featured: true, color: "#1677ff", icon: "fa fa-book",
    publish_date: "2026-10-01", review_at: "2026-10-02T10:00:00.000", content: "<p>Hello</p>", notes: "# Hello", meta: "{\"a\":1}",
  },
  { title: "Go Tips", category: 3, topic: 3, status: "review", tags: "go", views: 30, price: 0, rating: 3, progress: 60, featured: false },
  { title: "Weekend Trip", category: 5, topic: 5, status: "draft", views: 0, rating: 0, progress: 10, featured: false },
]);
await seed(components, [
  { name: "Sample A", code: "C-001", roles: ["ADMIN", "USER"], langs: ["JAVA", "GO"], attrs: { env: "prod", tier: "1" } },
  { name: "Sample B", code: "C-002", roles: ["GUEST"], langs: ["PYTHON"], attrs: {} },
]);
await node.serve(Number(env.PORT ?? 9090));
