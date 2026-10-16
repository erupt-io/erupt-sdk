// A blog admin served from Go, stored in SQLite: the showcase model of SHOWCASE.md. Create the node on the
// erupt server first, then:
//
//	ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 go run ./examples/blog
//
// ERUPT_NODE_NAME (default blog), PORT (9090) and ERUPT_DB (blog.db) are optional.
package main

import (
	"context"
	"database/sql"
	"log"
	"os"
	"time"

	erupt "github.com/erupt-io/erupt-sdk/go"
	_ "modernc.org/sqlite"
)

type Category struct {
	ID     int64  `json:"id" erupt:"pk"`
	Name   string `json:"name" erupt:"title=Name;search;notNull;sortable"`
	Parent *int64 `json:"parent" erupt:"title=Parent Id"`
	Sort   int64  `json:"sort" erupt:"title=Sort;sortable"`
}

type PublishForm struct {
	PublishDate time.Time `json:"publish_date" erupt:"title=Publish Date;type=DATE;notNull"`
}

// Edit types without a shortcut are declared as their storage type (INPUT, TEXTAREA, NUMBER) and turned into
// the real type by a raw @Edit (WithFieldEdit) below.
type Article struct {
	ID          int64     `json:"id" erupt:"pk"`
	Title       string    `json:"title" erupt:"title=Title;search;notNull;sortable"`
	Summary     string    `json:"summary" erupt:"title=Summary;type=TEXTAREA;hideTable"`
	Category    int64     `json:"category" erupt:"title=Category;ref=Category;search"`
	Topic       int64     `json:"topic" erupt:"title=Topic;ref=Category;tree=parent;hideTable"`
	Status      string    `json:"status" erupt:"title=Status;choices=draft:Draft,review:In Review,published:Published;search"`
	Tags        string    `json:"tags" erupt:"title=Tags"`
	Views       int64     `json:"views" erupt:"title=Views;sortable"`
	Price       float64   `json:"price" erupt:"title=Price"`
	Rating      float64   `json:"rating" erupt:"title=Rating"`
	Progress    int64     `json:"progress" erupt:"title=Progress"`
	Featured    bool      `json:"featured" erupt:"title=Featured;search"`
	Color       string    `json:"color" erupt:"title=Theme Color"`
	Icon        string    `json:"icon" erupt:"title=Icon;hideTable"`
	PublishDate time.Time `json:"publish_date" erupt:"title=Publish Date;type=DATE;search"`
	ReviewAt    time.Time `json:"review_at" erupt:"title=Review At;sortable"`
	Content     string    `json:"content" erupt:"title=Content;type=TEXTAREA;hideTable"`
	Notes       string    `json:"notes" erupt:"title=Notes;type=TEXTAREA;hideTable"`
	Meta        string    `json:"meta" erupt:"title=Meta (JSON);type=TEXTAREA;hideTable"`
}

// Component holds every component that needs no extra endpoint. Virtual fields (DIVIDE, CALLOUT, EMPTY, GROUP)
// are in the build only; a slice or map field (MULTI_CHOICE, KEY_VALUE) is a JSON value.
type Component struct {
	ID        int64             `json:"id" erupt:"pk"`
	Name      string            `json:"name" erupt:"title=Name;search;notNull"`
	Intro     string            `json:"intro" erupt:"title=Guide;virtual"`
	Basic     string            `json:"basic" erupt:"title=Basic;virtual"`
	Code      string            `json:"code" erupt:"title=Code;hideTable"`
	Roles     []string          `json:"roles" erupt:"title=Roles;choices=ADMIN:Admin,USER:User,GUEST:Guest"`
	Langs     []string          `json:"langs" erupt:"title=Languages;choices=JAVA:Java,PYTHON:Python,GO:Go,RUST:Rust"`
	Attrs     map[string]string `json:"attrs" erupt:"title=Attributes"`
	Spacer    string            `json:"spacer" erupt:"virtual"`
	Extra     string            `json:"extra" erupt:"title=Extra;virtual"`
	Location  string            `json:"location" erupt:"title=Location"`
	Signature string            `json:"signature" erupt:"title=Signature;hideTable"`
	Place     string            `json:"place" erupt:"title=Place & Sign;virtual"`
}

func main() {
	category := must(erupt.NewModel(Category{}, "Category"))
	publishForm := must(erupt.NewModel(PublishForm{}, "Publish Options"))
	article := must(erupt.NewModel(Article{}, "Article", erupt.WithOrderBy("id desc"), erupt.WithPower(map[string]bool{"importable": true}),
		erupt.WithFieldEdit("title", erupt.M{"inputType": erupt.M{"length": 60}}),
		erupt.WithFieldEdit("summary", erupt.M{"textareaType": erupt.M{"length": 200}}),
		erupt.WithFieldEdit("tags", erupt.M{"type": "TAGS", "tagsType": erupt.M{"allowExtension": true, "joinSeparator": ","}}),
		erupt.WithFieldEdit("views", erupt.M{"numberType": erupt.M{"min": 0}}),
		erupt.WithFieldEdit("price", erupt.M{"numberType": erupt.M{"min": 0, "precision": 2, "prefix": "$"}}),
		erupt.WithFieldEdit("rating", erupt.M{"type": "RATE", "rateType": erupt.M{"count": 5, "allowHalf": true}}),
		erupt.WithFieldEdit("progress", erupt.M{"type": "SLIDER", "sliderType": erupt.M{"min": 0, "max": 100, "step": 5}}),
		erupt.WithFieldEdit("color", erupt.M{"type": "COLOR"}),
		erupt.WithFieldEdit("icon", erupt.M{"type": "ICON"}),
		erupt.WithFieldEdit("content", erupt.M{"type": "HTML_EDITOR"}),
		erupt.WithFieldEdit("notes", erupt.M{"type": "MARKDOWN"}),
		erupt.WithFieldEdit("meta", erupt.M{"type": "CODE_EDITOR", "codeEditType": erupt.M{"language": "json"}}),
		erupt.WithOperations(
			erupt.Operation{Code: "publish", Title: "Publish", Icon: "fa fa-paper-plane", Form: publishForm,
				IfExpr: "item.status !== 'published'",
				Handler: func(op *erupt.OpContext) (string, error) {
					for _, row := range op.Rows {
						change := erupt.Record{"status": "published", "publish_date": op.Param["publish_date"]}
						if err := op.Repo.Update(op.Context, row["id"], change); err != nil {
							return "", err
						}
					}
					return "", nil
				}},
			erupt.Operation{Code: "feature", Title: "Feature", Mode: erupt.RowOperationModeSingle, Icon: "fa fa-star",
				Confirm: "Feature this article on the home page?",
				Handler: func(op *erupt.OpContext) (string, error) {
					return "", op.Repo.Update(op.Context, op.Rows[0]["id"], erupt.Record{"featured": true})
				}},
		)))

	component := must(erupt.NewModel(Component{}, "Component",
		erupt.WithFieldEdit("intro", erupt.M{"type": "CALLOUT", "calloutType": erupt.M{
			"value": "Every component a node can declare without extra endpoints.", "style": "INFO"}}),
		erupt.WithFieldEdit("basic", erupt.M{"type": "DIVIDE"}),
		erupt.WithFieldEdit("code", erupt.M{"type": "HIDDEN"}),
		erupt.WithFieldEdit("roles", erupt.M{"type": "MULTI_CHOICE", "multiChoiceType": erupt.M{"type": "CHECKBOX"}}),
		erupt.WithFieldEdit("langs", erupt.M{"type": "MULTI_CHOICE", "multiChoiceType": erupt.M{"type": "SELECT"}}),
		erupt.WithFieldEdit("attrs", erupt.M{"type": "KEY_VALUE", "keyValueType": erupt.M{"keyPlaceholder": "Key", "valuePlaceholder": "Value"}}),
		erupt.WithFieldEdit("spacer", erupt.M{"type": "EMPTY"}),
		erupt.WithFieldEdit("extra", erupt.M{"type": "DIVIDE"}),
		erupt.WithFieldEdit("location", erupt.M{"type": "MAP"}),
		erupt.WithFieldEdit("signature", erupt.M{"type": "SIGNATURE"}),
		erupt.WithFieldEdit("place", erupt.M{"type": "GROUP", "groupType": erupt.M{"fields": []string{"location", "signature"}}}),
	))

	db := must(sql.Open("sqlite", envOr("ERUPT_DB", "blog.db")))
	db.SetMaxOpenConns(1) // SQLite: one writer
	categories := &erupt.SQLRepository{DB: db, Table: "category", AutoCreate: true}
	articles := &erupt.SQLRepository{DB: db, Table: "article", AutoCreate: true}
	components := &erupt.SQLRepository{DB: db, Table: "component", AutoCreate: true}
	node := must(erupt.NewNode(erupt.Config{Name: envOr("ERUPT_NODE_NAME", "blog"), AccessToken: os.Getenv("ERUPT_ACCESS_TOKEN"),
		Servers: []string{envOr("ERUPT_SERVER", "http://localhost:8080")}}))
	check(node.Register(category, categories))
	check(node.Register(article, articles))
	check(node.Register(component, components))
	seed(categories, articles)
	seedComponents(components)
	check(node.ListenAndServe(":" + envOr("PORT", "9090")))
}

// seed fills empty tables with the showcase records; references are stored as the key only
func seed(categories, articles erupt.Repository) {
	ctx := context.Background()
	if total, _, err := categories.Page(ctx, erupt.Query{Limit: 1}); err != nil || total > 0 {
		check(err)
		return
	}
	for _, c := range []erupt.Record{
		{"name": "Tech", "parent": nil, "sort": 1}, {"name": "Python", "parent": 1, "sort": 2},
		{"name": "Go", "parent": 1, "sort": 3}, {"name": "Life", "parent": nil, "sort": 4},
		{"name": "Travel", "parent": 4, "sort": 5},
	} {
		check(categories.Add(ctx, c))
	}
	day := func(s string) time.Time { return must(time.Parse("2006-01-02", s)) }
	for _, a := range []erupt.Record{
		{"title": "Hello Erupt", "summary": "A first look at erupt nodes.", "category": 2, "topic": 2, "status": "published",
			"tags": "intro,erupt", "views": 120, "price": 9.9, "rating": 4.5, "progress": 100, "featured": true,
			"color": "#1677ff", "icon": "fa fa-book", "publish_date": day("2026-10-01"),
			"review_at": must(time.Parse(time.DateTime, "2026-10-02 10:00:00")),
			"content":   "<p>Hello</p>", "notes": "# Hello", "meta": `{"a":1}`},
		{"title": "Go Tips", "category": 3, "topic": 3, "status": "review", "tags": "go", "views": 30, "price": 0,
			"rating": 3, "progress": 60, "featured": false},
		{"title": "Weekend Trip", "category": 5, "topic": 5, "status": "draft", "views": 0, "rating": 0, "progress": 10,
			"featured": false},
	} {
		check(articles.Add(ctx, a))
	}
}

func seedComponents(components erupt.Repository) {
	ctx := context.Background()
	if total, _, err := components.Page(ctx, erupt.Query{Limit: 1}); err != nil || total > 0 {
		check(err)
		return
	}
	for _, c := range []erupt.Record{
		{"name": "Sample A", "code": "C-001", "roles": []any{"ADMIN", "USER"}, "langs": []any{"JAVA", "GO"},
			"attrs": map[string]any{"env": "prod", "tier": "1"}},
		{"name": "Sample B", "code": "C-002", "roles": []any{"GUEST"}, "langs": []any{"PYTHON"}, "attrs": map[string]any{}},
	} {
		check(components.Add(ctx, c))
	}
}

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func must[T any](v T, err error) T {
	check(err)
	return v
}

func check(err error) {
	if err != nil {
		log.Fatal(err)
	}
}
