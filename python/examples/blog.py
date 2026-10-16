"""A blog admin served from Python, covering the field types and features of SHOWCASE.md. Create the node on the
erupt server first, then:

    ERUPT_NODE_NAME=blog ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 python examples/blog.py

Edit types without a shortcut (RATE, SLIDER, TAGS, COLOR, ICON, HTML_EDITOR, MARKDOWN, CODE_EDITOR) are declared
as the storage type they hold (str / int) with the edit type and its options passed through ``edit={...}``.
The Component model shows the rest: form-only elements as ``virtual`` fields, MULTI_CHOICE / KEY_VALUE as JSON.
"""
import datetime
import logging
import os

from erupt import Field, Node, Query, SqliteRepository, erupt, operation


@erupt("Category")
class Category:
    id: int = Field(pk=True)
    name: str = Field("Name", search=True, not_null=True, sortable=True)
    parent: int = Field("Parent Id")
    sort: int = Field("Sort", sortable=True)


@erupt("Publish Options")
class PublishForm:
    publish_date: datetime.date = Field("Publish Date", not_null=True)


@erupt("Article", order_by="id desc", power={"importable": True})
class Article:
    id: int = Field(pk=True)
    title: str = Field("Title", search=True, not_null=True, sortable=True, edit={"inputType": {"length": 60}})
    summary: str = Field("Summary", type="TEXTAREA", table=False, edit={"textareaType": {"length": 200}})
    category: Category = Field("Category", search=True)
    topic: Category = Field("Topic", tree="parent", table=False)
    status: str = Field("Status", choices={"draft": "Draft", "review": "In Review", "published": "Published"}, search=True)
    tags: str = Field("Tags", edit={"type": "TAGS", "tagsType": {
        "allowExtension": True, "fetchHandler": [], "joinSeparator": ",", "maxTagCount": 9999}})
    views: int = Field("Views", sortable=True, edit={"numberType": {"min": 0}})
    price: float = Field("Price", edit={"numberType": {"min": 0, "precision": 2, "prefix": "$"}})
    rating: float = Field("Rating", sortable=True, edit={"type": "RATE", "rateType": {
        "count": 5, "allowHalf": True, "character": ""}})
    progress: int = Field("Progress", edit={"type": "SLIDER", "sliderType": {
        "min": 0, "max": 100, "step": 5, "markPoints": [], "dots": False}})
    featured: bool = Field("Featured", search=True)
    color: str = Field("Theme Color", edit={"type": "COLOR", "colorType": {"alpha": False, "presets": [], "showText": True}})
    icon: str = Field("Icon", table=False, edit={"type": "ICON"})
    publish_date: datetime.date = Field("Publish Date", search=True, edit={"search": {"operator": "RANGE"}})
    review_at: datetime.datetime = Field("Review At", sortable=True)
    content: str = Field("Content", table=False, edit={"type": "HTML_EDITOR", "htmlEditorType": {"value": "CKEDITOR"}})
    notes: str = Field("Notes", table=False, edit={"type": "MARKDOWN"})
    meta: str = Field("Meta (JSON)", table=False, edit={"type": "CODE_EDITOR", "codeEditType": {
        "language": "json", "height": 300, "hints": [], "hintHandler": []}})

    @operation("Publish", icon="fa fa-paper-plane", form=PublishForm, if_expr="item.status !== 'published'")
    def publish(op):
        for row in op.rows:
            op.repo.update(row["id"], {"status": "published", "publish_date": op.param["publish_date"]})

    @operation("Feature", mode="SINGLE", icon="fa fa-star", confirm="Feature this article on the home page?")
    def feature(op):
        op.repo.update(op.rows[0]["id"], {"featured": True})


@erupt("Component")
class Component:
    """Every component a node can declare without extra endpoints. Form-only elements are ``virtual``; MULTI_CHOICE
    and KEY_VALUE hold a JSON value (``list`` / ``dict``)."""
    id: int = Field(pk=True)
    name: str = Field("Name", search=True, not_null=True)
    intro = Field("Guide", type="INPUT", virtual=True, edit={"type": "CALLOUT", "calloutType": {
        "value": "Every component a node can declare without extra endpoints.", "style": "INFO"}})
    basic = Field("Basic", type="INPUT", virtual=True, edit={"type": "DIVIDE"})
    code: str = Field("Code", table=False, edit={"type": "HIDDEN"})
    roles: list = Field("Roles", search=True, choices={"ADMIN": "Admin", "USER": "User", "GUEST": "Guest"},
                        edit={"type": "MULTI_CHOICE", "multiChoiceType": {"type": "CHECKBOX"}})
    langs: list = Field("Languages", choices={"JAVA": "Java", "PYTHON": "Python", "GO": "Go", "RUST": "Rust"},
                        edit={"type": "MULTI_CHOICE", "multiChoiceType": {"type": "SELECT"}})
    attrs: dict = Field("Attributes", edit={"type": "KEY_VALUE", "keyValueType": {
        "keyPlaceholder": "Key", "valuePlaceholder": "Value"}})
    spacer = Field("", type="INPUT", virtual=True, edit={"type": "EMPTY"})
    extra = Field("Extra", type="INPUT", virtual=True, edit={"type": "DIVIDE"})
    location: str = Field("Location", edit={"type": "MAP"})
    signature: str = Field("Signature", table=False, edit={"type": "SIGNATURE"})
    place = Field("Place & Sign", type="INPUT", virtual=True, edit={"type": "GROUP", "groupType": {
        "fields": ["location", "signature"]}})


CATEGORIES = [
    {"name": "Tech", "parent": None, "sort": 1},
    {"name": "Python", "parent": 1, "sort": 2},
    {"name": "Go", "parent": 1, "sort": 3},
    {"name": "Life", "parent": None, "sort": 4},
    {"name": "Travel", "parent": 4, "sort": 5},
]

ARTICLES = [
    {"title": "Hello Erupt", "summary": "A first look at erupt nodes", "category": 2, "topic": 2, "status": "published",
     "tags": "intro,erupt", "views": 120, "price": 9.9, "rating": 4.5, "progress": 100, "featured": True,
     "color": "#1677ff", "icon": "fa fa-book", "publish_date": datetime.date(2026, 10, 1),
     "review_at": datetime.datetime(2026, 10, 2, 10, 0), "content": "<p>Hello</p>", "notes": "# Hello", "meta": '{"a":1}'},
    {"title": "Go Tips", "category": 3, "topic": 3, "status": "review", "tags": "go", "views": 30, "price": 0,
     "rating": 3, "progress": 60, "featured": False},
    {"title": "Weekend Trip", "category": 5, "topic": 5, "status": "draft", "views": 0, "rating": 0, "progress": 10,
     "featured": False},
]


COMPONENTS = [
    {"name": "Sample A", "code": "C-001", "roles": ["ADMIN", "USER"], "langs": ["JAVA", "GO"], "attrs": {"env": "prod", "tier": "1"}},
    {"name": "Sample B", "code": "C-002", "roles": ["GUEST"], "langs": ["PYTHON"], "attrs": {}},
]


def seed(repo, records):
    if repo.page(Query(limit=1))[0] == 0:
        for record in records:
            repo.add(record)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    db = os.environ.get("ERUPT_DB", "blog.db")
    node = Node(os.environ.get("ERUPT_NODE_NAME", "blog"), os.environ["ERUPT_ACCESS_TOKEN"],
                os.environ.get("ERUPT_SERVER", "http://localhost:8080"))
    categories, articles = SqliteRepository(db, "category"), SqliteRepository(db, "article")
    components = SqliteRepository(db, "component")
    node.register(Category, categories)
    node.register(Article, articles)
    node.register(Component, components)
    seed(categories, CATEGORIES)
    seed(articles, ARTICLES)
    seed(components, COMPONENTS)
    node.serve(port=int(os.environ.get("PORT", 9090)))
