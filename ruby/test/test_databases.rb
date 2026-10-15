# frozen_string_literal: true

# SqlRepository against real PostgreSQL and MySQL. Runs only when ERUPT_TEST_DATABASES is set (the databases
# workflow starts both as service containers, and installs the pg and mysql2 gems); connection settings come
# from the standard PG* variables and MYSQL_HOST / MYSQL_PORT / MYSQL_USER / MYSQL_DATABASE.
require_relative "test_helper"

class DbPost
  extend Erupt::Model
  erupt "DbPost"
  field :id, pk: true
  field :title, "Title", search: true
  field :views, "Views", Integer
  field :live, "Live", :boolean
  field :day, "Day", Date
  field :at, "At", Time
end

class DatabaseTest < Minitest::Test
  DDL = {
    postgres: 'CREATE TABLE "db_post" ("id" SERIAL PRIMARY KEY, "title" VARCHAR(255), "views" INTEGER, ' \
              '"live" BOOLEAN, "day" DATE, "at" TIMESTAMP(3))',
    mysql: "CREATE TABLE `db_post` (`id` INT AUTO_INCREMENT PRIMARY KEY, `title` VARCHAR(255), `views` INT, " \
           "`live` BOOLEAN, `day` DATE, `at` DATETIME(3))"
  }.freeze

  def setup
    skip "set ERUPT_TEST_DATABASES to run against PostgreSQL and MySQL" unless ENV["ERUPT_TEST_DATABASES"]
  end

  def test_postgres
    require "pg"
    run_scenario(Erupt::SqlExecutor.pg(PG.connect)) # libpq reads the PG* environment variables
  end

  def test_mysql
    require "mysql2"
    client = Mysql2::Client.new(host: ENV.fetch("MYSQL_HOST", "127.0.0.1"), port: Integer(ENV.fetch("MYSQL_PORT", "3306")),
                                username: ENV.fetch("MYSQL_USER", "root"), password: ENV.fetch("MYSQL_PASSWORD", ""),
                                database: ENV.fetch("MYSQL_DATABASE", "erupt"))
    run_scenario(Erupt::SqlExecutor.mysql2(client))
  end

  def run_scenario(executor)
    repo = Erupt::SqlRepository.new(executor, "db_post")
    executor.call("DROP TABLE IF EXISTS #{repo.q("db_post")}", [])
    executor.call(DDL.fetch(executor.dialect), [])
    repo.bind(DbPost.erupt_model)
    repo.add(title: "100% pure", views: 3, live: true, day: Date.new(2026, 1, 5), at: Time.new(2026, 1, 5, 10, 30, Rational(123, 1000)))
    repo.add(title: "wow!", views: 1, live: false, day: Date.new(2026, 3, 1), at: nil)
    repo.add(title: "a_b", views: nil, live: false, day: nil, at: nil)

    titles = lambda do |*conds, sort: [["title", false]]|
      repo.page(Erupt::Query.new(conditions: conds, sort: sort)).last.map { |r| r["title"] }
    end
    cond = ->(*args) { Erupt::Cond.new(*args) }
    assert_equal ["100% pure", "wow!", "a_b"], titles.call(sort: []), "default order is primary key ascending"
    assert_equal ["100% pure"], titles.call(cond.call("title", "LIKE", "%")), "LIKE escapes %"
    assert_equal ["wow!"], titles.call(cond.call("title", "LIKE", "!")), "LIKE escapes !"
    assert_equal ["a_b"], titles.call(cond.call("title", "LIKE", "_")), "LIKE escapes _"
    assert_equal ["100% pure"], titles.call(cond.call("title", "LIKE", "PURE")), "LIKE ignores case"
    assert_equal ["a_b", "wow!"], titles.call(cond.call("title", "NOT_LIKE", "pure")), "NOT_LIKE"
    assert_equal ["100% pure", "wow!"], titles.call(cond.call("views", "IN", [1, 3])), "IN"
    assert_equal [], titles.call(cond.call("views", "IN", [])), "empty IN"
    assert_equal ["wow!"], titles.call(cond.call("day", "RANGE", [Date.new(2026, 2, 1), Date.new(2026, 12, 31)])), "RANGE"
    assert_equal ["100% pure"], titles.call(cond.call("live", "EQ", true)), "boolean"
    assert_equal ["100% pure"], titles.call(cond.call("views", "GT", 2)), "GT"
    assert_equal ["a_b"], titles.call(cond.call("views", "NULL")), "NULL"
    total, rows = repo.page(Erupt::Query.new(sort: [["views", true]], offset: 1, limit: 1))
    assert_equal [3, 1], [total, rows.size], "total and page size"

    assert_equal({ "id" => 1, "title" => "100% pure", "views" => 3, "live" => true, "day" => Date.new(2026, 1, 5),
                   "at" => Time.new(2026, 1, 5, 10, 30, Rational(123, 1000)) }, repo.get(1), "round trip")
    repo.update(1, title: "renamed", live: false)
    assert_equal ["renamed", false], repo.get(1).values_at("title", "live")
    repo.delete([1, 2])
    assert_equal ["a_b"], titles.call
    assert_nil repo.get(1)
  end
end
