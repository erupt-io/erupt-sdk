"""SqlRepository against real PostgreSQL and MySQL. Runs only when ERUPT_TEST_DATABASES is set (the databases
workflow starts both as service containers); connection settings come from the standard PG* variables and
MYSQL_HOST / MYSQL_PORT / MYSQL_USER / MYSQL_DATABASE."""
import datetime
import os
import unittest

from erupt import Field, Query, SqlRepository, erupt
from erupt.repo import Cond

ENABLED = bool(os.environ.get("ERUPT_TEST_DATABASES"))


@erupt("DbPost")
class DbPost:
    id: int = Field(pk=True)
    title: str = Field("Title", search=True)
    views: int = Field("Views")
    live: bool = Field("Live")
    day: datetime.date = Field("Day")
    at: datetime.datetime = Field("At")


DDL = {
    "postgres": 'CREATE TABLE "db_post" ("id" SERIAL PRIMARY KEY, "title" VARCHAR(255), "views" INTEGER, '
                '"live" BOOLEAN, "day" DATE, "at" TIMESTAMP(3))',
    "mysql": "CREATE TABLE `db_post` (`id` INT AUTO_INCREMENT PRIMARY KEY, `title` VARCHAR(255), `views` INT, "
             "`live` BOOLEAN, `day` DATE, `at` DATETIME(3))",
}


def postgres():
    import psycopg  # the PG* environment variables configure the connection
    return psycopg.connect()


def mysql():
    import pymysql
    return pymysql.connect(host=os.environ.get("MYSQL_HOST", "127.0.0.1"), port=int(os.environ.get("MYSQL_PORT", 3306)),
                           user=os.environ.get("MYSQL_USER", "root"), password=os.environ.get("MYSQL_PASSWORD", ""),
                           database=os.environ.get("MYSQL_DATABASE", "erupt"))


@unittest.skipUnless(ENABLED, "set ERUPT_TEST_DATABASES to run against PostgreSQL and MySQL")
class DatabaseTest(unittest.TestCase):

    def run_scenario(self, dialect, connect):
        conn = connect()
        try:
            with conn.cursor() as cursor:
                cursor.execute("DROP TABLE IF EXISTS " + ('"db_post"' if dialect == "postgres" else "`db_post`"))
                cursor.execute(DDL[dialect])
            conn.commit()
        finally:
            conn.close()
        repo = SqlRepository(connect, "db_post", dialect=dialect)
        repo.bind(DbPost.__erupt__)
        repo.add({"title": "100% pure", "views": 3, "live": True, "day": datetime.date(2026, 1, 5),
                  "at": datetime.datetime(2026, 1, 5, 10, 30, 0, 123000)})
        repo.add({"title": "wow!", "views": 1, "live": False, "day": datetime.date(2026, 3, 1), "at": None})
        repo.add({"title": "a_b", "views": None, "live": False, "day": None, "at": None})

        def titles(*conds, sort=(("title", False),)):
            return [r["title"] for r in repo.page(Query(list(conds), list(sort), 0, 10))[1]]

        self.assertEqual(["100% pure", "wow!", "a_b"], titles(sort=()), "default order is primary key ascending")
        self.assertEqual(["100% pure"], titles(Cond("title", "LIKE", "%")), "LIKE escapes %")
        self.assertEqual(["wow!"], titles(Cond("title", "LIKE", "!")), "LIKE escapes !")
        self.assertEqual(["a_b"], titles(Cond("title", "LIKE", "_")), "LIKE escapes _")
        self.assertEqual(["a_b", "wow!"], titles(Cond("title", "NOT_LIKE", "pure")), "NOT_LIKE")
        self.assertEqual(["100% pure", "wow!"], titles(Cond("views", "IN", [1, 3])), "IN")
        self.assertEqual([], titles(Cond("views", "IN", [])), "empty IN")
        self.assertEqual(["wow!"], titles(Cond("day", "RANGE", [datetime.date(2026, 2, 1), datetime.date(2026, 12, 31)])), "RANGE")
        self.assertEqual(["100% pure"], titles(Cond("live", "EQ", True)), "boolean")
        self.assertEqual(["100% pure"], titles(Cond("views", "GT", 2)), "GT")
        self.assertEqual(["a_b"], titles(Cond("views", "NULL")), "NULL")
        total, rows = repo.page(Query([], [("views", True)], 1, 1))
        self.assertEqual((3, 1), (total, len(rows)), "total and page size")

        row = repo.get(1)
        self.assertEqual({"id": 1, "title": "100% pure", "views": 3, "live": True, "day": datetime.date(2026, 1, 5),
                          "at": datetime.datetime(2026, 1, 5, 10, 30, 0, 123000)}, row, "round trip")
        self.assertIsInstance(row["views"], int)
        repo.update(1, {"title": "renamed", "live": False})
        self.assertEqual(("renamed", False), (repo.get(1)["title"], repo.get(1)["live"]))
        repo.delete([1, 2])
        self.assertEqual(["a_b"], titles())
        self.assertIsNone(repo.get(1))

    def test_postgres(self):
        self.run_scenario("postgres", postgres)

    def test_mysql(self):
        self.run_scenario("mysql", mysql)


if __name__ == "__main__":
    unittest.main()
