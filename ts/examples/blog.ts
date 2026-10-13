// A blog admin served from Node.js. Create node 'blog' on the erupt server first, then:
//
//   npm run build && ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 node dist/examples/blog.js
import { field, model, Node, operation, SqliteRepository } from "../src/index.js";

const Category = model("Category", {
  id: field.pk(),
  name: field.input("Name", { search: true, notNull: true }),
  parent: field.number("Parent Id"),
});

const PublishForm = model("PublishForm", {
  publish_date: field.date("Publish Date", { notNull: true }),
}, { title: "Publish Options" });

const Article = model("Article", {
  id: field.pk(),
  title: field.input("Title", { search: true, notNull: true, sortable: true }),
  category: field.ref(Category, "Category", { search: true }),
  topic: field.ref(Category, "Topic", { tree: "parent", table: false }),
  status: field.choice("Status", { draft: "Draft", published: "Published" }, { search: true }),
  views: field.number("Views", { sortable: true }),
  featured: field.boolean("Featured", { search: true }),
  publish_date: field.date("Publish Date", { search: true }),
  review_at: field.dateTime("Review At", { sortable: true }),
  body: field.textarea("Body", { table: false }),
}, {
  orderBy: "id desc",
  operations: {
    publish: operation("Publish", { icon: "fa fa-paper-plane", form: PublishForm, ifExpr: "item.status !== 'published'" },
      (op) => {
        for (const row of op.rows) op.repo.update(row.id, { status: "published", publish_date: op.param!.publish_date });
      }),
    feature: operation("Feature", { mode: "SINGLE", icon: "fa fa-star", confirm: "Feature this article on the home page?" },
      (op) => op.repo.update(op.rows[0].id, { featured: true })),
  },
});

const env = process.env;
const node = new Node("blog", env.ERUPT_ACCESS_TOKEN!, env.ERUPT_SERVER ?? "http://localhost:8080");
node.register(Category, new SqliteRepository("blog.db", "category"));
node.register(Article, new SqliteRepository("blog.db", "article"));
await node.serve(Number(env.PORT ?? 9090));
