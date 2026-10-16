import 'dart:async';
import 'dart:convert';

import 'model.dart';
import 'types.g.dart';

/// One search condition; [value] is a list for RANGE (two values), IN and NOT_IN, absent for NULL / NOT_NULL.
class Cond {
  const Cond(this.field, this.op, [this.value]);

  final String field;
  final QueryExpression op;
  final Object? value;
}

/// What a repository is asked for; [sort] is `[(field, descending)]`.
class Query {
  Query({List<Cond>? conditions, List<(String, bool)>? sort, this.offset = 0, this.limit = 10})
      : conditions = conditions ?? [],
        sort = sort ?? [];

  final List<Cond> conditions;
  List<(String, bool)> sort;
  final int offset;
  final int limit;
}

/// Storage adapter: implement these methods to put a model on any storage; each may be async. A record is
/// keyed by field name. A repository only sees field names the node has already checked against the model,
/// so it may use them as identifiers; values always travel as parameters.
abstract class Repository {
  late final Model model;

  /// Called once by `Node.register` with the model this repository stores.
  void bind(Model model) => this.model = model;

  /// The total count and one page of records. Without a sort, by primary key ascending.
  FutureOr<(int, List<EruptRecord>)> page(Query query);

  FutureOr<EruptRecord?> get(Object pk);

  FutureOr<void> add(EruptRecord record);

  FutureOr<void> update(Object pk, EruptRecord record);

  FutureOr<void> delete(List<Object> pks);
}

/// Records in memory, for tests and demos.
class MemoryRepository extends Repository {
  /// [seed] records are added (with fresh ids 1, 2, ...) once the repository is registered.
  MemoryRepository([List<EruptRecord> seed = const []]) : _seed = seed;

  final List<EruptRecord> _seed;
  final _rows = <Object, EruptRecord>{};
  var _seq = 0;

  @override
  void bind(Model model) {
    super.bind(model);
    _seed.forEach(add);
  }

  @override
  (int, List<EruptRecord>) page(Query query) {
    final rows = _rows.values.where((r) => query.conditions.every((c) => _match(r[c.field], c))).toList();
    final sort = query.sort.isEmpty ? [(model.pk!, false)] : query.sort;
    // List.sort is not stable: the primary key settles ties
    rows.sort((a, b) {
      for (final (name, desc) in [...sort, (model.pk!, false)]) {
        final c = compareValues(a[name], b[name]);
        if (c != 0) return desc ? -c : c;
      }
      return 0;
    });
    return (
      rows.length,
      [
        for (final r in rows.skip(query.offset).take(query.limit)) {...r}
      ]
    );
  }

  @override
  EruptRecord? get(Object pk) => switch (_rows[pk]) { final row? => {...row}, null => null };

  @override
  void add(EruptRecord record) => _rows[++_seq] = {...record, model.pk!: _seq};

  @override
  void update(Object pk, EruptRecord record) => _rows[pk]?.addAll({...record, model.pk!: pk});

  @override
  void delete(List<Object> pks) => pks.forEach(_rows.remove);
}

/// Orders stored values: null last, false before true, otherwise by their natural order.
int compareValues(Object? a, Object? b) {
  if (a == null || b == null) return (a == null ? 1 : 0) - (b == null ? 1 : 0);
  if (a is bool && b is bool) return (a ? 1 : 0) - (b ? 1 : 0);
  if (a is Comparable && b is Comparable) {
    try {
      return a.compareTo(b);
    } on TypeError {
      // values of different kinds: compared as text
    }
  }
  return '$a'.compareTo('$b');
}

bool _match(Object? value, Cond c) {
  if (c.op == QueryExpression.NULL) return value == null;
  if (c.op == QueryExpression.NOT_NULL) return value != null;
  if (value == null) return false;
  // a JSON value is matched as its text
  if (value is List || value is Map) value = jsonEncode(value);
  final expect = c.value;
  bool like() => '$value'.toLowerCase().contains('$expect'.toLowerCase());
  return switch (c.op) {
    QueryExpression.EQ => compareValues(value, expect) == 0,
    QueryExpression.NEQ => compareValues(value, expect) != 0,
    QueryExpression.LIKE => like(),
    QueryExpression.NOT_LIKE => !like(),
    QueryExpression.IN => (expect as List).any((e) => compareValues(value, e) == 0),
    QueryExpression.NOT_IN => !(expect as List).any((e) => compareValues(value, e) == 0),
    QueryExpression.RANGE => compareValues((expect as List)[0], value) <= 0 && compareValues(value, expect[1]) <= 0,
    QueryExpression.GT => compareValues(value, expect) > 0,
    QueryExpression.GTE => compareValues(value, expect) >= 0,
    QueryExpression.LT => compareValues(value, expect) < 0,
    QueryExpression.LTE => compareValues(value, expect) <= 0,
    _ => false,
  };
}
