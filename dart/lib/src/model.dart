import 'dart:async';
import 'dart:convert';

import 'repository.dart';
import 'schema.dart';
import 'schema.g.dart';
import 'types.g.dart';

/// A record as repositories store it: field name -> value (a reference holds the referenced primary key).
typedef EruptRecord = Map<String, Object?>;

/// Rights by name (`add`, `edit`, `delete`, `query`, `viewDetails`, `export`, `importable`, ...).
typedef Power = Map<String, bool>;

final _templates = jsonDecode(defaultsJson) as Map<String, dynamic>;

final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Not an [EditType]: the SDK's DATE whose picker includes the time.
const dateTime = 'DATE_TIME';

const _references = {'REFERENCE_TABLE', 'REFERENCE_TREE'};

/// A deep copy of JSON data.
Object? copyJson(Object? value) => switch (value) {
      Map() => {for (final MapEntry(:key, :value) in value.entries) key as String: copyJson(value)},
      List() => [for (final v in value) copyJson(v)],
      _ => value,
    };

Map<String, dynamic> _template(String key) => copyJson(_templates[key]) as Map<String, dynamic>;

Map<String, dynamic> _merge(Map<String, dynamic> target, Map<String, Object?> override) {
  override.forEach((key, value) {
    final current = target[key];
    if (value is Map<String, Object?> && current is Map<String, dynamic>) {
      _merge(current, value);
    } else {
      target[key] = copyJson(value);
    }
  });
  return target;
}

/// The acting user the server forwards with every request.
class User {
  const User({this.uid, this.account, this.name, this.tenantId});

  factory User.fromJson(Map<String, dynamic> json) => User(
      uid: (json['uid'] as num?)?.toInt(),
      account: json['account'] as String?,
      name: json['name'] as String?,
      tenantId: json['tenantId']?.toString());

  final int? uid;
  final String? account;
  final String? name;
  final String? tenantId;
}

/// One column. [title] labels both the table column and the form input.
///
/// The edit type is [type] (INPUT when omitted; DATE with [time] picks a date and time), CHOICE when
/// [choices] are given, and a reference when [ref] is: the repository stores the referenced primary key,
/// the UI shows [label], and [tree] (the referenced model's parent field) turns the picker into a tree.
/// [json] holds a JSON value (MULTI_CHOICE list, KEY_VALUE object, its options in [choices]): SQL repositories
/// store it as JSON text. [virtual] declares a form-only element (DIVIDE, CALLOUT, EMPTY, GROUP) that is in
/// the build but never read or written. [view] and [edit] are raw annotation attributes for anything else.
class Field {
  Field(this.title,
      {EditType? type,
      bool time = false,
      this.search = false,
      this.notNull = false,
      this.sortable = false,
      this.table = true,
      this.form = true,
      this.virtual = false,
      this.json = false,
      Map<String, String>? choices,
      this.ref,
      this.label = 'name',
      this.tree,
      View? view,
      Edit? edit})
      : choices = choices == null ? null : Map.unmodifiable(choices),
        view = view?.toJson() ?? const {},
        edit = edit?.toJson() ?? const {},
        type = ref != null
            ? (tree != null ? 'REFERENCE_TREE' : 'REFERENCE_TABLE')
            : type != null
                ? (type == EditType.DATE && time ? dateTime : type.name)
                : (choices != null && !json ? 'CHOICE' : (time ? dateTime : 'INPUT'));

  /// The primary key: an auto-increment integer, hidden from table and form.
  Field.pk()
      : title = '',
        type = null,
        search = false,
        notNull = false,
        sortable = false,
        table = false,
        form = false,
        virtual = false,
        json = false,
        choices = null,
        ref = null,
        label = 'name',
        tree = null,
        view = const {},
        edit = const {};

  /// Set by the model: the key it is declared under.
  late final String name;
  final String title;

  /// The edit type (or [dateTime]); null for the primary key.
  final String? type;
  final bool search, notNull, sortable, table, form, virtual, json;
  final Map<String, String>? choices;
  final Model? ref;
  final String label;
  final String? tree;
  final Map<String, Object?> view, edit;

  bool get pk => type == null;

  bool get isReference => _references.contains(type);

  /// The referenced model, for a reference field.
  Model get target => ref!;

  Map<String, dynamic> build() {
    final tpl = _template('fields')[pk ? 'id' : type] as Map<String, dynamic>;
    tpl['fieldName'] = name;
    tpl['componentValue'] = null;
    if (pk) return tpl;
    final efj = tpl['eruptFieldJson'] as Map<String, dynamic>;
    final e = efj['edit'] as Map<String, dynamic>;
    final v = (efj['views'] as List)[0] as Map<String, dynamic>;
    e.addAll({'title': title, 'notNull': notNull, 'show': form});
    (e['search'] as Map<String, dynamic>)['value'] = search;
    v.addAll({'title': title, 'sortable': sortable});
    if (type == 'DATE') v['type'] = 'DATE';
    if (isReference) {
      tpl['fieldReturnName'] = target.name;
      final picker = e[type == 'REFERENCE_TABLE' ? 'referenceTableType' : 'referenceTreeType'] as Map<String, dynamic>;
      picker.addAll({'id': target.pk, 'label': label});
      if (tree != null) picker['pid'] = tree;
      v['column'] = label;
    }
    _merge(e, edit);
    _merge(v, view);
    if (!table) efj['views'] = [];
    if (choices != null) {
      // CHOICE, or MULTI_CHOICE over a JSON list
      tpl['componentValue'] = [
        for (final MapEntry(:key, :value) in choices!.entries)
          {'value': key, 'label': value, 'desc': null, 'color': null, 'disable': false},
      ];
    }
    return tpl;
  }

  /// Turns a JSON value from the browser into the value stored by the repository; throws [FormatException].
  Object? coerce(Object? value) {
    if (isReference) {
      // the browser sends the picked record as {<id>: ..., <label>: ...}
      if (value is Map) value = value[target.pk];
      return target.fields[target.pk]!.coerce(value);
    }
    if (value == null || value == '') return null;
    if (pk) return _integer(value);
    if (json) return _json(value);
    return switch (type) {
      'BOOLEAN' => value is bool ? value : const ['true', '1'].contains('$value'.toLowerCase()),
      'NUMBER' => toNumber(value),
      dateTime => parseDateTime(value),
      'DATE' => _date(parseDateTime(value)),
      'CHOICE' when choices != null && !choices!.containsKey('$value') =>
        throw FormatException("illegal option '$value'"),
      _ => '$value',
    };
  }

  Object _json(Object value) {
    final parsed = value is String ? jsonDecode(value) : value;
    if (parsed is! List && parsed is! Map) throw const FormatException('must be a JSON array or object');
    if (choices != null && parsed is List && !parsed.every((v) => choices!.containsKey('$v'))) {
      throw FormatException('illegal option in ${jsonEncode(parsed)}');
    }
    return parsed;
  }

  /// A stored value as the browser expects it.
  Object? toJsonValue(Object? value) => value is DateTime ? formatDateTime(value, date: type == 'DATE') : value;
}

int _integer(Object value) => switch (value) {
      int() => value,
      double() when value.isFinite && value == value.truncateToDouble() => value.toInt(),
      String() when int.tryParse(value.trim()) != null => int.parse(value.trim()),
      _ => throw FormatException("illegal id '$value'"),
    };

/// A number as an int when it is integral, a double otherwise.
num toNumber(Object value) {
  final n = switch (value) {
    num() => value,
    String() => num.tryParse(value.trim()),
    _ => null,
  };
  if (n == null || !n.isFinite) throw FormatException("illegal number '$value'");
  return n is double && n == n.truncateToDouble() && n.abs() < 9007199254740992 ? n.toInt() : n;
}

final _dateInput =
    RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[T ](\d{1,2}):(\d{1,2})(?::(\d{1,2})(?:\.(\d{1,9}))?)?)?Z?$');

DateTime _date(DateTime t) => DateTime(t.year, t.month, t.day);

/// A DATE / DATE_TIME as a local wall-clock DateTime: `2026-01-05`, `2026-01-05 10:30`,
/// `2026-01-05T10:30:00.123Z`, or a DateTime.
DateTime parseDateTime(Object value) {
  if (value is DateTime) return value;
  final m = _dateInput.firstMatch('$value'.trim());
  if (m != null) {
    final [y, mo, d, h, mi, s] = [for (var i = 1; i <= 6; i++) int.parse(m[i] ?? '0')];
    final ms = int.parse((m[7] ?? '0').padRight(3, '0').substring(0, 3));
    final t = DateTime(y, mo, d, h, mi, s, ms);
    // DateTime rolls 2026-02-30 over into March: only a date that comes back as written is real
    if (t.year == y && t.month == mo && t.day == d && h < 24 && mi < 60 && s < 60) return t;
  }
  throw FormatException("illegal date '$value'");
}

String _pad(int n, [int width = 2]) => '$n'.padLeft(width, '0');

/// `2026-01-05T10:30:00.000`, or `2026-01-05` for a [date].
String formatDateTime(DateTime t, {bool date = false}) {
  final day = '${_pad(t.year, 4)}-${_pad(t.month)}-${_pad(t.day)}';
  return date ? day : '${day}T${_pad(t.hour)}:${_pad(t.minute)}:${_pad(t.second)}.${_pad(t.millisecond, 3)}';
}

/// What an operation handler receives.
class OperationContext {
  OperationContext(
      {required this.rows, required this.param, required this.repo, required this.model, required this.user});

  /// Selected records as the repository returned them; empty for BUTTON mode.
  final List<EruptRecord> rows;

  /// Coerced form values, or null without a form.
  final EruptRecord? param;
  final Repository repo;
  final Model model;
  final User? user;
}

/// Runs an operation. It may return a string, which is executed as JavaScript in the browser, so only return
/// code you wrote.
typedef OperationHandler = FutureOr<void> Function(OperationContext op);

/// A row operation; pass it in `Model(..., operations: {code: ...})`.
///
/// [mode]: SINGLE (row button), MULTI (row and toolbar), MULTI_ONLY (toolbar), BUTTON (toolbar, no rows).
/// [form]: a model whose fields are asked for before running. [confirm] false skips the confirm dialog,
/// [confirmText] replaces its text. [show] hides the operation and refuses to run it. [ifExpr]: browser-side
/// JS over `item` that disables (or hides) the row button. [raw]: other `@RowOperation` attributes.
class Operation {
  Operation(this.title, this.handler,
      {this.mode = RowOperationMode.MULTI,
      this.icon,
      this.tip = '',
      this.confirm = true,
      this.confirmText,
      this.form,
      this.show,
      this.ifExpr = '',
      RowOperation? raw})
      : raw = raw?.toJson() ?? const {};

  final String title;
  final OperationHandler handler;
  final RowOperationMode mode;
  final String? icon;
  final String tip;
  final bool confirm;
  final String? confirmText;
  final Model? form;
  final bool Function(User? user)? show;
  final String ifExpr;
  final Map<String, Object?> raw;

  /// Set by the model: the key it is declared under.
  late final String code;

  bool visible(User? user) => show == null || show!(user);

  Map<String, dynamic> build() {
    final tpl = _template('rowOperation')
      ..addAll({
        'code': code,
        'title': title,
        'mode': mode.name,
        'tip': tip,
        'ifExpr': ifExpr,
        'type': 'ERUPT',
        'eruptClass': form?.name ?? 'void',
      });
    if (icon != null) tpl['icon'] = icon;
    if (!confirm) {
      tpl['callHint'] = ''; // the browser runs it without asking
    } else if (confirmText != null) {
      tpl['callHint'] = confirmText;
    }
    return _merge(tpl, raw);
  }
}

/// An erupt model. [name] is what the server addresses (`node.Name`); [fields] keep their order.
///
/// [power] switches features off (`{'delete': false}`); [orderBy] is the default table order, applied by the
/// node (`'views desc, id'`); [erupt] holds raw `@Erupt` attributes merged onto the defaults. Everything is
/// checked here, so a mistake fails at startup, not in the browser.
class Model {
  Model(this.name,
      {required Map<String, Field> fields,
      this.title,
      Power? power,
      String? orderBy,
      Erupt? erupt,
      Map<String, Operation>? operations})
      : power = Map.unmodifiable({...(_templates['power'] as Map).cast<String, bool>(), ...?power}),
        _raw = erupt?.toJson() ?? const {} {
    if (!_identifier.hasMatch(name)) throw ArgumentError("erupt name '$name' must be an identifier");
    Schema.check('Erupt', _raw, 'model $name');
    fields.forEach((key, f) {
      final path = '$name.$key';
      if (!_identifier.hasMatch(key)) throw ArgumentError("$path: field name must be an identifier");
      f.name = key;
      // an edit type, or a template variant of one (DATE_TIME is DATE with a date-time picker)
      if (f.type != null && !(_templates['fields'] as Map).containsKey(f.type)) {
        throw ArgumentError('$path: edit type ${f.type} is not supported yet');
      }
      Schema.check('View', f.view, '$path.view');
      Schema.check('Edit', f.edit, '$path.edit');
      if (f.isReference) _checkReference(f, path);
      declared.add(f);
      if (!f.virtual) this.fields[key] = f;
    });
    final pks = this.fields.values.where((f) => f.pk).toList();
    if (pks.length > 1) throw ArgumentError('$name: at most one Field.pk()');
    pk = pks.firstOrNull?.name;
    operations?.forEach((code, op) {
      Schema.check('RowOperation', op.raw, '$name.$code');
      op.code = code;
      this.operations[code] = op;
    });
    order = _parseOrder(orderBy ?? '');
  }

  final String name;

  /// Display name; not sent to the browser (the menu names the page).
  final String? title;
  final Power power;
  final Map<String, Object?> _raw;

  /// Stored and served.
  final Map<String, Field> fields = {};

  /// Every field in order, virtual ones included, for the build.
  final List<Field> declared = [];
  final Map<String, Operation> operations = {};

  /// The primary key field's name; a model without one can only serve as an operation form.
  late final String? pk;

  /// The default table order: `[(field, descending)]`.
  late final List<(String, bool)> order;

  List<(String, bool)> _parseOrder(String orderBy) => [
        for (final part in orderBy.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty))
          switch (part.split(RegExp(r'\s+'))) {
            [final f] when fields.containsKey(f) => (f, false),
            [final f, final dir] when fields.containsKey(f) && const ['asc', 'desc'].contains(dir.toLowerCase()) => (
                f,
                dir.toLowerCase() == 'desc'
              ),
            _ => throw ArgumentError("$name: illegal orderBy '$part'"),
          },
      ];

  void _checkReference(Field f, String path) {
    final target = f.target;
    if (target.pk == null) throw ArgumentError('$path: ${target.name} has no primary key');
    for (final key in [f.label, if (f.tree != null) f.tree!]) {
      if (!target.fields.containsKey(key)) throw ArgumentError("$path: ${target.name} has no field '$key'");
    }
  }

  Map<String, dynamic> buildErupt([List<Operation> operations = const []]) {
    final eruptJson = _template('erupt')..['primaryKeyCol'] = pk ?? 'id';
    eruptJson['rowOperation'] = [for (final op in operations) op.build()];
    _merge(eruptJson, _raw);
    return {
      'eruptName': name,
      'eruptJson': eruptJson,
      'eruptFieldModels': [for (final f in declared) f.build()],
      'searchCondition': <String, Object?>{},
      'extraRow': false,
      'tags': <String, Object?>{},
    };
  }

  Map<String, dynamic> buildModel(Power power, User? user) {
    final visible = operations.values.where((op) => op.visible(user)).toList();
    final forms = {
      for (final op in visible)
        if (op.form != null) op.code: op.form!.buildErupt()
    };
    return {
      'eruptModel': buildErupt(visible),
      'power': power,
      'tabErupts': null,
      'combineErupts': null,
      'operationErupts': forms.isEmpty ? null : forms,
    };
  }
}
