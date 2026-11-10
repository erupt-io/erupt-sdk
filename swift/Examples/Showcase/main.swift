// The showcase admin served from Swift that uses every capability of the SDK, as SHOWCASE.md describes it (the Python
// reference is python/examples/showcase.py). Create the node on the erupt server first, then:
//
//   ERUPT_NODE_NAME=showcase ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 swift run Showcase
//
// Environment: ERUPT_NODE_NAME (default showcase), ERUPT_ACCESS_TOKEN, ERUPT_SERVER, PORT (default 9090) and ERUPT_DB,
// the SQLite file the records live in (default showcase.db). Set ERUPT_DEBUG to log the rows the Article table reads.
// The Playground model calls the server back (Node Info: `userInfo()` and `config()`).
//
// Edit types without a shortcut are declared as the storage kind they hold with the edit type in `type:` and its
// options in `edit:`. Form-only elements (CALLOUT, DIVIDE, EMPTY, GROUP) are `virtual:` fields; MULTI_CHOICE and
// KEY_VALUE are `.json`. `@Transient` attributes go beside the annotation: a view's filter / orderBy in
// `visQuery:`, a drill's join column in `drillJoin:`, a dependent picker's column in `dependColumn:`.
import EruptSDK
import EruptSQLite
import Foundation

let env = ProcessInfo.processInfo.environment

/// Now as a DATE_TIME value, to the second.
func now() -> JSON {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.000"
    return .string(f.string(from: Date()))
}

// ---------------------------------------------------------------- the node's own code (invoke)

let cities = ["Paris", "Tokyo", "Lisbon", "Austin"]

/// title onchange: suggest a summary while there is none.
func summaryFromTitle(_ form: Record) -> FormChange {
    let title = form["title"]?.string ?? "", summary = form["summary"]?.string ?? ""
    return !title.isEmpty && summary.isEmpty ? FormChange(formData: ["summary": .string("About " + title)]) : FormChange()
}

/// level options: an expert level once the article is read a lot.
func levels(_ form: Record) -> [(value: String, label: String)] {
    var options = [(value: "beginner", label: "Beginner"), (value: "advanced", label: "Advanced")]
    if (form["views"]?.double ?? 0) >= 1000 { options.append((value: "expert", label: "Expert")) }
    return options
}

/// preview click: the title as a JavaScript string literal (JSON text is one).
func preview(_ form: Record) -> FormChange {
    FormChange(eval: "alert(" + JSON.string("Preview: " + (form["title"]?.string ?? "")).serialized() + ")")
}

/// Every hook of a data proxy; `audit` is the Audit Log repository the writes are logged to.
final class ArticleProxy: DataProxy {
    let audit: Repository
    private let lock = NSLock()
    private var fetched = 0

    init(audit: Repository) { self.audit = audit }

    func searchCondition(_ condition: inout [String: JSON]) { condition["status"] = "published" }

    func beforeFetch(_ conditions: [Cond]) throws -> SQLFilter? { "status <> 'archived'" }

    func afterFetch(_ rows: inout [Record]) throws {
        lock.lock()
        fetched += rows.count
        let total = fetched
        lock.unlock()
        if env["ERUPT_DEBUG"] != nil { FileHandle.standardError.write("[showcase] DEBUG rows fetched so far: \(total)\n".data(using: .utf8)!) }
    }

    func addBehavior(_ record: inout Record) throws {
        record["status"] = "draft"
        record["views"] = 0
        record["progress"] = 0
    }

    func validate(_ record: Record) throws {
        if record["title"] == "forbidden" { throw EruptFailure("This title is not allowed") }
    }

    func beforeAdd(_ record: inout Record) throws { stampReview(&record) }

    func beforeUpdate(_ record: inout Record) throws { stampReview(&record) }

    func afterAdd(_ record: Record) throws { try log("add", record) }

    func afterUpdate(_ record: Record) throws { try log("update", record) }

    func beforeDelete(_ record: Record) throws {
        if record["status"] == "published" { throw EruptFailure("Unpublish it first") }
    }

    func afterDelete(_ record: Record) throws { try log("delete", record) }

    private func stampReview(_ record: inout Record) {
        if record["status"] == "review", (record["review_at"] ?? .null) == .null { record["review_at"] = now() }
    }

    private func log(_ action: String, _ record: Record) throws {
        try audit.add([
            "action": .string(action), "article": record["title"] ?? .null,
            "account": User.current?.account.map(JSON.string) ?? .null, "at": now(),
        ])
    }
}

do {
    // ------------------------------------------------------------ reference data

    let category = try Model(
        "Category",
        erupt: Erupt(
            dragSort: DragSort(field: "sort"),
            drills: [Drill(code: "Articles", link: Link(linkErupt: "Article"), title: "Articles")],
            tree: Tree(pid: "parent")),
        drillJoin: ["Articles": DrillJoin(joinColumn: "category")]
    ) {
        Field("id", pk: true)
        Field("name", "Name", search: true, notNull: true, sortable: true)
        Field("parent", "Parent Id", .number)
        Field("sort", "Sort", .number, sortable: true)
    }

    let author = try Model(
        "Author",
        erupt: Erupt(drills: [
            Drill(code: "Articles", link: Link(linkCondition: "status = 'published'", linkErupt: "Article"), title: "Articles")
        ]),
        drillJoin: ["Articles": DrillJoin(joinColumn: "author")]
    ) {
        Field("id", pk: true)
        Field("name", "Name", search: true, notNull: true)
        Field("email", "Email", edit: Edit(inputType: InputType(regex: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#)))
        Field("active", "Active", .bool, search: true, notNull: true)
    }

    let tag = try Model("Tag") {
        Field("id", pk: true)
        Field("name", "Name", search: true, notNull: true)
        Field("color", "Color", type: .color)
    }

    let publishForm = try Model("PublishForm", title: "Publish Options") {
        Field("publish_date", "Publish Date", .date, notNull: true)
    }

    let auditLog = try Model("AuditLog", title: "Audit Log", power: ["add": false, "edit": false, "delete": false], orderBy: "id desc") {
        Field("id", pk: true)
        Field("action", "Action", search: true, choices: ["add": "Add", "update": "Update", "delete": "Delete"])
        Field("article", "Article")
        Field("account", "By", search: true)
        Field("at", "At", .dateTime, sortable: true)
    }

    let db = try SQLiteExecutor(path: env["ERUPT_DB"] ?? "showcase.db")
    let audits = try SQLRepository(db, table: "audit_log", autoCreate: true)

    // ------------------------------------------------------------ the article: every field type and behaviour

    let article = try Model(
        "Article", power: ["importable": true], orderBy: "id desc",
        erupt: Erupt(
            linkTree: LinkTree(field: "category"),
            vis: [
                Vis(code: "Drafts", title: "Drafts", type: .table),
                Vis(boardView: BoardView(groupField: "status", sumField: "views"), code: "Board", title: "Board", type: .board),
                Vis(calendarView: CalendarView(dateField: "publish_date"), code: "Calendar", title: "Calendar", type: .calendar),
                Vis(cardView: CardView(coverField: "cover"), code: "Cards", title: "Cards", type: .card),
                Vis(code: "Timeline", timelineView: TimelineView(dateField: "review_at"), title: "Timeline", type: .timeline),
            ]),
        dataProxy: [ArticleProxy(audit: audits)],
        visQuery: ["Drafts": VisQuery(filter: "status = 'draft'", orderBy: "views desc")]
    ) {
        Field("id", pk: true)
        Field("title", "Title", search: true, notNull: true, sortable: true, edit: Edit(inputType: InputType(length: 60)),
              onchange: summaryFromTitle)
        Field("summary", "Summary", type: .textarea, table: false, edit: Edit(textareaType: TextareaType(length: 200)))
        Field("author", "Author", .ref(author), search: true)
        Field("category", "Category", .ref(category), search: true)
        Field("sub_category", "Sub Category", .ref(category), table: false,
              edit: Edit(referenceTableType: ReferenceTableType(dependField: "category")), dependColumn: "parent")
        Field("topic", "Topic", .tree(category, pid: "parent"), table: false)
        Field("tag_ids", "Tags (checkbox)", .ref(tag), type: .checkbox, table: false)
        Field("reviewers", "Reviewers", .ref(author), type: .transfer, table: false)
        Field("sections", "Sections", .ref(category), type: .tabTree, table: false)
        Field("status", "Status", search: true,
              choices: ["draft": "Draft", "review": "In Review", "published": "Published", "archived": "Archived"])
        Field("level", "Level", fetch: .options(levels))
        Field("labels", "Labels", type: .tags, edit: Edit(tagsType: TagsType(allowExtension: true, joinSeparator: ",")),
              fetch: .tags { _ in ["hot", "new", "classic"] })
        Field("city", "City", type: .autoComplete, edit: Edit(autoCompleteType: AutoCompleteType(triggerLength: 1)),
              complete: { _, typed in cities.filter { $0.lowercased().contains(typed.lowercased()) } })
        Field("cover", "Cover", type: .attachment, edit: Edit(attachmentType: AttachmentType(maxLimit: 1, type: .image)))
        Field("views", "Views", .number, sortable: true, edit: Edit(numberType: NumberType(min: 0)))
        Field("price", "Price", .number, edit: Edit(numberType: NumberType(min: 0, precision: 2, prefix: "$")))
        Field("rating", "Rating", .number, type: .rate, sortable: true, edit: Edit(rateType: RateType(allowHalf: true, count: 5)))
        Field("progress", "Progress", .number, type: .slider, edit: Edit(sliderType: SliderType(max: 100, min: 0, step: 5)))
        Field("featured", "Featured", .bool, search: true)
        Field("color", "Theme Color", type: .color)
        Field("icon", "Icon", type: .icon, table: false)
        Field("publish_date", "Publish Date", .date, search: true, edit: Edit(search: Search(operator: .range)))
        Field("review_at", "Review At", .dateTime, sortable: true)
        Field("content", "Content", type: .htmlEditor, table: false)
        Field("notes", "Notes", type: .markdown, table: false)
        Field("meta", "Meta (JSON)", type: .codeEditor, table: false, edit: Edit(codeEditType: CodeEditorType(language: "json")))
        Field("preview", "Preview", type: .button, click: preview)

        RowAction("publish", "Publish", icon: "fa fa-paper-plane", form: publishForm, ifExpr: "item.status !== 'published'") { op in
            for row in op.rows {
                try op.repo.update(row["id"]!, ["status": "published", "publish_date": op.param!["publish_date"]!])
            }
            return nil
        }
        RowAction("feature", "Feature", mode: .single, icon: "fa fa-star", confirm: "Feature this article on the home page?") { op in
            try op.repo.update(op.rows[0]["id"]!, ["featured": true])
            return nil
        }
        RowAction("archive", "Archive", mode: .multiOnly, icon: "fa fa-archive", confirm: false) { op in
            for row in op.rows { try op.repo.update(row["id"]!, ["status": "archived"]) }
            return nil
        }
        RowAction("stats", "Stats", mode: .button, icon: "fa fa-bar-chart", show: { user in user?.account == "admin" }) { op in
            "alert('\(try op.repo.page(Query(limit: 1)).total) articles')"
        }
    }

    // ------------------------------------------------------------ layout and JSON-valued components

    let component = try Model("Component") {
        Field("id", pk: true)
        Field("name", "Name", search: true, notNull: true)
        Field("intro", "Guide", edit: Edit(
            calloutType: CalloutType(style: .info, value: "Layout and JSON-valued components."), type: .callout), virtual: true)
        Field("basic", "Basic", edit: Edit(type: .divide), virtual: true)
        Field("code", "Code", type: .hidden, table: false)
        Field("roles", "Roles", .json, search: true, choices: ["ADMIN": "Admin", "USER": "User", "GUEST": "Guest"],
              edit: Edit(multiChoiceType: MultiChoiceType(type: .checkbox), type: .multiChoice))
        Field("langs", "Languages", .json, choices: ["JAVA": "Java", "PYTHON": "Python", "GO": "Go", "RUST": "Rust"],
              edit: Edit(multiChoiceType: MultiChoiceType(type: .select), type: .multiChoice))
        Field("attrs", "Attributes", .json, edit: Edit(
            keyValueType: KeyValueType(keyPlaceholder: "Key", valuePlaceholder: "Value"), type: .keyValue))
        Field("spacer", "", edit: Edit(type: .empty), virtual: true)
        Field("extra", "Extra", edit: Edit(type: .divide), virtual: true)
        Field("location", "Location", type: .map)
        Field("signature", "Signature", type: .signature, table: false)
        Field("place", "Place & Sign", edit: Edit(groupType: GroupType(fields: ["location", "signature"]), type: .group), virtual: true)
    }

    // ------------------------------------------------------------ buttons, form behaviour, table display, server calls

    let renameForm = try Model("RenameForm", title: "Rename") {
        Field("name", "New Name", notNull: true)
    }

    /// Set once the node exists: the Node Info operation calls the server back through it.
    final class NodeBox { var node: Node? }
    let nodeBox = NodeBox()

    let playground = try Model(
        "Playground", title: "Buttons & Forms", power: ["export": false],
        erupt: Erupt(layout: Layout(pageSize: 20, tableLeftFixed: 1))
    ) {
        Field("id", pk: true)
        Field("name", "Name", search: true, notNull: true, edit: Edit(
            desc: "Shown first in the table",
            inputType: InputType(prefix: [VL(label: "@", value: "@")], suffix: [VL(label: ".dev", value: ".dev"), VL(label: ".io", value: ".io")]),
            placeHolder: "a short name", search: Search(lockOperator: true, operator: .like)))
        Field("kind", "Kind", search: true, choices: ["simple": "Simple", "advanced": "Advanced"])
        // cascading: the options follow the kind
        Field("level", "Level", edit: Edit(choiceType: ChoiceType(dependField: "kind")), fetch: .options { form in
            form["kind"] == "advanced"
                ? [(value: "high", label: "High"), (value: "expert", label: "Expert")]
                : [(value: "low", label: "Low"), (value: "mid", label: "Mid")]
        })
        Field("note", "Advanced Note", type: .textarea, table: false, edit: Edit(
            dynamic: Dynamic(condition: "value === 'advanced'", dependField: "kind", match: .show, noMatch: .hide)))
        Field("code", "Code", edit: Edit(readOnly: Readonly(add: false, edit: true)))
        Field("amount", "Amount", .number, view: View(className: "text-right", statistic: .sum, width: "120px"),
              edit: Edit(numberType: NumberType(prefix: "$")))
        Field("score", "Score", .number, view: View(statistic: .avg))
        Field("skills", "Skills", .json, fetch: .options { _ in
            [(value: "java", label: "Java"), (value: "python", label: "Python"), (value: "go", label: "Go")]
        })
        Field("files", "Files", type: .attachment, table: false, edit: Edit(
            attachmentType: AttachmentType(fileTypes: ["pdf", "txt", "md"], maxLimit: 3, type: .base)))
        Field("fill", "Fill Sample", type: .button, edit: Edit(buttonType: ButtonType(icon: "fa fa-magic", style: "primary")),
              click: { _ in FormChange(formData: ["name": "sample", "kind": "advanced", "amount": 42, "score": 4]) })
        Field("reset", "Clear", type: .button, edit: Edit(buttonType: ButtonType(confirm: "Clear the form?", danger: true)),
              click: { _ in FormChange(formData: ["name": "", "amount": 0, "score": 0]) })
        Field("whoami", "Who Am I", type: .button, edit: Edit(buttonType: ButtonType(fullSpan: true, icon: "fa fa-user")),
              click: { _ in FormChange(eval: "alert(" + JSON.string(User.current?.account ?? "").serialized() + ")") })

        RowAction("rename", "Rename", mode: .single, tip: "Give the row a new name", form: renameForm) { op in
            try op.repo.update(op.rows[0]["id"]!, ["name": op.param!["name"]!])
            return nil
        }
        RowAction("double", "Double", ifExpr: "item.amount > 0", raw: RowOperation(ifExprBehavior: .hide)) { op in
            for row in op.rows { try op.repo.update(row["id"]!, ["amount": .double((row["amount"]?.double ?? 0) * 2)]) }
            return nil
        }
        RowAction("reset_amounts", "Reset Amounts", confirm: "Reset the amounts?", raw: RowOperation(fold: true)) { op in
            for row in op.rows { try op.repo.update(row["id"]!, ["amount": 0]) }
            return nil
        }
        RowAction("node_info", "Node Info", mode: .button, icon: "fa fa-info-circle") { op in
            // the server called back: the acting user's info and the node's config text (0 when a call fails)
            let roles = (try? nodeBox.node?.userInfo())??["roles"]?.array?.count ?? 0
            let config = (try? nodeBox.node?.config())?.count ?? 0
            return "alert(" + JSON.string("\(op.user?.account ?? ""): \(roles) roles, config \(config) chars").serialized() + ")"
        }
    }

    // ------------------------------------------------------------ storage, seeds and the node

    let repos: [(Model, Repository)] = [
        (category, try SQLRepository(db, table: "category", autoCreate: true)),
        (author, try SQLRepository(db, table: "author", autoCreate: true)),
        (tag, try SQLRepository(db, table: "tag", autoCreate: true)),
        (article, try SQLRepository(db, table: "article", autoCreate: true)),
        (component, try SQLRepository(db, table: "component", autoCreate: true)),
        (auditLog, audits),
        (playground, try SQLRepository(db, table: "playground", autoCreate: true)),
    ]
    let node = try Node(
        name: env["ERUPT_NODE_NAME"] ?? "showcase", accessToken: env["ERUPT_ACCESS_TOKEN"] ?? "",
        servers: [env["ERUPT_SERVER"] ?? "http://localhost:8080"])
    nodeBox.node = node
    for (model, repo) in repos { try node.register(model, repo) }

    /// Seeds a table only while it is empty.
    func seed(_ repo: Repository, _ records: [Record]) throws {
        if try repo.page(Query(limit: 1)).total == 0 { for r in records { try repo.add(r) } }
    }
    try seed(repos[0].1, [
        ["name": "Tech", "parent": nil, "sort": 1], ["name": "Python", "parent": 1, "sort": 2],
        ["name": "Go", "parent": 1, "sort": 3], ["name": "Life", "parent": nil, "sort": 4],
        ["name": "Travel", "parent": 4, "sort": 5],
    ])
    try seed(repos[1].1, [
        ["name": "Ann", "email": "ann@example.com", "active": true],
        ["name": "Bob", "email": "bob@example.com", "active": true],
        ["name": "Cy", "email": "cy@example.com", "active": false],
    ])
    try seed(repos[2].1, [
        ["name": "intro", "color": "#1677ff"], ["name": "guide", "color": "#52c41a"], ["name": "news", "color": "#fa8c16"],
    ])
    try seed(repos[3].1, [
        ["title": "Hello Erupt", "summary": "A first look at erupt nodes", "author": 1, "category": 2, "topic": 2,
         "tag_ids": [1, 2], "reviewers": [2], "sections": [1, 2], "status": "published", "level": "beginner",
         "labels": "hot,new", "city": "Paris", "views": 120, "price": 9.9, "rating": 4.5, "progress": 100, "featured": true,
         "color": "#1677ff", "icon": "fa fa-book", "publish_date": "2026-10-01", "review_at": "2026-10-02T10:00:00.000",
         "content": "<p>Hello</p>", "notes": "# Hello", "meta": "{\"a\":1}"],
        ["title": "Go Tips", "author": 2, "category": 3, "topic": 3, "tag_ids": [2], "status": "review", "level": "advanced",
         "labels": "classic", "views": 30, "price": 0, "rating": 3, "progress": 60, "featured": false],
        ["title": "Weekend Trip", "author": 3, "category": 5, "topic": 5, "status": "draft", "views": 0, "rating": 0,
         "progress": 10, "featured": false],
    ])
    try seed(repos[4].1, [
        ["name": "Sample A", "code": "C-001", "roles": ["ADMIN", "USER"], "langs": ["JAVA", "GO"], "attrs": ["env": "prod", "tier": "1"]],
        ["name": "Sample B", "code": "C-002", "roles": ["GUEST"], "langs": ["PYTHON"], "attrs": [:]],
    ])
    try seed(repos[6].1, [
        ["name": "alpha", "kind": "simple", "level": "low", "code": "A-1", "amount": 10, "score": 3, "skills": ["java"]],
        ["name": "beta", "kind": "advanced", "level": "expert", "note": "deep dive", "code": "B-1", "amount": 0, "score": 5,
         "skills": ["python", "go"]],
        ["name": "gamma", "kind": "simple", "level": "mid", "code": "G-1", "amount": 25, "score": 4, "skills": []],
    ])
    try node.serve(port: Int(env["PORT"] ?? "") ?? 9090)
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
