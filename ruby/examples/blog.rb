# frozen_string_literal: true

# A blog admin served from Ruby, covering the field types and features of SHOWCASE.md. Create the node on the
# erupt server first, then:
#
#   ERUPT_NODE_NAME=blog ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 ruby examples/blog.rb
#
# Records live in the SQLite file ERUPT_DB (default blog.db) when the sqlite3 gem is installed, in memory
# otherwise. Edit types without a shortcut (RATE, SLIDER, TAGS, COLOR, ICON, HTML_EDITOR, MARKDOWN,
# CODE_EDITOR) are declared as the storage kind they hold, with the edit type and its options in +edit:+.
# The Component model shows the rest: form-only elements as +virtual:+ fields, MULTI_CHOICE / KEY_VALUE as JSON
# (kind Array / Hash).
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "date"
require "erupt"

class Category
  extend Erupt::Model
  erupt "Category"
  field :id, pk: true
  field :name, "Name", search: true, not_null: true, sortable: true
  field :parent, "Parent Id", Integer
  field :sort, "Sort", Integer, sortable: true
end

class PublishForm
  extend Erupt::Model
  erupt "Publish Options"
  field :publish_date, "Publish Date", Date, not_null: true
end

class Article
  extend Erupt::Model
  erupt "Article", order_by: "id desc", power: { importable: true }
  field :id, pk: true
  field :title, "Title", search: true, not_null: true, sortable: true, edit: { inputType: { length: 60 } }
  field :summary, "Summary", type: Erupt::EditType::TEXTAREA, table: false, edit: { textareaType: { length: 200 } }
  field :category, "Category", Category, search: true
  field :topic, "Topic", Category, tree: :parent, table: false
  field :status, "Status", choices: { draft: "Draft", review: "In Review", published: "Published" }, search: true
  field :tags, "Tags", edit: { type: "TAGS", tagsType: { allowExtension: true, fetchHandler: [], joinSeparator: ",",
                                                         maxTagCount: 9999 } }
  field :views, "Views", Integer, sortable: true, edit: { numberType: { min: 0 } }
  field :price, "Price", Float, edit: { numberType: { min: 0, precision: 2, prefix: "$" } }
  field :rating, "Rating", Float, sortable: true, edit: { type: "RATE", rateType: { count: 5, allowHalf: true, character: "" } }
  field :progress, "Progress", Integer, edit: { type: "SLIDER", sliderType: { min: 0, max: 100, step: 5, markPoints: [],
                                                                               dots: false } }
  field :featured, "Featured", :boolean, search: true
  field :color, "Theme Color", edit: { type: "COLOR", colorType: { alpha: false, presets: [], showText: true } }
  field :icon, "Icon", table: false, edit: { type: "ICON" }
  field :publish_date, "Publish Date", Date, search: true, edit: { search: { operator: "RANGE" } }
  field :review_at, "Review At", Time, sortable: true
  field :content, "Content", table: false, edit: { type: "HTML_EDITOR", htmlEditorType: { value: "CKEDITOR" } }
  field :notes, "Notes", table: false, edit: { type: "MARKDOWN" }
  field :meta, "Meta (JSON)", table: false, edit: { type: "CODE_EDITOR", codeEditType: { language: "json", height: 300,
                                                                                         hints: [], hintHandler: [] } }

  operation :publish, "Publish", icon: "fa fa-paper-plane", form: PublishForm, if_expr: "item.status !== 'published'" do |op|
    op.rows.each { |row| op.repo.update(row["id"], status: "published", publish_date: op.param["publish_date"]) }
  end

  operation :feature, "Feature", mode: Erupt::RowOperationMode::SINGLE, icon: "fa fa-star",
                                 confirm: "Feature this article on the home page?" do |op|
    op.repo.update(op.rows.first["id"], featured: true)
  end
end

# Every component a node can declare without extra endpoints
class Component
  extend Erupt::Model
  erupt "Component"
  field :id, pk: true
  field :name, "Name", search: true, not_null: true
  field :intro, "Guide", virtual: true, edit: { type: "CALLOUT", calloutType: {
    value: "Every component a node can declare without extra endpoints.", style: "INFO"
  } }
  field :basic, "Basic", virtual: true, edit: { type: "DIVIDE" }
  field :code, "Code", table: false, edit: { type: "HIDDEN" }
  field :roles, "Roles", Array, search: true, choices: { ADMIN: "Admin", USER: "User", GUEST: "Guest" },
                                edit: { type: "MULTI_CHOICE", multiChoiceType: { type: "CHECKBOX" } }
  field :langs, "Languages", Array, choices: { JAVA: "Java", PYTHON: "Python", GO: "Go", RUST: "Rust" },
                                    edit: { type: "MULTI_CHOICE", multiChoiceType: { type: "SELECT" } }
  field :attrs, "Attributes", Hash, edit: { type: "KEY_VALUE", keyValueType: { keyPlaceholder: "Key", valuePlaceholder: "Value" } }
  field :spacer, "", virtual: true, edit: { type: "EMPTY" }
  field :extra, "Extra", virtual: true, edit: { type: "DIVIDE" }
  field :location, "Location", edit: { type: "MAP" }
  field :signature, "Signature", table: false, edit: { type: "SIGNATURE" }
  field :place, "Place & Sign", virtual: true, edit: { type: "GROUP", groupType: { fields: %w[location signature] } }
end

CATEGORIES = [
  { name: "Tech", parent: nil, sort: 1 },
  { name: "Python", parent: 1, sort: 2 },
  { name: "Go", parent: 1, sort: 3 },
  { name: "Life", parent: nil, sort: 4 },
  { name: "Travel", parent: 4, sort: 5 }
].freeze

ARTICLES = [
  { title: "Hello Erupt", summary: "A first look at erupt nodes", category: 2, topic: 2, status: "published",
    tags: "intro,erupt", views: 120, price: 9.9, rating: 4.5, progress: 100, featured: true, color: "#1677ff",
    icon: "fa fa-book", publish_date: Date.new(2026, 10, 1), review_at: Time.new(2026, 10, 2, 10, 0, 0),
    content: "<p>Hello</p>", notes: "# Hello", meta: '{"a":1}' },
  { title: "Go Tips", category: 3, topic: 3, status: "review", tags: "go", views: 30, price: 0, rating: 3, progress: 60,
    featured: false },
  { title: "Weekend Trip", category: 5, topic: 5, status: "draft", views: 0, rating: 0, progress: 10, featured: false }
].freeze

COMPONENTS = [
  { name: "Sample A", code: "C-001", roles: %w[ADMIN USER], langs: %w[JAVA GO], attrs: { env: "prod", tier: "1" } },
  { name: "Sample B", code: "C-002", roles: ["GUEST"], langs: ["PYTHON"], attrs: {} }
].freeze

def repository(table)
  require "sqlite3"
  @db ||= SQLite3::Database.new(ENV.fetch("ERUPT_DB", "blog.db"))
  Erupt::SqlRepository.new(Erupt::SqlExecutor.sqlite3(@db), table, auto_create: true)
rescue LoadError
  warn "sqlite3 gem not installed: #{table} kept in memory"
  Erupt::MemoryRepository.new
end

def seed(repo, records)
  records.each { |record| repo.add(record) } if repo.page(Erupt::Query.new(limit: 1)).first.zero?
end

node = Erupt::Node.new(ENV.fetch("ERUPT_NODE_NAME", "blog"), ENV.fetch("ERUPT_ACCESS_TOKEN"),
                       ENV.fetch("ERUPT_SERVER", "http://localhost:8080"))
categories = repository("category")
articles = repository("article")
components = repository("component")
node.register(Category, categories)
node.register(Article, articles)
node.register(Component, components)
seed(categories, CATEGORIES)
seed(articles, ARTICLES)
seed(components, COMPONENTS)
node.serve(port: Integer(ENV.fetch("PORT", "9090")))
