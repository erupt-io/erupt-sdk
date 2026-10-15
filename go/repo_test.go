package erupt

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

func newSQLite(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1) // one connection, one in-memory database
	t.Cleanup(func() { db.Close() })
	return db
}

func repositories(t *testing.T) map[string]func() Repository {
	return map[string]func() Repository{
		"memory": func() Repository { return NewMemoryRepository() },
		"sqlite": func() Repository { return &SQLRepository{DB: newSQLite(t), Table: "article", AutoCreate: true} },
	}
}

func TestRepositories(t *testing.T) {
	ctx := context.Background()
	for name, factory := range repositories(t) {
		t.Run(name, func(t *testing.T) {
			_, article := testModels(t)
			repo := factory()
			if err := repo.(Binder).Bind(article); err != nil {
				t.Fatal(err)
			}
			day := func(d int) time.Time { return time.Date(2026, 1, d, 0, 0, 0, 0, time.UTC) }
			for i, title := range []string{"100% pure", "100 points", "under_score", "plain"} {
				rec := Record{"title": title, "views": int64(i), "featured": i%2 == 0, "publish_date": day(i + 1),
					"review_at": time.Date(2026, 1, 1, 10, i, 0, 0, time.UTC), "status": "draft"}
				if err := repo.Add(ctx, rec); err != nil {
					t.Fatal(err)
				}
			}
			titles := func(q Query) []string {
				total, records, err := repo.Page(ctx, q)
				if err != nil {
					t.Fatal(err)
				}
				out := []string{}
				for _, r := range records {
					out = append(out, r["title"].(string))
				}
				if q.Limit == 0 && int(total) != len(out) {
					t.Errorf("total %d for %d rows", total, len(out))
				}
				return out
			}
			asc := []Order{{Field: "views"}}
			check := func(what string, got, want []string) {
				t.Helper()
				if !reflect.DeepEqual(got, want) {
					t.Errorf("%s: got %v, want %v", what, got, want)
				}
			}
			check("LIKE escapes %", titles(Query{Conditions: []Cond{{"title", "LIKE", "100%"}}, Sort: asc, Limit: 10}), []string{"100% pure"})
			check("LIKE escapes _", titles(Query{Conditions: []Cond{{"title", "LIKE", "R_S"}}, Sort: asc, Limit: 10}), []string{"under_score"})
			check("NOT_LIKE", titles(Query{Conditions: []Cond{{"title", "NOT_LIKE", "100"}}, Sort: asc, Limit: 10}), []string{"under_score", "plain"})
			check("RANGE date", titles(Query{Conditions: []Cond{{"publish_date", "RANGE", []any{day(2), day(3)}}}, Sort: asc, Limit: 10}), []string{"100 points", "under_score"})
			check("GTE", titles(Query{Conditions: []Cond{{"views", "GTE", int64(2)}}, Sort: asc, Limit: 10}), []string{"under_score", "plain"})
			check("EQ bool", titles(Query{Conditions: []Cond{{"featured", "EQ", true}}, Sort: asc, Limit: 10}), []string{"100% pure", "under_score"})
			check("IN", titles(Query{Conditions: []Cond{{"views", "IN", []any{int64(0), int64(3)}}}, Sort: asc, Limit: 10}), []string{"100% pure", "plain"})
			check("empty IN", titles(Query{Conditions: []Cond{{"views", "IN", []any{}}}, Limit: 10}), []string{})
			check("NULL", titles(Query{Conditions: []Cond{{"body", "NULL", nil}}, Sort: asc, Limit: 10}), []string{"100% pure", "100 points", "under_score", "plain"})
			check("default order is primary key ascending", titles(Query{Limit: 10}), []string{"100% pure", "100 points", "under_score", "plain"})
			check("LIKE escapes !", titles(Query{Conditions: []Cond{{"title", "LIKE", "!"}}, Limit: 10}), []string{})
			check("sort desc + page", titles(Query{Sort: []Order{{Field: "views", Desc: true}}, Offset: 1, Limit: 2}), []string{"under_score", "100 points"})

			_, records, _ := repo.Page(ctx, Query{Sort: asc, Limit: 1})
			got := records[0]
			if got["publish_date"] != day(1) || got["review_at"] != time.Date(2026, 1, 1, 10, 0, 0, 0, time.UTC) || got["featured"] != true {
				t.Errorf("round trip: %#v", got)
			}
			pk := got["id"]
			if err := repo.Update(ctx, pk, Record{"title": "renamed", "id": int64(999)}); err != nil {
				t.Fatal(err)
			}
			if r, _ := repo.Get(ctx, pk); r == nil || r["title"] != "renamed" || r["views"] != int64(0) {
				t.Errorf("update: %#v", r)
			}
			if err := repo.Delete(ctx, []any{pk}); err != nil {
				t.Fatal(err)
			}
			if r, _ := repo.Get(ctx, pk); r != nil {
				t.Errorf("deleted record still there: %#v", r)
			}
		})
	}
}

func TestSQLGeneration(t *testing.T) {
	_, article := testModels(t)
	repo := &SQLRepository{Table: "article", Dollar: true, Quote: `"`}
	repo.model = article
	_, countArgs, page, args := repo.pageSQL(Query{Conditions: []Cond{
		{"title", "LIKE", `50%_off!`}, {"views", "IN", []any{int64(1), int64(2)}}, {"publish_date", "RANGE", []any{time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC), time.Date(2026, 2, 1, 0, 0, 0, 0, time.UTC)}},
	}, Sort: []Order{{Field: "title", Desc: true}}, Offset: 20, Limit: 10})
	want := `SELECT "id", "title", "status", "views", "featured", "publish_date", "review_at", "body", "category", "topic" FROM "article"` +
		` WHERE "title" LIKE $1 ESCAPE '!' AND "views" IN ($2, $3) AND "publish_date" BETWEEN $4 AND $5 ORDER BY "title" DESC LIMIT $6 OFFSET $7`
	if page != want {
		t.Errorf("page SQL\n got %s\nwant %s", page, want)
	}
	if !reflect.DeepEqual(args, []any{"%50!%!_off!!%", int64(1), int64(2), "2026-01-01", "2026-02-01", 10, 20}) {
		t.Errorf("args %#v", args)
	}
	if len(countArgs) != 5 {
		t.Errorf("count args %#v", countArgs)
	}
	if got := (&SQLRepository{Quote: "`"}).q("a`b"); got != "`a``b`" {
		t.Errorf("quote %s", got)
	}
	if err := (&SQLRepository{Table: "x; DROP TABLE y"}).Bind(article); err == nil {
		t.Error("an illegal table name was accepted")
	}
}

// TestNodeOverSQLite drives the HTTP handler against a fake erupt server, with SQLite storage.
func TestNodeOverSQLite(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"add":true,"edit":true,"delete":true,"viewDetails":true}`))
	}))
	defer server.Close()
	category, article := testModels(t)
	node, err := NewNode(Config{Name: "n", AccessToken: "secret", Servers: []string{server.URL}})
	if err != nil {
		t.Fatal(err)
	}
	db := newSQLite(t)
	if err := node.Register(category, &SQLRepository{DB: db, Table: "category", AutoCreate: true}); err != nil {
		t.Fatal(err)
	}
	if err := node.Register(article, &SQLRepository{DB: db, Table: "article", AutoCreate: true}); err != nil {
		t.Fatal(err)
	}
	user := base64.StdEncoding.EncodeToString([]byte(`{"uid":1,"account":"admin"}`))
	call := func(method, path, erupt, body string) (int, any) {
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Access-Token", "secret")
		req.Header.Set("erupt", erupt)
		req.Header.Set("user", user)
		w := httptest.NewRecorder()
		node.ServeHTTP(w, req)
		data, _ := io.ReadAll(w.Body)
		var v any
		_ = json.Unmarshal(data, &v)
		return w.Code, v
	}
	for _, name := range []string{"Tech", "Python"} {
		if code, r := call("POST", "/erupt-api/data/modify/Category", "Category", `{"name":"`+name+`"}`); code != 200 || r.(map[string]any)["success"] != true {
			t.Fatalf("add category: %d %v", code, r)
		}
	}
	body := `{"title":"100% pure","status":"draft","views":"7","featured":true,"publish_date":"2026-03-01","review_at":"2026-03-01 08:15:00","category":{"id":"2","name":"Python"}}`
	if code, r := call("POST", "/erupt-api/data/modify/Article", "Article", body); code != 200 || r.(map[string]any)["success"] != true {
		t.Fatalf("add article: %d %v", code, r)
	}
	call("POST", "/erupt-api/data/modify/Article", "Article", `{"title":"100 points"}`)
	code, page := call("POST", "/erupt-api/data/table/Article", "Article",
		`{"pageIndex":1,"pageSize":10,"condition":[{"key":"title","expression":"LIKE","value":"100%"},{"key":"publish_date","expression":"RANGE","value":["2026-02-01","2026-04-01"]}]}`)
	list := page.(map[string]any)["list"].([]any)
	if code != 200 || len(list) != 1 {
		t.Fatalf("table: %d %v", code, page)
	}
	row := list[0].(map[string]any)
	want := map[string]any{"title": "100% pure", "views": 7.0, "featured": true, "publish_date": "2026-03-01",
		"review_at": "2026-03-01T08:15:00.000", "category": 2.0}
	for k, v := range want {
		if !reflect.DeepEqual(row[k], v) {
			t.Errorf("%s: got %#v, want %#v", k, row[k], v)
		}
	}
	// a reference travels as its key; the server adds the label and the flattened column
	if _, ok := row["category_name"]; ok {
		t.Errorf("category_name is the server's to add: %v", row)
	}
}
