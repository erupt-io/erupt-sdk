# erupt node for Java

Java needs no separate SDK: **`erupt-cloud-node`** is the reference implementation of the node protocol
that the Python, Go and TypeScript SDKs in this repository follow. A Java service declares models with the
regular erupt annotations and becomes a node by adding one dependency.

**No Spring? Use [`jvm/`](../jvm).** `xyz.erupt:erupt-cloud-node` needs Spring Boot; `xyz.erupt:erupt-sdk`
serves the same `@Erupt` / `@EruptField` classes from plain Java, Kotlin, Quarkus, Micronaut, Vert.x or Ktor on
the JDK's HTTP server (or mounted in your own), with `erupt-annotation` as its only dependency.

```xml
<!-- with the JPA data layer (most services) -->
<dependency>
    <groupId>xyz.erupt</groupId>
    <artifactId>erupt-cloud-node-jpa</artifactId>
    <version>2.3.0</version>
</dependency>
<!-- or the bare node, for models served by another erupt data processor -->
<dependency>
    <groupId>xyz.erupt</groupId>
    <artifactId>erupt-cloud-node</artifactId>
    <version>2.3.0</version>
</dependency>
```

```yaml
erupt:
  cloud-node:
    node-name: blog
    access-token: ${ERUPT_ACCESS_TOKEN}       # Node Config -> View Token on the server; never commit it
    server-addresses: http://erupt-server:8080 # several addresses are round-robined
    # host-address: http://10.0.0.12:9090      # only when the server cannot reach the auto-detected address
```

Requirements: Java 17+, Spring Boot 3.5 (erupt 2.3.x).

## Example

[`examples/blog`](examples/blog) is the same blog as `python/examples/blog.py`: Category (tree), Article
with table and tree references, a choice, dates, and two row operations (one with a form).

```bash
cd java/examples/blog
mvn package
ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 PORT=9090 java -jar target/erupt-node-blog-0.1.0.jar
```

Then on the server add menus of type `table` with values `blog.Article` and `blog.Category`.

## The same concepts in every language

| Concept | Java (erupt-cloud-node) | Python | Go / TypeScript |
|---------|-------------------------|--------|-----------------|
| Model | `@Erupt` class (`@Entity` with JPA) | `@erupt` class | see `go/README.md`, `ts/README.md` |
| Field | `@EruptField(views = @View, edit = @Edit)` | `Field(...)` | |
| Reference | `@ManyToOne` + `REFERENCE_TABLE` / `REFERENCE_TREE` | field typed with another model | |
| Row operation | `@RowOperation` + `OperationHandler` bean | `@operation` method | |
| Storage | JPA / any erupt data processor | `Repository` | `Repository` |
| Default sort | `@Erupt(orderBy = ...)` | `order_by=` | |

Every SDK reproduces the JSON these annotations produce; the generated
[`schema/erupt-annotations.schema.json`](../schema/erupt-annotations.schema.json) describes it, so its
attribute names are the annotation attribute names.

## Differences worth knowing

- Field naming follows Java (`publishDate`); the other SDKs use whatever names the model declares.
- A wrong access token or a denied right answers **500** from the Java node and **403** from the SDKs
  (`erupt-cloud/PROTOCOL.md` §8 proposes 403 for v1). The browser shows an error either way.
- The Java node enforces the full annotation surface (sub-tables, Excel, attachments, DataProxy hooks…);
  the SDKs implement the levels listed in their READMEs.
