// Package dbtest runs SQLRepository against real PostgreSQL and MySQL. It is its own module so the
// drivers it needs never raise the SDK's minimum Go version. Runs only when ERUPT_TEST_DATABASES is set;
// connection settings come from the standard PG* variables and MYSQL_HOST / MYSQL_PORT / MYSQL_USER /
// MYSQL_DATABASE.
package dbtest

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"reflect"
	"testing"
	"time"

	erupt "github.com/erupt-io/erupt-sdk/go"
	_ "github.com/go-sql-driver/mysql"
	_ "github.com/jackc/pgx/v5/stdlib"
)

type dbPost struct {
	ID    int64     `json:"id" erupt:"pk"`
	Title string    `json:"title" erupt:"title=Title;search"`
	Views int64     `json:"views" erupt:"title=Views"`
	Live  bool      `json:"live" erupt:"title=Live"`
	Day   time.Time `json:"day" erupt:"title=Day;type=DATE"`
	At    time.Time `json:"at" erupt:"title=At"`
}

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func TestDatabases(t *testing.T) {
	if os.Getenv("ERUPT_TEST_DATABASES") == "" {
		t.Skip("set ERUPT_TEST_DATABASES to run against PostgreSQL and MySQL")
	}
	cases := []struct {
		name, driver, dsn, ddl string
		repo                   func(*sql.DB) *erupt.SQLRepository
	}{
		{"postgres", "pgx", "", // empty: pgx reads the PG* variables
			`CREATE TABLE "db_post" ("id" SERIAL PRIMARY KEY, "title" VARCHAR(255), "views" INTEGER, "live" BOOLEAN, "day" DATE, "at" TIMESTAMP(3))`,
			func(db *sql.DB) *erupt.SQLRepository {
				return &erupt.SQLRepository{DB: db, Table: "db_post", Dollar: true}
			}},
		{"mysql", "mysql", fmt.Sprintf("%s:%s@tcp(%s:%s)/%s", env("MYSQL_USER", "root"), env("MYSQL_PASSWORD", ""),
			env("MYSQL_HOST", "127.0.0.1"), env("MYSQL_PORT", "3306"), env("MYSQL_DATABASE", "erupt")),
			"CREATE TABLE `db_post` (`id` INT AUTO_INCREMENT PRIMARY KEY, `title` VARCHAR(255), `views` INT, `live` BOOLEAN, `day` DATE, `at` DATETIME(3))",
			func(db *sql.DB) *erupt.SQLRepository {
				return &erupt.SQLRepository{DB: db, Table: "db_post", Quote: "`"}
			}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			db, err := sql.Open(c.driver, c.dsn)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			ctx := context.Background()
			drop := "DROP TABLE IF EXISTS \"db_post\""
			if c.name == "mysql" {
				drop = "DROP TABLE IF EXISTS `db_post`"
			}
			for _, ddl := range []string{drop, c.ddl} {
				if _, err := db.ExecContext(ctx, ddl); err != nil {
					t.Fatal(err)
				}
			}
			model, err := erupt.NewModel(dbPost{}, "Post", erupt.WithName("DbPost"))
			if err != nil {
				t.Fatal(err)
			}
			repo := c.repo(db)
			if err := repo.Bind(model); err != nil {
				t.Fatal(err)
			}
			day := func(y int, m time.Month, d int) time.Time { return time.Date(y, m, d, 0, 0, 0, 0, time.UTC) }
			at := time.Date(2026, 1, 5, 10, 30, 0, 123e6, time.UTC)
			for _, r := range []erupt.Record{
				{"title": "100% pure", "views": int64(3), "live": true, "day": day(2026, 1, 5), "at": at},
				{"title": "wow!", "views": int64(1), "live": false, "day": day(2026, 3, 1), "at": nil},
				{"title": "a_b", "views": nil, "live": false, "day": nil, "at": nil},
			} {
				if err := repo.Add(ctx, r); err != nil {
					t.Fatal(err)
				}
			}
			byTitle := []erupt.Order{{Field: "title"}}
			titles := func(sort []erupt.Order, conds ...erupt.Cond) []string {
				t.Helper()
				_, records, err := repo.Page(ctx, erupt.Query{Conditions: conds, Sort: sort, Limit: 10})
				if err != nil {
					t.Fatal(err)
				}
				out := []string{}
				for _, r := range records {
					out = append(out, r["title"].(string))
				}
				return out
			}
			check := func(what string, got, want any) {
				t.Helper()
				if !reflect.DeepEqual(got, want) {
					t.Errorf("%s: got %#v, want %#v", what, got, want)
				}
			}
			check("default order is primary key ascending", titles(nil), []string{"100% pure", "wow!", "a_b"})
			check("LIKE escapes %", titles(byTitle, erupt.Cond{Field: "title", Op: "LIKE", Value: "%"}), []string{"100% pure"})
			check("LIKE escapes !", titles(byTitle, erupt.Cond{Field: "title", Op: "LIKE", Value: "!"}), []string{"wow!"})
			check("LIKE escapes _", titles(byTitle, erupt.Cond{Field: "title", Op: "LIKE", Value: "_"}), []string{"a_b"})
			check("NOT_LIKE", titles(byTitle, erupt.Cond{Field: "title", Op: "NOT_LIKE", Value: "pure"}), []string{"a_b", "wow!"})
			check("IN", titles(byTitle, erupt.Cond{Field: "views", Op: "IN", Value: []any{int64(1), int64(3)}}), []string{"100% pure", "wow!"})
			check("empty IN", titles(byTitle, erupt.Cond{Field: "views", Op: "IN", Value: []any{}}), []string{})
			check("RANGE", titles(byTitle, erupt.Cond{Field: "day", Op: "RANGE", Value: []any{day(2026, 2, 1), day(2026, 12, 31)}}), []string{"wow!"})
			check("boolean", titles(byTitle, erupt.Cond{Field: "live", Op: "EQ", Value: true}), []string{"100% pure"})
			check("GT", titles(byTitle, erupt.Cond{Field: "views", Op: "GT", Value: int64(2)}), []string{"100% pure"})
			check("NULL", titles(byTitle, erupt.Cond{Field: "views", Op: "NULL"}), []string{"a_b"})
			total, page, err := repo.Page(ctx, erupt.Query{Sort: []erupt.Order{{Field: "views", Desc: true}}, Offset: 1, Limit: 1})
			if err != nil {
				t.Fatal(err)
			}
			check("total and page size", []int{int(total), len(page)}, []int{3, 1})

			got, err := repo.Get(ctx, int64(1))
			if err != nil {
				t.Fatal(err)
			}
			check("round trip", got, erupt.Record{"id": int64(1), "title": "100% pure", "views": int64(3), "live": true,
				"day": day(2026, 1, 5), "at": at})
			if err := repo.Update(ctx, int64(1), erupt.Record{"title": "renamed", "live": false}); err != nil {
				t.Fatal(err)
			}
			got, _ = repo.Get(ctx, int64(1))
			check("update", []any{got["title"], got["live"]}, []any{"renamed", false})
			if err := repo.Delete(ctx, []any{int64(1), int64(2)}); err != nil {
				t.Fatal(err)
			}
			check("delete", titles(nil), []string{"a_b"})
		})
	}
}
