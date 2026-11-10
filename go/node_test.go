package erupt

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// enforcedFor is the Erupt-Enforced a v2 server sends with each endpoint (PROTOCOL.md §12.2).
func enforcedFor(method, path string) string {
	switch {
	case method == "GET" && strings.HasPrefix(path, "/erupt-api/build/"):
		return ""
	case strings.HasPrefix(path, "/erupt-api/data/table/"):
		return "power,query"
	case strings.HasPrefix(path, "/erupt-api/data/modify/") && !strings.HasSuffix(path, "/delete"):
		return "power,record"
	}
	return "power"
}

// signed signs a request as the server does, over the headers it already carries: with the Erupt-Enforced it sets
// (even empty), else the one its endpoint needs.
func signed(n *Node, req *http.Request, body string) *http.Request {
	enforced := enforcedFor(req.Method, req.URL.Path)
	if v, ok := req.Header[http.CanonicalHeaderKey(HeaderEnforced)]; ok {
		enforced = strings.Join(v, ",")
	}
	req.Header.Set(HeaderEnforced, enforced)
	pathAndQuery := req.URL.EscapedPath()
	if req.URL.RawQuery != "" {
		pathAndQuery += "?" + req.URL.RawQuery
	}
	ts := time.Now().Unix()
	req.Header.Set(HeaderTimestamp, strconv.FormatInt(ts, 10))
	req.Header.Set(HeaderSignature, Sign(n.cfg.AccessToken, req.Method, pathAndQuery, ts, enforced, req.Header.Get("user"), []byte(body)))
	return req
}

// serve sends one signed call; headers are set before signing.
func serve(n *Node, method, path, erupt, body string, headers map[string]string) (int, map[string]any) {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set("erupt", erupt)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	n.ServeHTTP(w, signed(n, req, body))
	var v map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &v)
	return w.Code, v
}

func articleNode(t *testing.T) *Node {
	t.Helper()
	category, article := testModels(t)
	node, err := NewNode(Config{Name: "n", AccessToken: "secret", Servers: []string{"http://127.0.0.1:1"}})
	if err != nil {
		t.Fatal(err)
	}
	if err := node.Register(category, NewMemoryRepository(Record{"name": "Tech"}, Record{"name": "Go"})); err != nil {
		t.Fatal(err)
	}
	if err := node.Register(article, NewMemoryRepository()); err != nil {
		t.Fatal(err)
	}
	return node
}

// Every call is signed, and carries what its endpoint needs in Erupt-Enforced (PROTOCOL.md §12.2).
func TestAuthentication(t *testing.T) {
	node := articleNode(t)
	unsigned := httptest.NewRequest("GET", "/erupt-api/build/Article", nil)
	unsigned.Header.Set("erupt", "Article")
	unsigned.Header.Set("Access-Token", "secret")
	w := httptest.NewRecorder()
	node.ServeHTTP(w, unsigned)
	if w.Code != 403 {
		t.Errorf("a plain Access-Token: %d", w.Code)
	}
	for _, c := range []struct{ method, path, body, enforced string }{
		{"POST", "/erupt-api/data/table/Article", `{}`, "power"},
		{"POST", "/erupt-api/data/table/Article", `{}`, "query"},
		{"POST", "/erupt-api/data/modify/Article", `{"title":"x"}`, "power"},
		{"POST", "/erupt-api/data/modify/Article/update", `{"id":1}`, "power,query"},
		{"POST", "/erupt-api/data/modify/Article/delete", `[1]`, ""},
		{"GET", "/erupt-api/data/Article/1", "", ""},
		{"GET", "/erupt-api/data/init-value/Article", "", "record"},
		{"POST", "/erupt-api/invoke/Article/operation/feature", `{"ids":[1]}`, "query"},
	} {
		if code, _ := serve(node, c.method, c.path, "Article", c.body, map[string]string{HeaderEnforced: c.enforced}); code != 403 {
			t.Errorf("%s %s with Erupt-Enforced %q: %d", c.method, c.path, c.enforced, code)
		}
	}
	if code, _ := serve(node, "GET", "/erupt-api/build/Article", "Article", "", map[string]string{HeaderEnforced: ""}); code != 200 {
		t.Errorf("a build needs nothing: %d", code)
	}
	if code, _ := serve(node, "GET", "/erupt-api/build/Article", "Article", "", map[string]string{"Origin": "http://evil"}); code != 403 {
		t.Errorf("Origin: %d", code)
	}
	req := signed(node, httptest.NewRequest("POST", "/erupt-api/data/table/Article", strings.NewReader(`{"pageSize":1}`)), `{}`)
	req.Header.Set("erupt", "Article")
	w = httptest.NewRecorder()
	node.ServeHTTP(w, req)
	if w.Code != 403 {
		t.Errorf("body altered after signing: %d", w.Code)
	}
	if code, _ := serve(node, "GET", "/erupt-api/build/Missing", "Missing", "", nil); code != 404 {
		t.Errorf("unknown erupt: %d", code)
	}
}

// A v2 node registers with protocolVersion 2 and stops for good at a server that does not answer it (§12.2).
func TestRegisterNegotiatesProtocol(t *testing.T) {
	for answer, keepsGoing := range map[string]bool{`{"protocolVersion":2}`: true, `{}`: false, ``: false, `{"protocolVersion":1}`: false} {
		var mu sync.Mutex
		var infos []map[string]any
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var info map[string]any
			body, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(body, &info)
			mu.Lock()
			infos = append(infos, info)
			mu.Unlock()
			_, _ = w.Write([]byte(answer))
		}))
		var logs bytes.Buffer
		node, _ := NewNode(Config{Name: "n", AccessToken: "secret", Servers: []string{server.URL}, Address: "http://node",
			Heartbeat: 20 * time.Millisecond, Logger: log.New(&logs, "", 0)})
		ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
		done := make(chan struct{})
		go func() { node.Heartbeat(ctx); close(done) }()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Fatalf("%q: the heartbeat did not stop", answer)
		}
		stoppedEarly := ctx.Err() == nil
		cancel()
		server.Close()
		mu.Lock()
		if infos[0]["protocolVersion"] != 2.0 {
			t.Errorf("node info %v", infos[0])
		}
		if keepsGoing && (stoppedEarly || len(infos) < 2) {
			t.Errorf("%q: registered %d times, stopped early %v", answer, len(infos), stoppedEarly)
		}
		if !keepsGoing && (!stoppedEarly || len(infos) != 1 || !strings.Contains(logs.String(), "does not speak node protocol v2")) {
			t.Errorf("%q: registered %d times, stopped early %v, log %q", answer, len(infos), stoppedEarly, logs.String())
		}
		mu.Unlock()
	}
}

// The build carries only what the model declares; the server completes it (PROTOCOL.md §12.3).
func TestBuildIsDeclaredOnly(t *testing.T) {
	node := articleNode(t)
	_, build := serve(node, "GET", "/erupt-api/build/Article", "Article", "", nil)
	if !reflect.DeepEqual(build["power"], map[string]any{"print": false, "ai": false}) {
		t.Errorf("power %v", build["power"])
	}
	model := build["eruptModel"].(map[string]any)
	erupt := model["eruptJson"].(map[string]any)
	if keys := strings.Join(sortedKeys(erupt), ","); keys != "layout,primaryKeyCol,rowOperation" {
		t.Errorf("eruptJson keys %s", keys)
	}
	wantOps := []any{
		map[string]any{"code": "publish", "title": "Publish", "mode": "MULTI", "tip": "", "ifExpr": "", "eruptClass": "PublishForm"},
		map[string]any{"code": "feature", "title": "Feature", "mode": "SINGLE", "tip": "", "ifExpr": "", "eruptClass": "void", "callHint": ""},
	}
	if !reflect.DeepEqual(erupt["rowOperation"], wantOps) {
		t.Errorf("rowOperation %v", erupt["rowOperation"])
	}
	fields := map[string]any{}
	for _, f := range model["eruptFieldModels"].([]any) {
		fields[str(f.(map[string]any)["fieldName"])] = f
	}
	field := func(name, returnName string, options any, edit map[string]any, views ...any) map[string]any {
		if views == nil {
			views = []any{}
		}
		return map[string]any{"fieldName": name, "fieldReturnName": returnName, "componentValue": options,
			"eruptFieldJson": map[string]any{"edit": edit, "views": views}}
	}
	type obj = map[string]any
	want := map[string]any{
		"id": obj{"fieldName": "id", "fieldReturnName": "number", "componentValue": nil,
			"eruptFieldJson": obj{"edit": obj{"title": "", "type": "NUMBER"}}},
		"title": field("title", "String", nil, obj{"title": "Title", "type": "INPUT", "notNull": true, "search": obj{"value": true},
			"inputType": obj{"length": 64.0}}, obj{"title": "Title", "sortable": true}),
		"status": field("status", "String", []any{
			obj{"value": "draft", "label": "Draft", "desc": nil, "color": nil, "disable": false},
			obj{"value": "published", "label": "Published", "desc": nil, "color": nil, "disable": false},
		}, obj{"title": "Status", "type": "CHOICE", "search": obj{"value": true}}, obj{"title": "Status"}),
		"views":        field("views", "number", nil, obj{"title": "Views", "type": "NUMBER"}, obj{"title": "Views", "sortable": true}),
		"featured":     field("featured", "Boolean", nil, obj{"title": "Featured", "type": "BOOLEAN", "search": obj{"value": true}}, obj{"title": "Featured"}),
		"publish_date": field("publish_date", "Date", nil, obj{"title": "Publish Date", "type": "DATE", "dateType": obj{"type": "DATE"}, "search": obj{"value": true}}, obj{"title": "Publish Date"}),
		"review_at":    field("review_at", "Date", nil, obj{"title": "Review At", "type": "DATE", "dateType": obj{"type": "DATE_TIME"}}, obj{"title": "Review At"}),
		"body":         field("body", "String", nil, obj{"title": "Body", "type": "TEXTAREA"}),
		"category": field("category", "Category", nil, obj{"title": "Category", "type": "REFERENCE_TABLE", "search": obj{"value": true},
			"referenceTableType": obj{"id": "id", "label": "name"}}, obj{"title": "Category", "column": "name"}),
		"topic": field("topic", "Category", nil, obj{"title": "Topic", "type": "REFERENCE_TREE",
			"referenceTreeType": obj{"id": "id", "label": "name", "pid": "parent"}}, obj{"title": "Topic", "column": "name"}),
	}
	for name, w := range want {
		if !reflect.DeepEqual(fields[name], w) {
			got, _ := json.Marshal(fields[name])
			exp, _ := json.Marshal(w)
			t.Errorf("%s\n got %s\nwant %s", name, got, exp)
		}
	}
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	for i := range keys {
		for j := i + 1; j < len(keys); j++ {
			if keys[j] < keys[i] {
				keys[i], keys[j] = keys[j], keys[i]
			}
		}
	}
	return keys
}

// Queries arrive checked and normalized: the node keeps its own names and its page-size cap (PROTOCOL.md §12.4, §12.6).
func TestNormalizedQueries(t *testing.T) {
	node := articleNode(t)
	for _, body := range []string{`{"title":"a","views":3,"category":2,"publish_date":"2026-01-05","review_at":"2026-01-05 10:30:00"}`,
		`{"title":"b","views":5,"category":1,"publish_date":"2026-02-05","review_at":"2026-02-05 10:30:00"}`} {
		if _, r := serve(node, "POST", "/erupt-api/data/modify/Article", "Article", body, nil); r["success"] != true {
			t.Fatalf("add %v", r)
		}
	}
	titles := func(body string) []string {
		code, page := serve(node, "POST", "/erupt-api/data/table/Article", "Article", body, nil)
		if code != 200 {
			t.Fatalf("%s: %d %v", body, code, page)
		}
		return titlesOf(page)
	}
	for body, want := range map[string][]string{
		// any stored field, searchable or not: the server's own conditions are on any of them
		`{"condition":[{"key":"views","expression":"LT","value":4}]}`:                                                    {"a"},
		`{"condition":[{"key":"category","expression":"IN","value":[1,3]}]}`:                                             {"b"},
		`{"condition":[{"key":"id","expression":"NULL"}]}`:                                                               {},
		`{"condition":[{"key":"review_at","expression":"RANGE","value":["2026-01-05 10:00:00","2026-01-05 11:00:00"]}]}`: {"a"},
		`{"condition":[{"key":"publish_date","expression":"GTE","value":"2026-02-01"}]}`:                                 {"b"},
		`{"sort":[{"field":"category.name","direction":"ASC"}]}`:                                                         {"b", "a"},
		`{"sort":[{"field":"body","direction":"DESC"},{"field":"views","direction":"DESC"}]}`:                            {"b", "a"},
	} {
		if got := titles(body); !reflect.DeepEqual(got, want) {
			t.Errorf("%s: %v, want %v", body, got, want)
		}
	}
	for _, body := range []string{`{"condition":[{"key":"title\" OR 1=1 --","expression":"EQ","value":1}]}`,
		`{"sort":[{"field":"nope","direction":"ASC"}]}`, `{"condition":[{"key":"views","expression":"IN","value":3}]}`,
		`{"condition":[{"key":"title","expression":"DROP","value":1}]}`, `{"condition":[{"key":"title","value":"a"}]}`} {
		if _, r := serve(node, "POST", "/erupt-api/data/table/Article", "Article", body, nil); r["success"] != false {
			t.Errorf("%s: %v", body, r)
		}
	}
	if _, page := serve(node, "POST", "/erupt-api/data/table/Article", "Article", `{"pageSize":100000}`, nil); page["pageSize"] != float64(maxPageSize) {
		t.Errorf("page size %v", page["pageSize"])
	}
}

// The server turns a link tree into conditions: IN on the tree field, NULL on the pk with nothing picked (§12.4).
func TestLinkTreeConditions(t *testing.T) {
	category, _ := testModels(t)
	m, err := NewModel(doc{}, "Doc", WithName("Doc"), WithRaw(M{"linkTree": LinkTree{Field: Ptr("topic"), DependNode: Ptr(true)}}))
	if err != nil {
		t.Fatal(err)
	}
	node, _ := NewNode(Config{Name: "n", AccessToken: "secret", Servers: []string{"http://127.0.0.1:1"}})
	if err := node.Register(category, NewMemoryRepository()); err != nil {
		t.Fatal(err)
	}
	if err := node.Register(m, NewMemoryRepository(Record{"title": "a", "topic": 1}, Record{"title": "b", "topic": 2}, Record{"title": "c", "topic": 3})); err != nil {
		t.Fatal(err)
	}
	_, build := serve(node, "GET", "/erupt-api/build/Doc", "Doc", "", nil)
	if lt := build["eruptModel"].(map[string]any)["eruptJson"].(map[string]any)["linkTree"]; !reflect.DeepEqual(lt, map[string]any{"field": "topic", "dependNode": true}) {
		t.Errorf("linkTree declared %v", lt)
	}
	for body, want := range map[string][]string{
		`{"condition":[{"key":"id","expression":"NULL"}]}`:                {},
		`{"condition":[{"key":"topic","expression":"IN","value":[2]}]}`:   {"b"},
		`{"condition":[{"key":"topic","expression":"IN","value":[1,2]}]}`: {"a", "b"},
		`{}`: {"a", "b", "c"},
	} {
		if _, page := serve(node, "POST", "/erupt-api/data/table/Doc", "Doc", body, nil); !reflect.DeepEqual(titlesOf(page), want) {
			t.Errorf("%s: %v, want %v", body, titlesOf(page), want)
		}
	}
}
