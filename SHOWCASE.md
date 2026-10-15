# Showcase spec for every `examples/blog`

One shared model, so the same admin screens can be compared language by language. Field names are the
storage columns; titles are what the UI shows.

## Category (`@Erupt` title "Category")

| field | type | notes |
|---|---|---|
| id | pk, auto | |
| name | INPUT | "Name", search, notNull, sortable |
| parent | NUMBER (key of a Category) | "Parent Id" (plain key column, read by the tree picker) |
| sort | NUMBER | "Sort", sortable |

Seed when empty: 1 Tech (parent null), 2 Python (parent 1), 3 Go (parent 1), 4 Life (parent null), 5 Travel (parent 4).

## Article (`@Erupt` title "Article", orderBy `id desc`)

| field | edit type | attributes |
|---|---|---|
| id | pk, auto | |
| title | INPUT | "Title", search, notNull, sortable, inputType.length 60 |
| summary | TEXTAREA | "Summary", table hidden, textareaType.length 200 |
| category | REFERENCE_TABLE → Category (id/name) | "Category", search |
| topic | REFERENCE_TREE → Category (id/name/pid=parent) | "Topic", table hidden |
| status | CHOICE | "Status", search; vl: draft "Draft", review "In Review", published "Published" |
| tags | TAGS | "Tags", tagsType allowExtension true, joinSeparator "," |
| views | NUMBER | "Views", sortable, numberType min 0 |
| price | NUMBER (decimal) | "Price", numberType min 0, precision 2, prefix "$" |
| rating | RATE | "Rating", rateType count 5, allowHalf true |
| progress | SLIDER | "Progress", sliderType min 0, max 100, step 5 |
| featured | BOOLEAN | "Featured", search |
| color | COLOR | "Theme Color" |
| icon | ICON | "Icon", table hidden |
| publish_date | DATE | "Publish Date", search (range) |
| review_at | DATE_TIME (DATE with dateType.type DATE_TIME) | "Review At", sortable |
| content | HTML_EDITOR | "Content", table hidden |
| notes | MARKDOWN | "Notes", table hidden |
| meta | CODE_EDITOR | "Meta (JSON)", table hidden, codeEditType.language "json" |

Row operations (keep the existing ones):
- **Publish** — MULTI, icon `fa fa-paper-plane`, form { publish_date DATE notNull }, ifExpr `item.status !== 'published'`;
  sets status=published and publish_date.
- **Feature** — SINGLE, icon `fa fa-star`, confirm "Feature this article on the home page?"; sets featured=true.

Seed when empty (3 articles): "Hello Erupt" (category 2, topic 2, published, tags "intro,erupt", views 120,
price 9.9, rating 4.5, progress 100, featured true, color "#1677ff", icon "fa fa-book", publish_date 2026-10-01,
review_at 2026-10-02T10:00:00, content "<p>Hello</p>", notes "# Hello", meta "{\"a\":1}"); "Go Tips" (category 3,
topic 3, review, tags "go", views 30, price 0, rating 3, progress 60); "Weekend Trip" (category 5, topic 5, draft,
views 0, rating 0, progress 10). References are stored as the key only.

Environment: `ERUPT_NODE_NAME` (default `blog`), `ERUPT_ACCESS_TOKEN`, `ERUPT_SERVER`, `PORT`, and `ERUPT_DB`
(SQLite file, default `blog.db`) — every example reads all five.

Not in the spec on purpose (need endpoints SDKs do not serve yet): CHECKBOX, AUTO_COMPLETE, ATTACHMENT, TAB_*,
erupt-level tree / vis views, MULTI_CHOICE.

## Component (`@Erupt` title "Component") — every component that needs no extra endpoint

A second model, menu `<node>.Component`. Storage column per field unless marked *virtual* (no column, never
read or written; the SDK must leave it out of SQL — if it cannot, report it).

| field | edit type | attributes / storage |
|---|---|---|
| id | pk, auto | |
| name | INPUT | "Name", search, notNull |
| intro | CALLOUT | "Guide", *virtual*, calloutType { value "Every component a node can declare without extra endpoints.", style INFO } |
| basic | DIVIDE | "Basic", *virtual* |
| code | HIDDEN | "Code" (string; seeded "C-001"), table hidden |
| roles | MULTI_CHOICE | "Roles", multiChoiceType { type CHECKBOX, vl ADMIN "Admin", USER "User", GUEST "Guest" }, search; **stored as a JSON array of strings** (`["ADMIN","USER"]`), returned as an array |
| langs | MULTI_CHOICE | "Languages", multiChoiceType { type SELECT, vl JAVA "Java", PYTHON "Python", GO "Go", RUST "Rust" }; JSON array |
| attrs | KEY_VALUE | "Attributes", keyValueType { keyPlaceholder "Key", valuePlaceholder "Value" }; **stored as a JSON object** (`{"env":"prod"}`), returned as an object |
| spacer | EMPTY | "", *virtual* |
| extra | DIVIDE | "Extra", *virtual* |
| location | MAP | "Location" (string) |
| signature | SIGNATURE | "Signature" (string, base64 image), table hidden |
| place | GROUP | "Place & Sign", *virtual*, groupType { fields ["location", "signature"] } |

Seed when empty: 2 rows — {name "Sample A", code "C-001", roles ["ADMIN","USER"], langs ["JAVA","GO"], attrs {"env":"prod","tier":"1"}},
{name "Sample B", code "C-002", roles ["GUEST"], langs ["PYTHON"], attrs {}}.

Needs endpoints no SDK serves yet (protocol work, not in the showcase): CHECKBOX, AUTO_COMPLETE, TRANSFER, ATTACHMENT,
TAB_TREE / TAB_TABLE_REFER / TAB_TABLE_ADD, MULTI_FORM, COMBINE, TPL, BUTTON, dynamic choice / tags fetch; PASSWORD
needs server-side masking first.
