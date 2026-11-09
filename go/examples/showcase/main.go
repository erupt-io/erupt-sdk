// The showcase admin served from Go that uses every capability of the SDK, as SHOWCASE.md describes it (the Python
// reference is python/examples/showcase.py). Create the node on the erupt server first, then:
//
//	ERUPT_NODE_NAME=showcase ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 go run ./examples/showcase
//
// PORT (9090) and ERUPT_DB (showcase.db, a SQLite file) are optional.
//
// Edit types without a tag shortcut are declared as the storage type they hold (string / int64 / slice / map) and
// turned into the real type by a raw @Edit (WithFieldEdit). Form-only elements are `virtual`; a slice or map field
// (MULTI_CHOICE, KEY_VALUE, CHECKBOX, TRANSFER, TAB_TREE) holds a JSON value.
//
// A searched MULTI_CHOICE (Component.roles) matches each picked value as "<value>" in its JSON text.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"log/slog"
	"os"
	"strings"
	"sync/atomic"
	"time"

	erupt "github.com/erupt-io/erupt-sdk/go"
	_ "modernc.org/sqlite"
)

// ---------------------------------------------------------------- reference data

type Category struct {
	ID     int64  `json:"id" erupt:"pk"`
	Name   string `json:"name" erupt:"title=Name;search;notNull;sortable"`
	Parent *int64 `json:"parent" erupt:"title=Parent Id"`
	Sort   int64  `json:"sort" erupt:"title=Sort;sortable"`
}

type Author struct {
	ID     int64  `json:"id" erupt:"pk"`
	Name   string `json:"name" erupt:"title=Name;search;notNull"`
	Email  string `json:"email" erupt:"title=Email"`
	Active bool   `json:"active" erupt:"title=Active;search;notNull"`
}

type Tag struct {
	ID    int64  `json:"id" erupt:"pk"`
	Name  string `json:"name" erupt:"title=Name;search;notNull"`
	Color string `json:"color" erupt:"title=Color;type=COLOR"`
}

// PublishForm is the form of the Publish operation; it is not registered.
type PublishForm struct {
	PublishDate time.Time `json:"publish_date" erupt:"title=Publish Date;type=DATE;notNull"`
}

type AuditLog struct {
	ID      int64     `json:"id" erupt:"pk"`
	Action  string    `json:"action" erupt:"title=Action;search;choices=add:Add,update:Update,delete:Delete"`
	Article string    `json:"article" erupt:"title=Article"`
	Account string    `json:"account" erupt:"title=By;search"`
	At      time.Time `json:"at" erupt:"title=At;sortable"`
}

// ---------------------------------------------------------------- the article: every field type and behaviour

type Article struct {
	ID          int64     `json:"id" erupt:"pk"`
	Title       string    `json:"title" erupt:"title=Title;search;notNull;sortable"`
	Summary     string    `json:"summary" erupt:"title=Summary;type=TEXTAREA;hideTable"`
	Author      int64     `json:"author" erupt:"title=Author;ref=Author;search"`
	Category    int64     `json:"category" erupt:"title=Category;ref=Category;search"`
	SubCategory int64     `json:"sub_category" erupt:"title=Sub Category;ref=Category;hideTable"`
	Topic       int64     `json:"topic" erupt:"title=Topic;ref=Category;tree=parent;hideTable"`
	TagIDs      []int64   `json:"tag_ids" erupt:"title=Tags (checkbox);type=CHECKBOX;ref=Tag;hideTable"`
	Reviewers   []int64   `json:"reviewers" erupt:"title=Reviewers;type=TRANSFER;ref=Author;hideTable"`
	Sections    []int64   `json:"sections" erupt:"title=Sections;type=TAB_TREE;ref=Category;hideTable"`
	Status      string    `json:"status" erupt:"title=Status;search;choices=draft:Draft,review:In Review,published:Published,archived:Archived"`
	Level       string    `json:"level" erupt:"title=Level"` // a CHOICE whose options are fetched (WithFieldCode)
	Labels      string    `json:"labels" erupt:"title=Labels;type=TAGS"`
	City        string    `json:"city" erupt:"title=City;type=AUTO_COMPLETE"`
	Cover       string    `json:"cover" erupt:"title=Cover;type=ATTACHMENT"`
	Views       int64     `json:"views" erupt:"title=Views;sortable"`
	Price       float64   `json:"price" erupt:"title=Price"`
	Rating      float64   `json:"rating" erupt:"title=Rating;type=RATE;sortable"`
	Progress    int64     `json:"progress" erupt:"title=Progress;type=SLIDER"`
	Featured    bool      `json:"featured" erupt:"title=Featured;search"`
	Color       string    `json:"color" erupt:"title=Theme Color;type=COLOR"`
	Icon        string    `json:"icon" erupt:"title=Icon;type=ICON;hideTable"`
	PublishDate time.Time `json:"publish_date" erupt:"title=Publish Date;type=DATE;search"`
	ReviewAt    time.Time `json:"review_at" erupt:"title=Review At;sortable"`
	Content     string    `json:"content" erupt:"title=Content;type=HTML_EDITOR;hideTable"`
	Notes       string    `json:"notes" erupt:"title=Notes;type=MARKDOWN;hideTable"`
	Meta        string    `json:"meta" erupt:"title=Meta (JSON);type=CODE_EDITOR;hideTable"`
	Preview     string    `json:"preview" erupt:"title=Preview;type=BUTTON"`
}

// ---------------------------------------------------------------- the node's own code (invoke)

var cities = []string{"Paris", "Tokyo", "Lisbon", "Austin"}

var articleCode = map[string]erupt.FieldCode{
	// title onchange: suggest a summary while there is none
	"title": {Onchange: func(_ context.Context, form erupt.M) (erupt.Change, error) {
		title, _ := form["title"].(string)
		if summary, _ := form["summary"].(string); title != "" && summary == "" {
			return erupt.Change{FormData: erupt.M{"summary": "About " + title}}, nil
		}
		return erupt.Change{}, nil
	}},
	// level options: an expert level once the article is read a lot
	"level": {Fetch: func(_ context.Context, form erupt.M) ([]erupt.Option, error) {
		options := []erupt.Option{{Value: "beginner", Label: "Beginner"}, {Value: "advanced", Label: "Advanced"}}
		// form numbers arrive as json.Number, as the SDK decodes every body exactly
		views, _ := form["views"].(json.Number)
		if n, _ := views.Float64(); n >= 1000 {
			options = append(options, erupt.Option{Value: "expert", Label: "Expert"})
		}
		return options, nil
	}},
	"labels": {Tags: func(context.Context, erupt.M) ([]string, error) {
		return []string{"hot", "new", "classic"}, nil
	}},
	"city": {Complete: func(_ context.Context, _ erupt.M, typed string) ([]string, error) {
		var matches []string
		for _, c := range cities {
			if strings.Contains(strings.ToLower(c), strings.ToLower(typed)) {
				matches = append(matches, c)
			}
		}
		return matches, nil
	}},
	"preview": {Click: func(_ context.Context, form erupt.M) (erupt.Click, error) {
		title, _ := form["title"].(string)
		text, _ := json.Marshal("Preview: " + title) // a JSON string is a valid JS string literal
		return erupt.Click{Eval: "alert(" + string(text) + ")"}, nil
	}},
}

// ArticleProxy implements every hook of a data proxy; audit is the Audit Log repository.
type ArticleProxy struct {
	erupt.BaseDataProxy
	audit   erupt.Repository
	fetched atomic.Int64
}

func (p *ArticleProxy) SearchCondition(_ context.Context, condition erupt.M) error {
	condition["status"] = "published"
	return nil
}

func (p *ArticleProxy) BeforeFetch(context.Context, []erupt.Cond) (erupt.Filter, error) {
	return erupt.Filter{SQL: "status <> 'archived'"}, nil
}

func (p *ArticleProxy) AfterFetch(_ context.Context, rows []erupt.M) error {
	slog.Debug("rows fetched so far", "count", p.fetched.Add(int64(len(rows))))
	return nil
}

func (p *ArticleProxy) AddBehavior(_ context.Context, record erupt.Record) error {
	record["status"], record["views"], record["progress"] = "draft", 0, 0
	return nil
}

func (p *ArticleProxy) Validate(_ context.Context, record erupt.Record) error {
	if record["title"] == "forbidden" {
		return erupt.Fail("This title is not allowed")
	}
	return nil
}

func (p *ArticleProxy) BeforeAdd(_ context.Context, record erupt.Record) error {
	stampReview(record)
	return nil
}

func (p *ArticleProxy) BeforeUpdate(_ context.Context, record erupt.Record) error {
	stampReview(record)
	return nil
}

func (p *ArticleProxy) AfterAdd(ctx context.Context, record erupt.Record) error {
	return p.log(ctx, "add", record)
}

func (p *ArticleProxy) AfterUpdate(ctx context.Context, record erupt.Record) error {
	return p.log(ctx, "update", record)
}

func (p *ArticleProxy) BeforeDelete(_ context.Context, record erupt.Record) error {
	if record["status"] == "published" {
		return erupt.Fail("Unpublish it first")
	}
	return nil
}

func (p *ArticleProxy) AfterDelete(ctx context.Context, record erupt.Record) error {
	return p.log(ctx, "delete", record)
}

func (p *ArticleProxy) log(ctx context.Context, action string, record erupt.Record) error {
	var account any
	if user := erupt.UserFrom(ctx); user != nil {
		account = user.Account
	}
	return p.audit.Add(ctx, erupt.Record{"action": action, "article": record["title"], "account": account, "at": now()})
}

func stampReview(record erupt.Record) {
	if record["status"] == "review" && record["review_at"] == nil {
		record["review_at"] = now()
	}
}

// now is the local wall clock to the second; the SDK keeps dates as naive wall-clock times in UTC.
func now() time.Time {
	t := time.Now()
	return time.Date(t.Year(), t.Month(), t.Day(), t.Hour(), t.Minute(), t.Second(), 0, time.UTC)
}

func articleOperations(publishForm *erupt.Model) []erupt.Operation {
	return []erupt.Operation{
		{Code: "publish", Title: "Publish", Icon: "fa fa-paper-plane", Form: publishForm, IfExpr: "item.status !== 'published'",
			Handler: func(op *erupt.OpContext) (string, error) {
				for _, row := range op.Rows {
					change := erupt.Record{"status": "published", "publish_date": op.Param["publish_date"]}
					if err := op.Repo.Update(op.Context, row["id"], change); err != nil {
						return "", err
					}
				}
				return "", nil
			}},
		{Code: "feature", Title: "Feature", Mode: erupt.RowOperationModeSingle, Icon: "fa fa-star",
			Confirm: "Feature this article on the home page?",
			Handler: func(op *erupt.OpContext) (string, error) {
				return "", op.Repo.Update(op.Context, op.Rows[0]["id"], erupt.Record{"featured": true})
			}},
		{Code: "archive", Title: "Archive", Mode: erupt.RowOperationModeMultiOnly, Icon: "fa fa-archive", NoConfirm: true,
			Handler: func(op *erupt.OpContext) (string, error) {
				for _, row := range op.Rows {
					if err := op.Repo.Update(op.Context, row["id"], erupt.Record{"status": "archived"}); err != nil {
						return "", err
					}
				}
				return "", nil
			}},
		{Code: "stats", Title: "Stats", Mode: erupt.RowOperationModeButton, Icon: "fa fa-bar-chart",
			Show: func(user *erupt.User) bool { return user != nil && user.Account == "admin" },
			Handler: func(op *erupt.OpContext) (string, error) {
				total, _, err := op.Repo.Page(op.Context, erupt.Query{Limit: 1})
				return fmt.Sprintf("alert('%d articles')", total), err
			}},
	}
}

// ---------------------------------------------------------------- layout and JSON-valued components

// Component: virtual fields (CALLOUT, DIVIDE, EMPTY, GROUP) are in the build only; MULTI_CHOICE and KEY_VALUE hold
// a JSON value.
type Component struct {
	ID        int64             `json:"id" erupt:"pk"`
	Name      string            `json:"name" erupt:"title=Name;search;notNull"`
	Intro     string            `json:"intro" erupt:"title=Guide;virtual"`
	Basic     string            `json:"basic" erupt:"title=Basic;virtual"`
	Code      string            `json:"code" erupt:"title=Code;type=HIDDEN;hideTable"`
	Roles     []string          `json:"roles" erupt:"title=Roles;search;choices=ADMIN:Admin,USER:User,GUEST:Guest"`
	Langs     []string          `json:"langs" erupt:"title=Languages;choices=JAVA:Java,PYTHON:Python,GO:Go,RUST:Rust"`
	Attrs     map[string]string `json:"attrs" erupt:"title=Attributes"`
	Spacer    string            `json:"spacer" erupt:"virtual"`
	Extra     string            `json:"extra" erupt:"title=Extra;virtual"`
	Location  string            `json:"location" erupt:"title=Location;type=MAP"`
	Signature string            `json:"signature" erupt:"title=Signature;type=SIGNATURE;hideTable"`
	Place     string            `json:"place" erupt:"title=Place & Sign;virtual"`
}

// ---------------------------------------------------------------- buttons, form behaviour, table display, server calls

// node is set when the node starts: the Node Info operation calls the server back through it.
var node *erupt.Node

// RenameForm is the form of the Rename operation; it is not registered.
type RenameForm struct {
	Name string `json:"name" erupt:"title=New Name;notNull"`
}

type Playground struct {
	ID     int64    `json:"id" erupt:"pk"`
	Name   string   `json:"name" erupt:"title=Name;search;notNull"`
	Kind   string   `json:"kind" erupt:"title=Kind;search;choices=simple:Simple,advanced:Advanced"`
	Level  string   `json:"level" erupt:"title=Level"` // a CHOICE whose options follow the kind (WithFieldCode)
	Note   string   `json:"note" erupt:"title=Advanced Note;type=TEXTAREA;hideTable"`
	Code   string   `json:"code" erupt:"title=Code"`
	Amount float64  `json:"amount" erupt:"title=Amount"`
	Score  float64  `json:"score" erupt:"title=Score"`
	Skills []string `json:"skills" erupt:"title=Skills"` // a fetched MULTI_CHOICE, a JSON array
	Files  string   `json:"files" erupt:"title=Files;type=ATTACHMENT;hideTable"`
	Fill   string   `json:"fill" erupt:"title=Fill Sample;type=BUTTON"`
	Reset  string   `json:"reset" erupt:"title=Clear;type=BUTTON"`
	Whoami string   `json:"whoami" erupt:"title=Who Am I;type=BUTTON"`
}

func options(pairs ...string) []erupt.Option {
	list := make([]erupt.Option, 0, len(pairs)/2)
	for i := 0; i+1 < len(pairs); i += 2 {
		list = append(list, erupt.Option{Value: pairs[i], Label: pairs[i+1]})
	}
	return list
}

// account is the acting user's account, "" without one.
func account(ctx context.Context) string {
	if user := erupt.UserFrom(ctx); user != nil {
		return user.Account
	}
	return ""
}

// jsString renders text as a JS string literal (a JSON string is one).
func jsString(text string) string {
	quoted, _ := json.Marshal(text)
	return string(quoted)
}

var playgroundCode = map[string]erupt.FieldCode{
	// level options follow the kind (choiceType.dependField)
	"level": {Fetch: func(_ context.Context, form erupt.M) ([]erupt.Option, error) {
		if form["kind"] == "advanced" {
			return options("high", "High", "expert", "Expert"), nil
		}
		return options("low", "Low", "mid", "Mid"), nil
	}},
	"skills": {Fetch: func(context.Context, erupt.M) ([]erupt.Option, error) {
		return options("java", "Java", "python", "Python", "go", "Go"), nil
	}},
	"fill": {Click: func(context.Context, erupt.M) (erupt.Click, error) {
		return erupt.Click{FormData: erupt.M{"name": "sample", "kind": "advanced", "amount": 42, "score": 4}}, nil
	}},
	"reset": {Click: func(context.Context, erupt.M) (erupt.Click, error) {
		return erupt.Click{FormData: erupt.M{"name": "", "amount": 0, "score": 0}}, nil
	}},
	"whoami": {Click: func(ctx context.Context, _ erupt.M) (erupt.Click, error) {
		return erupt.Click{Eval: "alert(" + jsString(account(ctx)) + ")"}, nil
	}},
}

func playgroundOperations(renameForm *erupt.Model) []erupt.Operation {
	return []erupt.Operation{
		{Code: "rename", Title: "Rename", Mode: erupt.RowOperationModeSingle, Form: renameForm, Tip: "Give the row a new name",
			Handler: func(op *erupt.OpContext) (string, error) {
				return "", op.Repo.Update(op.Context, op.Rows[0]["id"], erupt.Record{"name": op.Param["name"]})
			}},
		{Code: "double", Title: "Double", IfExpr: "item.amount > 0", Raw: erupt.M{"ifExprBehavior": "HIDE"},
			Handler: func(op *erupt.OpContext) (string, error) {
				for _, row := range op.Rows {
					var amount float64
					switch n := row["amount"].(type) {
					case int64:
						amount = float64(n)
					case float64:
						amount = n
					}
					if err := op.Repo.Update(op.Context, row["id"], erupt.Record{"amount": amount * 2}); err != nil {
						return "", err
					}
				}
				return "", nil
			}},
		{Code: "reset_amounts", Title: "Reset Amounts", Confirm: "Reset the amounts?", Raw: erupt.M{"fold": true},
			Handler: func(op *erupt.OpContext) (string, error) {
				for _, row := range op.Rows {
					if err := op.Repo.Update(op.Context, row["id"], erupt.Record{"amount": 0}); err != nil {
						return "", err
					}
				}
				return "", nil
			}},
		{Code: "node_info", Title: "Node Info", Mode: erupt.RowOperationModeButton, Icon: "fa fa-info-circle",
			Handler: func(op *erupt.OpContext) (string, error) {
				roles, config := 0, 0 // 0 when a call fails
				if info, err := node.UserInfo(op.Context); err == nil {
					if list, ok := info["roles"].([]any); ok {
						roles = len(list)
					}
				}
				if text, err := node.NodeConfig(op.Context); err == nil {
					config = len(text)
				}
				return "alert(" + jsString(fmt.Sprintf("%s: %d roles, config %d chars", account(op.Context), roles, config)) + ")", nil
			}},
	}
}

// ---------------------------------------------------------------- models

func drill(linkErupt, joinColumn, linkCondition string) erupt.M {
	link := erupt.M{"linkErupt": linkErupt, "joinColumn": joinColumn}
	if linkCondition != "" {
		link["linkCondition"] = linkCondition
	}
	return erupt.M{"title": "Articles", "code": "Articles", "link": link}
}

func models(audit *ArticleProxy) (category, author, tag, article, component, auditLog, playground *erupt.Model) {
	category = must(erupt.NewModel(Category{}, "Category", erupt.WithRaw(erupt.M{
		"tree": erupt.M{"pid": "parent"}, "dragSort": erupt.M{"field": "sort"},
		"drills": []any{drill("Article", "category", "")}})))
	author = must(erupt.NewModel(Author{}, "Author",
		erupt.WithRaw(erupt.M{"drills": []any{drill("Article", "author", "status = 'published'")}}),
		erupt.WithFieldEdit("email", erupt.M{"inputType": erupt.M{"regex": `^[^@\s]+@[^@\s]+\.[^@\s]+$`}})))
	tag = must(erupt.NewModel(Tag{}, "Tag"))
	publishForm := must(erupt.NewModel(PublishForm{}, "Publish Options"))
	auditLog = must(erupt.NewModel(AuditLog{}, "Audit Log", erupt.WithOrderBy("id desc"),
		erupt.WithPower(map[string]bool{"add": false, "edit": false, "delete": false})))

	opts := []erupt.ModelOption{
		erupt.WithOrderBy("id desc"), erupt.WithPower(map[string]bool{"importable": true}), erupt.WithDataProxy(audit),
		erupt.WithRaw(erupt.M{"linkTree": erupt.M{"field": "category"}, "vis": []any{
			erupt.M{"title": "Drafts", "code": "Drafts", "type": "TABLE", "filter": "status = 'draft'", "orderBy": "views desc"},
			erupt.M{"title": "Board", "code": "Board", "type": "BOARD", "boardView": erupt.M{"groupField": "status", "sumField": "views"}},
			erupt.M{"title": "Calendar", "code": "Calendar", "type": "CALENDAR", "calendarView": erupt.M{"dateField": "publish_date"}},
			erupt.M{"title": "Cards", "code": "Cards", "type": "CARD", "cardView": erupt.M{"coverField": "cover"}},
			erupt.M{"title": "Timeline", "code": "Timeline", "type": "TIMELINE", "timelineView": erupt.M{"dateField": "review_at"}},
		}}),
		erupt.WithFieldEdit("title", erupt.M{"inputType": erupt.M{"length": 60}}),
		erupt.WithFieldEdit("summary", erupt.M{"textareaType": erupt.M{"length": 200}}),
		erupt.WithFieldEdit("sub_category", erupt.M{"referenceTableType": erupt.M{"dependField": "category", "dependColumn": "parent"}}),
		erupt.WithFieldEdit("labels", erupt.M{"tagsType": erupt.M{"allowExtension": true, "joinSeparator": ","}}),
		erupt.WithFieldEdit("city", erupt.M{"autoCompleteType": erupt.M{"triggerLength": 1}}),
		erupt.WithFieldEdit("cover", erupt.M{"attachmentType": erupt.M{"type": "IMAGE", "maxLimit": 1}}),
		erupt.WithFieldEdit("views", erupt.M{"numberType": erupt.M{"min": 0}}),
		erupt.WithFieldEdit("price", erupt.M{"numberType": erupt.M{"min": 0, "precision": 2, "prefix": "$"}}),
		erupt.WithFieldEdit("rating", erupt.M{"rateType": erupt.M{"count": 5, "allowHalf": true}}),
		erupt.WithFieldEdit("progress", erupt.M{"sliderType": erupt.M{"min": 0, "max": 100, "step": 5}}),
		erupt.WithFieldEdit("publish_date", erupt.M{"search": erupt.M{"operator": "RANGE"}}),
		erupt.WithFieldEdit("meta", erupt.M{"codeEditType": erupt.M{"language": "json"}}),
		erupt.WithOperations(articleOperations(publishForm)...),
	}
	for name, code := range articleCode {
		opts = append(opts, erupt.WithFieldCode(name, code))
	}
	article = must(erupt.NewModel(Article{}, "Article", opts...))

	component = must(erupt.NewModel(Component{}, "Component",
		erupt.WithFieldEdit("intro", erupt.M{"type": "CALLOUT", "calloutType": erupt.M{
			"value": "Layout and JSON-valued components.", "style": "INFO"}}),
		erupt.WithFieldEdit("basic", erupt.M{"type": "DIVIDE"}),
		erupt.WithFieldEdit("roles", erupt.M{"type": "MULTI_CHOICE", "multiChoiceType": erupt.M{"type": "CHECKBOX"}}),
		erupt.WithFieldEdit("langs", erupt.M{"type": "MULTI_CHOICE", "multiChoiceType": erupt.M{"type": "SELECT"}}),
		erupt.WithFieldEdit("attrs", erupt.M{"type": "KEY_VALUE", "keyValueType": erupt.M{"keyPlaceholder": "Key", "valuePlaceholder": "Value"}}),
		erupt.WithFieldEdit("spacer", erupt.M{"type": "EMPTY"}),
		erupt.WithFieldEdit("extra", erupt.M{"type": "DIVIDE"}),
		erupt.WithFieldEdit("place", erupt.M{"type": "GROUP", "groupType": erupt.M{"fields": []string{"location", "signature"}}}),
	))

	opts = []erupt.ModelOption{
		erupt.WithName("Playground"), erupt.WithPower(map[string]bool{"export": false}),
		erupt.WithRaw(erupt.M{"layout": erupt.M{"pageSize": 20, "tableLeftFixed": 1}}),
		erupt.WithFieldEdit("name", erupt.M{"search": erupt.M{"operator": "LIKE", "lockOperator": true},
			"inputType": erupt.M{"prefix": []any{erupt.M{"value": "@", "label": "@"}},
				"suffix": []any{erupt.M{"value": ".dev", "label": ".dev"}, erupt.M{"value": ".io", "label": ".io"}}},
			"placeHolder": "a short name", "desc": "Shown first in the table"}),
		erupt.WithFieldEdit("level", erupt.M{"choiceType": erupt.M{"dependField": "kind"}}),
		erupt.WithFieldEdit("note", erupt.M{"dynamic": erupt.M{
			"dependField": "kind", "condition": "value === 'advanced'", "match": "SHOW", "noMatch": "HIDE"}}),
		erupt.WithFieldEdit("code", erupt.M{"readOnly": erupt.M{"add": false, "edit": true}}),
		erupt.WithFieldEdit("amount", erupt.M{"numberType": erupt.M{"prefix": "$"}}),
		erupt.WithFieldView("amount", erupt.M{"statistic": "SUM", "className": "text-right", "width": "120px"}),
		erupt.WithFieldView("score", erupt.M{"statistic": "AVG"}),
		erupt.WithFieldEdit("files", erupt.M{"attachmentType": erupt.M{"type": "BASE", "maxLimit": 3, "fileTypes": []string{"pdf", "txt", "md"}}}),
		erupt.WithFieldEdit("fill", erupt.M{"buttonType": erupt.M{"style": "primary", "icon": "fa fa-magic"}}),
		erupt.WithFieldEdit("reset", erupt.M{"buttonType": erupt.M{"danger": true, "confirm": "Clear the form?"}}),
		erupt.WithFieldEdit("whoami", erupt.M{"buttonType": erupt.M{"fullSpan": true, "icon": "fa fa-user"}}),
		erupt.WithOperations(playgroundOperations(must(erupt.NewModel(RenameForm{}, "Rename")))...),
	}
	for name, code := range playgroundCode {
		opts = append(opts, erupt.WithFieldCode(name, code))
	}
	playground = must(erupt.NewModel(Playground{}, "Buttons & Forms", opts...))
	return
}

// ---------------------------------------------------------------- seed data

func day(s string) time.Time { return must(time.Parse("2006-01-02", s)) }

var (
	categories = []erupt.Record{{"name": "Tech", "parent": nil, "sort": 1}, {"name": "Python", "parent": 1, "sort": 2},
		{"name": "Go", "parent": 1, "sort": 3}, {"name": "Life", "parent": nil, "sort": 4}, {"name": "Travel", "parent": 4, "sort": 5}}
	authors = []erupt.Record{{"name": "Ann", "email": "ann@example.com", "active": true},
		{"name": "Bob", "email": "bob@example.com", "active": true}, {"name": "Cy", "email": "cy@example.com", "active": false}}
	tags = []erupt.Record{{"name": "intro", "color": "#1677ff"}, {"name": "guide", "color": "#52c41a"},
		{"name": "news", "color": "#fa8c16"}}
	articles = []erupt.Record{
		{"title": "Hello Erupt", "summary": "A first look at erupt nodes", "author": 1, "category": 2, "topic": 2,
			"tag_ids": []any{1, 2}, "reviewers": []any{2}, "sections": []any{1, 2}, "status": "published", "level": "beginner",
			"labels": "hot,new", "city": "Paris", "views": 120, "price": 9.9, "rating": 4.5, "progress": 100, "featured": true,
			"color": "#1677ff", "icon": "fa fa-book", "publish_date": day("2026-10-01"),
			"review_at": must(time.Parse(time.DateTime, "2026-10-02 10:00:00")), "content": "<p>Hello</p>",
			"notes": "# Hello", "meta": `{"a":1}`},
		{"title": "Go Tips", "author": 2, "category": 3, "topic": 3, "tag_ids": []any{2}, "status": "review", "level": "advanced",
			"labels": "classic", "views": 30, "price": 0, "rating": 3, "progress": 60, "featured": false},
		{"title": "Weekend Trip", "author": 3, "category": 5, "topic": 5, "status": "draft", "views": 0, "rating": 0,
			"progress": 10, "featured": false},
	}
	playgroundRows = []erupt.Record{
		{"name": "alpha", "kind": "simple", "level": "low", "code": "A-1", "amount": 10, "score": 3, "skills": []any{"java"}},
		{"name": "beta", "kind": "advanced", "level": "expert", "note": "deep dive", "code": "B-1", "amount": 0, "score": 5,
			"skills": []any{"python", "go"}},
		{"name": "gamma", "kind": "simple", "level": "mid", "code": "G-1", "amount": 25, "score": 4, "skills": []any{}},
	}
	components = []erupt.Record{
		{"name": "Sample A", "code": "C-001", "roles": []any{"ADMIN", "USER"}, "langs": []any{"JAVA", "GO"},
			"attrs": map[string]any{"env": "prod", "tier": "1"}},
		{"name": "Sample B", "code": "C-002", "roles": []any{"GUEST"}, "langs": []any{"PYTHON"}, "attrs": map[string]any{}},
	}
)

// seed fills a table only while it is empty; a reference is stored as the referenced key.
func seed(repo erupt.Repository, records []erupt.Record) {
	ctx := context.Background()
	total, _, err := repo.Page(ctx, erupt.Query{Limit: 1})
	check(err)
	for i := 0; total == 0 && i < len(records); i++ {
		check(repo.Add(ctx, records[i]))
	}
}

func main() {
	db := must(sql.Open("sqlite", envOr("ERUPT_DB", "showcase.db")))
	db.SetMaxOpenConns(1) // SQLite: one writer
	repo := func(table string) *erupt.SQLRepository {
		return &erupt.SQLRepository{DB: db, Table: table, AutoCreate: true}
	}
	audits := repo("audit_log")
	proxy := &ArticleProxy{audit: audits}
	category, author, tag, article, component, auditLog, playground := models(proxy)

	node = must(erupt.NewNode(erupt.Config{Name: envOr("ERUPT_NODE_NAME", "showcase"), AccessToken: os.Getenv("ERUPT_ACCESS_TOKEN"),
		Servers: []string{envOr("ERUPT_SERVER", "http://localhost:8080")}}))
	// a referenced model is registered before the models that reference it
	for _, r := range []struct {
		model *erupt.Model
		repo  *erupt.SQLRepository
		seed  []erupt.Record
	}{
		{category, repo("category"), categories}, {author, repo("author"), authors}, {tag, repo("tag"), tags},
		{auditLog, audits, nil}, {article, repo("article"), articles}, {component, repo("component"), components},
		{playground, repo("playground"), playgroundRows},
	} {
		check(node.Register(r.model, r.repo))
		seed(r.repo, r.seed)
	}
	check(node.ListenAndServe(":" + envOr("PORT", "9090")))
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
