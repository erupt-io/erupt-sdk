using System.Data.Common;
using MySqlConnector;
using Npgsql;

namespace Erupt.Tests;

[EruptModel("Post", Name = "DbPost")]
public sealed class DbPost
{
    [Pk] public long Id { get; set; }
    [Field("Title", Search = true)] public string? Title { get; set; }
    [Field("Views")] public long? Views { get; set; }
    [Field("Live")] public bool Live { get; set; }
    [Field("Day")] public DateOnly? Day { get; set; }
    [Field("At")] public DateTime? At { get; set; }
}

/// <summary>
/// DbRepository against real PostgreSQL and MySQL. Runs only when ERUPT_TEST_DATABASES is set (the databases
/// workflow starts both as service containers); connection settings come from the standard PG* variables and
/// MYSQL_HOST / MYSQL_PORT / MYSQL_USER / MYSQL_DATABASE.
/// </summary>
public sealed class DatabaseTests
{
    private static readonly bool Enabled = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("ERUPT_TEST_DATABASES"));

    private static string Env(string name, string fallback) =>
        Environment.GetEnvironmentVariable(name) is { Length: > 0 } value ? value : fallback;

    [Fact]
    public async Task Postgres()
    {
        if (!Enabled) return;
        var cs = $"Host={Env("PGHOST", "127.0.0.1")};Port={Env("PGPORT", "5432")};Username={Env("PGUSER", "postgres")};" +
                 $"Password={Env("PGPASSWORD", "")};Database={Env("PGDATABASE", "erupt")}";
        await Scenario(() => new NpgsqlConnection(cs), new DbRepository(() => new NpgsqlConnection(cs), "db_post"),
            "DROP TABLE IF EXISTS \"db_post\"",
            "CREATE TABLE \"db_post\" (\"id\" SERIAL PRIMARY KEY, \"title\" VARCHAR(255), \"views\" INTEGER, \"live\" BOOLEAN, \"day\" DATE, \"at\" TIMESTAMP(3))");
    }

    [Fact]
    public async Task MySql()
    {
        if (!Enabled) return;
        var cs = $"Server={Env("MYSQL_HOST", "127.0.0.1")};Port={Env("MYSQL_PORT", "3306")};User ID={Env("MYSQL_USER", "root")};" +
                 $"Password={Env("MYSQL_PASSWORD", "")};Database={Env("MYSQL_DATABASE", "erupt")}";
        await Scenario(() => new MySqlConnection(cs), new DbRepository(() => new MySqlConnection(cs), "db_post") { Quote = ("`", "`") },
            "DROP TABLE IF EXISTS `db_post`",
            "CREATE TABLE `db_post` (`id` INT AUTO_INCREMENT PRIMARY KEY, `title` VARCHAR(255), `views` INT, `live` BOOLEAN, `day` DATE, `at` DATETIME(3))");
    }

    private static async Task Scenario(Func<DbConnection> connect, DbRepository repo, params string[] ddl)
    {
        await using (var conn = connect())
        {
            await conn.OpenAsync();
            foreach (var sql in ddl)
            {
                await using var cmd = conn.CreateCommand();
                cmd.CommandText = sql;
                await cmd.ExecuteNonQueryAsync();
            }
        }
        repo.Bind(EruptModel.Of<DbPost>());
        var at = new DateTime(2026, 1, 5, 10, 30, 0, 123);
        await repo.AddAsync(new Record { ["title"] = "100% pure", ["views"] = 3L, ["live"] = true, ["day"] = new DateOnly(2026, 1, 5), ["at"] = at });
        await repo.AddAsync(new Record { ["title"] = "wow!", ["views"] = 1L, ["live"] = false, ["day"] = new DateOnly(2026, 3, 1), ["at"] = null });
        await repo.AddAsync(new Record { ["title"] = "a_b", ["views"] = null, ["live"] = false, ["day"] = null, ["at"] = null });

        async Task<List<string?>> Titles(List<(string Field, bool Desc)>? sort = null, params Cond[] conditions)
        {
            var (_, records) = await repo.PageAsync(new Query { Conditions = [.. conditions], Sort = sort ?? [("title", false)], Limit = 10 });
            return records.Select(r => r["title"] as string).ToList();
        }

        Assert.Equal(["100% pure", "wow!", "a_b"], await Titles([]));
        Assert.Equal(["100% pure"], await Titles(null, new Cond("title", "LIKE", "%")));
        Assert.Equal(["wow!"], await Titles(null, new Cond("title", "LIKE", "!")));
        Assert.Equal(["a_b"], await Titles(null, new Cond("title", "LIKE", "_")));
        Assert.Equal(["a_b", "wow!"], await Titles(null, new Cond("title", "NOT_LIKE", "pure")));
        Assert.Equal(["100% pure", "wow!"], await Titles(null, new Cond("views", "IN", new List<object?> { 1L, 3L })));
        Assert.Empty(await Titles(null, new Cond("views", "IN", new List<object?>())));
        Assert.Equal(["wow!"], await Titles(null, new Cond("day", "RANGE", new List<object?> { new DateOnly(2026, 2, 1), new DateOnly(2026, 12, 31) })));
        Assert.Equal(["100% pure"], await Titles(null, new Cond("live", "EQ", true)));
        Assert.Equal(["100% pure"], await Titles(null, new Cond("views", "GT", 2L)));
        Assert.Equal(["a_b"], await Titles(null, new Cond("views", "NULL")));
        var (total, page) = await repo.PageAsync(new Query { Sort = [("views", true)], Offset = 1, Limit = 1 });
        Assert.Equal((3L, 1), (total, page.Count));

        var row = (await repo.GetAsync(1L))!;
        Assert.Equal(1L, row["id"]);
        Assert.Equal(3L, row["views"]);
        Assert.Equal(true, row["live"]);
        Assert.Equal(new DateOnly(2026, 1, 5), row["day"]);
        Assert.Equal(at, row["at"]);
        await repo.UpdateAsync(1L, new Record { ["title"] = "renamed", ["live"] = false });
        row = (await repo.GetAsync(1L))!;
        Assert.Equal(("renamed", (object?)false), (row["title"] as string, row["live"]));
        await repo.DeleteAsync([1L, 2L]);
        Assert.Equal(["a_b"], await Titles());
        Assert.Null(await repo.GetAsync(1L));
    }
}
