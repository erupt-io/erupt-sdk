# erupt-sdk (TypeScript / Node.js)

Serve Node.js models as an erupt admin UI. Node 22+, zero runtime dependencies.

```ts
import { field, model, Node, SqliteRepository } from "erupt-sdk";

const Article = model("Article", {
  id: field.pk(),
  title: field.input("Title", { search: true, notNull: true, sortable: true }),
  status: field.choice("Status", { draft: "Draft", published: "Published" }, { search: true }),
  publish_date: field.date("Publish Date", { search: true }),
  body: field.textarea("Body", { table: false }),
}, { orderBy: "id desc" });

const node = new Node("blog", process.env.ERUPT_ACCESS_TOKEN!, "http://erupt-server:8080");
node.register(Article, new SqliteRepository("blog.db", "article"));
await node.serve(9090);
```

1. On the erupt server create node `blog` (Node Config) and copy its access token.
2. Add a menu of type `table` with value `blog.Article`.
3. Run the node. The server must reach it on `http://<node ip>:9090`; pass `{ address }` otherwise.

`node.listener` is a plain `(req, res)` handler for any `node:http` server; then call `node.startHeartbeat()`
once it listens and `node.deregister()` on shutdown. `serve()` does all three (deregisters on SIGINT / SIGTERM).

## Fields

`field.pk()`, `field.input`, `field.textarea`, `field.number`, `field.boolean`, `field.date`, `field.dateTime`,
`field.choice(title, { value: label })`, `field.ref(target, title)` and `field.of(editType, title)`.
Options: `search`, `notNull`, `sortable`, `table` (column, default true), `form` (default true), and raw
`view` / `edit` attributes. Model options: `power` (`{ delete: false }`), `orderBy` (`"views desc, id"`,
applied by the node), raw `erupt` attributes (`{ layout: { pageSize: 30 } }`), `operations`.

Raw attributes are typed with the generated `View`, `Edit`, `Erupt`, `RowOperation` interfaces and checked
against the erupt annotation schema when the model is declared, so a misspelt key or enum value throws
at startup instead of silently doing nothing in the browser.

Dates are stored as wall-clock strings: DATE `2026-01-05`, DATE_TIME `2026-01-05T10:30:00.000`.

## References

```ts
const Category = model("Category", { id: field.pk(), name: field.input("Name", { search: true }), parent: field.number("Parent Id") });

const Article = model("Article", {
  id: field.pk(),
  category: field.ref(Category, "Category", { search: true }),    // table picker
  topic: field.ref(Category, "Topic", { tree: "parent" }),        // tree picker over Category.parent
});
```

The repository stores the referenced primary key; the UI shows `label` (default `name`). Register the
referenced model on the same node.

## Row operations

```ts
const PublishForm = model("PublishForm", { publish_date: field.date("Publish Date", { notNull: true }) });

model("Article", { /* ... */ }, {
  operations: {
    publish: operation("Publish", { form: PublishForm, ifExpr: "item.status !== 'published'" }, async (op) => {
      for (const row of op.rows) await op.repo.update(row.id, { status: "published", publish_date: op.param!.publish_date });
    }),
  },
});
```

The key is the operation code. `mode`: `SINGLE` / `MULTI` (default) / `MULTI_ONLY` / `BUTTON`. `confirm: false`
skips the dialog, a string replaces its text. `show: (user) => ...` hides the operation and refuses to run it.
A returned string is executed as JavaScript in the browser, so return only code you wrote.

## Storage

A `Repository` implements `bind`, `page`, `get`, `add`, `update`, `delete` (sync or async);
`MemoryRepository` and `SqliteRepository` (node:sqlite) ship with it. `currentUser()` returns the acting
user inside a repository or operation call.

Not yet: sub-tables (TAB_TABLE_*), TPL operations, depend fields of references, tree models, file upload,
Excel, i18n of messages.

## Development

```bash
npm install
npm test                                   # build + unit tests
npm run conformance                        # the shared protocol suite (conformance/)
node tools/gen-types.mjs <erupt>/schema    # sync schemas, regenerate src/types.ts (--check for CI)
```
