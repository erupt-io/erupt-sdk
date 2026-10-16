// The conformance fixture (conformance/README.md) in Dart.
import 'dart:io';

import 'package:erupt_sdk/erupt_sdk.dart';

final category = Model('Category', fields: {
  'id': Field.pk(),
  'name': Field('Name', search: true),
  'parent': Field('Parent', type: EditType.NUMBER),
});

final publishForm = Model('PublishForm', title: 'Publish Options', fields: {
  'note': Field('Note', notNull: true),
});

final article = Model('Article', orderBy: 'id desc', fields: {
  'id': Field.pk(),
  'title':
      Field('Title', search: true, notNull: true, sortable: true, edit: const Edit(inputType: InputType(length: 64))),
  'status': Field('Status', choices: {'draft': 'Draft', 'published': 'Published'}, search: true),
  'views': Field('Views', type: EditType.NUMBER, sortable: true),
  'featured': Field('Featured', type: EditType.BOOLEAN, search: true),
  'publish_date': Field('Publish Date', type: EditType.DATE, search: true),
  'review_at': Field('Review At', type: EditType.DATE, time: true),
  'body': Field('Body', type: EditType.TEXTAREA, table: false),
  'category': Field('Category', ref: category, search: true),
  'topic': Field('Topic', ref: category, tree: 'parent'),
}, operations: {
  'publish': Operation('Publish', icon: 'fa fa-paper-plane', form: publishForm, ifExpr: "item.status !== 'published'",
      (op) async {
    for (final row in op.rows) {
      await op.repo.update(row['id']!, {'status': 'published'});
    }
  }),
  'feature': Operation('Feature', mode: RowOperationMode.SINGLE, confirm: false, (op) => "alert('featured')"),
  'rebuild': Operation('Rebuild', mode: RowOperationMode.BUTTON, show: (user) => user?.account == 'root', (op) => null),
});

final note = Model('Note', power: {
  'delete': false
}, fields: {
  'id': Field.pk(),
  'text': Field('Text'),
});

Future<void> main() async {
  final env = Platform.environment;
  final port = int.parse(env['PORT']!);
  final node =
      Node('conformance', env['ERUPT_ACCESS_TOKEN']!, [env['ERUPT_SERVER']!], address: 'http://127.0.0.1:$port')
        ..register(
            category,
            MemoryRepository([
              {'name': 'Tech', 'parent': null},
              {'name': 'Python', 'parent': 1},
              {'name': 'Life', 'parent': null},
            ]))
        ..register(article, MemoryRepository())
        ..register(note, MemoryRepository());
  await node.serve(port: port, host: '127.0.0.1');
}
