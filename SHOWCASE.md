# Showcase spec for every `examples/showcase`

One shared application that uses **every capability a node SDK has**, so the same admin screens can be compared
language by language and every scenario can be clicked through (and checked by `conformance/showcase.py`).
Field names are the storage columns; titles are what the UI shows. The node speaks protocol v2: it declares,
the server completes, checks and enforces (`erupt-cloud/PROTOCOL.md` §12).

Model names (what the server addresses as `<node>.<Name>`): `Category`, `Author`, `Tag`, `Article`, `Component`,
`AuditLog`, `Playground`; the operation forms `PublishForm` and `RenameForm` are not registered. `conformance/showcase.py` runs every scenario below
against an example: `python3 conformance/showcase.py -- <command that starts examples/showcase>`.

Environment: `ERUPT_NODE_NAME` (default `showcase`), `ERUPT_ACCESS_TOKEN`, `ERUPT_SERVER`, `PORT`, `ERUPT_DB` (SQLite
file, default `showcase.db`). Every example reads all five. Use the SDK's SQLite repository; an SDK without one uses its
memory repository and says so at the top of the file (the SQL-only parts below are then marked as skipped there).
Seed each model only when its table is empty. A reference is stored as the referenced key; CHECKBOX / TAB_TREE /
TRANSFER as the JSON list of keys; MULTI_CHOICE as a JSON array; KEY_VALUE as a JSON object.

## Category (title "Category") — tree, drag sort, drill

`@Erupt`: `tree { pid "parent" }` (the server builds the tree from the rows), `dragSort { field "sort" }` (the
server rewrites `sort`), one drill: title/code `Articles`, link `{ linkErupt "Article", joinColumn "category" }`.

| field | type | notes |
|---|---|---|
| id | pk, auto | |
| name | INPUT | "Name", search, notNull, sortable |
| parent | NUMBER | "Parent Id" (plain key column the tree and the dependent picker read) |
| sort | NUMBER | "Sort", sortable |

Seed: 1 Tech (null), 2 Python (1), 3 Go (1), 4 Life (null), 5 Travel (4); sort = id.

## Author (title "Author") — drill target of a second model

Drill title/code `Articles`, link `{ linkErupt "Article", joinColumn "author", linkCondition }` where the
linkCondition keeps only published articles (`status = 'published'`, in the SDK's query language; an SDK that
cannot express one leaves it out and says so).

| field | type | notes |
|---|---|---|
| id | pk, auto | |
| name | INPUT | "Name", search, notNull |
| email | INPUT | "Email", inputType.regex for an e-mail address (the server checks it) |
| active | BOOLEAN | "Active", search, notNull (renders as a switch) |

Seed: 1 Ann (ann@example.com, true), 2 Bob (bob@example.com, true), 3 Cy (cy@example.com, false).

## Tag (title "Tag") — target of CHECKBOX / TRANSFER

| field | type | notes |
|---|---|---|
| id | pk, auto | |
| name | INPUT | "Name", search, notNull |
| color | COLOR | "Color" |

Seed: 1 intro (#1677ff), 2 guide (#52c41a), 3 news (#fa8c16).

## Publish Options (title "Publish Options", operation form only, not registered)

`publish_date` DATE "Publish Date", notNull.

## Article (title "Article", orderBy `id desc`, power `importable` on) — every field type and behaviour

| field | edit type | attributes |
|---|---|---|
| id | pk, auto | |
| title | INPUT | "Title", search, notNull, sortable, inputType.length 60; **onchange** (below) |
| summary | TEXTAREA | "Summary", table hidden, textareaType.length 200 |
| author | REFERENCE_TABLE → Author (id/name) | "Author", search |
| category | REFERENCE_TABLE → Category (id/name) | "Category", search |
| sub_category | REFERENCE_TABLE → Category (id/name) | "Sub Category", table hidden, referenceTableType { dependField "category", dependColumn "parent" } (dependent picker) |
| topic | REFERENCE_TREE → Category (id/name/pid parent) | "Topic", table hidden |
| tag_ids | CHECKBOX → Tag | "Tags (checkbox)", table hidden |
| reviewers | TRANSFER → Author | "Reviewers", table hidden |
| sections | TAB_TREE → Category | "Sections", table hidden |
| status | CHOICE | "Status", search; draft "Draft", review "In Review", published "Published", archived "Archived" |
| level | CHOICE | "Level", **fetch** (below) |
| labels | TAGS | "Labels", **fetch** (below), tagsType allowExtension true, joinSeparator "," |
| city | AUTO_COMPLETE | "City", **complete** (below), autoCompleteType.triggerLength 1 |
| cover | ATTACHMENT | "Cover", attachmentType { type IMAGE, maxLimit 1 } (the server stores the file; the node stores the path) |
| views | NUMBER | "Views", sortable, numberType.min 0 |
| price | NUMBER (decimal) | "Price", numberType { min 0, precision 2, prefix "$" } |
| rating | RATE | "Rating", rateType { count 5, allowHalf true } |
| progress | SLIDER | "Progress", sliderType { min 0, max 100, step 5 } |
| featured | BOOLEAN | "Featured", search |
| color | COLOR | "Theme Color" |
| icon | ICON | "Icon", table hidden |
| publish_date | DATE | "Publish Date", search (RANGE) |
| review_at | DATE_TIME | "Review At", sortable |
| content | HTML_EDITOR | "Content", table hidden |
| notes | MARKDOWN | "Notes", table hidden |
| meta | CODE_EDITOR | "Meta (JSON)", table hidden, codeEditType.language "json" |
| preview | BUTTON (virtual) | "Preview", **click** (below) |

Code the node runs (`invoke`, PROTOCOL.md §5.5):
- `title` onchange: `{"formData": {"summary": "About " + title}}` when the summary is empty, else nothing.
- `level` fetch: options `beginner` "Beginner", `advanced` "Advanced", plus `expert` "Expert" when the form's
  `views` is 1000 or more.
- `labels` fetch: `["hot", "new", "classic"]`.
- `city` complete: the cities of `["Paris", "Tokyo", "Lisbon", "Austin"]` containing the typed text, case-insensitive.
- `preview` click: `{"eval": "alert('Preview: ' + <title>)"}` with the form's title (escaped as a JS string).

`@Erupt` extras:
- `linkTree { field "category" }`: the category tree beside the table filters it.
- `vis` (the server reads the rows through the table endpoint; a view's filter/orderBy run on the node):
  - `Drafts` — TABLE, filter "status = 'draft'", orderBy "views desc" (SQL; skipped on a memory repository).
  - `Board` — BOARD, boardView { groupField "status", sumField "views" }.
  - `Calendar` — CALENDAR, calendarView { dateField "publish_date" }.
  - `Cards` — CARD, cardView { coverField "cover" }.
  - `Timeline` — TIMELINE, timelineView { dateField "review_at" }.

Data proxy (every hook, in this order of use):
- `search_condition`: the search bar opens with `status = published`.
- `before_fetch`: SQL `status <> 'archived'` (skipped on a memory repository).
- `after_fetch`: nothing visible; increments an in-process "fetched rows" counter logged at debug level.
- `add_behavior`: a new form opens with `status` "draft", `views` 0, `progress` 0.
- `edit_behavior`: nothing.
- `validate`: refuse a `title` equal to "forbidden" with the message "This title is not allowed".
- `before_add` / `before_update`: set `review_at` to now when the status is "review" and it is empty.
- `after_add` / `after_update` / `after_delete`: write an Audit Log row (below).
- `before_delete`: refuse deleting a published article with the message "Unpublish it first".

Row operations:
- **Publish** — MULTI, icon `fa fa-paper-plane`, form Publish Options, ifExpr `item.status !== 'published'`; sets
  status=published and publish_date from the form.
- **Feature** — SINGLE, icon `fa fa-star`, confirm "Feature this article on the home page?"; sets featured=true.
- **Archive** — MULTI_ONLY (toolbar only), confirm off; sets status=archived (archived rows disappear through
  `before_fetch`).
- **Stats** — BUTTON (no rows), shown only to the account `admin`; returns the script
  `alert('<n> articles')` with the article count.

Seed (3 articles): "Hello Erupt" (author 1, category 2, sub_category none, topic 2, tag_ids [1,2], reviewers [2],
sections [1,2], published, level beginner, labels "hot,new", city "Paris", views 120, price 9.9, rating 4.5,
progress 100, featured true, color "#1677ff", icon "fa fa-book", publish_date 2026-10-01, review_at
2026-10-02T10:00:00, content "<p>Hello</p>", notes "# Hello", meta "{\"a\":1}"); "Go Tips" (author 2, category 3,
topic 3, tag_ids [2], review, level advanced, labels "classic", views 30, price 0, rating 3, progress 60);
"Weekend Trip" (author 3, category 5, topic 5, draft, views 0, rating 0, progress 10).

## Component (title "Component") — layout and JSON-valued components

Storage column per field unless marked *virtual* (no column, never read or written).

| field | edit type | attributes / storage |
|---|---|---|
| id | pk, auto | |
| name | INPUT | "Name", search, notNull |
| intro | CALLOUT | "Guide", *virtual*, calloutType { value "Layout and JSON-valued components.", style INFO } |
| basic | DIVIDE | "Basic", *virtual* |
| code | HIDDEN | "Code" (string), table hidden |
| roles | MULTI_CHOICE | "Roles", multiChoiceType { type CHECKBOX }, ADMIN "Admin", USER "User", GUEST "Guest", search; JSON array |
| langs | MULTI_CHOICE | "Languages", multiChoiceType { type SELECT }, JAVA "Java", PYTHON "Python", GO "Go", RUST "Rust"; JSON array |
| attrs | KEY_VALUE | "Attributes", keyValueType { keyPlaceholder "Key", valuePlaceholder "Value" }; JSON object |
| spacer | EMPTY | "", *virtual* |
| extra | DIVIDE | "Extra", *virtual* |
| location | MAP | "Location" (string) |
| signature | SIGNATURE | "Signature" (string, base64 image), table hidden |
| place | GROUP | "Place & Sign", *virtual*, groupType { fields ["location", "signature"] } |

Seed: {name "Sample A", code "C-001", roles ["ADMIN","USER"], langs ["JAVA","GO"], attrs {"env":"prod","tier":"1"}},
{name "Sample B", code "C-002", roles ["GUEST"], langs ["PYTHON"], attrs {}}.

## Audit Log (title "Audit Log", power `add`, `edit`, `delete` off) — a read-only model the hooks write

| field | type | notes |
|---|---|---|
| id | pk, auto | |
| action | CHOICE | "Action", search; add "Add", update "Update", delete "Delete" |
| article | INPUT | "Article" (the article's title) |
| account | INPUT | "By", search (the acting user's account, `current_user`) |
| at | DATE_TIME | "At", sortable |

orderBy `id desc`; no seed.

## Playground (title "Buttons & Forms") — custom buttons, form behaviour, table display, server calls

`@Erupt`: power `export` off (a right switched off besides the read-only audit log), layout { pageSize 20,
tableLeftFixed 1 }.

| field | edit type | attributes |
|---|---|---|
| id | pk, auto | |
| name | INPUT | "Name", notNull, search with operator LIKE and lockOperator true, inputType { prefix [{value "@", label "@"}], suffix [{value ".dev", label ".dev"}, {value ".io", label ".io"}] } (selectable affixes), placeHolder "a short name", desc "Shown first in the table" |
| kind | CHOICE | "Kind", search; simple "Simple", advanced "Advanced" |
| level | CHOICE | "Level", **fetch** with choiceType.dependField "kind" (cascading: the options follow the kind) |
| note | TEXTAREA | "Advanced Note", table hidden, dynamic { dependField "kind", condition "value === 'advanced'", match SHOW, noMatch HIDE } |
| code | INPUT | "Code", readOnly { add false, edit true } (written once, then read-only) |
| amount | NUMBER | "Amount", numberType.prefix "$", view { statistic SUM, className "text-right", width "120px" } |
| score | NUMBER | "Score", view.statistic AVG |
| skills | MULTI_CHOICE | "Skills", **fetch** (options computed by the node); JSON array |
| files | ATTACHMENT | "Files", attachmentType { type BASE, maxLimit 3, fileTypes ["pdf", "txt", "md"] }, table hidden |
| fill | BUTTON (virtual) | "Fill Sample", buttonType { style "primary", icon "fa fa-magic" }, **click** (below) |
| reset | BUTTON (virtual) | "Clear", buttonType { danger true, confirm "Clear the form?" }, **click** (below) |
| whoami | BUTTON (virtual) | "Who Am I", buttonType { fullSpan true, icon "fa fa-user" }, **click** (below) |

Code the node runs:
- `level` fetch (depends on `kind`): `low` "Low", `mid` "Mid" for simple (or no kind); `high` "High", `expert` "Expert" for advanced.
- `skills` fetch: `java` "Java", `python` "Python", `go` "Go".
- `fill` click: `{"formData": {"name": "sample", "kind": "advanced", "amount": 42, "score": 4}}` — the button fills the form.
- `reset` click: `{"formData": {"name": "", "amount": 0, "score": 0}}`.
- `whoami` click: `{"eval": "alert('<account>')"}` with the acting user's account (`current_user`).

Row operations:
- **Rename** — SINGLE, form RenameForm (`name` INPUT "New Name", notNull), tip "Give the row a new name"; sets `name`.
- **Double** — MULTI, ifExpr `item.amount > 0`, ifExprBehavior HIDE (the button disappears on rows without an
  amount); doubles `amount`.
- **Reset Amounts** — MULTI, fold true (in the "more" menu), confirm "Reset the amounts?"; sets `amount` 0.
- **Node Info** — BUTTON; calls the server back (`user_info()` and `config()`) and returns
  `alert('<account>: <n> roles, config <m> chars')` (n = roles in the user info, m = length of the node config text,
  0 when either call fails).

Seed: {name "alpha", kind "simple", level "low", code "A-1", amount 10, score 3, skills ["java"]},
{name "beta", kind "advanced", level "expert", note "deep dive", code "B-1", amount 0, score 5, skills ["python","go"]},
{name "gamma", kind "simple", level "mid", code "G-1", amount 25, score 4, skills []}.

## Not in the showcase

Needs endpoints no SDK serves yet: a TPL row operation (a page the node would render), TAB_TABLE_REFER / TAB_TABLE_ADD, MULTI_FORM, COMBINE, TPL, GANTT / MAP / CUBE
views, KEY_VALUE inside a search, PASSWORD (needs server-side masking first).
