// A blog admin served from Dart, covering the field types and features of SHOWCASE.md. Create the node on
// the erupt server first, then:
//
//   ERUPT_NODE_NAME=blog ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 dart run example/blog.dart
//
// Records live in the SQLite file ERUPT_DB (default blog.db; package:sqlite3, a dev dependency of this
// package), in memory when SQLite cannot be loaded. Edit types without a shortcut (RATE, SLIDER, TAGS, COLOR,
// ICON, HTML_EDITOR, MARKDOWN, CODE_EDITOR) are declared as the storage kind they hold, with the edit type and
// its options in `edit:`. The Component model shows the rest: form-only elements as `virtual` fields,
// MULTI_CHOICE / KEY_VALUE as `json` fields.
import 'dart:io';

import 'package:erupt_sdk/erupt_sdk.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

final category = Model('Category', fields: {
  'id': Field.pk(),
  'name': Field('Name', search: true, notNull: true, sortable: true),
  'parent': Field('Parent Id', type: EditType.NUMBER),
  'sort': Field('Sort', type: EditType.NUMBER, sortable: true),
});

final publishForm = Model('PublishForm', title: 'Publish Options', fields: {
  'publish_date': Field('Publish Date', type: EditType.DATE, notNull: true),
});

final article = Model('Article', orderBy: 'id desc', power: {
  'importable': true
}, fields: {
  'id': Field.pk(),
  'title':
      Field('Title', search: true, notNull: true, sortable: true, edit: const Edit(inputType: InputType(length: 60))),
  'summary': Field('Summary',
      type: EditType.TEXTAREA, table: false, edit: const Edit(textareaType: TextareaType(length: 200))),
  'category': Field('Category', ref: category, search: true),
  'topic': Field('Topic', ref: category, tree: 'parent', table: false),
  'status': Field('Status', choices: {'draft': 'Draft', 'review': 'In Review', 'published': 'Published'}, search: true),
  'tags': Field('Tags',
      edit: const Edit(
          type: EditType.TAGS,
          tagsType: TagsType(allowExtension: true, fetchHandler: [], joinSeparator: ',', maxTagCount: 9999))),
  'views': Field('Views', type: EditType.NUMBER, sortable: true, edit: const Edit(numberType: NumberType(min: 0))),
  'price': Field('Price',
      type: EditType.NUMBER, edit: const Edit(numberType: NumberType(min: 0, precision: 2, prefix: r'$'))),
  'rating': Field('Rating',
      type: EditType.NUMBER,
      sortable: true,
      edit: const Edit(type: EditType.RATE, rateType: RateType(count: 5, allowHalf: true, character: ''))),
  'progress': Field('Progress',
      type: EditType.NUMBER,
      edit: const Edit(
          type: EditType.SLIDER, sliderType: SliderType(min: 0, max: 100, step: 5, markPoints: [], dots: false))),
  'featured': Field('Featured', type: EditType.BOOLEAN, search: true),
  'color': Field('Theme Color',
      edit: const Edit(type: EditType.COLOR, colorType: ColorType(alpha: false, presets: [], showText: true))),
  'icon': Field('Icon', table: false, edit: const Edit(type: EditType.ICON)),
  'publish_date': Field('Publish Date',
      type: EditType.DATE, search: true, edit: const Edit(search: Search(operator_: QueryExpression.RANGE))),
  'review_at': Field('Review At', type: EditType.DATE, time: true, sortable: true),
  'content': Field('Content',
      table: false,
      edit: const Edit(type: EditType.HTML_EDITOR, htmlEditorType: HtmlEditorType(value: HtmlEditorTypeType.CKEDITOR))),
  'notes': Field('Notes', table: false, edit: const Edit(type: EditType.MARKDOWN)),
  'meta': Field('Meta (JSON)',
      table: false,
      edit: const Edit(
          type: EditType.CODE_EDITOR,
          codeEditType: CodeEditorType(language: 'json', height: 300, hints: [], hintHandler: []))),
}, operations: {
  'publish': Operation('Publish', icon: 'fa fa-paper-plane', form: publishForm, ifExpr: "item.status !== 'published'",
      (op) async {
    for (final row in op.rows) {
      await op.repo.update(row['id']!, {'status': 'published', 'publish_date': op.param!['publish_date']});
    }
  }),
  'feature': Operation(
      'Feature',
      mode: RowOperationMode.SINGLE,
      icon: 'fa fa-star',
      confirmText: 'Feature this article on the home page?',
      (op) => op.repo.update(op.rows.first['id']!, {'featured': true})),
});

// Every component a node can declare without extra endpoints
final component = Model('Component', fields: {
  'id': Field.pk(),
  'name': Field('Name', search: true, notNull: true),
  'intro': Field('Guide',
      virtual: true,
      edit: const Edit(
          type: EditType.CALLOUT,
          calloutType: CalloutType(
              value: 'Every component a node can declare without extra endpoints.', style: CalloutTypeStyle.INFO))),
  'basic': Field('Basic', virtual: true, edit: const Edit(type: EditType.DIVIDE)),
  'code': Field('Code', table: false, edit: const Edit(type: EditType.HIDDEN)),
  'roles': Field('Roles',
      json: true,
      search: true,
      choices: {'ADMIN': 'Admin', 'USER': 'User', 'GUEST': 'Guest'},
      edit: const Edit(
          type: EditType.MULTI_CHOICE, multiChoiceType: MultiChoiceType(type: MultiChoiceTypeType.CHECKBOX))),
  'langs': Field('Languages',
      json: true,
      choices: {'JAVA': 'Java', 'PYTHON': 'Python', 'GO': 'Go', 'RUST': 'Rust'},
      edit:
          const Edit(type: EditType.MULTI_CHOICE, multiChoiceType: MultiChoiceType(type: MultiChoiceTypeType.SELECT))),
  'attrs': Field('Attributes',
      json: true,
      edit: const Edit(
          type: EditType.KEY_VALUE, keyValueType: KeyValueType(keyPlaceholder: 'Key', valuePlaceholder: 'Value'))),
  'spacer': Field('', virtual: true, edit: const Edit(type: EditType.EMPTY)),
  'extra': Field('Extra', virtual: true, edit: const Edit(type: EditType.DIVIDE)),
  'location': Field('Location', edit: const Edit(type: EditType.MAP)),
  'signature': Field('Signature', table: false, edit: const Edit(type: EditType.SIGNATURE)),
  'place': Field('Place & Sign',
      virtual: true, edit: const Edit(type: EditType.GROUP, groupType: GroupType(fields: ['location', 'signature']))),
});

const categories = [
  {'name': 'Tech', 'parent': null, 'sort': 1},
  {'name': 'Python', 'parent': 1, 'sort': 2},
  {'name': 'Go', 'parent': 1, 'sort': 3},
  {'name': 'Life', 'parent': null, 'sort': 4},
  {'name': 'Travel', 'parent': 4, 'sort': 5},
];

final articles = [
  {
    'title': 'Hello Erupt', 'summary': 'A first look at erupt nodes', 'category': 2, 'topic': 2,
    'status': 'published', //
    'tags': 'intro,erupt', 'views': 120, 'price': 9.9, 'rating': 4.5, 'progress': 100, 'featured': true,
    'color': '#1677ff', 'icon': 'fa fa-book', 'publish_date': DateTime(2026, 10, 1),
    'review_at': DateTime(2026, 10, 2, 10), 'content': '<p>Hello</p>', 'notes': '# Hello', 'meta': '{"a":1}',
  },
  {
    'title': 'Go Tips', 'category': 3, 'topic': 3, 'status': 'review', 'tags': 'go', 'views': 30, 'price': 0, //
    'rating': 3, 'progress': 60, 'featured': false,
  },
  {
    'title': 'Weekend Trip', 'category': 5, 'topic': 5, 'status': 'draft', 'views': 0, 'rating': 0, 'progress': 10, //
    'featured': false,
  },
];

const components = [
  {
    'name': 'Sample A', 'code': 'C-001', 'roles': ['ADMIN', 'USER'], 'langs': ['JAVA', 'GO'], //
    'attrs': {'env': 'prod', 'tier': '1'},
  },
  {
    'name': 'Sample B',
    'code': 'C-002',
    'roles': ['GUEST'],
    'langs': ['PYTHON'],
    'attrs': <String, String>{}
  },
];

/// A table in the SQLite file, or in memory when SQLite cannot be loaded.
Repository repository(String table) {
  try {
    final db = _db ??= sqlite.sqlite3.open(Platform.environment['ERUPT_DB'] ?? 'blog.db');
    final executor = SqlExecutor(SqlDialect.sqlite,
        query: (sql, params) => [for (final row in db.select(sql, params)) Map.of(row)],
        execute: (sql, params) => db.execute(sql, params));
    return SqlRepository(executor, table, autoCreate: true);
  } catch (e) {
    stderr.writeln('SQLite unavailable ($e): $table kept in memory');
    return MemoryRepository();
  }
}

sqlite.Database? _db;

Future<void> seed(Repository repo, List<EruptRecord> records) async {
  if ((await repo.page(Query(limit: 1))).$1 > 0) return;
  for (final record in records) {
    await repo.add(record);
  }
}

Future<void> main() async {
  final env = Platform.environment;
  final node = Node(
      env['ERUPT_NODE_NAME'] ?? 'blog', env['ERUPT_ACCESS_TOKEN']!, [env['ERUPT_SERVER'] ?? 'http://localhost:8080']);
  final repos = {category: repository('category'), article: repository('article'), component: repository('component')};
  repos.forEach(node.register);
  await seed(repos[category]!, categories);
  await seed(repos[article]!, articles);
  await seed(repos[component]!, components);
  await node.serve(port: int.parse(env['PORT'] ?? '9090'));
}
