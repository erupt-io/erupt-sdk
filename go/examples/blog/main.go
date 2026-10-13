// A blog admin served from Go. Create node "blog" on the erupt server first, then:
//
//	ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 go run ./examples/blog
//
// Records live in memory; use erupt.SQLRepository with any database/sql driver to persist them.
package main

import (
	"log"
	"os"
	"time"

	erupt "github.com/erupt-io/erupt-sdk/go"
)

type Category struct {
	ID     int64  `json:"id" erupt:"pk"`
	Name   string `json:"name" erupt:"title=Name;search;notNull"`
	Parent int64  `json:"parent" erupt:"title=Parent Id"`
}

type PublishForm struct {
	PublishDate time.Time `json:"publish_date" erupt:"title=Publish Date;type=DATE;notNull"`
}

type Article struct {
	ID          int64     `json:"id" erupt:"pk"`
	Title       string    `json:"title" erupt:"title=Title;search;notNull;sortable"`
	Category    int64     `json:"category" erupt:"title=Category;ref=Category;search"`
	Topic       int64     `json:"topic" erupt:"title=Topic;ref=Category;tree=parent;hideTable"`
	Status      string    `json:"status" erupt:"title=Status;choices=draft:Draft,published:Published;search"`
	Views       int64     `json:"views" erupt:"title=Views;sortable"`
	Featured    bool      `json:"featured" erupt:"title=Featured;search"`
	PublishDate time.Time `json:"publish_date" erupt:"title=Publish Date;type=DATE;search"`
	ReviewAt    time.Time `json:"review_at" erupt:"title=Review At;sortable"`
	Body        string    `json:"body" erupt:"title=Body;type=TEXTAREA;hideTable"`
}

func main() {
	category := must(erupt.NewModel(Category{}, "Category"))
	publishForm := must(erupt.NewModel(PublishForm{}, "Publish Options"))
	article := must(erupt.NewModel(Article{}, "Article", erupt.WithOrderBy("id desc"), erupt.WithOperations(
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

	server := os.Getenv("ERUPT_SERVER")
	if server == "" {
		server = "http://localhost:8080"
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "9090"
	}
	node := must(erupt.NewNode(erupt.Config{Name: "blog", AccessToken: os.Getenv("ERUPT_ACCESS_TOKEN"), Servers: []string{server}}))
	check(node.Register(category, erupt.NewMemoryRepository()))
	check(node.Register(article, erupt.NewMemoryRepository()))
	check(node.ListenAndServe(":" + port))
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
