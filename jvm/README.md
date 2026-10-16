# JVM node (no Spring)

The JVM node is **`xyz.erupt:erupt-cloud-node-lite`** in the erupt repository
([`erupt-cloud/erupt-cloud-node-lite`](https://github.com/erupts/erupt/tree/develop/erupt-cloud/erupt-cloud-node-lite)),
released with erupt so its annotations always match the server. Plain Java / Kotlin, plus adapters
`erupt-cloud-node-solon`, `erupt-cloud-node-quarkus` and `erupt-cloud-node-vertx`. Its README documents models,
handlers, storage and the frameworks.

```xml
<dependency>
    <groupId>xyz.erupt</groupId>
    <artifactId>erupt-cloud-node-lite</artifactId>   <!-- or -solon, -quarkus, -vertx -->
    <version>${erupt.version}</version>
</dependency>
```

Here are only what runs against it across languages:

- [`examples/conformance`](examples/conformance): the conformance fixture in Java;
- [`examples/blog`](examples/blog): the blog in Kotlin over H2 (`java -jar examples/blog/target/erupt-blog.jar`).

```bash
# in an erupt checkout (until the version in examples/pom.xml is released)
mvn install -pl erupt-cloud/erupt-cloud-node-lite -am -DskipTests
# here
mvn -f jvm/examples/pom.xml package
python3 conformance/run.py -- java -jar jvm/examples/conformance/target/erupt-conformance.jar
```
