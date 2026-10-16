import 'dart:convert';
import 'dart:io';

import 'package:erupt_sdk/erupt_sdk.dart';
import 'package:test/test.dart';

const token = 'node-secret';

final calls = <Object?>[];

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
  'title': Field('Title', search: true, notNull: true, sortable: true),
  'status': Field('Status', choices: {'draft': 'Draft', 'published': 'Published'}, search: true),
  'views': Field('Views', type: EditType.NUMBER, sortable: true),
  'featured': Field('Featured', type: EditType.BOOLEAN, search: true),
  'publish_date': Field('Publish Date', type: EditType.DATE, search: true),
  'review_at': Field('Review At', type: EditType.DATE, time: true),
  'body': Field('Body', type: EditType.TEXTAREA, table: false),
  'category': Field('Category', ref: category, search: true),
  'topic': Field('Topic', ref: category, tree: 'parent'),
}, operations: {
  'publish': Operation('Publish', form: publishForm, (op) async {
    calls.add(['publish', op.rows.map((r) => r['id']).toList(), op.param]);
    for (final row in op.rows) {
      await op.repo.update(row['id']!, {'status': 'published'});
    }
  }),
  'feature': Operation('Feature', mode: RowOperationMode.SINGLE, confirm: false, (op) => "alert('featured')"),
  'rebuild': Operation('Rebuild', mode: RowOperationMode.BUTTON, show: (user) => user?.account == 'root', (op) {
    calls.add(['rebuild', op.rows, op.param, currentUser()?.account]);
    return null;
  }),
  'boom': Operation('Boom', mode: RowOperationMode.BUTTON, (op) => throw StateError('secret detail')),
});

final note = Model('Note', power: {
  'delete': false
}, fields: {
  'id': Field.pk(),
  'text': Field('Text'),
});

final widget = Model('Widget', fields: {
  'id': Field.pk(),
  'name': Field('Name'),
  'basic': Field('Basic', virtual: true, edit: const Edit(type: EditType.DIVIDE)),
  'roles': Field('Roles',
      json: true,
      search: true,
      choices: {'ADMIN': 'Admin', 'USER': 'User', 'GUEST': 'Guest'},
      edit: const Edit(type: EditType.MULTI_CHOICE)),
  'attrs': Field('Attributes', json: true, edit: const Edit(type: EditType.KEY_VALUE)),
});

late HttpServer eruptServer;
late Node node;

/// What the fake erupt server answers to erupt-power; null answers HTTP 500.
Map<String, bool>? remote;
var powerCalls = 0;

Map<String, bool> full() =>
    {'add': true, 'edit': true, 'delete': true, 'viewDetails': true, 'export': true, 'importable': true};

Future<(int, Object?)> call(String method, String target,
    {Object? body,
    String? erupt = 'Article',
    String account = 'admin',
    Map<String, String?> headers = const {}}) async {
  final raw = body == null ? <int>[] : (body is List<int> ? body : utf8.encode(jsonEncode(body)));
  final h = <String, String?>{
    'access-token': token,
    'token': 't1',
    'user': base64.encode(utf8.encode(jsonEncode({'uid': 1, 'account': account}))),
    'erupt': erupt,
    ...headers,
  };
  final r = await node.handle(NodeRequest(method, target, (n) => h[n], raw));
  final text = utf8.decode(r.body);
  return (r.status, r.contentType.startsWith('application/json') ? jsonDecode(text) : text);
}

Future<Map<String, dynamic>> ok(Future<(int, Object?)> response) async {
  final (status, body) = await response;
  expect(status, 200);
  expect((body as Map)['success'], isTrue, reason: '$body');
  return body.cast<String, dynamic>();
}

Future<Map<String, dynamic>> fail(Future<(int, Object?)> response) async {
  final (status, body) = await response;
  expect(status, 200);
  expect((body as Map)['success'], isFalse, reason: '$body');
  expect(body['message'], isNotEmpty);
  return body.cast<String, dynamic>();
}

Future<Map<String, dynamic>> table(
    {List<Object?> condition = const [], List<Object?> sort = const [], int size = 10}) async {
  final (status, page) = await call('POST', '/erupt-api/data/table/Article',
      body: {'pageIndex': 1, 'pageSize': size, 'condition': condition, 'sort': sort});
  expect(status, 200, reason: '$page');
  return page as Map<String, dynamic>;
}

List<Object?> titles(Map<String, dynamic> page) => [for (final r in page['list'] as List) r['title']];

Future<void> add(Map<String, Object?> row) => ok(call('POST', '/erupt-api/data/modify/Article', body: row));

void main() {
  setUp(() async {
    remote = full();
    powerCalls = 0;
    calls.clear();
    eruptServer = await HttpServer.bind('127.0.0.1', 0);
    eruptServer.listen((req) async {
      if (req.uri.path == '/erupt-cloud-api/erupt-power') {
        powerCalls++;
        req.response.statusCode = remote == null ? 500 : 200;
        req.response.write(remote == null ? 'down' : jsonEncode(remote));
      }
      await req.response.close();
    });
    node = Node('blog', token, ['http://127.0.0.1:${eruptServer.port}'], logger: (level, message) {})
      ..register(
          category,
          MemoryRepository([
            {'name': 'Tech', 'parent': null},
            {'name': 'Python', 'parent': 1},
            {'name': 'Life', 'parent': null},
          ]))
      ..register(article, MemoryRepository())
      ..register(note, MemoryRepository())
      ..register(widget, MemoryRepository());
  });

  tearDown(() => eruptServer.close(force: true));

  test('build', () async {
    final (status, b) = await call('GET', '/erupt-api/build/Article');
    expect(status, 200);
    final m = (b as Map)['eruptModel'] as Map;
    final f = {for (final x in m['eruptFieldModels'] as List) x['fieldName']: x};
    expect({
      for (final e in f.entries) e.key: e.value['eruptFieldJson']['edit']['type']
    }, {
      'id': 'NUMBER', 'title': 'INPUT', 'status': 'CHOICE', 'views': 'NUMBER', 'featured': 'BOOLEAN', //
      'publish_date': 'DATE', 'review_at': 'DATE', 'body': 'TEXTAREA', 'category': 'REFERENCE_TABLE',
      'topic': 'REFERENCE_TREE',
    });
    expect(f['category']['fieldReturnName'], 'Category');
    expect(f['category']['eruptFieldJson']['edit']['referenceTableType'],
        {'dependField': '', 'id': 'id', 'label': 'name'});
    expect(f['topic']['eruptFieldJson']['edit']['referenceTreeType']['pid'], 'parent');
    expect(f['review_at']['eruptFieldJson']['edit']['dateType']['type'], 'DATE_TIME');
    expect(f['publish_date']['eruptFieldJson']['views'][0]['type'], 'DATE');
    expect(f['body']['eruptFieldJson']['views'], isEmpty);
    expect([for (final o in f['status']['componentValue']) o['value']], ['draft', 'published']);
    final ops = {for (final o in m['eruptJson']['rowOperation'] as List) o['code']: o};
    expect(ops.keys, ['publish', 'feature', 'boom'], reason: 'rebuild is hidden from admin');
    expect([ops['feature']['eruptClass'], ops['feature']['callHint'], ops['feature']['mode']], ['void', '', 'SINGLE']);
    expect((b['operationErupts'] as Map).keys, ['publish']);
    expect(b['power']['cellEdit'], isFalse);
    expect(b['power']['add'], isTrue);
  });

  test('build matches the schema', () async {
    for (final name in ['Article', 'Category', 'Note', 'Widget']) {
      final (_, b) = await call('GET', '/erupt-api/build/$name', erupt: name, account: 'root');
      for (final m in [(b as Map)['eruptModel'], ...?(b['operationErupts'] as Map?)?.values]) {
        Schema.check('Erupt', m['eruptJson'], m['eruptName'] as String, false);
        for (final op in m['eruptJson']['rowOperation'] as List) {
          Schema.check('RowOperation', op, op['code'] as String, false);
        }
        for (final fm in m['eruptFieldModels'] as List) {
          Schema.check('EruptField', fm['eruptFieldJson'], fm['fieldName'] as String, false);
        }
      }
    }
  });

  test('virtual and JSON fields', () async {
    final (_, b) = await call('GET', '/erupt-api/build/Widget', erupt: 'Widget');
    final f = {for (final x in (b as Map)['eruptModel']['eruptFieldModels'] as List) x['fieldName']: x};
    expect({for (final e in f.entries) e.key: e.value['eruptFieldJson']['edit']['type']},
        {'id': 'NUMBER', 'name': 'INPUT', 'basic': 'DIVIDE', 'roles': 'MULTI_CHOICE', 'attrs': 'KEY_VALUE'});
    for (final row in [
      {
        'name': 'A',
        'roles': ['ADMIN', 'USER'],
        'attrs': {'env': 'prod'},
        'basic': 'ignored'
      },
      {'name': 'B', 'roles': '["GUEST"]', 'attrs': {}},
    ]) {
      await ok(call('POST', '/erupt-api/data/modify/Widget', body: row, erupt: 'Widget'));
    }
    await fail(call('POST', '/erupt-api/data/modify/Widget',
        body: {
          'name': 'C',
          'roles': ['ROOT']
        },
        erupt: 'Widget'));
    final (_, page) = await call('POST', '/erupt-api/data/table/Widget', body: {}, erupt: 'Widget');
    final a = ((page as Map)['list'] as List).firstWhere((r) => r['name'] == 'A');
    expect([
      a['roles'],
      a['attrs']
    ], [
      ['ADMIN', 'USER'],
      {'env': 'prod'}
    ]);
    expect(a.containsKey('basic'), isFalse);
    final (_, found) = await call('POST', '/erupt-api/data/table/Widget',
        body: {
          'condition': [
            {
              'key': 'roles',
              'expression': 'IN',
              'value': ['GUEST']
            },
          ],
        },
        erupt: 'Widget');
    expect([for (final r in (found as Map)['list'] as List) r['name']], ['B']);
  });

  test('power: declared, from the server, cached, failing closed', () async {
    remote = {...full(), 'add': false};
    expect((await call('POST', '/erupt-api/data/modify/Article', body: {'title': 'x'})).$1, 403);
    expect((await call('GET', '/erupt-api/data/init-value/Article')).$1, 403);
    expect(powerCalls, 1, reason: 'cached per token and model');
    final (_, b) = await call('GET', '/erupt-api/build/Note', erupt: 'Note');
    expect((b as Map)['power']['delete'], isFalse);
    expect((await call('POST', '/erupt-api/data/modify/Note/delete', body: [1], erupt: 'Note')).$1, 403);
    remote = null;
    expect(
        (await call('POST', '/erupt-api/data/modify/Article', body: {'title': 'x'}, headers: {'token': 't2'})).$1, 403);
  });

  test('guards', () async {
    expect(await call('GET', '/node-health', erupt: null, headers: {'access-token': null}), (200, 'blog'));
    expect((await call('GET', '/erupt-api/build/Article', headers: {'origin': 'http://evil'})).$1, 403);
    expect((await call('GET', '/erupt-api/build/Article', headers: {'access-token': 'bad'})).$1, 403);
    expect((await call('GET', '/erupt-api/build/Article', headers: {'access-token': null})).$1, 403);
    expect((await call('GET', '/erupt-api/build/Missing', erupt: 'Missing')).$1, 404);
    expect((await call('GET', '/erupt-api/build/Article', erupt: 'Note')).$1, 404);
    expect((await call('GET', '/erupt-api/build/Article', erupt: null)).$1, 404);
    expect((await call('GET', '/erupt-api/build/Article', headers: {'eruptparent': 'blog.Note'})).$1, 404);
    expect((await call('GET', '/erupt-api/build/Article?_eruptParent=blog.Note')).$1, 404);
    expect((await call('GET', '/erupt-api/build/Article', headers: {'eruptparent': 'blog.Article'})).$1, 200);
    expect((await call('GET', '/erupt-api/build/%E0%A4%A', erupt: '%E0%A4%A')).$1, 404);
    expect((await call('GET', '/erupt-api/nothing/here')).$1, 404);
  });

  test('signature', () async {
    Future<int> signed(String method, String target,
        {Object? body, String? enforced, int? ts, List<int>? signedBody, bool requireSignature = false}) async {
      final raw = body == null ? <int>[] : utf8.encode(jsonEncode(body));
      final time = ts ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final user = base64.encode(utf8.encode('{"uid":1,"account":"admin"}'));
      final h = {
        'erupt': 'Article',
        'token': 't1',
        'user': user,
        'erupt-timestamp': '$time',
        'erupt-enforced': enforced,
        'erupt-signature': Signature.sign(token, method, target, time, enforced, user, signedBody ?? raw),
      };
      return (await node.handle(NodeRequest(method, target, (n) => h[n], raw))).status;
    }

    expect(await signed('GET', '/erupt-api/build/Article?_probe=1'), 200);
    expect(await signed('POST', '/erupt-api/data/table/Article', body: {'pageIndex': 1}), 200);
    expect(await signed('POST', '/erupt-api/data/table/Article', body: {'pageIndex': 1}, signedBody: utf8.encode('{}')),
        403);
    expect(
        await signed('GET', '/erupt-api/build/Article', ts: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 301), 403);
    // with power enforced by the server, the node does not ask it
    remote = null;
    powerCalls = 0;
    expect(
        await signed('POST', '/erupt-api/data/modify/Article', body: {'title': 'enforced'}, enforced: 'power,record'),
        200);
    expect(powerCalls, 0);
    // a node that requires signatures refuses the plain token
    node = Node('strict', token, ['http://127.0.0.1:${eruptServer.port}'], requireSignature: true, logger: (_, __) {})
      ..register(Model('Article', fields: {'id': Field.pk()}), MemoryRepository());
    expect((await call('GET', '/erupt-api/build/Article')).$1, 403);
    expect(await signed('GET', '/erupt-api/build/Article'), 200);
  });

  test('crud', () async {
    await add({
      'title': 'Hello erupt', 'status': 'published', 'views': 10, 'featured': true, 'publish_date': '2026-01-05', //
      'review_at': '2026-01-05 10:30:00', 'body': '...',
    });
    await add({'title': 'Second', 'status': 'draft', 'views': '3', 'featured': false, 'publish_date': '2026-03-01'});
    var page = await table();
    expect([page['total'], page['totalPage']], [2, 1]);
    expect(titles(page), ['Second', 'Hello erupt'], reason: 'default order id desc');
    final first = (page['list'] as List).last as Map;
    expect([first['publish_date'], first['review_at'], first['views'], first['featured']],
        ['2026-01-05', '2026-01-05T10:30:00.000', 10, true]);
    Map<String, Object?> cond(String key, String op, Object? value) => {'key': key, 'expression': op, 'value': value};
    expect(titles(await table(condition: [cond('title', 'LIKE', 'hello')])), ['Hello erupt']);
    expect(titles(await table(condition: [cond('status', 'EQ', 'draft')])), ['Second']);
    expect(titles(await table(condition: [cond('featured', 'EQ', true)])), ['Hello erupt']);
    expect(
        titles(await table(condition: [
          cond('publish_date', 'RANGE', ['2026-02-01', '2026-12-31'])
        ])),
        ['Second']);
    expect(titles(await table(condition: [cond('publish_date', 'NULL', null)])), isEmpty);
    expect(
        titles(await table(condition: [
          cond('title', 'IN', ['Second', 'Hello erupt']),
        ], sort: [
          {'field': 'title', 'direction': 'ASC'},
        ])),
        ['Hello erupt', 'Second']);
    expect(
        titles(await table(sort: [
          {'field': 'views', 'direction': 'ASC'},
        ])),
        ['Second', 'Hello erupt']);
    expect((await table(size: 1))['list'], hasLength(1));
    final pk = first['id'];
    final (_, row) = await call('GET', '/erupt-api/data/Article/$pk');
    expect((row as Map)['title'], 'Hello erupt');
    await ok(call('POST', '/erupt-api/data/modify/Article/update', body: {...row, 'title': 'Renamed'}));
    expect(((await call('GET', '/erupt-api/data/Article/$pk')).$2 as Map)['title'], 'Renamed');
    await ok(call('POST', '/erupt-api/data/modify/Article/delete', body: [pk]));
    page = await table();
    expect(page['total'], 1);
    expect((await call('GET', '/erupt-api/data/init-value/Article')).$2, containsPair('title', null));
  });

  test('references', () async {
    final (status, b) = await call('GET', '/erupt-api/build/Article/category');
    expect([status, ((b as Map)['eruptModel'] as Map)['eruptName']], [200, 'Category']);
    expect((await call('GET', '/erupt-api/build/Article/title')).$1, 404);
    final (_, picker) = await call('POST', '/erupt-api/data/Article/reference-table/category?tabRef=false', body: {
      'condition': [
        {'key': 'name', 'expression': 'LIKE', 'value': 'py'},
      ],
    });
    expect((picker as Map)['list'], [
      {'id': 2, 'name': 'Python', 'parent': 1},
    ]);
    expect((await call('POST', '/erupt-api/data/Article/reference-table/topic', body: {})).$1, 404);
    expect((await call('GET', '/erupt-api/data/Article/reference-tree/topic')).$1, 404);
    await add({
      'title': 'Ref',
      'category': {'id': '2', 'name': 'Python'},
      'topic': {'id': 1, 'name': 'Tech'},
    });
    final row = (await table())['list'][0] as Map;
    expect([row['category'], row['topic']], [2, 1]);
    expect(row.containsKey('category_name'), isFalse);
    final search = await table(condition: [
      {
        'key': 'category',
        'expression': 'IN',
        'value': [
          {'id': 2},
        ],
      },
    ]);
    expect(search['total'], 1);
    await fail(call('POST', '/erupt-api/data/table/Article', body: {
      'condition': [
        {'key': 'category', 'expression': 'LIKE', 'value': 'x'},
      ],
    }));
  });

  test('operations', () async {
    await add({'title': 'A'});
    await add({'title': 'B'});
    final ids = [for (final r in (await table())['list'] as List) r['id']];
    const path = '/erupt-api/data/Article/operator/';
    await fail(call('POST', '${path}publish', body: {'ids': ids, 'param': {}}));
    final r = await ok(call('POST', '${path}publish', body: {
      'ids': ids,
      'param': {'note': 'go'}
    }));
    expect(r['message'], 'Executed successfully');
    expect(calls.last, [
      'publish',
      ids,
      {'note': 'go'},
    ]);
    expect([for (final x in (await table())['list'] as List) x['status']], ['published', 'published']);
    await fail(call('POST', '${path}feature', body: {'ids': ids}));
    expect((await ok(call('POST', '${path}feature', body: {'ids': ids.sublist(0, 1)})))['data'], "alert('featured')");
    await fail(call('POST', '${path}publish', body: {
      'ids': [],
      'param': {'note': 'go'}
    }));
    await fail(call('POST', '${path}publish', body: {
      'ids': [999],
      'param': {'note': 'go'}
    }));
    expect((await call('POST', '${path}rebuild', body: {})).$1, 403);
    await ok(call('POST', '${path}rebuild', body: {}, account: 'root'));
    expect(calls.last, ['rebuild', [], null, 'root']);
    expect((await call('POST', '${path}missing', body: {})).$1, 404);
    final (formStatus, formValue) = await call('POST', '${path}publish/form-value');
    expect([
      formStatus,
      formValue
    ], [
      200,
      {'note': null},
    ]);
    expect((await call('POST', '${path}feature/form-value')).$1, 404);
  });

  test('internal errors keep the stack in the log', () async {
    final (status, body) = await call('POST', '/erupt-api/data/Article/operator/boom', body: {});
    expect(status, 500);
    expect((body as Map)['message'], contains('secret detail'));
    expect('$body', isNot(contains('node.dart')));
  });

  test('rejects illegal input', () async {
    const modify = '/erupt-api/data/modify/Article';
    const tablePath = '/erupt-api/data/table/Article';
    await fail(call('POST', modify, body: {'status': 'draft'}));
    await fail(call('POST', modify, body: {'title': 'x', 'status': 'deleted'}));
    await fail(call('POST', modify, body: {'title': 'x', 'views': 'many'}));
    await fail(call('POST', modify, body: {'title': 'x', 'publish_date': 'someday'}));
    await fail(call('POST', modify, body: {'title': 'x', 'publish_date': '2026-02-30'}));
    await fail(call('POST', modify, body: utf8.encode('{not json')));
    await fail(call('POST', '$modify/delete', body: {'id': 1}));
    for (final c in [
      {'key': 'views', 'expression': 'EQ', 'value': 1},
      {'key': 'title" OR 1=1 --', 'value': 1},
      {'key': 'title', 'expression': 'DROP', 'value': 1},
      {'key': 'title', 'expression': 'AUTO', 'value': 1},
      {
        'key': 'publish_date',
        'expression': 'RANGE',
        'value': ['2026-01-01']
      },
    ]) {
      await fail(call('POST', tablePath, body: {
        'condition': [c],
      }));
    }
    await fail(call('POST', tablePath, body: {
      'sort': [
        {'field': 'body', 'direction': 'ASC'},
      ],
    }));
    await fail(call('POST', tablePath, body: {'pageSize': 'many'}));
    await fail(call('GET', '/erupt-api/data/Article/abc'));
  });

  test('serves over dart:io, registers and deregisters', () async {
    final registered = <Map<String, dynamic>>[];
    final removed = <String>[];
    await eruptServer.close(force: true);
    eruptServer = await HttpServer.bind('127.0.0.1', 0);
    eruptServer.listen((req) async {
      final body = await utf8.decodeStream(req);
      if (req.uri.path == '/erupt-cloud-api/register-node') registered.add(jsonDecode(body) as Map<String, dynamic>);
      if (req.uri.path == '/erupt-cloud-api/remove-instance-node') removed.add(body);
      await req.response.close();
    });
    final served = Node('io', token, ['http://127.0.0.1:${eruptServer.port}/'], logger: (_, __) {})
      ..register(Model('Item', fields: {'id': Field.pk(), 'name': Field('Name')}), MemoryRepository());
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen(served.handleHttp);
    await served.start(server.port);
    final client = HttpClient();
    final request = await client.get('127.0.0.1', server.port, '/node-health');
    final response = await request.close();
    expect(await utf8.decodeStream(response), 'io');
    for (var i = 0; i < 50 && registered.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(registered.single['nodeName'], 'io');
    expect(registered.single['erupts'], ['Item']);
    expect(registered.single['version'], 'dart-$version');
    expect(registered.single['nodeAddress'], [isNot(contains('null'))]);
    await served.stop();
    expect(removed.single, contains('nodeName=io'));
    client.close(force: true);
    await server.close(force: true);
  });
}
