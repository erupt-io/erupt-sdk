# JVM node

Java and Kotlin need no SDK here: the node ships with erupt, so its annotations always match the server.
A service declares models with the regular `@Erupt` / `@EruptField` annotations and becomes a node by adding
one dependency.

| Stack | Artifact |
|-------|----------|
| Spring Boot 3.5 | `xyz.erupt:erupt-cloud-node-jpa` (JPA data layer), or the bare `erupt-cloud-node` |
| No Spring | [`xyz.erupt:erupt-cloud-node-lite`](https://github.com/erupts/erupt/tree/develop/erupt-cloud/erupt-cloud-node-lite) on the JDK's HTTP server, or mounted by `-solon`, `-quarkus`, `-micronaut`, `-vertx`, `-ktor`, `-servlet` |

`erupt-cloud-node` runs the full erupt-core pipeline and speaks node protocol v1; `erupt-cloud-node-lite` speaks
v2 from erupt 2.4.1, like every SDK here, and its README documents models, handlers, storage and the frameworks.

```xml
<dependency>
    <groupId>xyz.erupt</groupId>
    <artifactId>erupt-cloud-node-jpa</artifactId>   <!-- or erupt-cloud-node-lite / -solon / -quarkus ... -->
    <version>${erupt.version}</version>
</dependency>
```

With Spring the node is configured in `application.yml`:

```yaml
erupt:
  cloud-node:
    node-name: blog
    access-token: ${ERUPT_ACCESS_TOKEN}       # Node Config -> View Token on the server; never commit it
    server-addresses: http://erupt-server:8080 # several addresses are round-robined
    # host-address: http://10.0.0.12:9090      # only when the server cannot reach the auto-detected address
```

## Examples

The JVM example nodes live in the erupt repository, built with the erupt they ship with:
[`erupt-cloud/examples`](https://github.com/erupts/erupt/tree/develop/erupt-cloud/examples) — the conformance fixture,
[SHOWCASE.md](../SHOWCASE.md) on erupt-cloud-node-lite served by every adapter (JDK, Solon, Quarkus, Micronaut, Vert.x,
Ktor, servlet), a Kotlin blog and the same blog on Spring Boot. erupt's CI runs this repository's
`conformance/run.py` and `conformance/showcase.py` against them (`.github/workflows/node-examples.yml` there).

## Differences worth knowing

- Field naming follows Java (`publishDate`); the other SDKs use whatever names the model declares.
- A wrong access token or a denied right answers **500** from the Spring node and **403** from the lite node and the
  SDKs (`erupt-cloud/PROTOCOL.md` §8 proposes 403 for v1). The browser shows an error either way.
- The Spring node enforces the full annotation surface (sub-tables, Excel, attachments, DataProxy hooks…) and speaks
  protocol v1; the lite node and the SDKs speak v2 and implement the levels listed in their READMEs.
