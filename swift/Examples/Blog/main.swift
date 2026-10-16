// A blog admin served from Swift, covering the field types and features of SHOWCASE.md. Create the node on the
// erupt server first, then:
//
//   ERUPT_NODE_NAME=blog ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 swift run Blog
//
// Records live in the SQLite file ERUPT_DB (default blog.db). Edit types without a shortcut (RATE, SLIDER, TAGS,
// COLOR, ICON, HTML_EDITOR, MARKDOWN, CODE_EDITOR) are declared as the storage kind they hold, with the edit type
// and its options in `edit:`. The Component model shows the rest: form-only elements as `virtual:` fields,
// MULTI_CHOICE / KEY_VALUE as `.json`.
import EruptSDK
import EruptSQLite
import Foundation

let env = ProcessInfo.processInfo.environment

do {
    let category = try Model("Category") {
        Field("id", pk: true)
        Field("name", "Name", search: true, notNull: true, sortable: true)
        Field("parent", "Parent Id", .number)
        Field("sort", "Sort", .number, sortable: true)
    }

    let publishForm = try Model("PublishForm", title: "Publish Options") {
        Field("publish_date", "Publish Date", .date, notNull: true)
    }

    let article = try Model("Article", power: ["importable": true], orderBy: "id desc") {
        Field("id", pk: true)
        Field("title", "Title", search: true, notNull: true, sortable: true, edit: Edit(inputType: InputType(length: 60)))
        Field("summary", "Summary", type: .textarea, table: false, edit: Edit(textareaType: TextareaType(length: 200)))
        Field("category", "Category", .ref(category), search: true)
        Field("topic", "Topic", .tree(category, pid: "parent"), table: false)
        Field("status", "Status", search: true, choices: ["draft": "Draft", "review": "In Review", "published": "Published"])
        Field("tags", "Tags", edit: Edit(
            tagsType: TagsType(allowExtension: true, fetchHandler: [], joinSeparator: ",", maxTagCount: 9999), type: .tags))
        Field("views", "Views", .number, sortable: true, edit: Edit(numberType: NumberType(min: 0)))
        Field("price", "Price", .number, edit: Edit(numberType: NumberType(min: 0, precision: 2, prefix: "$")))
        Field("rating", "Rating", .number, sortable: true, edit: Edit(
            rateType: RateType(allowHalf: true, character: "", count: 5), type: .rate))
        Field("progress", "Progress", .number, edit: Edit(
            sliderType: SliderType(dots: false, markPoints: [], max: 100, min: 0, step: 5), type: .slider))
        Field("featured", "Featured", .bool, search: true)
        Field("color", "Theme Color", edit: Edit(colorType: ColorType(alpha: false, presets: [], showText: true), type: .color))
        Field("icon", "Icon", table: false, edit: Edit(type: .icon))
        Field("publish_date", "Publish Date", .date, search: true, edit: Edit(search: Search(operator: .range)))
        Field("review_at", "Review At", .dateTime, sortable: true)
        Field("content", "Content", table: false, edit: Edit(htmlEditorType: HtmlEditorType(value: .ckeditor), type: .htmlEditor))
        Field("notes", "Notes", table: false, edit: Edit(type: .markdown))
        Field("meta", "Meta (JSON)", table: false, edit: Edit(
            codeEditType: CodeEditorType(height: 300, hintHandler: [], hints: [], language: "json"), type: .codeEditor))

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
    }

    // Every component a node can declare without extra endpoints
    let component = try Model("Component") {
        Field("id", pk: true)
        Field("name", "Name", search: true, notNull: true)
        Field("intro", "Guide", edit: Edit(
            calloutType: CalloutType(style: .info, value: "Every component a node can declare without extra endpoints."),
            type: .callout), virtual: true)
        Field("basic", "Basic", edit: Edit(type: .divide), virtual: true)
        Field("code", "Code", table: false, edit: Edit(type: .hidden))
        Field("roles", "Roles", .json, search: true, choices: ["ADMIN": "Admin", "USER": "User", "GUEST": "Guest"],
              edit: Edit(multiChoiceType: MultiChoiceType(dependField: "", type: .checkbox), type: .multiChoice))
        Field("langs", "Languages", .json, choices: ["JAVA": "Java", "PYTHON": "Python", "GO": "Go", "RUST": "Rust"],
              edit: Edit(multiChoiceType: MultiChoiceType(dependField: "", type: .select), type: .multiChoice))
        Field("attrs", "Attributes", .json, edit: Edit(
            keyValueType: KeyValueType(keyPlaceholder: "Key", keys: [], max: 9999, valuePlaceholder: "Value"), type: .keyValue))
        Field("spacer", "", edit: Edit(type: .empty), virtual: true)
        Field("extra", "Extra", edit: Edit(type: .divide), virtual: true)
        Field("location", "Location", edit: Edit(type: .map))
        Field("signature", "Signature", table: false, edit: Edit(type: .signature))
        Field("place", "Place & Sign", edit: Edit(groupType: GroupType(collapsed: false, fields: ["location", "signature"]), type: .group),
              virtual: true)
    }

    let db = try SQLiteExecutor(path: env["ERUPT_DB"] ?? "blog.db")
    let categories = try SQLRepository(db, table: "category", autoCreate: true)
    let articles = try SQLRepository(db, table: "article", autoCreate: true)
    let components = try SQLRepository(db, table: "component", autoCreate: true)

    let node = try Node(
        name: env["ERUPT_NODE_NAME"] ?? "blog", accessToken: env["ERUPT_ACCESS_TOKEN"] ?? "",
        servers: [env["ERUPT_SERVER"] ?? "http://localhost:8080"])
    try node.register(category, categories)
    try node.register(article, articles)
    try node.register(component, components)

    func seed(_ repo: Repository, _ records: [Record]) throws {
        if try repo.page(Query(limit: 1)).total == 0 { for r in records { try repo.add(r) } }
    }
    try seed(categories, [
        ["name": "Tech", "parent": nil, "sort": 1],
        ["name": "Python", "parent": 1, "sort": 2],
        ["name": "Go", "parent": 1, "sort": 3],
        ["name": "Life", "parent": nil, "sort": 4],
        ["name": "Travel", "parent": 4, "sort": 5],
    ])
    try seed(articles, [
        ["title": "Hello Erupt", "summary": "A first look at erupt nodes", "category": 2, "topic": 2, "status": "published",
         "tags": "intro,erupt", "views": 120, "price": 9.9, "rating": 4.5, "progress": 100, "featured": true,
         "color": "#1677ff", "icon": "fa fa-book", "publish_date": "2026-10-01", "review_at": "2026-10-02T10:00:00.000",
         "content": "<p>Hello</p>", "notes": "# Hello", "meta": "{\"a\":1}"],
        ["title": "Go Tips", "category": 3, "topic": 3, "status": "review", "tags": "go", "views": 30, "price": 0,
         "rating": 3, "progress": 60, "featured": false],
        ["title": "Weekend Trip", "category": 5, "topic": 5, "status": "draft", "views": 0, "rating": 0, "progress": 10,
         "featured": false],
    ])
    try seed(components, [
        ["name": "Sample A", "code": "C-001", "roles": ["ADMIN", "USER"], "langs": ["JAVA", "GO"], "attrs": ["env": "prod", "tier": "1"]],
        ["name": "Sample B", "code": "C-002", "roles": ["GUEST"], "langs": ["PYTHON"], "attrs": [:]],
    ])
    try node.serve(port: Int(env["PORT"] ?? "") ?? 9090)
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
