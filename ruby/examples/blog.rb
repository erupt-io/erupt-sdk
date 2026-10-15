# frozen_string_literal: true

# A blog admin served from Ruby. Create node "blog" on the erupt server first, then:
#
#   ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 ruby examples/blog.rb
#
# Records live in memory; hand Erupt::SqlRepository a database (see README) to persist them.
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "erupt"

class Category
  extend Erupt::Model
  erupt "Category"
  field :id, pk: true
  field :name, "Name", search: true, not_null: true
  field :parent, "Parent Id", Integer
end

class PublishForm
  extend Erupt::Model
  erupt "Publish Options"
  field :publish_date, "Publish Date", Date, not_null: true
end

class Article
  extend Erupt::Model
  erupt "Article", order_by: "id desc"
  field :id, pk: true
  field :title, "Title", search: true, not_null: true, sortable: true
  field :category, "Category", Category, search: true
  field :topic, "Topic", Category, tree: :parent, table: false
  field :status, "Status", choices: { draft: "Draft", published: "Published" }, search: true
  field :views, "Views", Integer, sortable: true
  field :featured, "Featured", :boolean, search: true
  field :publish_date, "Publish Date", Date, search: true
  field :review_at, "Review At", Time, sortable: true
  field :body, "Body", type: Erupt::EditType::TEXTAREA, table: false

  operation :publish, "Publish", icon: "fa fa-paper-plane", form: PublishForm, if_expr: "item.status !== 'published'" do |op|
    op.rows.each { |row| op.repo.update(row["id"], status: "published", publish_date: op.param["publish_date"]) }
  end

  operation :feature, "Feature", mode: Erupt::RowOperationMode::SINGLE, icon: "fa fa-star",
                                 confirm: "Feature this article on the home page?" do |op|
    op.repo.update(op.rows.first["id"], featured: true)
  end
end

node = Erupt::Node.new(ENV.fetch("ERUPT_NODE_NAME", "blog"), ENV.fetch("ERUPT_ACCESS_TOKEN"),
                       ENV.fetch("ERUPT_SERVER", "http://localhost:8080"))
node.register(Category, Erupt::MemoryRepository.new([{ name: "Tech" }, { name: "Ruby", parent: 1 }, { name: "Life" }]))
node.register(Article, Erupt::MemoryRepository.new)
node.serve(port: Integer(ENV.fetch("PORT", "9090")))
