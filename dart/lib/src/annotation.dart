/// Base of the generated annotation classes (types.g.dart): typed raw attributes that a declaration
/// merges onto the defaults the Java proxies emit.
abstract class Annotation {
  const Annotation();

  /// Every attribute by its JSON name, null when not set.
  Map<String, Object?> get attributes;

  /// The attributes that are set, as JSON data.
  Map<String, Object?> toJson() => {
        for (final MapEntry(:key, :value) in attributes.entries)
          if (value != null) key: annotationJson(value),
      };
}

/// An attribute value as JSON data: an annotation as its object, an enum as its name.
Object? annotationJson(Object? value) => switch (value) {
      Annotation() => value.toJson(),
      Enum() => value.name,
      List() => [for (final v in value) annotationJson(v)],
      Map() => {for (final MapEntry(:key, :value) in value.entries) '$key': annotationJson(value)},
      _ => value,
    };
