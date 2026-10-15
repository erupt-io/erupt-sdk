"""A blog admin served from Python. Create node 'blog' on the erupt server first, then:

    ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 python examples/blog.py
"""
import datetime
import logging
import os

from erupt import Field, Node, SqliteRepository, erupt, operation


@erupt("Category")
class Category:
    id: int = Field(pk=True)
    name: str = Field("Name", search=True, not_null=True)
    parent: int = Field("Parent Id")


@erupt("Publish Options")
class PublishForm:
    publish_date: datetime.date = Field("Publish Date", not_null=True)


@erupt("Article", order_by="id desc")
class Article:
    id: int = Field(pk=True)
    title: str = Field("Title", search=True, not_null=True, sortable=True)
    category: Category = Field("Category", search=True)
    topic: Category = Field("Topic", tree="parent", table=False)
    status: str = Field("Status", choices={"draft": "Draft", "published": "Published"}, search=True)
    views: int = Field("Views", sortable=True)
    featured: bool = Field("Featured", search=True)
    publish_date: datetime.date = Field("Publish Date", search=True)
    review_at: datetime.datetime = Field("Review At", sortable=True)
    body: str = Field("Body", type="TEXTAREA", table=False)

    @operation("Publish", icon="fa fa-paper-plane", form=PublishForm, if_expr="item.status !== 'published'")
    def publish(op):
        for row in op.rows:
            op.repo.update(row["id"], {"status": "published", "publish_date": op.param["publish_date"]})

    @operation("Feature", mode="SINGLE", icon="fa fa-star", confirm="Feature this article on the home page?")
    def feature(op):
        op.repo.update(op.rows[0]["id"], {"featured": True})


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    node = Node(os.environ.get("ERUPT_NODE_NAME", "blog"), os.environ["ERUPT_ACCESS_TOKEN"], os.environ.get("ERUPT_SERVER", "http://localhost:8080"))
    node.register(Category, SqliteRepository("blog.db", "category"))
    node.register(Article, SqliteRepository("blog.db", "article"))
    node.serve(port=int(os.environ.get("PORT", 9090)))
