"""The showcase admin served from Python that uses every capability of the SDK, as SHOWCASE.md describes it. Create the
node on the erupt server first, then:

    ERUPT_NODE_NAME=showcase ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 python examples/showcase.py

Edit types without a shortcut are declared as the storage type they hold (str / int / list) with the edit type and
its options passed through ``edit={...}``. Form-only elements are ``virtual``; MULTI_CHOICE / KEY_VALUE hold JSON.
"""
import datetime
import json
import logging
import os

from erupt import DataProxy, Fail, Field, Node, Query, SqliteRepository, current_user, erupt, operation

log = logging.getLogger("showcase")


# ---------------------------------------------------------------- reference data

@erupt("Category", tree={"pid": "parent"}, dragSort={"field": "sort"},
       drills=[{"title": "Articles", "code": "Articles", "link": {"linkErupt": "Article", "joinColumn": "category"}}])
class Category:
    id: int = Field(pk=True)
    name: str = Field("Name", search=True, not_null=True, sortable=True)
    parent: int = Field("Parent Id")
    sort: int = Field("Sort", sortable=True)


@erupt("Author", drills=[{"title": "Articles", "code": "Articles",
                          "link": {"linkErupt": "Article", "joinColumn": "author", "linkCondition": "status = 'published'"}}])
class Author:
    id: int = Field(pk=True)
    name: str = Field("Name", search=True, not_null=True)
    email: str = Field("Email", edit={"inputType": {"regex": r"^[^@\s]+@[^@\s]+\.[^@\s]+$"}})
    active: bool = Field("Active", search=True, not_null=True)


@erupt("Tag")
class Tag:
    id: int = Field(pk=True)
    name: str = Field("Name", search=True, not_null=True)
    color: str = Field("Color", edit={"type": "COLOR"})


@erupt("Publish Options")
class PublishForm:
    publish_date: datetime.date = Field("Publish Date", not_null=True)


@erupt("Audit Log", order_by="id desc", power={"add": False, "edit": False, "delete": False})
class AuditLog:
    id: int = Field(pk=True)
    action: str = Field("Action", search=True, choices={"add": "Add", "update": "Update", "delete": "Delete"})
    article: str = Field("Article")
    account: str = Field("By", search=True)
    at: datetime.datetime = Field("At", sortable=True)


# ---------------------------------------------------------------- the node's own code (invoke)

CITIES = ["Paris", "Tokyo", "Lisbon", "Austin"]


def summary_from_title(form):
    """title onchange: suggest a summary while there is none."""
    if form.get("title") and not form.get("summary"):
        return {"formData": {"summary": "About " + form["title"]}}
    return {}


def levels(form):
    """level options: an expert level once the article is read a lot."""
    options = {"beginner": "Beginner", "advanced": "Advanced"}
    if (form.get("views") or 0) >= 1000:
        options["expert"] = "Expert"
    return options


def preview(form):
    return {"eval": "alert(" + json.dumps("Preview: " + (form.get("title") or "")) + ")"}


class ArticleProxy(DataProxy):
    """Every hook of a data proxy; ``audit`` is the Audit Log repository, set when the node starts."""
    audit = None
    fetched = 0

    def search_condition(self, condition):
        condition["status"] = "published"

    def before_fetch(self, conditions):
        return "status <> 'archived'"

    def after_fetch(self, rows):
        ArticleProxy.fetched += len(rows)
        log.debug("rows fetched so far: %s", ArticleProxy.fetched)

    def add_behavior(self, record):
        record.update(status="draft", views=0, progress=0)

    def validate(self, record):
        if record.get("title") == "forbidden":
            raise Fail("This title is not allowed")

    def before_add(self, record):
        self._stamp_review(record)

    def before_update(self, record):
        self._stamp_review(record)

    def after_add(self, record):
        self._log("add", record)

    def after_update(self, record):
        self._log("update", record)

    def before_delete(self, record):
        if record.get("status") == "published":
            raise Fail("Unpublish it first")

    def after_delete(self, record):
        self._log("delete", record)

    @staticmethod
    def _stamp_review(record):
        if record.get("status") == "review" and not record.get("review_at"):
            record["review_at"] = datetime.datetime.now().replace(microsecond=0)

    def _log(self, action, record):
        user = current_user() or {}
        self.audit.add({"action": action, "article": record.get("title"), "account": user.get("account"),
                        "at": datetime.datetime.now().replace(microsecond=0)})


# ---------------------------------------------------------------- the article: every field type and behaviour

@erupt("Article", order_by="id desc", power={"importable": True}, data_proxy=ArticleProxy,
       linkTree={"field": "category"},
       vis=[{"title": "Drafts", "code": "Drafts", "type": "TABLE", "filter": "status = 'draft'", "orderBy": "views desc"},
            {"title": "Board", "code": "Board", "type": "BOARD", "boardView": {"groupField": "status", "sumField": "views"}},
            {"title": "Calendar", "code": "Calendar", "type": "CALENDAR", "calendarView": {"dateField": "publish_date"}},
            {"title": "Cards", "code": "Cards", "type": "CARD", "cardView": {"coverField": "cover"}},
            {"title": "Timeline", "code": "Timeline", "type": "TIMELINE", "timelineView": {"dateField": "review_at"}}])
class Article:
    id: int = Field(pk=True)
    title: str = Field("Title", search=True, not_null=True, sortable=True, edit={"inputType": {"length": 60}},
                       onchange=summary_from_title)
    summary: str = Field("Summary", type="TEXTAREA", table=False, edit={"textareaType": {"length": 200}})
    author: Author = Field("Author", search=True)
    category: Category = Field("Category", search=True)
    sub_category: Category = Field("Sub Category", table=False,
                                   edit={"referenceTableType": {"dependField": "category", "dependColumn": "parent"}})
    topic: Category = Field("Topic", tree="parent", table=False)
    tag_ids: list = Field("Tags (checkbox)", type="CHECKBOX", ref=Tag, table=False)
    reviewers: list = Field("Reviewers", type="TRANSFER", ref=Author, table=False)
    sections: list = Field("Sections", type="TAB_TREE", ref=Category, table=False)
    status: str = Field("Status", search=True, choices={
        "draft": "Draft", "review": "In Review", "published": "Published", "archived": "Archived"})
    level: str = Field("Level", fetch=levels)
    labels: str = Field("Labels", type="TAGS", fetch=lambda form: ["hot", "new", "classic"],
                        edit={"tagsType": {"allowExtension": True, "joinSeparator": ","}})
    city: str = Field("City", type="AUTO_COMPLETE", edit={"autoCompleteType": {"triggerLength": 1}},
                      complete=lambda form, typed: [c for c in CITIES if typed.lower() in c.lower()])
    cover: str = Field("Cover", type="ATTACHMENT", edit={"attachmentType": {"type": "IMAGE", "maxLimit": 1}})
    views: int = Field("Views", sortable=True, edit={"numberType": {"min": 0}})
    price: float = Field("Price", edit={"numberType": {"min": 0, "precision": 2, "prefix": "$"}})
    rating: float = Field("Rating", type="RATE", sortable=True, edit={"rateType": {"count": 5, "allowHalf": True}})
    progress: int = Field("Progress", type="SLIDER", edit={"sliderType": {"min": 0, "max": 100, "step": 5}})
    featured: bool = Field("Featured", search=True)
    color: str = Field("Theme Color", type="COLOR")
    icon: str = Field("Icon", type="ICON", table=False)
    publish_date: datetime.date = Field("Publish Date", search=True, edit={"search": {"operator": "RANGE"}})
    review_at: datetime.datetime = Field("Review At", sortable=True)
    content: str = Field("Content", type="HTML_EDITOR", table=False)
    notes: str = Field("Notes", type="MARKDOWN", table=False)
    meta: str = Field("Meta (JSON)", type="CODE_EDITOR", table=False, edit={"codeEditType": {"language": "json"}})
    preview = Field("Preview", type="BUTTON", click=preview)

    @operation("Publish", icon="fa fa-paper-plane", form=PublishForm, if_expr="item.status !== 'published'")
    def publish(op):
        for row in op.rows:
            op.repo.update(row["id"], {"status": "published", "publish_date": op.param["publish_date"]})

    @operation("Feature", mode="SINGLE", icon="fa fa-star", confirm="Feature this article on the home page?")
    def feature(op):
        op.repo.update(op.rows[0]["id"], {"featured": True})

    @operation("Archive", mode="MULTI_ONLY", icon="fa fa-archive", confirm=False)
    def archive(op):
        for row in op.rows:
            op.repo.update(row["id"], {"status": "archived"})

    @operation("Stats", mode="BUTTON", icon="fa fa-bar-chart", show=lambda user: bool(user) and user.get("account") == "admin")
    def stats(op):
        total, _ = op.repo.page(Query(limit=1))
        return f"alert('{total} articles')"


@erupt("Component")
class Component:
    """Layout and JSON-valued components. Form-only elements are ``virtual``; MULTI_CHOICE and KEY_VALUE hold a JSON
    value (``list`` / ``dict``)."""
    id: int = Field(pk=True)
    name: str = Field("Name", search=True, not_null=True)
    intro = Field("Guide", type="INPUT", virtual=True, edit={"type": "CALLOUT", "calloutType": {
        "value": "Layout and JSON-valued components.", "style": "INFO"}})
    basic = Field("Basic", type="INPUT", virtual=True, edit={"type": "DIVIDE"})
    code: str = Field("Code", type="HIDDEN", table=False)
    roles: list = Field("Roles", search=True, choices={"ADMIN": "Admin", "USER": "User", "GUEST": "Guest"},
                        edit={"type": "MULTI_CHOICE", "multiChoiceType": {"type": "CHECKBOX"}})
    langs: list = Field("Languages", choices={"JAVA": "Java", "PYTHON": "Python", "GO": "Go", "RUST": "Rust"},
                        edit={"type": "MULTI_CHOICE", "multiChoiceType": {"type": "SELECT"}})
    attrs: dict = Field("Attributes", edit={"type": "KEY_VALUE", "keyValueType": {
        "keyPlaceholder": "Key", "valuePlaceholder": "Value"}})
    spacer = Field("", type="INPUT", virtual=True, edit={"type": "EMPTY"})
    extra = Field("Extra", type="INPUT", virtual=True, edit={"type": "DIVIDE"})
    location: str = Field("Location", type="MAP")
    signature: str = Field("Signature", type="SIGNATURE", table=False)
    place = Field("Place & Sign", type="INPUT", virtual=True, edit={"type": "GROUP", "groupType": {
        "fields": ["location", "signature"]}})


# ---------------------------------------------------------------- buttons, form behaviour, table display, server calls

NODE = None  # set when the node starts: the Node Info operation calls the server back through it


def levels_by_kind(form):
    """level options follow the kind (choiceType.dependField)."""
    if form.get("kind") == "advanced":
        return {"high": "High", "expert": "Expert"}
    return {"low": "Low", "mid": "Mid"}


def whoami(form):
    account = (current_user() or {}).get("account") or ""
    return {"eval": "alert(" + json.dumps(account) + ")"}


@erupt("Rename")
class RenameForm:
    name: str = Field("New Name", not_null=True)


@erupt("Buttons & Forms", power={"export": False}, layout={"pageSize": 20, "tableLeftFixed": 1})
class Playground:
    id: int = Field(pk=True)
    name: str = Field("Name", search=True, not_null=True, edit={
        "search": {"operator": "LIKE", "lockOperator": True}, "inputType": {"prefix": [{"value": "@", "label": "@"}],
                      "suffix": [{"value": ".dev", "label": ".dev"}, {"value": ".io", "label": ".io"}]},
        "placeHolder": "a short name", "desc": "Shown first in the table"})
    kind: str = Field("Kind", search=True, choices={"simple": "Simple", "advanced": "Advanced"})
    level: str = Field("Level", fetch=levels_by_kind, edit={"choiceType": {"dependField": "kind"}})
    note: str = Field("Advanced Note", type="TEXTAREA", table=False, edit={"dynamic": {
        "dependField": "kind", "condition": "value === 'advanced'", "match": "SHOW", "noMatch": "HIDE"}})
    code: str = Field("Code", edit={"readOnly": {"add": False, "edit": True}})
    amount: float = Field("Amount", edit={"numberType": {"prefix": "$"}},
                          view={"statistic": "SUM", "className": "text-right", "width": "120px"})
    score: float = Field("Score", view={"statistic": "AVG"})
    skills: list = Field("Skills", fetch=lambda form: {"java": "Java", "python": "Python", "go": "Go"})
    files: str = Field("Files", type="ATTACHMENT", table=False,
                       edit={"attachmentType": {"type": "BASE", "maxLimit": 3, "fileTypes": ["pdf", "txt", "md"]}})
    fill = Field("Fill Sample", type="BUTTON", edit={"buttonType": {"style": "primary", "icon": "fa fa-magic"}},
                 click=lambda form: {"formData": {"name": "sample", "kind": "advanced", "amount": 42, "score": 4}})
    reset = Field("Clear", type="BUTTON", edit={"buttonType": {"danger": True, "confirm": "Clear the form?"}},
                  click=lambda form: {"formData": {"name": "", "amount": 0, "score": 0}})
    whoami = Field("Who Am I", type="BUTTON", edit={"buttonType": {"fullSpan": True, "icon": "fa fa-user"}}, click=whoami)

    @operation("Rename", mode="SINGLE", form=RenameForm, tip="Give the row a new name")
    def rename(op):
        op.repo.update(op.rows[0]["id"], {"name": op.param["name"]})

    @operation("Double", if_expr="item.amount > 0", ifExprBehavior="HIDE")
    def double(op):
        for row in op.rows:
            op.repo.update(row["id"], {"amount": (row.get("amount") or 0) * 2})

    @operation("Reset Amounts", confirm="Reset the amounts?", fold=True)
    def reset_amounts(op):
        for row in op.rows:
            op.repo.update(row["id"], {"amount": 0})

    @operation("Node Info", mode="BUTTON", icon="fa fa-info-circle")
    def node_info(op):
        account = (op.user or {}).get("account") or ""
        try:
            roles = len((NODE.user_info() or {}).get("roles") or [])
        except Exception:
            roles = 0
        try:
            config = len(NODE.config() or "")
        except Exception:
            config = 0
        return f"alert({json.dumps(f'{account}: {roles} roles, config {config} chars')})"


# ---------------------------------------------------------------- seed data

CATEGORIES = [{"name": "Tech", "parent": None, "sort": 1}, {"name": "Python", "parent": 1, "sort": 2},
              {"name": "Go", "parent": 1, "sort": 3}, {"name": "Life", "parent": None, "sort": 4},
              {"name": "Travel", "parent": 4, "sort": 5}]

AUTHORS = [{"name": "Ann", "email": "ann@example.com", "active": True},
           {"name": "Bob", "email": "bob@example.com", "active": True},
           {"name": "Cy", "email": "cy@example.com", "active": False}]

TAGS = [{"name": "intro", "color": "#1677ff"}, {"name": "guide", "color": "#52c41a"}, {"name": "news", "color": "#fa8c16"}]

ARTICLES = [
    {"title": "Hello Erupt", "summary": "A first look at erupt nodes", "author": 1, "category": 2, "topic": 2,
     "tag_ids": [1, 2], "reviewers": [2], "sections": [1, 2], "status": "published", "level": "beginner",
     "labels": "hot,new", "city": "Paris", "views": 120, "price": 9.9, "rating": 4.5, "progress": 100, "featured": True,
     "color": "#1677ff", "icon": "fa fa-book", "publish_date": datetime.date(2026, 10, 1),
     "review_at": datetime.datetime(2026, 10, 2, 10, 0), "content": "<p>Hello</p>", "notes": "# Hello", "meta": '{"a":1}'},
    {"title": "Go Tips", "author": 2, "category": 3, "topic": 3, "tag_ids": [2], "status": "review", "level": "advanced",
     "labels": "classic", "views": 30, "price": 0, "rating": 3, "progress": 60, "featured": False},
    {"title": "Weekend Trip", "author": 3, "category": 5, "topic": 5, "status": "draft", "views": 0, "rating": 0,
     "progress": 10, "featured": False},
]

PLAYGROUND = [
    {"name": "alpha", "kind": "simple", "level": "low", "code": "A-1", "amount": 10, "score": 3, "skills": ["java"]},
    {"name": "beta", "kind": "advanced", "level": "expert", "note": "deep dive", "code": "B-1", "amount": 0, "score": 5,
     "skills": ["python", "go"]},
    {"name": "gamma", "kind": "simple", "level": "mid", "code": "G-1", "amount": 25, "score": 4, "skills": []},
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
    db = os.environ.get("ERUPT_DB", "showcase.db")
    node = Node(os.environ.get("ERUPT_NODE_NAME", "showcase"), os.environ["ERUPT_ACCESS_TOKEN"],
                os.environ.get("ERUPT_SERVER", "http://localhost:8080"))
    repos = {model: SqliteRepository(db, table) for model, table in [
        (Category, "category"), (Author, "author"), (Tag, "tag"), (Article, "article"), (Component, "component"),
        (AuditLog, "audit_log"), (Playground, "playground")]}
    ArticleProxy.audit = repos[AuditLog]
    NODE = node
    for model, repo in repos.items():
        node.register(model, repo)
    for model, rows in [(Category, CATEGORIES), (Author, AUTHORS), (Tag, TAGS), (Article, ARTICLES), (Component, COMPONENTS),
                        (Playground, PLAYGROUND)]:
        seed(repos[model], rows)
    node.serve(port=int(os.environ.get("PORT", 9090)))
