import 'dart:async';
import 'dart:convert';

import 'model.dart';
import 'repository.dart';
import 'types.g.dart';

enum SqlDialect { sqlite, postgres, mysql, mssql }

/// A row as the driver returns it, keyed by column name.
typedef SqlRow = Map<String, Object?>;

/// What [SqlRepository] needs from a database. The SDK depends on no driver: hand it two closures over
/// yours, for example package:postgres
///
/// ```dart
/// SqlExecutor(SqlDialect.postgres,
///     query: (sql, params) async => [for (final r in await pool.execute(sql, parameters: params)) r.toColumnMap()],
///     execute: (sql, params) => pool.execute(sql, parameters: params));
/// ```
class SqlExecutor {
  SqlExecutor(this.dialect, {required this.query, required this.execute});

  final SqlDialect dialect;

  /// Runs a SELECT with bound values.
  final FutureOr<List<SqlRow>> Function(String sql, List<Object?> params) query;

  /// Runs an INSERT / UPDATE / DELETE / DDL statement with bound values.
  final FutureOr<void> Function(String sql, List<Object?> params) execute;
}

/// Collects bound values and writes the dialect's placeholder for each.
class _Params {
  _Params(this.dialect);

  final SqlDialect dialect;
  final values = <Object?>[];

  String add(Object? value, [Field? field]) {
    values.add(switch (value) {
      // only PostgreSQL has a boolean type every driver binds; elsewhere a boolean is 0 / 1
      bool() when dialect != SqlDialect.postgres => value ? 1 : 0,
      DateTime() =>
        field?.type == 'DATE' ? formatDateTime(value, date: true) : formatDateTime(value).replaceFirst('T', ' '),
      _ => value,
    });
    final n = values.length;
    return switch (dialect) { SqlDialect.postgres => '\$$n', SqlDialect.mssql => '@p${n - 1}', _ => '?' };
  }
}

const _sqlOps = {
  QueryExpression.EQ: '=',
  QueryExpression.NEQ: '<>',
  QueryExpression.GT: '>',
  QueryExpression.GTE: '>=',
  QueryExpression.LT: '<',
  QueryExpression.LTE: '<=',
};

const _sqliteTypes = {
  'NUMBER': 'NUMERIC',
  'BOOLEAN': 'INTEGER',
  'DATE': 'TEXT',
  dateTime: 'TEXT',
  'REFERENCE_TABLE': 'INTEGER',
  'REFERENCE_TREE': 'INTEGER',
};

/// A table on PostgreSQL, MySQL, SQL Server or SQLite through a [SqlExecutor]. Column names are the model's
/// field names (quoted, so case sensitive on PostgreSQL); every value is a bound parameter; LIKE escapes with
/// `ESCAPE '!'`, which every database reads the same way. Without a sort, rows come back by primary key
/// ascending. [autoCreate] creates a missing SQLite table: create production tables yourself.
class SqlRepository extends Repository {
  SqlRepository(this.executor, this.table, {this.autoCreate = false}) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(table)) throw ArgumentError("illegal table name '$table'");
    if (autoCreate && executor.dialect != SqlDialect.sqlite) {
      throw ArgumentError('autoCreate creates SQLite tables only');
    }
  }

  final SqlExecutor executor;
  final String table;
  final bool autoCreate;
  late final Map<String, String> _columns;
  Future<void> _ready = Future.value();

  SqlDialect get dialect => executor.dialect;

  /// A quoted identifier; the closing quote is doubled.
  String q(String identifier) {
    final (open, close) =
        switch (dialect) { SqlDialect.mysql => ('`', '`'), SqlDialect.mssql => ('[', ']'), _ => ('"', '"') };
    return '$open${identifier.replaceAll(close, close * 2)}$close';
  }

  @override
  void bind(Model model) {
    super.bind(model);
    _columns = {for (final name in model.fields.keys) name.toLowerCase(): name};
    if (!autoCreate) return;
    final cols = [
      for (final f in model.fields.values)
        f.pk ? '${q(f.name)} INTEGER PRIMARY KEY AUTOINCREMENT' : '${q(f.name)} ${_sqliteTypes[f.type] ?? 'TEXT'}',
    ];
    // bind is synchronous; the DDL is awaited before the first statement
    _ready =
        Future.sync(() => executor.execute('CREATE TABLE IF NOT EXISTS ${q(table)} (${cols.join(', ')})', const []));
  }

  @override
  Future<(int, List<EruptRecord>)> page(Query query) async {
    await _ready;
    final count = _Params(dialect);
    final rows =
        await executor.query('SELECT COUNT(*) AS n FROM ${q(table)}${_where(query.conditions, count)}', count.values);
    final p = _Params(dialect);
    final where = _where(query.conditions, p);
    final sort = query.sort.isEmpty ? [(model.pk!, false)] : query.sort;
    final order = sort.map((s) => '${q(s.$1)} ${s.$2 ? 'DESC' : 'ASC'}').join(', ');
    final paging = dialect == SqlDialect.mssql
        ? 'OFFSET ${p.add(query.offset)} ROWS FETCH NEXT ${p.add(query.limit)} ROWS ONLY'
        : 'LIMIT ${p.add(query.limit)} OFFSET ${p.add(query.offset)}';
    final list = await executor.query('SELECT * FROM ${q(table)}$where ORDER BY $order $paging', p.values);
    return (toNumber(rows.first.values.first!).toInt(), [for (final row in list) _record(row)]);
  }

  @override
  Future<EruptRecord?> get(Object pk) async {
    await _ready;
    final p = _Params(dialect);
    final rows = await executor.query('SELECT * FROM ${q(table)} WHERE ${q(model.pk!)} = ${p.add(pk)}', p.values);
    return rows.isEmpty ? null : _record(rows.first);
  }

  @override
  Future<void> add(EruptRecord record) async {
    await _ready;
    final columns = _store(record);
    final p = _Params(dialect);
    final values = [for (final MapEntry(:key, :value) in columns.entries) p.add(value, model.fields[key])];
    await executor.execute(
        'INSERT INTO ${q(table)} (${columns.keys.map(q).join(', ')}) VALUES (${values.join(', ')})', p.values);
  }

  @override
  Future<void> update(Object pk, EruptRecord record) async {
    await _ready;
    final columns = _store(record);
    if (columns.isEmpty) return;
    final p = _Params(dialect);
    final sets = [
      for (final MapEntry(:key, :value) in columns.entries) '${q(key)} = ${p.add(value, model.fields[key])}'
    ];
    await executor.execute('UPDATE ${q(table)} SET ${sets.join(', ')} WHERE ${q(model.pk!)} = ${p.add(pk)}', p.values);
  }

  @override
  Future<void> delete(List<Object> pks) async {
    await _ready;
    if (pks.isEmpty) return;
    final p = _Params(dialect);
    final marks = pks.map(p.add).join(', ');
    await executor.execute('DELETE FROM ${q(table)} WHERE ${q(model.pk!)} IN ($marks)', p.values);
  }

  /// The columns of a record, a JSON value as its text.
  Map<String, Object?> _store(EruptRecord record) => {
        for (final MapEntry(:key, :value) in record.entries)
          if (key != model.pk) key: model.fields[key]?.json == true && value != null ? jsonEncode(value) : value,
      };

  String _where(List<Cond> conditions, _Params p) {
    final clauses = conditions.map((c) {
      final col = q(c.field);
      final field = model.fields[c.field];
      final values = c.value is List ? c.value as List : const [];
      final sql = _sqlOps[c.op];
      if (sql != null) return '$col $sql ${p.add(c.value, field)}';
      switch (c.op) {
        case QueryExpression.LIKE || QueryExpression.NOT_LIKE:
          // '!' rather than a backslash: MySQL reads a backslash inside a string literal as an escape itself;
          // ILIKE because PostgreSQL's LIKE is case sensitive, the others' (and the memory repository's) is not;
          // [ opens a character class in SQL Server's LIKE
          final special = RegExp(dialect == SqlDialect.mssql ? r'[!%_[]' : r'[!%_]');
          final pattern = '%${'${c.value}'.replaceAllMapped(special, (m) => '!${m[0]}')}%';
          final like = dialect == SqlDialect.postgres ? 'ILIKE' : 'LIKE';
          return "$col ${c.op == QueryExpression.NOT_LIKE ? 'NOT ' : ''}$like ${p.add(pattern)} ESCAPE '!'";
        case QueryExpression.RANGE:
          return '$col BETWEEN ${p.add(values[0], field)} AND ${p.add(values[1], field)}';
        case QueryExpression.IN || QueryExpression.NOT_IN:
          final notIn = c.op == QueryExpression.NOT_IN;
          if (values.isEmpty) return notIn ? '1=1' : '1=0';
          return '$col ${notIn ? 'NOT ' : ''}IN (${values.map((v) => p.add(v, field)).join(', ')})';
        case QueryExpression.NULL:
          return '$col IS NULL';
        case QueryExpression.NOT_NULL:
          return '$col IS NOT NULL';
        default:
          throw ArgumentError("illegal operator '${c.op.name}'");
      }
    }).toList();
    return clauses.isEmpty ? '' : ' WHERE ${clauses.join(' AND ')}';
  }

  /// A driver row as a record: columns matched to fields case-insensitively, values normalized by field type.
  EruptRecord _record(SqlRow row) {
    final byField = {for (final MapEntry(:key, :value) in row.entries) _columns[key.toLowerCase()] ?? key: value};
    return {
      for (final f in model.fields.values)
        f.name: switch (byField[f.name]) { null => null, final v => _normalize(f, v) },
    };
  }

  Object? _normalize(Field f, Object value) {
    if (f.json) return value is String ? jsonDecode(value) : value;
    return switch (f.type) {
      'BOOLEAN' => const [true, 1, '1', 't', 'true'].contains(value),
      'DATE' => switch (parseDateTime(value)) { final t => DateTime(t.year, t.month, t.day) },
      dateTime => parseDateTime(value),
      'NUMBER' || 'REFERENCE_TABLE' || 'REFERENCE_TREE' || null => value is BigInt ? value.toInt() : toNumber(value),
      _ => value,
    };
  }
}
