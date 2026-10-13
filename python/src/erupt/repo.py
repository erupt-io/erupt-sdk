"""Storage adapters. A repository only sees field names the node has already checked against the model,
so it may use them as identifiers; values always travel as parameters."""
import datetime
import sqlite3
import threading
from dataclasses import dataclass, field


@dataclass
class Cond:
    field: str
    op: str  # EQ NEQ GT GTE LT LTE LIKE NOT_LIKE RANGE IN NOT_IN NULL NOT_NULL
    value: object = None


@dataclass
class Query:
    conditions: list = field(default_factory=list)
    sort: list = field(default_factory=list)  # [(field, descending)]
    offset: int = 0
    limit: int = 10


class Repository:
    """Implement these five methods to put an erupt model on any storage."""

    def bind(self, model):
        self.model = model

    def page(self, query):
        """Return ``(total, [record, ...])``; a record is a dict keyed by field name."""
        raise NotImplementedError

    def get(self, pk):
        raise NotImplementedError

    def add(self, record):
        raise NotImplementedError

    def update(self, pk, record):
        raise NotImplementedError

    def delete(self, pks):
        raise NotImplementedError


def _match(value, cond):
    op, expect = cond.op, cond.value
    if op == "NULL":
        return value is None
    if op == "NOT_NULL":
        return value is not None
    if value is None:
        return False
    if op == "EQ":
        return value == expect
    if op == "NEQ":
        return value != expect
    if op == "LIKE":
        return str(expect).lower() in str(value).lower()
    if op == "NOT_LIKE":
        return str(expect).lower() not in str(value).lower()
    if op == "IN":
        return value in expect
    if op == "NOT_IN":
        return value not in expect
    if op == "RANGE":
        return expect[0] <= value <= expect[1]
    return {"GT": value > expect, "GTE": value >= expect, "LT": value < expect, "LTE": value <= expect}[op]


class MemoryRepository(Repository):

    def __init__(self, records=()):
        self._lock = threading.Lock()
        self._rows = {}
        self._seq = 0
        self._pending = list(records)

    def bind(self, model):
        super().bind(model)
        for record in self._pending:
            self.add(record)

    def page(self, query):
        with self._lock:
            rows = [r for r in self._rows.values() if all(_match(r.get(c.field), c) for c in query.conditions)]
        for name, desc in reversed(query.sort):
            rows.sort(key=lambda r: (r.get(name) is None, r.get(name)), reverse=desc)
        return len(rows), [dict(r) for r in rows[query.offset:query.offset + query.limit]]

    def get(self, pk):
        row = self._rows.get(pk)
        return dict(row) if row else None

    def add(self, record):
        with self._lock:
            self._seq += 1
            record = {**record, self.model.pk: self._seq}
            self._rows[self._seq] = record

    def update(self, pk, record):
        with self._lock:
            if pk in self._rows:
                self._rows[pk].update(record)

    def delete(self, pks):
        with self._lock:
            for pk in pks:
                self._rows.pop(pk, None)


_SQL_OPS = {"EQ": "=", "NEQ": "<>", "GT": ">", "GTE": ">=", "LT": "<", "LTE": "<="}

_SQLITE_TYPES = {"NUMBER": "NUMERIC", "BOOLEAN": "INTEGER", "DATE": "DATE", "DATE_TIME": "TIMESTAMP",
                 "REFERENCE_TABLE": "INTEGER", "REFERENCE_TREE": "INTEGER"}


class SqliteRepository(Repository):
    """SQLite table, created on first use when missing."""

    def __init__(self, path, table):
        self.path, self.table = path, table
        self._local = threading.local()

    def _conn(self):
        if not hasattr(self._local, "conn"):
            conn = sqlite3.connect(self.path, detect_types=sqlite3.PARSE_DECLTYPES)
            conn.row_factory = sqlite3.Row
            self._local.conn = conn
        return self._local.conn

    @staticmethod
    def _q(identifier):
        return '"' + identifier.replace('"', '""') + '"'

    def bind(self, model):
        super().bind(model)
        cols = []
        for f in model.fields.values():
            if f.pk:
                cols.append(f"{self._q(f.name)} INTEGER PRIMARY KEY AUTOINCREMENT")
            else:
                cols.append(f"{self._q(f.name)} {_SQLITE_TYPES.get(f.type, 'TEXT')}")
        with self._conn() as conn:
            conn.execute(f"CREATE TABLE IF NOT EXISTS {self._q(self.table)} ({', '.join(cols)})")

    def _where(self, conditions):
        clauses, params = [], []
        for c in conditions:
            col = self._q(c.field)
            if c.op in _SQL_OPS:
                clauses.append(f"{col} {_SQL_OPS[c.op]} ?")
                params.append(c.value)
            elif c.op in ("LIKE", "NOT_LIKE"):
                clauses.append(f"{col} {'NOT ' if c.op == 'NOT_LIKE' else ''}LIKE ? ESCAPE '\\'")
                escaped = str(c.value).replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
                params.append(f"%{escaped}%")
            elif c.op == "RANGE":
                clauses.append(f"{col} BETWEEN ? AND ?")
                params.extend(c.value[:2])
            elif c.op in ("IN", "NOT_IN"):
                if not c.value:
                    clauses.append("1=0" if c.op == "IN" else "1=1")
                    continue
                clauses.append(f"{col} {'NOT ' if c.op == 'NOT_IN' else ''}IN ({', '.join('?' * len(c.value))})")
                params.extend(c.value)
            elif c.op in ("NULL", "NOT_NULL"):
                clauses.append(f"{col} IS {'NOT ' if c.op == 'NOT_NULL' else ''}NULL")
        return (" WHERE " + " AND ".join(clauses)) if clauses else "", params

    def page(self, query):
        where, params = self._where(query.conditions)
        table = self._q(self.table)
        conn = self._conn()
        total = conn.execute(f"SELECT COUNT(*) FROM {table}{where}", params).fetchone()[0]
        order = ", ".join(f"{self._q(n)} {'DESC' if d else 'ASC'}" for n, d in query.sort) or self._q(self.model.pk) + " DESC"
        rows = conn.execute(f"SELECT * FROM {table}{where} ORDER BY {order} LIMIT ? OFFSET ?",
                            [*params, query.limit, query.offset]).fetchall()
        return total, [self._record(r) for r in rows]

    def _record(self, row):
        record = dict(row)
        for f in self.model.fields.values():
            if f.type == "BOOLEAN" and record.get(f.name) is not None:
                record[f.name] = bool(record[f.name])
        return record

    def get(self, pk):
        row = self._conn().execute(f"SELECT * FROM {self._q(self.table)} WHERE {self._q(self.model.pk)} = ?", [pk]).fetchone()
        return self._record(row) if row else None

    def add(self, record):
        record = {k: v for k, v in record.items() if k != self.model.pk}
        cols = ", ".join(self._q(k) for k in record)
        with self._conn() as conn:
            conn.execute(f"INSERT INTO {self._q(self.table)} ({cols}) VALUES ({', '.join('?' * len(record))})",
                         list(record.values()))

    def update(self, pk, record):
        record = {k: v for k, v in record.items() if k != self.model.pk}
        sets = ", ".join(f"{self._q(k)} = ?" for k in record)
        with self._conn() as conn:
            conn.execute(f"UPDATE {self._q(self.table)} SET {sets} WHERE {self._q(self.model.pk)} = ?",
                         [*record.values(), pk])

    def delete(self, pks):
        if not pks:
            return
        with self._conn() as conn:
            conn.execute(f"DELETE FROM {self._q(self.table)} WHERE {self._q(self.model.pk)} IN ({', '.join('?' * len(pks))})",
                         list(pks))


sqlite3.register_adapter(datetime.datetime, lambda v: v.isoformat(" "))
sqlite3.register_adapter(datetime.date, lambda v: v.isoformat())
sqlite3.register_converter("TIMESTAMP", lambda b: datetime.datetime.fromisoformat(b.decode()))
sqlite3.register_converter("DATE", lambda b: datetime.date.fromisoformat(b.decode()))
