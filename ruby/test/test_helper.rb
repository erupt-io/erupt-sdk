# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "erupt"
require "minitest/autorun"

# The sqlite3 gem is optional: SQLite-backed tests run where it is installed.
SQLITE3 = begin
  require "sqlite3"
  true
rescue LoadError
  false
end
