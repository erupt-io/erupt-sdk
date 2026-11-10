# frozen_string_literal: true

# The showcase admin served from Ruby that uses every capability of the SDK, as SHOWCASE.md describes it. Create the node
# on the erupt server first, then (the sqlite3 gem holds the records in ERUPT_DB, default showcase.db):
#
#   ERUPT_NODE_NAME=showcase ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 ruby examples/showcase.rb
#
# Edit types without a shortcut are declared as the storage kind they hold (String / Integer / Array / Hash) with
# the edit type in +type:+ and its options in +edit:+. Form-only elements are +virtual:+; MULTI_CHOICE / KEY_VALUE
# hold JSON (kind Array / Hash), and KEY_VALUE, CALLOUT, DIVIDE, EMPTY, GROUP are declared through +edit: { type: }+.
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "date"
require "json"
require "logger"
require "sqlite3"
require "erupt"

LOG = Logger.new($stderr, level: Logger::INFO, progname: "showcase")
T = Erupt::EditType

# ---------------------------------------------------------------- reference data

class Category
  extend Erupt::Model
  erupt "Category", tree: { pid: "parent" }, dragSort: { field: "sort" },
                    drills: [{ title: "Articles", code: "Articles", link: { linkErupt: "Article", joinColumn: "category" } }]
  field :id, pk: true
  field :name, "Name", search: true, not_null: true, sortable: true
  field :parent, "Parent Id", Integer
  field :sort, "Sort", Integer, sortable: true
end

class Author
  extend Erupt::Model
  erupt "Author", drills: [{ title: "Articles", code: "Articles",
                             link: { linkErupt: "Article", joinColumn: "author", linkCondition: "status = 'published'" } }]
  field :id, pk: true
  field :name, "Name", search: true, not_null: true
  field :email, "Email", edit: { inputType: { regex: '^[^@\s]+@[^@\s]+\.[^@\s]+$' } }
  field :active, "Active", :boolean, search: true, not_null: true
end

class Tag
  extend Erupt::Model
  erupt "Tag"
  field :id, pk: true
  field :name, "Name", search: true, not_null: true
  field :color, "Color", type: T::COLOR
end

class PublishForm
  extend Erupt::Model
  erupt "Publish Options"
  field :publish_date, "Publish Date", Date, not_null: true
end

class AuditLog
  extend Erupt::Model
  erupt "Audit Log", order_by: "id desc", power: { add: false, edit: false, delete: false }
  field :id, pk: true
  field :action, "Action", search: true, choices: { add: "Add", update: "Update", delete: "Delete" }
  field :article, "Article"
  field :account, "By", search: true
  field :at, "At", Time, sortable: true
end

# ---------------------------------------------------------------- the node's own code (invoke)

CITIES = %w[Paris Tokyo Lisbon Austin].freeze

# title onchange: suggest a summary while there is none.
SUMMARY_FROM_TITLE = lambda do |form|
  title, summary = form["title"].to_s, form["summary"].to_s
  !title.empty? && summary.empty? ? { formData: { summary: "About #{title}" } } : {}
end

# level options: an expert level once the article is read a lot.
LEVELS = lambda do |form|
  options = { beginner: "Beginner", advanced: "Advanced" }
  options[:expert] = "Expert" if form["views"].to_f >= 1000
  options
end

PREVIEW = ->(form) { { eval: "alert(#{JSON.generate("Preview: #{form["title"]}")})" } }

def now = Time.at(Time.now.to_i)

# Every hook of a data proxy; +audit+ is the Audit Log repository, set when the node starts.
class ArticleProxy < Erupt::DataProxy
  class << self
    attr_accessor :audit
  end
  @fetched = 0
  @lock = Mutex.new

  def self.count(rows) = @lock.synchronize { @fetched += rows }

  def search_condition(condition)
    condition["status"] = "published"
  end

  def before_fetch(_conditions) = "status <> 'archived'"

  def after_fetch(rows)
    LOG.debug("rows fetched so far: #{ArticleProxy.count(rows.size)}")
  end

  def add_behavior(record)
    record.merge!("status" => "draft", "views" => 0, "progress" => 0)
  end

  def validate(record)
    raise Erupt::Fail, "This title is not allowed" if record["title"] == "forbidden"
  end

  def before_add(record) = stamp_review(record)

  def before_update(record) = stamp_review(record)

  def after_add(record) = log("add", record)

  def after_update(record) = log("update", record)

  def before_delete(record)
    raise Erupt::Fail, "Unpublish it first" if record["status"] == "published"
  end

  def after_delete(record) = log("delete", record)

  private

  def stamp_review(record)
    record["review_at"] = now if record["status"] == "review" && record["review_at"].nil?
  end

  def log(action, record)
    user = Erupt.current_user || {}
    ArticleProxy.audit.add(action: action, article: record["title"], account: user["account"], at: now)
  end
end

# ---------------------------------------------------------------- the article: every field type and behaviour

class Article
  extend Erupt::Model
  erupt "Article", order_by: "id desc", power: { importable: true }, data_proxy: ArticleProxy,
                   linkTree: { field: "category" },
                   vis: [{ title: "Drafts", code: "Drafts", type: "TABLE", filter: "status = 'draft'", orderBy: "views desc" },
                         { title: "Board", code: "Board", type: "BOARD", boardView: { groupField: "status", sumField: "views" } },
                         { title: "Calendar", code: "Calendar", type: "CALENDAR", calendarView: { dateField: "publish_date" } },
                         { title: "Cards", code: "Cards", type: "CARD", cardView: { coverField: "cover" } },
                         { title: "Timeline", code: "Timeline", type: "TIMELINE", timelineView: { dateField: "review_at" } }]
  field :id, pk: true
  field :title, "Title", search: true, not_null: true, sortable: true, edit: { inputType: { length: 60 } },
                         onchange: SUMMARY_FROM_TITLE
  field :summary, "Summary", type: T::TEXTAREA, table: false, edit: { textareaType: { length: 200 } }
  field :author, "Author", Author, search: true
  field :category, "Category", Category, search: true
  field :sub_category, "Sub Category", Category, table: false,
                                       edit: { referenceTableType: { dependField: "category", dependColumn: "parent" } }
  field :topic, "Topic", Category, tree: :parent, table: false
  field :tag_ids, "Tags (checkbox)", type: T::CHECKBOX, ref: Tag, table: false
  field :reviewers, "Reviewers", type: T::TRANSFER, ref: Author, table: false
  field :sections, "Sections", type: T::TAB_TREE, ref: Category, table: false
  field :status, "Status", search: true, choices: { draft: "Draft", review: "In Review", published: "Published",
                                                    archived: "Archived" }
  field :level, "Level", fetch: LEVELS
  field :labels, "Labels", type: T::TAGS, fetch: ->(_form) { %w[hot new classic] },
                           edit: { tagsType: { allowExtension: true, joinSeparator: "," } }
  field :city, "City", type: T::AUTO_COMPLETE, edit: { autoCompleteType: { triggerLength: 1 } },
                       complete: ->(_form, typed) { CITIES.select { |c| c.downcase.include?(typed.to_s.downcase) } }
  field :cover, "Cover", type: T::ATTACHMENT, edit: { attachmentType: { type: "IMAGE", maxLimit: 1 } }
  field :views, "Views", Integer, sortable: true, edit: { numberType: { min: 0 } }
  field :price, "Price", Float, edit: { numberType: { min: 0, precision: 2, prefix: "$" } }
  field :rating, "Rating", Float, type: T::RATE, sortable: true, edit: { rateType: { count: 5, allowHalf: true } }
  field :progress, "Progress", Integer, type: T::SLIDER, edit: { sliderType: { min: 0, max: 100, step: 5 } }
  field :featured, "Featured", :boolean, search: true
  field :color, "Theme Color", type: T::COLOR
  field :icon, "Icon", type: T::ICON, table: false
  field :publish_date, "Publish Date", Date, search: true, edit: { search: { operator: "RANGE" } }
  field :review_at, "Review At", Time, sortable: true
  field :content, "Content", type: T::HTML_EDITOR, table: false
  field :notes, "Notes", type: T::MARKDOWN, table: false
  field :meta, "Meta (JSON)", type: T::CODE_EDITOR, table: false, edit: { codeEditType: { language: "json" } }
  field :preview, "Preview", type: T::BUTTON, click: PREVIEW

  operation :publish, "Publish", icon: "fa fa-paper-plane", form: PublishForm, if_expr: "item.status !== 'published'" do |op|
    op.rows.each { |row| op.repo.update(row["id"], status: "published", publish_date: op.param["publish_date"]) }
  end

  operation :feature, "Feature", mode: Erupt::RowOperationMode::SINGLE, icon: "fa fa-star",
                                 confirm: "Feature this article on the home page?" do |op|
    op.repo.update(op.rows.first["id"], featured: true)
  end

  operation :archive, "Archive", mode: Erupt::RowOperationMode::MULTI_ONLY, icon: "fa fa-archive", confirm: false do |op|
    op.rows.each { |row| op.repo.update(row["id"], status: "archived") }
  end

  operation :stats, "Stats", mode: Erupt::RowOperationMode::BUTTON, icon: "fa fa-bar-chart",
                             show: ->(user) { user&.fetch("account", nil) == "admin" } do |op|
    total, = op.repo.page(Erupt::Query.new(limit: 1))
    "alert('#{total} articles')"
  end
end

# Layout and JSON-valued components. Form-only elements are virtual; MULTI_CHOICE and KEY_VALUE hold a JSON value
# (kind Array / Hash).
class Component
  extend Erupt::Model
  erupt "Component"
  field :id, pk: true
  field :name, "Name", search: true, not_null: true
  field :intro, "Guide", virtual: true, edit: { type: "CALLOUT", calloutType: {
    value: "Layout and JSON-valued components.", style: "INFO"
  } }
  field :basic, "Basic", virtual: true, edit: { type: "DIVIDE" }
  field :code, "Code", type: T::HIDDEN, table: false
  field :roles, "Roles", Array, search: true, choices: { ADMIN: "Admin", USER: "User", GUEST: "Guest" },
                                edit: { multiChoiceType: { type: "CHECKBOX" } }
  field :langs, "Languages", Array, choices: { JAVA: "Java", PYTHON: "Python", GO: "Go", RUST: "Rust" },
                                    edit: { multiChoiceType: { type: "SELECT" } }
  field :attrs, "Attributes", Hash, edit: { type: "KEY_VALUE", keyValueType: { keyPlaceholder: "Key", valuePlaceholder: "Value" } }
  field :spacer, "", virtual: true, edit: { type: "EMPTY" }
  field :extra, "Extra", virtual: true, edit: { type: "DIVIDE" }
  field :location, "Location", type: T::MAP
  field :signature, "Signature", type: T::SIGNATURE, table: false
  field :place, "Place & Sign", virtual: true, edit: { type: "GROUP", groupType: { fields: %w[location signature] } }
end

# ---------------------------------------------------------------- buttons, form behaviour, table display, server calls

# level options follow the kind (choiceType.dependField).
LEVELS_BY_KIND = ->(form) { form["kind"] == "advanced" ? { high: "High", expert: "Expert" } : { low: "Low", mid: "Mid" } }

WHOAMI = ->(_form) { { eval: "alert(#{JSON.generate((Erupt.current_user || {})["account"].to_s)})" } }

class RenameForm
  extend Erupt::Model
  erupt "Rename"
  field :name, "New Name", not_null: true
end

class Playground
  extend Erupt::Model
  class << self
    # set when the node starts: the Node Info operation calls the server back through it
    attr_accessor :node
  end

  erupt "Buttons & Forms", power: { export: false }, layout: { pageSize: 20, tableLeftFixed: 1 }
  field :id, pk: true
  field :name, "Name", search: true, not_null: true, edit: {
    search: { operator: "LIKE", lockOperator: true },
    inputType: { prefix: [{ value: "@", label: "@" }], suffix: [{ value: ".dev", label: ".dev" }, { value: ".io", label: ".io" }] },
    placeHolder: "a short name", desc: "Shown first in the table"
  }
  field :kind, "Kind", search: true, choices: { simple: "Simple", advanced: "Advanced" }
  field :level, "Level", fetch: LEVELS_BY_KIND, edit: { choiceType: { dependField: "kind" } }
  field :note, "Advanced Note", type: T::TEXTAREA, table: false, edit: { dynamic: {
    dependField: "kind", condition: "value === 'advanced'", match: "SHOW", noMatch: "HIDE"
  } }
  field :code, "Code", edit: { readOnly: { add: false, edit: true } }
  field :amount, "Amount", Float, edit: { numberType: { prefix: "$" } },
                                  view: { statistic: "SUM", className: "text-right", width: "120px" }
  field :score, "Score", Float, view: { statistic: "AVG" }
  field :skills, "Skills", Array, fetch: ->(_form) { { java: "Java", python: "Python", go: "Go" } }
  field :files, "Files", type: T::ATTACHMENT, table: false,
                         edit: { attachmentType: { type: "BASE", maxLimit: 3, fileTypes: %w[pdf txt md] } }
  field :fill, "Fill Sample", type: T::BUTTON, edit: { buttonType: { style: "primary", icon: "fa fa-magic" } },
                              click: ->(_form) { { formData: { name: "sample", kind: "advanced", amount: 42, score: 4 } } }
  field :reset, "Clear", type: T::BUTTON, edit: { buttonType: { danger: true, confirm: "Clear the form?" } },
                         click: ->(_form) { { formData: { name: "", amount: 0, score: 0 } } }
  field :whoami, "Who Am I", type: T::BUTTON, edit: { buttonType: { fullSpan: true, icon: "fa fa-user" } }, click: WHOAMI

  operation :rename, "Rename", mode: Erupt::RowOperationMode::SINGLE, form: RenameForm, tip: "Give the row a new name" do |op|
    op.repo.update(op.rows.first["id"], name: op.param["name"])
  end

  operation :double, "Double", if_expr: "item.amount > 0", ifExprBehavior: "HIDE" do |op|
    op.rows.each { |row| op.repo.update(row["id"], amount: (row["amount"] || 0) * 2) }
  end

  operation :reset_amounts, "Reset Amounts", confirm: "Reset the amounts?", fold: true do |op|
    op.rows.each { |row| op.repo.update(row["id"], amount: 0) }
  end

  operation :node_info, "Node Info", mode: Erupt::RowOperationMode::BUTTON, icon: "fa fa-info-circle" do |op|
    account = (op.user || {})["account"].to_s
    roles = begin
      Array((Playground.node.user_info || {})["roles"]).size
    rescue StandardError
      0
    end
    config = begin
      Playground.node.config.to_s.size
    rescue StandardError
      0
    end
    "alert(#{JSON.generate("#{account}: #{roles} roles, config #{config} chars")})"
  end
end

# ---------------------------------------------------------------- seed data

CATEGORIES = [
  { name: "Tech", parent: nil, sort: 1 }, { name: "Python", parent: 1, sort: 2 }, { name: "Go", parent: 1, sort: 3 },
  { name: "Life", parent: nil, sort: 4 }, { name: "Travel", parent: 4, sort: 5 }
].freeze

AUTHORS = [
  { name: "Ann", email: "ann@example.com", active: true }, { name: "Bob", email: "bob@example.com", active: true },
  { name: "Cy", email: "cy@example.com", active: false }
].freeze

TAGS = [{ name: "intro", color: "#1677ff" }, { name: "guide", color: "#52c41a" }, { name: "news", color: "#fa8c16" }].freeze

ARTICLES = [
  { title: "Hello Erupt", summary: "A first look at erupt nodes", author: 1, category: 2, topic: 2, tag_ids: [1, 2],
    reviewers: [2], sections: [1, 2], status: "published", level: "beginner", labels: "hot,new", city: "Paris",
    views: 120, price: 9.9, rating: 4.5, progress: 100, featured: true, color: "#1677ff", icon: "fa fa-book",
    publish_date: Date.new(2026, 10, 1), review_at: Time.new(2026, 10, 2, 10, 0, 0), content: "<p>Hello</p>",
    notes: "# Hello", meta: '{"a":1}' },
  { title: "Go Tips", author: 2, category: 3, topic: 3, tag_ids: [2], status: "review", level: "advanced",
    labels: "classic", views: 30, price: 0, rating: 3, progress: 60, featured: false },
  { title: "Weekend Trip", author: 3, category: 5, topic: 5, status: "draft", views: 0, rating: 0, progress: 10,
    featured: false }
].freeze

COMPONENTS = [
  { name: "Sample A", code: "C-001", roles: %w[ADMIN USER], langs: %w[JAVA GO], attrs: { env: "prod", tier: "1" } },
  { name: "Sample B", code: "C-002", roles: ["GUEST"], langs: ["PYTHON"], attrs: {} }
].freeze

PLAYGROUND = [
  { name: "alpha", kind: "simple", level: "low", code: "A-1", amount: 10, score: 3, skills: ["java"] },
  { name: "beta", kind: "advanced", level: "expert", note: "deep dive", code: "B-1", amount: 0, score: 5,
    skills: %w[python go] },
  { name: "gamma", kind: "simple", level: "mid", code: "G-1", amount: 25, score: 4, skills: [] }
].freeze

def seed(repo, records)
  records.each { |record| repo.add(record) } if repo.page(Erupt::Query.new(limit: 1)).first.zero?
end

if $PROGRAM_NAME == __FILE__
  db = Erupt::SqlExecutor.sqlite3(SQLite3::Database.new(ENV.fetch("ERUPT_DB", "showcase.db")))
  node = Erupt::Node.new(ENV.fetch("ERUPT_NODE_NAME", "showcase"), ENV.fetch("ERUPT_ACCESS_TOKEN"),
                         ENV.fetch("ERUPT_SERVER", "http://localhost:8080"))
  repos = { Category => "category", Author => "author", Tag => "tag", Article => "article", Component => "component",
            AuditLog => "audit_log", Playground => "playground" }.to_h { |model, table| [model, Erupt::SqlRepository.new(db, table, auto_create: true)] }
  ArticleProxy.audit = repos[AuditLog]
  Playground.node = node
  repos.each { |model, repo| node.register(model, repo) }
  [[Category, CATEGORIES], [Author, AUTHORS], [Tag, TAGS], [Article, ARTICLES], [Component, COMPONENTS],
   [Playground, PLAYGROUND]].each do |model, rows|
    seed(repos[model], rows)
  end
  node.serve(port: Integer(ENV.fetch("PORT", "9090")))
end
