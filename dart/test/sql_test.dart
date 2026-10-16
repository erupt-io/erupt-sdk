import 'dart:io';

import 'package:erupt_sdk/erupt_sdk.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

Model post() => Model('Post', fields: {
      'id': Field.pk(),
      'title': Field('Title', search: true),
      'views': Field('Views', type: EditType.NUMBER),
      'live': Field('Live', type: EditType.BOOLEAN),
      'day': Field('Day', type: EditType.DATE),
      'at': Field('At', type: EditType.DATE, time: true),
      'tags': Field('Tags', json: true),
    });

/// Records statements the way a driver receives them; answers like pg's text protocol (upper-case columns).
(SqlRepository, List<List<Object?>>) fake(SqlDialect dialect) {
  final log = <List<Object?>>[];
  final executor = SqlExecutor(dialect,
      query: (sql, params) {
        log.add([sql, params]);
        if (sql.startsWith('SELECT COUNT')) {
          return [
            {'N': '2'},
          ];
        }
        return [
          {
            'ID': '1',
            'TITLE': 'a',
            'VIEWS': '3.0',
            'LIVE': 't',
            'DAY': '2026-01-05',
            'AT': '2026-01-05 10:30:00.000',
            'TAGS': '["x"]'
          },
        ];
      },
      execute: (sql, params) => log.add([sql, params]));
  return (SqlRepository(executor, 'post')..bind(post()), log);
}

QueryExpression op(String name) => QueryExpression.values.byName(name);

void main() {
  test('dialects', () async {
    final expected = {
      SqlDialect.postgres: (
        'SELECT * FROM "post" WHERE "title" ILIKE \$1 ESCAPE \'!\' AND "views" IN (\$2, \$3) AND "live" = \$4 '
            'ORDER BY "id" ASC LIMIT \$5 OFFSET \$6',
        ['%a!%!!!_%', 1, 2, true, 10, 0]
      ),
      SqlDialect.mysql: (
        "SELECT * FROM `post` WHERE `title` LIKE ? ESCAPE '!' AND `views` IN (?, ?) AND `live` = ? "
            'ORDER BY `id` ASC LIMIT ? OFFSET ?',
        ['%a!%!!!_%', 1, 2, 1, 10, 0]
      ),
      SqlDialect.mssql: (
        "SELECT * FROM [post] WHERE [title] LIKE @p0 ESCAPE '!' AND [views] IN (@p1, @p2) AND [live] = @p3 "
            'ORDER BY [id] ASC OFFSET @p4 ROWS FETCH NEXT @p5 ROWS ONLY',
        ['%a!%!!!_%', 1, 2, 1, 0, 10]
      ),
    };
    for (final MapEntry(key: dialect, value: (sql, params)) in expected.entries) {
      final (repo, log) = fake(dialect);
      final (total, rows) = await repo.page(Query(conditions: [
        Cond('title', op('LIKE'), 'a%!_'),
        Cond('views', op('IN'), [1, 2]),
        Cond('live', op('EQ'), true),
      ]));
      expect(log[1], [sql, params], reason: '$dialect');
      expect(total, 2);
      // upper-case columns and text values are normalized by field type
      expect(rows.single, {
        'id': 1, 'title': 'a', 'views': 3, 'live': true, 'day': DateTime(2026, 1, 5), //
        'at': DateTime(2026, 1, 5, 10, 30), 'tags': ['x'],
      });
    }
  });

  test('writes', () async {
    final (repo, log) = fake(SqlDialect.mysql);
    await repo.add({
      'title': 'x',
      'live': false,
      'day': DateTime(2026, 1, 5),
      'at': DateTime(2026, 1, 5, 10, 30, 0, 123),
      'tags': ['a'],
      'id': 9
    });
    await repo.update(1, {'title': 'y', 'id': 9});
    await repo.update(1, {'id': 9});
    await repo.delete([1, 2]);
    await repo.delete([]);
    expect(log, [
      [
        'INSERT INTO `post` (`title`, `live`, `day`, `at`, `tags`) VALUES (?, ?, ?, ?, ?)',
        ['x', 0, '2026-01-05', '2026-01-05 10:30:00.123', '["a"]'],
      ],
      [
        'UPDATE `post` SET `title` = ? WHERE `id` = ?',
        ['y', 1],
      ],
      [
        'DELETE FROM `post` WHERE `id` IN (?, ?)',
        [1, 2],
      ],
    ]);
  });

  test('conditions', () async {
    final (repo, log) = fake(SqlDialect.postgres);
    await repo.page(Query(conditions: [
      Cond('day', op('RANGE'), [DateTime(2026, 1, 1), DateTime(2026, 2, 1)]),
      Cond('views', op('NOT_IN'), []),
      Cond('title', op('NOT_LIKE'), 'x'),
      Cond('at', op('NULL')),
      Cond('views', op('IN'), []),
    ], sort: [
      ('views', true),
      ('title', false)
    ], offset: 20, limit: 5));
    expect(log[1], [
      'SELECT * FROM "post" WHERE "day" BETWEEN \$1 AND \$2 AND 1=1 AND "title" NOT ILIKE \$3 ESCAPE \'!\' AND "at" IS NULL '
          'AND 1=0 ORDER BY "views" DESC, "title" ASC LIMIT \$4 OFFSET \$5',
      ['2026-01-01', '2026-02-01', '%x%', 5, 20]
    ]);
  });

  test('identifiers are quoted and checked', () {
    expect(fake(SqlDialect.mysql).$1.q('we`ird'), '`we``ird`');
    expect(fake(SqlDialect.postgres).$1.q('we"ird'), '"we""ird"');
    expect(fake(SqlDialect.mssql).$1.q('we]ird'), '[we]]ird]');
    final executor = SqlExecutor(SqlDialect.mysql, query: (_, __) => [], execute: (_, __) {});
    expect(() => SqlRepository(executor, 'post; DROP TABLE x'), throwsArgumentError);
    expect(() => SqlRepository(executor, 'post', autoCreate: true), throwsArgumentError);
  });

  test('memory and SQLite repositories agree', () async {
    final dir = Directory.systemTemp.createTempSync('erupt-sql');
    final db = sqlite.sqlite3.open('${dir.path}/sql.db');
    addTearDown(() {
      db.dispose();
      dir.deleteSync(recursive: true);
    });
    final repos = {
      'memory': MemoryRepository(),
      'sqlite': SqlRepository(
          SqlExecutor(SqlDialect.sqlite,
              query: (sql, params) => [for (final row in db.select(sql, params)) Map.of(row)],
              execute: (sql, params) => db.execute(sql, params)),
          'post',
          autoCreate: true),
    };
    for (final MapEntry(key: kind, value: repo) in repos.entries) {
      repo.bind(post());
      for (final (title, views, live) in [('100% pure', 3, true), ('wow!', 1, false), ('a_b', null, false)]) {
        await repo.add({
          'title': title, 'views': views, 'live': live, 'day': DateTime(2026, 1, 5), //
          'at': DateTime(2026, 1, 5, 10, 30), 'tags': [title],
        });
      }
      Future<List<Object?>> titles([List<Cond> conds = const [], List<(String, bool)>? sort]) async =>
          [for (final r in (await repo.page(Query(conditions: conds, sort: sort))).$2) r['title']];
      expect(await titles(), ['100% pure', 'wow!', 'a_b'], reason: '$kind: default order is primary key ascending');
      expect(await titles([Cond('title', op('LIKE'), '%')]), ['100% pure'], reason: kind);
      expect(await titles([Cond('title', op('LIKE'), '!')]), ['wow!'], reason: kind);
      expect(await titles([Cond('title', op('LIKE'), '_')]), ['a_b'], reason: kind);
      expect(await titles([Cond('title', op('LIKE'), 'PURE')]), ['100% pure'], reason: '$kind: LIKE ignores case');
      expect(await titles([Cond('live', op('EQ'), false), Cond('views', op('NOT_NULL'))]), ['wow!'], reason: kind);
      expect(await titles([Cond('views', op('GT'), 2)]), ['100% pure'], reason: kind);
      expect(
          await titles([
            Cond('day', op('RANGE'), [DateTime(2026, 1, 5), DateTime(2026, 1, 6)])
          ]),
          hasLength(3),
          reason: kind);
      expect(await titles([Cond('tags', op('LIKE'), '"wow!"')]), ['wow!'], reason: '$kind: JSON matched as text');
      expect(await titles([], [('title', true)]), ['wow!', 'a_b', '100% pure'], reason: kind);
      final row = (await repo.get(1))!;
      expect([
        row['live'],
        row['day'],
        row['at'],
        row['tags']
      ], [
        true,
        DateTime(2026, 1, 5),
        DateTime(2026, 1, 5, 10, 30),
        ['100% pure']
      ], reason: kind);
      await repo.update(1, {'title': 'renamed'});
      expect((await repo.get(1))!['title'], 'renamed', reason: kind);
      await repo.delete([1, 2]);
      expect(await titles(), ['a_b'], reason: kind);
      expect(await repo.get(1), isNull, reason: kind);
    }
  });
}
