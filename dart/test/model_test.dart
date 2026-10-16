import 'package:erupt_sdk/erupt_sdk.dart';
import 'package:test/test.dart';

void main() {
  final category = Model('Category', fields: {'id': Field.pk(), 'name': Field('Name')});

  test('coerces browser values by field type', () {
    final m = Model('Post', fields: {
      'id': Field.pk(),
      'n': Field('N', type: EditType.NUMBER),
      'b': Field('B', type: EditType.BOOLEAN),
      'd': Field('D', type: EditType.DATE),
      't': Field('T', type: EditType.DATE, time: true),
      'c': Field('C', choices: {'a': 'A'}),
      'r': Field('R', ref: category),
      'j': Field('J', json: true),
    });
    Object? c(String f, Object? v) => m.fields[f]!.coerce(v);
    expect([c('n', '3'), c('n', 2.0), c('n', '2.5'), c('n', ''), c('n', null)], [3, 2, 2.5, null, null]);
    expect(c('n', 3), isA<int>());
    expect([c('b', true), c('b', 'true'), c('b', '1'), c('b', 'no')], [true, true, true, false]);
    expect(c('d', '2026-01-05T10:30:00Z'), DateTime(2026, 1, 5));
    expect(c('t', '2026-01-05 10:30'), DateTime(2026, 1, 5, 10, 30));
    expect(c('t', '2026-01-05T10:30:00.123456'), DateTime(2026, 1, 5, 10, 30, 0, 123));
    expect([
      c('c', 'a'),
      c('r', {'id': '2', 'name': 'x'}),
      c('r', 3),
      c('id', ' 7 ')
    ], [
      'a',
      2,
      3,
      7
    ]);
    expect(c('j', '{"a":1}'), {'a': 1});
    for (final (f, v) in [
      ('n', 'x'),
      ('n', double.infinity),
      ('d', '2026-13-01'),
      ('d', '2026-02-29'),
      ('t', '2026-01-05 24:00'),
      ('c', 'b'),
      ('id', 'x'),
      ('id', 1.5),
      ('j', '3')
    ]) {
      expect(() => c(f, v), throwsFormatException, reason: '$f $v');
    }
  });

  test('builds from the Java templates with overrides', () {
    final m = Model('Post', orderBy: 'title desc, id', erupt: const Erupt(layout: Layout(pageSize: 30)), fields: {
      'id': Field.pk(),
      'title': Field('Title', edit: const Edit(inputType: InputType(length: 64)), view: const View(width: '200px')),
      'search': Field('Search', edit: const Edit(search: Search(operator_: QueryExpression.RANGE))),
    });
    expect(m.order, [('title', true), ('id', false)]);
    final b = m.buildErupt();
    expect(b['eruptJson']['layout']['pageSize'], 30);
    final title = b['eruptFieldModels'][1]['eruptFieldJson'];
    expect([title['edit']['inputType']['length'], title['views'][0]['width']], [64, '200px']);
    expect(b['eruptFieldModels'][2]['eruptFieldJson']['edit']['search']['operator'], 'RANGE');
  });

  test('rejects mistakes when declared', () {
    expect(() => Model('bad name', fields: {}), throwsArgumentError);
    expect(() => Model('Post', fields: {'bad key': Field('x')}), throwsArgumentError);
    expect(() => Model('Post', fields: {'a': Field.pk(), 'b': Field.pk()}), throwsArgumentError);
    expect(() => Model('Post', orderBy: 'missing', fields: {'id': Field.pk()}), throwsArgumentError);
    expect(() => Model('Post', orderBy: 'id sideways', fields: {'id': Field.pk()}), throwsArgumentError);
    expect(() => Model('Post', fields: {'r': Field('R', ref: category, label: 'missing')}), throwsArgumentError);
    expect(() => Model('Post', fields: {'r': Field('R', ref: Model('Form', fields: {}))}), throwsArgumentError);
    expect(() => Model('Post', fields: {'x': Field('X', type: EditType.TAGS)}), throwsArgumentError,
        reason: 'no template: declared through edit.type');
    expect(() => Node('n', '', ['http://s']), throwsArgumentError);
    final node = Node('n', 't', ['http://s'])..register(category, MemoryRepository());
    expect(() => node.register(category, MemoryRepository()), throwsArgumentError);
    expect(() => node.register(Model('Form', fields: {'a': Field('A')}), MemoryRepository()), throwsArgumentError);
  });

  test('checks raw attributes against the schema', () {
    expect(
        () => Schema.check('Edit', {
              'inputType': {'length': 'long'}
            }),
        throwsArgumentError);
    expect(() => Schema.check('Edit', {'nope': 1}), throwsArgumentError);
    expect(() => Schema.check('EditType', 'NOPE'), throwsArgumentError);
    expect(() => Schema.check('Edit', {'title': 't'}, 'Edit', false), throwsArgumentError);
    Schema.check('Edit', {
      'inputType': {'length': 64},
      'type': 'TAGS'
    });
  });
}
