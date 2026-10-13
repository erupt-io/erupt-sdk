import datetime
import decimal
import os
import sqlite3
import tempfile
import unittest

from erupt import Field, MemoryRepository, Query, SqliteRepository, erupt
from erupt.repo import Cond, SqlRepository


@erupt("Post")
class Post:
    id: int = Field(pk=True)
    title: str = Field("Title", search=True)
    views: int = Field("Views")
    live: bool = Field("Live")
    day: datetime.date = Field("Day")
    at: datetime.datetime = Field("At")


class FakeCursor:
    def __init__(self, conn):
        self.conn, self.description = conn, None

    def execute(self, sql, params):
        self.conn.log.append((sql, params))
        if self.conn.fail:
            raise RuntimeError("boom")
        if sql.startswith("SELECT COUNT"):
            self.description, self.rows = [("N",)], [(2,)]
        elif sql.startswith("SELECT"):
            self.description = [("ID",), ("TITLE",), ("VIEWS",), ("LIVE",), ("DAY",), ("AT",)]
            self.rows = [(1, "a", decimal.Decimal("3"), 1, "2026-01-05", "2026-01-05 10:30:00.000")]

    def fetchall(self):
        return self.rows

    def close(self):
        pass


class FakeConnection:
    """Records SQL the way a DB-API driver would receive it."""

    def __init__(self, fail=False):
        self.log, self.fail, self.events = [], fail, []

    def cursor(self):
        return FakeCursor(self)

    def commit(self):
        self.events.append("commit")

    def rollback(self):
        self.events.append("rollback")

    def close(self):
        self.events.append("close")


def fake(dialect, paramstyle, fail=False):
    conn = FakeConnection(fail)
    released = []
    repo = SqlRepository(lambda: conn, "post", dialect=dialect, paramstyle=paramstyle, release=released.append)
    repo.bind(Post.__erupt__)
    return repo, conn, released


class SqlRepositoryTest(unittest.TestCase):

    def setUp(self):
        self.path = tempfile.NamedTemporaryFile(suffix=".db", delete=False).name

    def tearDown(self):
        os.remove(self.path)

    def repositories(self):
        generic = SqlRepository(lambda: sqlite3.connect(self.path, detect_types=sqlite3.PARSE_DECLTYPES), "post",
                                auto_create=True)
        return {"memory": MemoryRepository(), "sqlite": SqliteRepository(self.path, "post_s"), "generic": generic}

    def test_repositories_agree(self):
        for kind, repo in self.repositories().items():
            with self.subTest(kind):
                repo.bind(Post.__erupt__)
                for title, views, live in (("100% pure", 3, True), ("wow!", 1, False), ("a_b", None, False)):
                    repo.add({"title": title, "views": views, "live": live, "day": datetime.date(2026, 1, 5),
                              "at": datetime.datetime(2026, 1, 5, 10, 30)})
                titles = lambda *conds: [r["title"] for r in repo.page(Query(list(conds), limit=10))[1]]
                self.assertEqual(["100% pure", "wow!", "a_b"], titles(), "default order is primary key ascending")
                self.assertEqual(["100% pure"], titles(Cond("title", "LIKE", "%")))
                self.assertEqual(["wow!"], titles(Cond("title", "LIKE", "!")))
                self.assertEqual(["a_b"], titles(Cond("title", "LIKE", "_")))
                self.assertEqual(["wow!"], titles(Cond("live", "EQ", False), Cond("views", "NOT_NULL")))
                row = repo.get(1)
                self.assertEqual((True, datetime.date(2026, 1, 5), datetime.datetime(2026, 1, 5, 10, 30)),
                                 (row["live"], row["day"], row["at"]))
                repo.update(1, {"title": "renamed"})
                self.assertEqual("renamed", repo.get(1)["title"])
                repo.delete([1, 2])
                self.assertEqual(["a_b"], titles())

    def test_dialects_and_paramstyles(self):
        cases = {
            ("postgres", "format"): ('SELECT * FROM "post" WHERE "title" LIKE %s ESCAPE \'!\' AND "views" IN (%s, %s) '
                                     'ORDER BY "id" ASC LIMIT %s OFFSET %s', ["%a!%!!%", 1, 2, 10, 0]),
            ("mysql", "pyformat"): ("SELECT * FROM `post` WHERE `title` LIKE %(p0)s ESCAPE '!' AND `views` IN (%(p1)s, %(p2)s) "
                                    "ORDER BY `id` ASC LIMIT %(p3)s OFFSET %(p4)s",
                                    {"p0": "%a!%!!%", "p1": 1, "p2": 2, "p3": 10, "p4": 0}),
            ("mssql", "qmark"): ("SELECT * FROM [post] WHERE [title] LIKE ? ESCAPE '!' AND [views] IN (?, ?) "
                                 "ORDER BY [id] ASC OFFSET ? ROWS FETCH NEXT ? ROWS ONLY", ["%a!%!!%", 1, 2, 0, 10]),
            ("oracle", "numeric"): ('SELECT * FROM "post" WHERE "title" LIKE :1 ESCAPE \'!\' AND "views" IN (:2, :3) '
                                    'ORDER BY "id" ASC OFFSET :4 ROWS FETCH NEXT :5 ROWS ONLY', ["%a!%!!%", 1, 2, 0, 10]),
            ("oracle", "named"): ('SELECT * FROM "post" WHERE "title" LIKE :p0 ESCAPE \'!\' AND "views" IN (:p1, :p2) '
                                  'ORDER BY "id" ASC OFFSET :p3 ROWS FETCH NEXT :p4 ROWS ONLY',
                                  {"p0": "%a!%!!%", "p1": 1, "p2": 2, "p3": 0, "p4": 10}),
        }
        for (dialect, style), expected in cases.items():
            with self.subTest(f"{dialect} {style}"):
                repo, conn, released = fake(dialect, style)
                total, rows = repo.page(Query([Cond("title", "LIKE", "a%!"), Cond("views", "IN", [1, 2])], limit=10))
                self.assertEqual(expected, conn.log[1])
                self.assertEqual(2, total)
                # upper-case columns, Decimal and string dates are normalized by field type
                self.assertEqual({"id": 1, "title": "a", "views": 3, "live": True, "day": datetime.date(2026, 1, 5),
                                  "at": datetime.datetime(2026, 1, 5, 10, 30)}, rows[0])
                self.assertIsInstance(rows[0]["views"], int)
                self.assertEqual(["commit", "commit"], conn.events)
                self.assertEqual(2, len(released))

    def test_identifiers_are_quoted_and_escaped(self):
        repo, conn, _ = fake("mssql", "qmark")
        self.assertEqual("[we]]ird]", repo._q("we]ird"))
        repo, conn, _ = fake("mysql", "format")
        self.assertEqual("`we``ird`", repo._q("we`ird"))
        with self.assertRaises(ValueError):
            SqlRepository(lambda: None, "post; DROP TABLE x")
        with self.assertRaises(ValueError):
            SqlRepository(lambda: None, "post", dialect="db2")

    def test_failure_rolls_back_and_releases(self):
        repo, conn, released = fake("postgres", "format", fail=True)
        with self.assertRaisesRegex(RuntimeError, "boom"):
            repo.add({"title": "x"})
        self.assertEqual(["rollback"], conn.events)
        self.assertEqual(1, len(released))

    def test_paramstyle_is_detected_from_the_driver(self):
        repo = SqlRepository(lambda: sqlite3.connect(self.path), "post", auto_create=True)
        repo.bind(Post.__erupt__)
        repo.add({"title": "x"})
        self.assertEqual("x", repo.get(1)["title"])

        class Unknown(FakeConnection):
            pass

        repo = SqlRepository(lambda: Unknown(), "post")
        repo.bind(Post.__erupt__)
        with self.assertRaisesRegex(ValueError, "paramstyle"):
            repo.get(1)


if __name__ == "__main__":
    unittest.main()
