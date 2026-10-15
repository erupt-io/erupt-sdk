# erupt-sdk (JVM)

Serve Java / Kotlin classes as an erupt admin UI, **without Spring**: plain Java, Kotlin, Quarkus, Micronaut,
Vert.x, Ktor. Java 17+. The one runtime dependency is `xyz.erupt:erupt-annotation` (itself dependency-free):
models are declared with the very annotations a Spring erupt application uses, so a class moves between the two
unchanged.

```xml
<dependency>
    <groupId>xyz.erupt</groupId>
    <artifactId>erupt-sdk</artifactId>
    <version>0.1.0</version>
</dependency>
```

```java
@Erupt(name = "Article", orderBy = "id desc")
public class Article {
    @EruptField
    private Long id;

    @EruptField(views = @View(title = "Title", sortable = true),
            edit = @Edit(title = "Title", notNull = true, search = @Search))
    private String title;

    @EruptField(views = @View(title = "Publish Date"), edit = @Edit(title = "Publish Date", search = @Search))
    private LocalDate publishDate;

    @EruptField(edit = @Edit(title = "Body", type = EditType.TEXTAREA))
    private String body;
}

new Node("blog", System.getenv("ERUPT_ACCESS_TOKEN"), "http://erupt-server:8080")
        .register(Article.class, new JdbcRepository<>(dataSource, "article"))
        .serve("0.0.0.0", 9090);
```

The same in Kotlin (a `var` with a default needs no `@field:`; `fun` is quoted in imports):

```kotlin
import xyz.erupt.annotation.`fun`.OperationHandler

@Erupt(name = "Article", orderBy = "id desc")
class Article {
    @EruptField
    var id: Long? = null

    @EruptField(views = [View(title = "Title", sortable = true)], edit = Edit(title = "Title", notNull = true, search = Search()))
    var title: String? = null

    @EruptField(views = [View(title = "Status")], edit = Edit(title = "Status", search = Search()))
    var status: Status? = null          // an enum is a CHOICE of its constants
}

fun main() {
    Node("blog", System.getenv("ERUPT_ACCESS_TOKEN"), "http://erupt-server:8080")
        .register(Article::class.java, JdbcRepository(dataSource, "article"))
        .serve("0.0.0.0", 9090)
}
```

1. On the erupt server create node `blog` (Node Config) and copy its access token.
2. Add a menu of type `table` with value `blog.Article`.
3. Run the node. The server must reach it on `http://<node ip>:9090`; set `.address(...)` otherwise.

## Models

Exactly erupt's rules: the class needs a no-argument constructor; every `@EruptField` member is a column
named like the member; the primary key is `@Erupt(primaryKeyCol)` (`id`), declared with a bare `@EruptField`.
A field shows in the form when its `@Edit` has a title. `AUTO` types are inferred from the member type as the
erupt proxies do (`String` INPUT, numbers NUMBER, `Boolean` BOOLEAN, `LocalDate` / `LocalDateTime` / `Date` DATE,
an enum CHOICE, another `@Erupt` class a reference). The build JSON is serialized from the annotations by
erupt's own rules (`AnnotationProcess`): `@Transient` attributes left out, `@Match` branches evaluated, enums
by name, classes by simple name.

`@Erupt(orderBy)` is the default sort, written `"field [asc|desc], ..."`.

## References

A member typed with another `@Erupt` class (registered on the same node) references one of its records. The
repository stores the referenced primary key; rows carry it as the key and the server resolves the label.

```java
@EruptField(views = @View(title = "Category", column = "name"), edit = @Edit(title = "Category", search = @Search))
private Category category;                       // table picker

@EruptField(views = @View(title = "Topic", column = "name"), edit = @Edit(title = "Topic",
        type = EditType.REFERENCE_TREE, referenceTreeType = @ReferenceTreeType(pid = "parent")))
private Category topic;                          // tree picker over Category.parent
```

## Handlers

The erupt-annotation interfaces, named in the annotations, work as in a Spring application:

| Interface | Declared in | |
|-----------|-------------|-|
| `DataProxy<T>` | `@Erupt(dataProxy)` | `validate`, `before/afterAdd`, `before/afterUpdate`, `before/afterDelete`, `afterFetch`, `addBehavior`, `editBehavior`, `searchCondition` |
| `OperationHandler<T, Form>` | `@RowOperation(operationHandler)` | `exec(rows, form, params)`; a returned string runs as JavaScript in the browser, so return only code you wrote. `eruptFormValue` fills the form |
| `ChoiceFetchHandler` | `@ChoiceType(fetchHandler)` | dynamic CHOICE options |
| `PowerHandler` | `@Power(powerHandler)` | narrows the declared power |
| `ExprBool.ExprHandler` | `show` / `ifRender` | per-user visibility of operations, views, edits |
| `Readonly.ReadonlyHandler` | `@Readonly(exprHandler)` | |

Throw `xyz.erupt.annotation.exception.EruptException` to show the user a message. Inside a request,
`Node.currentUser()` is the acting user and `Node.current().repository(Article.class)` a registered repository.

```java
@Erupt(name = "Article", rowOperation = @RowOperation(code = "publish", title = "Publish",
        eruptClass = PublishForm.class, operationHandler = Publish.class,
        show = @ExprBool(exprHandler = EditorsOnly.class)))
public class Article { ... }

public class Publish implements OperationHandler<Article, PublishForm> {
    public String exec(List<Article> rows, PublishForm form, String[] params) {
        var repo = Node.current().repository(Article.class);
        rows.forEach(a -> { a.setStatus("published"); repo.update(a); });
        return null;
    }
}
```

Handlers are created by their no-argument constructor, once per class. With a DI container, hand the node
its lookup: `node.factory(beanContainer::get)` (Micronaut `ctx::getBean`, Quarkus `c -> Arc.container().instance(c).get()`,
Guice `injector::getInstance`).

## Storage

Storage is any `Repository<T>` (`page`, `get`, `add`, `update`, `delete`) over instances of the model class;
`Model.get` / `Model.set` read and write a column's stored value. Shipped:

- `MemoryRepository` for tests and demos;
- `JdbcRepository(dataSource, table)` over any JDBC `DataSource`. Columns are the member names (quoted, so case
  sensitive on PostgreSQL and Oracle; a reference column holds the referenced key), every value is a bound
  parameter, LIKE escapes with `ESCAPE '!'`. Identifier quotes and paging are detected from the connection
  (`.dialect(Dialect.SQLSERVER)` to set them). Create the tables yourself.

Without a sort, every repository returns rows by primary key ascending.

## Other HTTP stacks

`node.handle(Request)` answers one request and never throws; mount it under any path and call `node.connect()`
(registration and heartbeat; `.address(...)` is required then) and `node.close()` on shutdown.

```kotlin
// Ktor
route("/{path...}") {
    handle {
        val target = call.request.uri.removePrefix(mountPath)
        val r = node.handle(Node.Request(call.request.httpMethod.value, target, { call.request.headers[it] }, call.receive<ByteArray>()))
        call.respondBytes(r.body(), ContentType.parse(r.contentType()), HttpStatusCode.fromValue(r.status()))
    }
}
```

```java
// a servlet
var r = node.handle(new Node.Request(req.getMethod(), target, req::getHeader, req.getInputStream().readAllBytes()));
resp.setStatus(r.status()); resp.setContentType(r.contentType()); resp.getOutputStream().write(r.body());
```

`target` is the raw path and query below the mount point, as received: the server's signature covers it.

## Security

Server calls are verified by `Erupt-Signature` (`.requireSignature(true)` refuses the plain access token);
`Erupt-Enforced` is trusted only under a valid signature. Calls with an `Origin` header are refused. Without
`Erupt-Enforced: power` the node asks the server for the user's rights (`erupt-power`, cached 5 s) and fails
closed. Condition keys and sort fields are whitelisted against the model.

Not yet: sub-tables (TAB_*), MULTI_CHOICE / collection members, TPL operations, tree models, depend fields of
references, file upload, Excel, `@Erupt(filter)`, i18n of messages.

## Keeping in step with erupt

There is no generated code: the build JSON comes from the annotations themselves, so a newer erupt is a bump
of `erupt.version` in `pom.xml`. The SDK compiles against the oldest supported erupt-annotation and reads
newer attributes reflectively.

## Development

```bash
mvn verify                                        # unit tests: signature vectors, SQL, node, H2
ERUPT_TEST_DATABASES=1 mvn test -Dtest=DatabaseTest   # also PostgreSQL / MySQL (PG*, MYSQL_* variables)
mvn install -DskipTests && mvn -f examples/pom.xml package
python3 ../conformance/run.py -- java -jar examples/conformance/target/erupt-conformance.jar
```

[`examples/blog`](examples/blog) is the blog in Kotlin over H2 (`java -jar examples/blog/target/erupt-blog.jar`);
[`examples/conformance`](examples/conformance) is the conformance fixture in Java.
