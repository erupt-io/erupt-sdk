/// One record, keyed by field name.
public typealias Record = [String: JSON]

/// What a field holds; it picks the edit type unless `type:` names one.
public enum FieldKind {
    /// INPUT
    case string
    /// NUMBER
    case number
    /// BOOLEAN
    case bool
    /// DATE, held as `2026-01-05`
    case date
    /// DATE with a time of day, held as `2026-01-05T10:30:00.000`
    case dateTime
    /// A JSON array or object (MULTI_CHOICE, KEY_VALUE): SQL repositories store it as JSON text
    case json
    /// A record of `model`, stored as its primary key, picked from a table that shows `label`
    case ref(Model, label: String = "name")
    /// A record of `model` picked from a tree over its parent field `pid`
    case tree(Model, pid: String, label: String = "name")
}

/// The options a field fetches when the form opens (PROTOCOL.md §5.5): `.options` for a CHOICE / MULTI_CHOICE,
/// `.tags` for a TAGS field; both get the form's values.
public enum FieldFetch {
    case options((Record) throws -> [(value: String, label: String)])
    case tags((Record) throws -> [String])
}

/// What an onchange or a BUTTON click answers: form values to set, `editExpr` per field and, for a BUTTON only,
/// JavaScript the browser runs (`eval`): only return code you wrote.
public struct FormChange {
    public var eval: String?
    public var formData: Record
    public var editExpr: Record

    public init(eval: String? = nil, formData: Record = [:], editExpr: Record = [:]) {
        self.eval = eval
        self.formData = formData
        self.editExpr = editExpr
    }

    var json: JSON {
        // nothing to change answers an empty object (as the Go and Python SDKs do); a missing key changes nothing
        var o: [String: JSON] = [:]
        if !formData.isEmpty { o["formData"] = .object(formData) }
        if !editExpr.isEmpty { o["editExpr"] = .object(editExpr) }
        if let eval { o["eval"] = .string(eval) }
        return .object(o)
    }
}

/// One column of a model. `title` labels both the table column and the form input; `view` / `edit` take typed
/// annotation attributes for anything the shortcuts do not cover. A `virtual` field is a form-only element
/// (DIVIDE, CALLOUT, EMPTY, GROUP, BUTTON) that is in the build but never read or written.
///
/// A field can run its own code, called by the erupt server through the node's invoke endpoint with the form's
/// values: `fetch` (CHOICE / MULTI_CHOICE / TAGS options), `onchange` (any field), `complete` (AUTO_COMPLETE, with
/// the typed text) and `click` (BUTTON). Throw an `EruptFailure` to refuse with a message.
///
/// `dependColumn` (a reference table whose `referenceTableType.dependField` names another field) is the referenced
/// model's column the server matches to that field's value: `@Transient` in Java, so not in `ReferenceTableType`.
public struct Field {
    public let name: String
    public let title: String
    let kind: FieldKind
    let explicitType: EditType?
    let pk, search, notNull, sortable, table, form, virtual: Bool
    let choices: [(value: String, label: String)]?
    let view: View?
    let edit: Edit?
    let dependColumn: String?
    let fetch: FieldFetch?
    let onchange: ((Record) throws -> FormChange)?
    let complete: ((Record, String) throws -> [String])?
    let click: ((Record) throws -> FormChange)?
    /// the template key the field resolves to: an EditType, or DATE_TIME
    var type = ""

    public init(
        _ name: String, _ title: String = "", _ kind: FieldKind = .string, type: EditType? = nil, pk: Bool = false,
        search: Bool = false, notNull: Bool = false, sortable: Bool = false, table: Bool = true, form: Bool = true,
        choices: KeyValuePairs<String, String>? = nil, view: View? = nil, edit: Edit? = nil, dependColumn: String? = nil,
        virtual: Bool = false,
        fetch: FieldFetch? = nil, onchange: ((Record) throws -> FormChange)? = nil,
        complete: ((Record, String) throws -> [String])? = nil, click: ((Record) throws -> FormChange)? = nil
    ) {
        self.name = name
        self.title = title
        self.kind = kind
        self.explicitType = type
        self.pk = pk
        self.search = search
        self.notNull = notNull
        self.sortable = sortable
        self.table = table
        self.form = form
        self.choices = choices.map { $0.map { (value: $0.key, label: $0.value) } }
        self.view = view
        self.edit = edit
        self.dependColumn = dependColumn
        self.virtual = virtual || type == .button
        self.fetch = fetch
        self.onchange = onchange
        self.complete = complete
        self.click = click
    }

    /// CHECKBOX / TAB_TREE / TRANSFER: many records of another model, stored as the JSON list of their keys
    static let collections = [EditType.checkbox.rawValue, EditType.tabTree.rawValue, EditType.transfer.rawValue]
    /// the edit attribute that names a fetchHandler, by the type that fetches options
    static let fetched = [EditType.choice.rawValue: "choiceType", EditType.multiChoice.rawValue: "multiChoiceType", EditType.tags.rawValue: "tagsType"]
    /// the edit types this SDK stores and serves (DATE_TIME is a DATE with a time picker)
    static let supported: Set<String> = Set(
        [
            EditType.attachment, .autoComplete, .boolean, .button, .checkbox, .choice, .codeEditor, .color, .date, .hidden,
            .htmlEditor, .icon, .input, .map, .markdown, .multiChoice, .number, .rate, .referenceTable, .referenceTree,
            .signature, .slider, .tabTree, .tags, .textarea, .transfer,
        ].map(\.rawValue) + [dateTimeType])
    /// fieldReturnName by edit type (PROTOCOL.md §7.1); a reference names its target, the rest are "String"
    /// the edit types that hold a number (NUMBER, RATE, SLIDER)
    static let numeric: Set<String> = [EditType.number.rawValue, EditType.rate.rawValue, EditType.slider.rawValue]
    static let returnNames = [
        EditType.number.rawValue: "number", EditType.rate.rawValue: "number", EditType.slider.rawValue: "number",
        EditType.boolean.rawValue: "Boolean", EditType.date.rawValue: "Date", dateTimeType: "Date",
    ]

    var isCollection: Bool { Field.collections.contains(type) }

    var isJSON: Bool { if case .json = kind { return true } else { return isCollection } }

    var isReference: Bool { type == EditType.referenceTable.rawValue || type == EditType.referenceTree.rawValue }

    /// The referenced model, label and tree parent field of a reference.
    var reference: (target: Model, label: String, pid: String?)? {
        switch kind {
        case .ref(let model, let label): return (model, label, nil)
        case .tree(let model, let pid, let label): return (model, label, pid)
        default: return nil
        }
    }

    mutating func resolve(_ path: String) throws {
        guard isIdentifier(name) else { throw DeclarationError("\(path): name must be an identifier") }
        if pk { return }
        var fetchesOptions = false
        if case .options = fetch { fetchesOptions = true }
        switch kind {
        case _ where explicitType.map { Field.collections.contains($0.rawValue) } == true:
            guard reference != nil else { throw DeclarationError("\(path): \(explicitType!.rawValue) needs a .ref(model)") }
            type = explicitType!.rawValue
        case .ref: type = EditType.referenceTable.rawValue
        case .tree: type = EditType.referenceTree.rawValue
        default:
            if let explicitType {
                type = explicitType.rawValue
            } else if choices != nil || fetchesOptions {
                type = isJSON ? EditType.multiChoice.rawValue : EditType.choice.rawValue
            } else {
                switch kind {
                case .number: type = EditType.number.rawValue
                case .bool: type = EditType.boolean.rawValue
                case .date: type = EditType.date.rawValue
                case .dateTime: type = dateTimeType
                default: type = EditType.input.rawValue
                }
            }
        }
        guard Field.supported.contains(type) else {
            throw DeclarationError("\(path): edit type \(type) is not supported yet")
        }
        var fetchFits = true
        switch fetch {
        case .options: fetchFits = type == EditType.choice.rawValue || type == EditType.multiChoice.rawValue
        case .tags: fetchFits = type == EditType.tags.rawValue
        case nil: break
        }
        if !fetchFits || (complete != nil && type != EditType.autoComplete.rawValue) || (click != nil && type != EditType.button.rawValue) {
            throw DeclarationError("\(path): fetch, complete and click belong to CHOICE / MULTI_CHOICE / TAGS, AUTO_COMPLETE and BUTTON")
        }
        if dependColumn != nil, type != EditType.referenceTable.rawValue {
            throw DeclarationError("\(path): dependColumn belongs to a REFERENCE_TABLE")
        }
        if let (target, label, pid) = reference {
            guard target.pk != nil else { throw DeclarationError("\(path): \(target.name) has no primary key") }
            for key in [label, pid].compactMap({ $0 }) where target.fields[key] == nil {
                throw DeclarationError("\(path): \(target.name) has no field '\(key)'")
            }
        }
    }

    /// The field as declared (PROTOCOL.md §12.3): the server completes the rest from Java's defaults.
    func build() -> JSON {
        if pk {
            return [
                "fieldName": .string(name), "fieldReturnName": "number", "componentValue": nil,
                "eruptFieldJson": ["edit": ["title": "", "type": "NUMBER"]],
            ]
        }
        // a DATE_TIME is a DATE whose dateType says so; a DATE says it too, as AUTO is the node's to resolve
        var edit: JSON = ["title": .string(title), "type": .string(type == dateTimeType ? EditType.date.rawValue : type)]
        if type == dateTimeType || type == EditType.date.rawValue { edit["dateType"] = ["type": .string(type)] }
        if notNull { edit["notNull"] = true }
        if !form { edit["show"] = false }
        if search { edit["search"] = ["value": true] }
        var view: JSON = ["title": .string(title)]
        if sortable { view["sortable"] = true }
        var returnName = Field.returnNames[type] ?? "String"
        if let (target, label, pid) = reference {
            // the server lists a CHECKBOX by the view column, a TAB_TREE by the target's own tree
            returnName = target.name
            view["column"] = .string(label)
            if type == EditType.referenceTable.rawValue {
                edit["referenceTableType"] = ["id": .string(target.pk!), "label": .string(label)]
            } else if type == EditType.referenceTree.rawValue {
                edit["referenceTreeType"] = ["id": .string(target.pk!), "label": .string(label), "pid": pid.map(JSON.string) ?? ""]
            }
        }
        if fetch != nil, let attr = Field.fetched[type] { edit[attr] = ["fetchHandler": ["invoke"]] }
        if onchange != nil { edit["onchange"] = "invoke" }
        if let override = self.edit { merge(&edit, override.json) }
        // @Transient in Java: not in ReferenceTableType, read by the server off the build
        if let dependColumn {
            if edit["referenceTableType"] == nil { edit["referenceTableType"] = [:] }
            edit["referenceTableType"]!["dependColumn"] = .string(dependColumn)
        }
        if let override = self.view { merge(&view, override.json) }
        // a BUTTON is a form element only: no table column
        let views: JSON = table && type != EditType.button.rawValue ? [view] : []
        var options: JSON = nil
        if let choices {  // CHOICE, or MULTI_CHOICE over a JSON array
            options = .array(choices.map {
                ["value": .string($0.value), "label": .string($0.label), "desc": nil, "color": nil, "disable": false]
            })
        }
        return [
            "fieldName": .string(name), "fieldReturnName": .string(returnName), "componentValue": options,
            "eruptFieldJson": ["edit": edit, "views": views],
        ]
    }

    /// A JSON value as the server sends it (PROTOCOL.md §12.4) as the value the repository stores: a DATE_TIME in
    /// its stored form, a number as a number, a key as its key type. The server has checked it; a key in a path
    /// segment, a delete body or an operation's ids arrives as the browser sent it, so it may fail here.
    func coerce(_ value: JSON) throws -> JSON {
        if isCollection, let (target, _, _) = reference {
            // the picked keys, stored as the JSON list of them
            if value == .null { return [] }
            guard let items = value.array else { throw EruptFailure("must be a JSON array") }
            let pk = target.fields[target.pk!]!
            return .array(try items.map { try pk.coerce($0) })
        }
        if let (target, _, _) = reference { return try target.fields[target.pk!]!.coerce(value) }
        if value == .null || value == "" { return .null }
        if pk {
            if let i = value.int, value.double != nil { return .int(i) }
            if case .string(let s) = value, let i = Int64(s.trimmingSpaces) { return .int(i) }
            throw EruptFailure("illegal id '\(value.text)'")
        }
        if isJSON { return value }
        switch type {
        case EditType.boolean.rawValue:
            if case .bool = value { return value }
            return .bool(["true", "1"].contains(value.text.lowercased()))
        case _ where Field.numeric.contains(type): return try Values.number(value)
        // the server sends `yyyy-MM-dd HH:mm:ss`; stored as `yyyy-MM-ddTHH:mm:ss.SSS`, which compares as text
        case dateTimeType: return .string(try Values.dateTime(value))
        case EditType.date.rawValue: return .string(try Values.date(value))
        default: return .string(value.text)
        }
    }
}

/// Not an EditType: the template of a DATE whose picker includes the time of day
let dateTimeType = "DATE_TIME"

func isIdentifier(_ s: String) -> Bool {
    guard let first = s.unicodeScalars.first, first == "_" || (first.isASCII && first.properties.isAlphabetic) else {
        return false
    }
    return s.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) }
}

/// The acting user of a request, as the server describes it.
public struct User: Sendable {
    public let raw: JSON
    public var uid: JSON { raw["uid"] ?? .null }
    public var account: String? { raw["account"]?.string }
    public var name: String? { raw["name"]?.string }
    public var tenantId: JSON { raw["tenantId"] ?? .null }

    public init(_ raw: JSON) { self.raw = raw }

    /// The user of the request being served, in repositories and operation handlers.
    @TaskLocal public static var current: User?
}

/// What an operation handler receives: `rows` (selected records as the repository returned them; empty for
/// BUTTON mode), `param` (coerced form values, nil without a form), `repo`, `model` and `user`.
public struct OperationContext {
    public let rows: [Record]
    public let param: Record?
    public let repo: Repository
    public let model: Model
    public let user: User?
}

/// The confirm dialog of an operation: `true` (the default text), `false` (none) or a text of its own.
public enum Confirm: ExpressibleByBooleanLiteral, ExpressibleByStringLiteral {
    case ask
    case none
    case text(String)

    public init(booleanLiteral value: Bool) { self = value ? .ask : .none }
    public init(stringLiteral value: String) { self = .text(value) }
}

/// A row operation. The handler may return JavaScript the browser runs, so only return code you wrote, and may
/// throw an `EruptFailure` to show a message. `mode`: `.single` (row button), `.multi` (row and toolbar),
/// `.multiOnly` (toolbar), `.button` (toolbar, no rows). `form`: a model whose fields are asked for before
/// running. `show` hides the operation and refuses to run it; `ifExpr` is browser-side JavaScript over `item`
/// that disables (or hides) the row button; `raw` carries any other `@RowOperation` attribute.
public struct RowAction {
    public typealias Handler = (OperationContext) throws -> String?

    public let code: String
    public let title: String
    let mode: RowOperationMode
    let icon: String?
    let tip: String
    let confirm: Confirm
    let form: Model?
    let ifExpr: String
    let raw: RowOperation?
    let show: ((User?) -> Bool)?
    let handler: Handler

    public init(
        _ code: String, _ title: String, mode: RowOperationMode = .multi, icon: String? = nil, tip: String = "",
        confirm: Confirm = .ask, form: Model? = nil, ifExpr: String = "", raw: RowOperation? = nil,
        show: ((User?) -> Bool)? = nil, handler: @escaping Handler
    ) {
        self.code = code
        self.title = title
        self.mode = mode
        self.icon = icon
        self.tip = tip
        self.confirm = confirm
        self.form = form
        self.ifExpr = ifExpr
        self.raw = raw
        self.show = show
        self.handler = handler
    }

    func isVisible(to user: User?) -> Bool { show?(user) ?? true }

    /// The operation as declared (PROTOCOL.md §12.3).
    func build() -> JSON {
        var tpl: JSON = [
            "code": .string(code), "title": .string(title), "mode": mode.json, "tip": .string(tip), "ifExpr": .string(ifExpr),
            "eruptClass": .string(form?.name ?? "void"),
        ]
        if let icon { tpl["icon"] = .string(icon) }
        switch confirm {
        case .ask: break
        case .none: tpl["callHint"] = ""  // the browser runs it without asking
        case .text(let text): tpl["callHint"] = .string(text)
        }
        if let raw { merge(&tpl, raw.json) }
        return tpl
    }
}

/// Hooks around a model's data, as erupt's Java `DataProxy`: implement what you need and pass it as
/// `Model(..., dataProxy: [...])`. A record is what the repository stores, a row what the browser reads; change
/// them in place. Throw an `EruptFailure` to refuse with a message.
public protocol DataProxy {
    /// Default values of the search bar, `condition[field] = value`.
    func searchCondition(_ condition: inout [String: JSON])
    /// SQL ANDed to a table page's WHERE, as written: `"status <> 'deleted'"`, or with its values bound,
    /// `SQLFilter("owner = ?", [uid])`. `conditions` are the search bar's. Only SQL repositories apply it.
    func beforeFetch(_ conditions: [Cond]) throws -> SQLFilter?
    /// The rows of a table page, before they are sent.
    func afterFetch(_ rows: inout [Record]) throws
    /// The values a new record's form opens with.
    func addBehavior(_ record: inout Record) throws
    /// A record read by its key, for the edit form or the detail view.
    func editBehavior(_ record: inout Record) throws
    /// A record about to be added or updated.
    func validate(_ record: Record) throws
    func beforeAdd(_ record: inout Record) throws
    func afterAdd(_ record: Record) throws
    func beforeUpdate(_ record: inout Record) throws
    func afterUpdate(_ record: Record) throws
    func beforeDelete(_ record: Record) throws
    func afterDelete(_ record: Record) throws
}

extension DataProxy {
    public func searchCondition(_ condition: inout [String: JSON]) {}
    public func beforeFetch(_ conditions: [Cond]) throws -> SQLFilter? { nil }
    public func afterFetch(_ rows: inout [Record]) throws {}
    public func addBehavior(_ record: inout Record) throws {}
    public func editBehavior(_ record: inout Record) throws {}
    public func validate(_ record: Record) throws {}
    public func beforeAdd(_ record: inout Record) throws {}
    public func afterAdd(_ record: Record) throws {}
    public func beforeUpdate(_ record: inout Record) throws {}
    public func afterUpdate(_ record: Record) throws {}
    public func beforeDelete(_ record: Record) throws {}
    public func afterDelete(_ record: Record) throws {}
}

/// What the node applies when a table is read for one `@Vis` view, given as `Model(..., visQuery:)` under the
/// view's code: `filter` is SQL ANDed to the WHERE as written (SQL repositories only, like `beforeFetch`), `orderBy`
/// the view's order when the request has none (`"title desc, id"`). Java keeps both `@Transient`: they are not in
/// `Vis` and never in the build.
public struct VisQuery {
    let filter: [String]
    let orderBy: String?

    public init(filter: [String] = [], orderBy: String? = nil) {
        self.filter = filter
        self.orderBy = orderBy
    }

    public init(filter: String, orderBy: String? = nil) { self.init(filter: [filter], orderBy: orderBy) }
}

/// How a drill from a row of this model joins the linked model, given as `Model(..., drillJoin:)` under the drill's
/// code: the linked model's rows whose `joinColumn` (a field, `"author"` or `"author.id"`) holds the row's `column`.
/// Java keeps both `@Transient`, so they are not in `Link`; they are written into the drill's link in the build, as
/// the server turns a drill into a condition (PROTOCOL.md §12.3, §12.4).
public struct DrillJoin {
    let column: String
    let joinColumn: String

    public init(column: String = "id", joinColumn: String) {
        self.column = column
        self.joinColumn = joinColumn
    }
}

/// One element of a model declaration.
public enum ModelPart {
    case field(Field)
    case action(RowAction)
}

@resultBuilder
public enum ModelBuilder {
    public static func buildExpression(_ field: Field) -> [ModelPart] { [.field(field)] }
    public static func buildExpression(_ action: RowAction) -> [ModelPart] { [.action(action)] }
    public static func buildBlock(_ parts: [ModelPart]...) -> [ModelPart] { parts.flatMap { $0 } }
    public static func buildOptional(_ parts: [ModelPart]?) -> [ModelPart] { parts ?? [] }
    public static func buildEither(first parts: [ModelPart]) -> [ModelPart] { parts }
    public static func buildEither(second parts: [ModelPart]) -> [ModelPart] { parts }
    public static func buildArray(_ parts: [[ModelPart]]) -> [ModelPart] { parts.flatMap { $0 } }
}

/// A declared erupt model, compiled into erupt build JSON.
///
/// Nothing here re-implements annotation semantics. The build carries only what a model declares; the server
/// completes every annotation from its Java defaults and checks it (erupt-cloud/PROTOCOL.md §12.3, protocol v2).
///
/// ```swift
/// let article = try Model("Article", orderBy: "id desc") {
///     Field("id", pk: true)
///     Field("title", "Title", search: true, notNull: true)
///     RowAction("publish", "Publish") { op in ... }
/// }
/// ```
public final class Model {
    /// rights a model may switch off (@Erupt power, PowerObject)
    static let rights: Set<String> = [
        "add", "edit", "delete", "query", "viewDetails", "export", "importable", "print", "copy", "cellEdit", "batchEdit",
        "ai", "comment", "revision",
    ]

    /// The erupt name the server addresses as `<node>.<name>`.
    public let name: String
    public let title: String
    /// The primary key field; nil for a model that only serves as an operation form.
    public let pk: String?
    /// The stored fields, in declaration order (virtual ones left out).
    public let fieldNames: [String]
    /// the rights the model switches off; the server enforces them and the user's (PROTOCOL.md §12.5)
    let power: [String: Bool]
    let raw: Erupt?
    let declared: [Field]
    let fields: [String: Field]
    let actions: [RowAction]
    let proxies: [DataProxy]
    /// the default table order, applied by the node
    let order: [(field: String, descending: Bool)]
    /// view code -> the filters and order the node applies to that view's table queries
    let vis: [String: (filters: [SQLFilter], order: [(field: String, descending: Bool)])]
    /// drill code -> its linkCondition, which the node adds to a drilled table (PROTOCOL.md §12.4)
    let drills: [String: String]
    /// drill code -> the columns its link joins on, written into the build
    private let drillJoins: [String: DrillJoin]

    /// `name` is what the server addresses; `power` switches features off (`["delete": false]`); `orderBy` is
    /// the default table order (`"views desc, id"`); `erupt` carries other `@Erupt` attributes
    /// (`Erupt(layout: Layout(pageSize: 30))`); `dataProxy` runs around every read and write of the model, in
    /// order; `visQuery` gives a `@Vis` view (by its code, or its title when it has none) a filter and an order;
    /// `drillJoin` gives every drill (by its code, or its title when it has none) the columns it joins on.
    /// A misspelt power key, order or drill fails here; the server checks every other attribute (PROTOCOL.md §12.3).
    public init(
        _ name: String, title: String? = nil, power: [String: Bool] = [:], orderBy: String? = nil, erupt: Erupt? = nil,
        dataProxy: [DataProxy] = [], visQuery: [String: VisQuery] = [:], drillJoin: [String: DrillJoin] = [:],
        @ModelBuilder _ body: () -> [ModelPart]
    ) throws {
        guard isIdentifier(name) else { throw DeclarationError("erupt name '\(name)' must be an identifier") }
        self.name = name
        self.title = title ?? name
        if let right = power.keys.sorted().first(where: { !Model.rights.contains($0) }) {
            throw DeclarationError("erupt \(name): unknown power '\(right)', expected some of \(Model.rights.sorted().joined(separator: ", "))")
        }
        self.power = power
        var erupt = erupt
        // a view without a code is addressed by its title
        let views = erupt?.vis?.map { v in
            var v = v
            if v.code == nil { v.code = v.title ?? "" }
            return v
        }
        erupt?.vis = views
        // a drill without a code is addressed by its title
        let drillList = erupt?.drills?.map { d in
            var d = d
            if d.code == nil { d.code = d.title ?? "" }
            return d
        }
        erupt?.drills = drillList
        var drills: [String: String] = [:]
        for d in drillList ?? [] {
            guard d.link?.linkErupt?.isEmpty == false, drillJoin[d.code!]?.joinColumn.isEmpty == false else {
                throw DeclarationError("erupt \(name): drill '\(d.code!)' needs link.linkErupt and a drillJoin")
            }
            drills[d.code!] = d.link?.linkCondition ?? ""
        }
        if let code = drillJoin.keys.sorted().first(where: { drills[$0] == nil }) {
            throw DeclarationError("erupt \(name): drillJoin '\(code)' is not a declared drill")
        }
        self.drills = drills
        self.drillJoins = drillJoin
        self.raw = erupt
        self.proxies = dataProxy

        var declared: [Field] = [], fields: [String: Field] = [:], names: [String] = [], actions: [RowAction] = []
        var pk: String?
        for part in body() {
            switch part {
            case .field(var f):
                try f.resolve("\(name).\(f.name)")
                guard !declared.contains(where: { $0.name == f.name }) else {
                    throw DeclarationError("\(name): field '\(f.name)' declared twice")
                }
                if f.pk {
                    guard pk == nil else { throw DeclarationError("\(name): at most one primary key") }
                    pk = f.name
                }
                declared.append(f)
                if !f.virtual {
                    fields[f.name] = f
                    names.append(f.name)
                }
            case .action(let a):
                guard !actions.contains(where: { $0.code == a.code }) else {
                    throw DeclarationError("\(name): operation code '\(a.code)' declared twice")
                }
                actions.append(a)
            }
        }
        self.declared = declared
        self.fields = fields
        self.fieldNames = names
        self.actions = actions
        self.pk = pk
        func parseOrder(_ text: String?) throws -> [(field: String, descending: Bool)] {
            try (text ?? "").split(separator: ",").map { String($0).trimmingSpaces }.filter { !$0.isEmpty }.map { part in
                let words = part.split(separator: " ").map(String.init)
                let dir = words.count > 1 ? words[1].lowercased() : "asc"
                guard fields[words[0]] != nil, words.count <= 2, dir == "asc" || dir == "desc" else {
                    throw DeclarationError("\(name): illegal orderBy '\(part)'")
                }
                return (words[0], dir == "desc")
            }
        }
        self.order = try parseOrder(orderBy)
        let codes = Set(erupt?.vis?.compactMap(\.code) ?? [])
        self.vis = try visQuery.mapValues { q in (q.filter.map { SQLFilter($0) }, try parseOrder(q.orderBy)) }
        if let code = visQuery.keys.sorted().first(where: { !codes.contains($0) }) {
            throw DeclarationError("\(name): visQuery '\(code)' is not a declared vis")
        }
        // the server filters by the tree beside the table (PROTOCOL.md §12.4); the field it names is checked here
        if let field = erupt?.linkTree?.field, !field.isEmpty, fields[field]?.isReference != true {
            throw DeclarationError("\(name): linkTree.field '\(field)' must be a reference field")
        }
    }

    func field(_ name: String) -> Field? { fields[name] }

    func action(_ code: String) -> RowAction? { actions.first { $0.code == code } }

    /// Runs one DataProxy hook on every proxy, in declaration order.
    func hook(_ run: (DataProxy) throws -> Void) rethrows { for p in proxies { try run(p) } }

    /// The SQL every proxy's `beforeFetch` adds.
    func filters(_ conditions: [Cond]) throws -> [SQLFilter] { try proxies.compactMap { try $0.beforeFetch(conditions) } }

    /// Values as the fields hold them, where they can be read so: lets seeds be written loosely
    /// (`"2026-10-02 10:00"`, `"9.9"`); anything else is kept as given.
    func normalized(_ record: Record) -> Record {
        var out = record
        for (key, value) in record {
            if let f = fields[key], !f.pk, let v = try? f.coerce(value) { out[key] = v }
        }
        return out
    }

    func buildErupt(_ actions: [RowAction] = []) -> JSON {
        var erupt: JSON = ["primaryKeyCol": .string(pk ?? "id"), "rowOperation": .array(actions.map { $0.build() })]
        if let raw { merge(&erupt, raw.json) }
        // a drill's link goes to the server whole: it reads the source row and joins on column / joinColumn
        if let drills = raw?.drills {
            erupt["drills"] = .array(drills.map { d in
                var o = d.json
                let join = drillJoins[d.code!]!
                o["link"]!["column"] = .string(join.column)
                o["link"]!["joinColumn"] = .string(join.joinColumn)
                return o
            })
        }
        var condition: [String: JSON] = [:]
        hook { $0.searchCondition(&condition) }
        return [
            "eruptName": .string(name), "eruptJson": erupt, "eruptFieldModels": .array(declared.map { $0.build() }),
            "searchCondition": .object(condition), "extraRow": false, "tags": [:],
        ]
    }

    func buildModel(power: [String: Bool], user: User?) -> JSON {
        let visible = actions.filter { $0.isVisible(to: user) }
        var forms: [String: JSON] = [:]
        for a in visible { if let form = a.form { forms[a.code] = form.buildErupt() } }
        return [
            "eruptModel": buildErupt(visible), "power": .object(power.mapValues(JSON.bool)), "tabErupts": nil,
            "combineErupts": nil, "operationErupts": forms.isEmpty ? nil : .object(forms),
        ]
    }
}
