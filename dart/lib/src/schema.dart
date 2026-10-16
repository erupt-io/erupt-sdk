import 'dart:convert';

import 'schema.g.dart';

/// Checks annotation JSON against erupt-annotations.schema.json (the same schema types.g.dart is generated
/// from), so a wrong attribute fails when the model is declared instead of silently doing nothing in the
/// browser.
abstract final class Schema {
  static final Map<String, dynamic> _defs =
      (jsonDecode(schemaJson) as Map<String, dynamic>)[r'$defs'] as Map<String, dynamic>;

  /// The values of enum definition [name].
  static List<String> enumValues(String name) => (_defs[name]['enum'] as List).cast<String>();

  /// Throws [ArgumentError] unless [value] fits definition [name]. [partial] (an override) lets every
  /// attribute be omitted; otherwise the attributes the Java side always emits must be present.
  static void check(String name, Object? value, [String? path, bool partial = true]) =>
      _walk({r'$ref': '#/\$defs/$name'}, value, path ?? name, partial);

  static void _walk(Map<String, dynamic> schema, Object? value, String path, bool partial) {
    final ref = schema[r'$ref'] as String?;
    if (ref != null) return _walkRef(ref.split('/').last, value, path, partial);
    switch (schema['type']) {
      case 'array':
        if (value is! List) throw ArgumentError('$path: expected an array');
        for (var i = 0; i < value.length; i++) {
          _walk(schema['items'] as Map<String, dynamic>, value[i], '$path[$i]', partial);
        }
      case 'object':
        if (value is! Map) throw ArgumentError('$path: expected an object');
        final items = schema['additionalProperties'];
        if (items is! Map<String, dynamic>) return;
        value.forEach((key, item) => _walk(items, item, '$path.$key', partial));
      case final String type:
        final ok = switch (type) {
          'string' => value is String,
          'integer' => value is int,
          'number' => value is num && value.isFinite,
          'boolean' => value is bool,
          _ => false,
        };
        if (!ok) throw ArgumentError('$path: expected $type, got ${jsonEncode(value)}');
    }
  }

  static void _walkRef(String name, Object? value, String path, bool partial) {
    final d = _defs[name] as Map<String, dynamic>;
    final values = d['enum'] as List?;
    if (values != null) {
      if (!values.contains(value)) {
        throw ArgumentError("$path: '$value' is not a $name, expected one of ${values.join(', ')}");
      }
      return;
    }
    if (value is! Map) throw ArgumentError('$path: expected an object ($name)');
    final props = d['properties'] as Map<String, dynamic>;
    value.forEach((key, item) {
      if (!props.containsKey(key)) throw ArgumentError("$path: $name has no attribute '$key'");
      _walk(props[key] as Map<String, dynamic>, item, '$path.$key', partial);
    });
    if (!partial) {
      final missing = ((d['required'] as List?) ?? const []).where((k) => !value.containsKey(k));
      if (missing.isNotEmpty) throw ArgumentError('$path: missing ${missing.join(', ')}');
    }
  }
}
