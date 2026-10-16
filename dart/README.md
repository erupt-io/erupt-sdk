# erupt-sdk (Dart)

Serve Dart models as an erupt admin UI. No runtime dependencies (dart:io only), Dart 3.3+.

```dart
import 'package:erupt_sdk/erupt_sdk.dart';

final article = Model('Article', orderBy: 'id desc', fields: {
  'id': Field.pk(),
  'title': Field('Title', search: true, notNull: true, sortable: true),
  'status': Field('Status', choices: {'draft': 'Draft', 'published': 'Published'}, search: true),
  'publish_date': Field('Publish Date', type: EditType.DATE, search: true),
  'body': Field('Body', type: EditType.TEXTAREA, table: false),
});

Future<void> main() async {
  final node = Node('blog', Platform.environment['ERUPT_ACCESS_TOKEN']!, ['http://erupt-server:8080'])
    ..register(article, MemoryRepository());
  await node.serve(port: 9090);
}
```

1. On the erupt server create node `blog` (Node Config) and copy its access token.
2. Add a menu of type `table` with value `blog.Article`.
3. Run the node. The server must be able to reach it on `http://<node ip>:9090`; pass `address:` otherwise.

`Field(title)` is an INPUT; `type:` picks another edit type (`EditType.NUMBER`, `EditType.BOOLEAN`,
`EditType.DATE`, ...; `time: true` turns a DATE into a date-time picker), `choices:` makes a CHOICE, `ref:` a
reference. `view:` / `edit:` on a field, `erupt:` on a model and `raw:` on an operation take the typed
annotation classes generated from erupt's schema (`Edit(inputType: InputType(length: 64))`), so a misspelt
attribute does not compile and a wrong value fails at startup.

Records are `Map<String, Object?>` keyed by field name (`row['title']`). DATE and DATE_TIME values are
`DateTime`, NUMBER values `int` or `double`.

## Mounting in an existing server

`serve` runs a dart:io server of its own. To answer from an existing server instead, route the node's paths
(`/erupt-api/*` and `/node-health`) to it, then `start` it with the port the erupt server reaches and `stop` it
on the way out:

```dart
// dart:io: the request path must be the node's own
server.listen((request) => request.uri.path.startsWith('/erupt-api/') || request.uri.path == '/node-health'
    ? node.handleHttp(request)
    : app(request));
await node.start(server.port);

// shelf (or any other framework): hand over the path below the mount point, raw headers and body
Handler eruptHandler(Node node) => (Request request) async {
      final r = await node.handle(NodeRequest(request.method, '/${request.url}', (name) => request.headers[name],
          await request.read().expand((chunk) => chunk).toList()));
      return Response(r.status, body: r.body, headers: {'content-type': r.contentType});
    };
```

## References

Pass another model (registered on the same node) as `ref:`. The repository stores the referenced primary key;
the UI shows `label:` (default `name`).

```dart
final category = Model('Category', fields: {
  'id': Field.pk(),
  'name': Field('Name', search: true),
  'parent': Field('Parent Id', type: EditType.NUMBER),
});

// in Article's fields
'category': Field('Category', ref: category, search: true),   // table picker
'topic': Field('Topic', ref: category, tree: 'parent'),       // tree picker over Category.parent
```

## Row operations

```dart
final publishForm = Model('PublishForm', fields: {           // a form model needs no primary key
  'publish_date': Field('Publish Date', type: EditType.DATE, notNull: true),
});

// in Article's operations
'publish': Operation('Publish', form: publishForm, ifExpr: "item.status !== 'published'", (op) async {
  for (final row in op.rows) {                               // op.rows, op.param, op.repo, op.user
    await op.repo.update(row['id']!, {'status': 'published', 'publish_date': op.param!['publish_date']});
  }
}),
```

`mode:` `SINGLE` / `MULTI` (default) / `MULTI_ONLY` / `BUTTON`. `confirm: false` skips the dialog,
`confirmText:` replaces its text. `show: (user) => ...` hides the operation and refuses to run it. A returned
string is executed as JavaScript in the browser, so return only code you wrote. `currentUser()` gives the
acting user anywhere below a request.

## Storage

Storage is any `Repository` (`page`, `get`, `add`, `update`, `delete`, each sync or async). Shipped:

- `MemoryRepository` for tests and demos;
- `SqlRepository(executor, table, autoCreate: false)` on PostgreSQL, MySQL, SQL Server or SQLite. The SDK
  depends on no driver: a `SqlExecutor` runs each statement with bound values through two closures over the
  driver you choose. Create the tables yourself, with columns named like the fields (`autoCreate` creates
  SQLite tables).

```dart
// SQLite (package:sqlite3)
final db = sqlite3.open('blog.db');
final repo = SqlRepository(SqlExecutor(SqlDialect.sqlite,
    query: (sql, params) => [for (final row in db.select(sql, params)) Map.of(row)],
    execute: (sql, params) => db.execute(sql, params)), 'article', autoCreate: true);

// PostgreSQL (package:postgres 3.x)
final repo = SqlRepository(SqlExecutor(SqlDialect.postgres,
    query: (sql, params) async => [for (final row in await pool.execute(sql, parameters: params)) row.toColumnMap()],
    execute: (sql, params) => pool.execute(sql, parameters: params)), 'article');
```

Every value is bound, identifiers come from the model and are quoted, LIKE escapes its wildcards. JSON fields
(`json: true`: MULTI_CHOICE lists, KEY_VALUE objects) are stored as JSON text.

## Security

The node trusts only the erupt server: every call must carry its access token or a valid `Erupt-Signature`
(`requireSignature: true` accepts nothing else), and a request with an `Origin` header (a browser) is refused.
Rights come from the server per user (`erupt-power`, cached for 5 s, failing closed) and are ANDed onto the
model's declared `power`.

## Examples

```bash
dart run example/blog.dart          # SHOWCASE.md: every field type, operations, SQLite storage
python3 ../conformance/run.py -- dart run example/conformance.dart
```

## Development

```bash
dart pub get
dart run tool/gen_types.dart ../schema   # after schema/ changed; --check in CI
dart analyze && dart test
```
