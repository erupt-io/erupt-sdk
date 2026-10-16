import Foundation
import Testing

@testable import EruptSDK

let token = "node-secret"

func articleModel() throws -> (Model, Model) {
    let category = try Model("Category") {
        Field("id", pk: true)
        Field("name", "Name", search: true)
        Field("parent", "Parent", .number)
    }
    let article = try Model("Article", orderBy: "id desc") {
        Field("id", pk: true)
        Field("title", "Title", search: true, notNull: true, sortable: true)
        Field("status", "Status", search: true, choices: ["draft": "Draft", "published": "Published"])
        Field("views", "Views", .number, sortable: true)
        Field("publish_date", "Publish Date", .date, search: true)
        Field("category", "Category", .ref(category), search: true)
        Field("tags", "Tags", .json, search: true, choices: ["a": "A", "b": "B"], edit: Edit(type: .multiChoice))
        Field("divider", "Divider", edit: Edit(type: .divide), virtual: true)
        RowAction("hello", "Hello", mode: .button) { _ in "alert('hi')" }
    }
    return (category, article)
}

/// A node whose server is unreachable: every call is signed with power enforced, so it never asks it.
func node() throws -> Node {
    let (category, article) = try articleModel()
    let node = try Node(name: "test", accessToken: token, servers: ["http://127.0.0.1:9"], log: { _, _ in })
    try node.register(category, MemoryRepository([["name": "Tech"], ["name": "Python", "parent": 1]]))
    try node.register(article, MemoryRepository())
    return node
}

func call(_ node: Node, _ method: String, _ target: String, erupt: String = "Article", body: JSON? = nil,
          signed: Bool = true) -> (Int, JSON?) {
    let raw = body.map { Array($0.serialized().utf8) } ?? []
    let user = Data("{\"account\":\"admin\"}".utf8).base64EncodedString()
    var headers = ["erupt": erupt, "user": user, "token": "t"]
    if signed {
        let now = Int64(Date().timeIntervalSince1970)
        headers["Erupt-Timestamp"] = String(now)
        headers["Erupt-Enforced"] = "power"
        headers["Erupt-Signature"] = Signature.sign(
            accessToken: token, method: method, pathAndQuery: target, timestamp: now, enforced: "power", user: user, body: raw)
    } else {
        headers["Access-Token"] = token
    }
    let response = node.handle(NodeRequest(method: method, target: target, headers: headers, body: raw))
    return (response.status, response.body.isEmpty ? nil : try? JSON.parse(response.body))
}

@Suite struct NodeTests {
    @Test func health() throws {
        let response = try node().handle(NodeRequest(method: "GET", target: "/node-health", headers: [:]))
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == "test")
    }

    @Test func guards() throws {
        let n = try node()
        #expect(n.handle(NodeRequest(method: "GET", target: "/erupt-api/build/Article", headers: ["erupt": "Article"])).status == 403)
        let wrong = ["erupt": "Article", "Access-Token": "nope"]
        #expect(n.handle(NodeRequest(method: "GET", target: "/erupt-api/build/Article", headers: wrong)).status == 403)
        #expect(call(n, "GET", "/erupt-api/build/Article", erupt: "Category").0 == 404)
        #expect(call(n, "GET", "/erupt-api/nothing").0 == 404)
    }

    @Test func buildMatchesTheSchema() throws {
        let (status, build) = call(try node(), "GET", "/erupt-api/build/Article")
        #expect(status == 200)
        let model = try #require(build?["eruptModel"])
        try Schema.check("Erupt", model["eruptJson"]!, partial: false)
        let fields = model["eruptFieldModels"]!.array!
        #expect(fields.map { $0["fieldName"]!.text } == ["id", "title", "status", "views", "publish_date", "category", "tags", "divider"])
        for f in fields { try Schema.check("EruptField", f["eruptFieldJson"]!, partial: false) }
        #expect(fields[6]["eruptFieldJson"]!["edit"]!["type"] == "MULTI_CHOICE")
        #expect(build?["power"]?["cellEdit"] == true) // the server edits the cell
    }

    @Test func crudAndSearch() throws {
        let n = try node()
        let add: (JSON) -> JSON? = { call(n, "POST", "/erupt-api/data/modify/Article", body: $0).1 }
        #expect(add(["title": "A", "status": "draft", "views": "3", "publish_date": "2026-01-05", "category": ["id": "2"], "tags": ["a"]])?["success"] == true)
        #expect(add(["title": "B", "status": "published", "views": 10, "tags": ["a", "b"]])?["success"] == true)
        #expect(add(["status": "draft"])?["message"] == "Title cannot be empty")
        #expect(add(["title": "C", "status": "gone"])?["success"] == false)
        #expect(add(["title": "C", "tags": ["z"]])?["success"] == false)

        let table: (JSON) -> JSON = { call(n, "POST", "/erupt-api/data/table/Article", body: $0).1! }
        let all = table([:])
        #expect(all["list"]!.array!.map { $0["title"]!.text } == ["B", "A"])
        #expect(all["list"]![1]!["category"] == 2)
        #expect(all["list"]![1]!["views"] == 3)
        #expect(table(["condition": [["key": "tags", "expression": "IN", "value": ["b"]]]])["total"] == 1)
        #expect(table(["condition": [["key": "title", "expression": "LIKE", "value": "a"]]])["total"] == 1)
        #expect(table(["condition": [["key": "category", "expression": "EQ", "value": ["id": 2]]]])["total"] == 1)
        #expect(table(["sort": [["field": "views", "direction": "ASC"]]])["list"]![0]!["title"] == "A")
        #expect(table(["sort": [["field": "status", "direction": "ASC"]]])["success"] == false)

        let pk = all["list"]![0]!["id"]!
        #expect(call(n, "GET", "/erupt-api/data/Article/\(pk.text)").1?["title"] == "B")
        #expect(call(n, "POST", "/erupt-api/data/modify/Article/delete", body: [pk]).1?["success"] == true)
        #expect(table([:])["total"] == 1)
        #expect(call(n, "POST", "/erupt-api/data/Article/operator/hello", body: [:]).1?["data"] == "alert('hi')")
    }

    @Test func plainAccessToken() throws {
        // without a signature the node asks the server for the user's power and, unreachable, fails closed
        let n = try node()
        #expect(call(n, "GET", "/erupt-api/build/Article", signed: false).1?["power"]?["add"] == false)
        #expect(call(n, "POST", "/erupt-api/data/modify/Article", body: ["title": "x"], signed: false).0 == 403)
    }

    @Test func servesOverHTTP() throws {
        let n = try node()
        let server = try HTTPServer(host: "127.0.0.1", port: 0, handler: n.handle)
        server.start()
        defer { server.close() }
        let body = try String(contentsOf: URL(string: "http://127.0.0.1:\(server.port)/node-health")!, encoding: .utf8)
        #expect(body == "test")
    }
}

@Suite struct DeclarationTests {
    @Test func rejectsIllegalDeclarations() throws {
        #expect(throws: DeclarationError.self) { try Model("bad name") { Field("id", pk: true) } }
        #expect(throws: DeclarationError.self) { try Model("M") { Field("id", pk: true); Field("id") } }
        #expect(throws: DeclarationError.self) { try Model("M") { Field("id", pk: true); Field("x-y") } }
        #expect(throws: DeclarationError.self) { try Model("M", power: ["fly": true]) { Field("id", pk: true) } }
        #expect(throws: DeclarationError.self) { try Model("M", orderBy: "nope desc") { Field("id", pk: true) } }
        #expect(throws: DeclarationError.self) { try Model("M") { Field("id", pk: true); Field("a", type: .password) } }
        let target = try Model("T") { Field("id", pk: true) }
        #expect(throws: DeclarationError.self) { try Model("M") { Field("id", pk: true); Field("t", "T", .ref(target)) } }
        let form = try Model("F") { Field("note") }
        #expect(throws: DeclarationError.self) {
            try Node(name: "n", accessToken: "t", servers: ["http://x"]).register(form, MemoryRepository())
        }
    }
}

@Suite struct ValueTests {
    @Test func dates() throws {
        #expect(try Values.dateTime("2026-01-05") == "2026-01-05T00:00:00.000")
        #expect(try Values.dateTime("2026-01-05 10:30") == "2026-01-05T10:30:00.000")
        #expect(try Values.dateTime("2026-01-05T10:30:01.5Z") == "2026-01-05T10:30:01.500")
        #expect(try Values.date("2024-02-29T23:59:59") == "2024-02-29")
        for bad: JSON in ["2023-02-29", "2026-13-01", "someday", "2026-01-05T25:00", 20260105] {
            #expect(throws: EruptFailure.self) { try Values.date(bad) }
        }
    }

    @Test func numbers() throws {
        #expect(try Values.number("3") == .int(3))
        #expect(try Values.number(9.0) == .int(9))
        #expect(try Values.number("9.9") == .double(9.9))
        for bad: JSON in ["many", "nan", true, [1]] { #expect(throws: EruptFailure.self) { try Values.number(bad) } }
    }

    @Test func json() throws {
        let text = #"{"a":[1,2.5,true,null,"\u00e9\ud83d\ude00\n"],"b":{}}"#
        let value = try JSON.parse(text)
        #expect(value["a"]![0] == .int(1))
        #expect(value["a"]![4] == "é😀\n")
        #expect(try JSON.parse(value.serialized()) == value)
        #expect(value.serialized() == #"{"a":[1,2.5,true,null,"é😀\n"],"b":{}}"#)
        for bad in ["", "{", "[1,]", "01x", "\"\\x\"", "nul", "{\"a\" 1}"] {
            #expect(throws: JSONParseError.self) { try JSON.parse(bad) }
        }
    }
}

@Suite struct SignatureTests {
    @Test func javaVectors() throws {
        let url = URL(fileURLWithPath: #filePath).appendingPathComponent("../../../../conformance/signature-vectors.json").standardized
        let doc = try JSON.parse(Array(try Data(contentsOf: url)))
        let accessToken = doc["accessToken"]!.text
        for v in doc["vectors"]!.array! {
            let body = v["body"]!.string.map { Array($0.utf8) }
            let ts = v["timestamp"]!.int!
            let args = (v["method"]!.text, v["pathAndQuery"]!.text, v["enforced"]!.string, v["user"]!.string)
            let signature = v["signature"]!.text
            #expect(Signature.sign(accessToken: accessToken, method: args.0, pathAndQuery: args.1, timestamp: ts,
                                   enforced: args.2, user: args.3, body: body) == signature, "\(v["case"]!.text)")
            func verify(_ s: String, _ now: Int64) -> Bool {
                Signature.verify(accessToken: accessToken, method: args.0, pathAndQuery: args.1, timestamp: String(ts),
                                 enforced: args.2, user: args.3, body: body, signature: s, now: now)
            }
            #expect(verify(signature, ts + 300))
            #expect(!verify(signature, ts + 301))
            #expect(!verify(String(signature.reversed()), ts))
        }
        #expect(!Signature.verify(accessToken: "t", method: "GET", pathAndQuery: "/", timestamp: "soon", enforced: nil,
                                  user: nil, body: [], signature: "00", now: 0))
    }

    @Test func sha256() {
        #expect(Signature.hex(SHA256.hash(Array("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Signature.hex(SHA256.hash(Array(repeating: 0x61, count: 1000))).hasPrefix("41edece4"))
        // RFC 4231 test case 2
        #expect(Signature.hex(SHA256.hmac(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8)))
            == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }
}
