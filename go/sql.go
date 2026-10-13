package erupt

import (
	"context"
	"database/sql"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
)

// SQLRepository keeps a model in a table through database/sql. Column names are the model's field names,
// already checked as identifiers, and quoted; every value is a bound parameter. Pagination uses
// LIMIT / OFFSET (SQLite, PostgreSQL, MySQL, MariaDB).
type SQLRepository struct {
	DB    *sql.DB
	Table string
	// Dollar uses $1, $2 placeholders (PostgreSQL) instead of ?.
	Dollar bool
	// Quote wraps identifiers, `"` by default; "`" for MySQL without ANSI_QUOTES.
	Quote string
	// AutoCreate issues CREATE TABLE IF NOT EXISTS with SQLite column types on Register.
	AutoCreate bool

	model *Model
}

var sqliteTypes = map[string]string{"NUMBER": "NUMERIC", "BOOLEAN": "INTEGER", "DATE": "DATE", typeDateTime: "TIMESTAMP",
	typeReferenceTable: "INTEGER", typeReferenceTree: "INTEGER"}

func (r *SQLRepository) Bind(m *Model) error {
	if !identifier.MatchString(r.Table) {
		return fmt.Errorf("table '%s' must be an identifier", r.Table)
	}
	if r.Quote == "" {
		r.Quote = `"`
	}
	r.model = m
	if !r.AutoCreate {
		return nil
	}
	cols := make([]string, len(m.fields))
	for i, f := range m.fields {
		if f.pk {
			cols[i] = r.q(f.name) + " INTEGER PRIMARY KEY AUTOINCREMENT"
		} else {
			t, ok := sqliteTypes[f.typ]
			if !ok {
				t = "TEXT"
			}
			cols[i] = r.q(f.name) + " " + t
		}
	}
	_, err := r.DB.Exec("CREATE TABLE IF NOT EXISTS " + r.q(r.Table) + " (" + strings.Join(cols, ", ") + ")")
	return err
}

func (r *SQLRepository) q(id string) string {
	return r.Quote + strings.ReplaceAll(id, r.Quote, r.Quote+r.Quote) + r.Quote
}

// sqlBuilder numbers placeholders as they are added.
type sqlBuilder struct {
	dollar bool
	args   []any
}

func (b *sqlBuilder) p(v any) string {
	b.args = append(b.args, v)
	if b.dollar {
		return "$" + strconv.Itoa(len(b.args))
	}
	return "?"
}

// likeEscape escapes the LIKE wildcards with '!', which needs no special casing in any dialect.
func likeEscape(s string) string {
	return strings.NewReplacer("!", "!!", "%", "!%", "_", "!_").Replace(s)
}

var sqlOps = map[string]string{"EQ": "=", "NEQ": "<>", "GT": ">", "GTE": ">=", "LT": "<", "LTE": "<="}

func (r *SQLRepository) where(b *sqlBuilder, conds []Cond) string {
	var clauses []string
	for _, c := range conds {
		col := r.q(c.Field)
		f := r.model.byName[c.Field]
		switch c.Op {
		case "EQ", "NEQ", "GT", "GTE", "LT", "LTE":
			clauses = append(clauses, col+" "+sqlOps[c.Op]+" "+b.p(r.toDB(f, c.Value)))
		case "LIKE", "NOT_LIKE":
			not := ""
			if c.Op == "NOT_LIKE" {
				not = "NOT "
			}
			clauses = append(clauses, col+" "+not+"LIKE "+b.p("%"+likeEscape(str(c.Value))+"%")+" ESCAPE '!'")
		case "RANGE":
			bounds := c.Value.([]any)
			clauses = append(clauses, col+" BETWEEN "+b.p(r.toDB(f, bounds[0]))+" AND "+b.p(r.toDB(f, bounds[1])))
		case "IN", "NOT_IN":
			values := c.Value.([]any)
			if len(values) == 0 {
				if c.Op == "IN" {
					clauses = append(clauses, "1=0")
				}
				continue
			}
			marks := make([]string, len(values))
			for i, v := range values {
				marks[i] = b.p(r.toDB(f, v))
			}
			not := ""
			if c.Op == "NOT_IN" {
				not = "NOT "
			}
			clauses = append(clauses, col+" "+not+"IN ("+strings.Join(marks, ", ")+")")
		case "NULL":
			clauses = append(clauses, col+" IS NULL")
		case "NOT_NULL":
			clauses = append(clauses, col+" IS NOT NULL")
		}
	}
	if len(clauses) == 0 {
		return ""
	}
	return " WHERE " + strings.Join(clauses, " AND ")
}

func (r *SQLRepository) columns() string {
	cols := make([]string, len(r.model.fields))
	for i, f := range r.model.fields {
		cols[i] = r.q(f.name)
	}
	return strings.Join(cols, ", ")
}

// pageSQL builds the count and the page statements of a query.
func (r *SQLRepository) pageSQL(q Query) (count string, countArgs []any, page string, pageArgs []any) {
	cb := &sqlBuilder{dollar: r.Dollar}
	count = "SELECT COUNT(*) FROM " + r.q(r.Table) + r.where(cb, q.Conditions)
	pb := &sqlBuilder{dollar: r.Dollar}
	where := r.where(pb, q.Conditions)
	orders := make([]string, len(q.Sort))
	for i, o := range q.Sort {
		orders[i] = r.q(o.Field) + " ASC"
		if o.Desc {
			orders[i] = r.q(o.Field) + " DESC"
		}
	}
	order := strings.Join(orders, ", ")
	if order == "" {
		order = r.q(r.model.pk) + " ASC"
	}
	page = "SELECT " + r.columns() + " FROM " + r.q(r.Table) + where + " ORDER BY " + order +
		" LIMIT " + pb.p(q.Limit) + " OFFSET " + pb.p(q.Offset)
	return count, cb.args, page, pb.args
}

func (r *SQLRepository) Page(ctx context.Context, q Query) (int64, []Record, error) {
	count, countArgs, page, pageArgs := r.pageSQL(q)
	var total int64
	if err := r.DB.QueryRowContext(ctx, count, countArgs...).Scan(&total); err != nil {
		return 0, nil, err
	}
	records, err := r.query(ctx, page, pageArgs...)
	return total, records, err
}

func (r *SQLRepository) query(ctx context.Context, query string, args ...any) ([]Record, error) {
	rows, err := r.DB.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	records := []Record{}
	for rows.Next() {
		values := make([]any, len(r.model.fields))
		ptrs := make([]any, len(values))
		for i := range values {
			ptrs[i] = &values[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, err
		}
		record := Record{}
		for i, f := range r.model.fields {
			record[f.name] = r.fromDB(f, values[i])
		}
		records = append(records, record)
	}
	return records, rows.Err()
}

func (r *SQLRepository) Get(ctx context.Context, pk any) (Record, error) {
	b := &sqlBuilder{dollar: r.Dollar}
	records, err := r.query(ctx, "SELECT "+r.columns()+" FROM "+r.q(r.Table)+" WHERE "+r.q(r.model.pk)+" = "+b.p(pk), b.args...)
	if err != nil || len(records) == 0 {
		return nil, err
	}
	return records[0], nil
}

// writable lists the record's columns in declaration order, without the primary key.
func (r *SQLRepository) writable(record Record) []*field {
	var fields []*field
	for _, f := range r.model.fields {
		if _, ok := record[f.name]; ok && !f.pk {
			fields = append(fields, f)
		}
	}
	return fields
}

func (r *SQLRepository) insertSQL(record Record) (string, []any) {
	b := &sqlBuilder{dollar: r.Dollar}
	fields := r.writable(record)
	cols, marks := make([]string, len(fields)), make([]string, len(fields))
	for i, f := range fields {
		cols[i], marks[i] = r.q(f.name), b.p(r.toDB(f, record[f.name]))
	}
	return "INSERT INTO " + r.q(r.Table) + " (" + strings.Join(cols, ", ") + ") VALUES (" + strings.Join(marks, ", ") + ")", b.args
}

func (r *SQLRepository) Add(ctx context.Context, record Record) error {
	query, args := r.insertSQL(record)
	_, err := r.DB.ExecContext(ctx, query, args...)
	return err
}

func (r *SQLRepository) Update(ctx context.Context, pk any, record Record) error {
	b := &sqlBuilder{dollar: r.Dollar}
	fields := r.writable(record)
	if len(fields) == 0 {
		return nil
	}
	sets := make([]string, len(fields))
	for i, f := range fields {
		sets[i] = r.q(f.name) + " = " + b.p(r.toDB(f, record[f.name]))
	}
	query := "UPDATE " + r.q(r.Table) + " SET " + strings.Join(sets, ", ") + " WHERE " + r.q(r.model.pk) + " = " + b.p(pk)
	_, err := r.DB.ExecContext(ctx, query, b.args...)
	return err
}

func (r *SQLRepository) Delete(ctx context.Context, pks []any) error {
	if len(pks) == 0 {
		return nil
	}
	b := &sqlBuilder{dollar: r.Dollar}
	marks := make([]string, len(pks))
	for i, pk := range pks {
		marks[i] = b.p(pk)
	}
	_, err := r.DB.ExecContext(ctx, "DELETE FROM "+r.q(r.Table)+" WHERE "+r.q(r.model.pk)+" IN ("+strings.Join(marks, ", ")+")", b.args...)
	return err
}

// toDB stores dates as ISO text, which every dialect accepts and which sorts correctly.
func (r *SQLRepository) toDB(f *field, v any) any {
	if t, ok := v.(time.Time); ok {
		if f != nil && f.typ == "DATE" {
			return t.Format(dateLayout)
		}
		return t.Format("2006-01-02 15:04:05.000")
	}
	return v
}

// fromDB normalizes what a driver returns into the values the node expects.
func (r *SQLRepository) fromDB(f *field, v any) any {
	if b, ok := v.([]byte); ok {
		v = string(b)
	}
	if v == nil {
		return nil
	}
	switch {
	case f.typ == "BOOLEAN":
		if n, ok := toFloat(v); ok {
			return n != 0
		}
		if s, ok := v.(string); ok {
			return s == "1" || strings.EqualFold(s, "true")
		}
	case f.typ == "DATE" || f.typ == typeDateTime:
		t, err := parseDateTime(v)
		if err != nil {
			return v
		}
		if t.Location() != time.UTC {
			// a driver that parsed the column: keep the wall clock, drop the zone
			t = time.Date(t.Year(), t.Month(), t.Day(), t.Hour(), t.Minute(), t.Second(), t.Nanosecond(), time.UTC)
		}
		if f.typ == "DATE" {
			return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
		}
		return t
	case f.pk || f.typ == "NUMBER" || f.isReference():
		if s, ok := v.(string); ok {
			if n, err := strconv.ParseInt(s, 10, 64); err == nil {
				return n
			}
			if n, err := strconv.ParseFloat(s, 64); err == nil {
				return n
			}
		}
		// drivers differ (int32 from pgx, int64 from mysql, float64 from sqlite): integral numbers become int64
		if n, ok := toFloat(v); ok && n == math.Trunc(n) && math.Abs(n) < 1<<53 {
			return int64(n)
		}
	}
	return v
}
