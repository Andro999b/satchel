import 'vault_exceptions.dart';

/// [time] in UTC, truncated to whole milliseconds.
///
/// The web has millisecond precision only, so timestamps are stored that way
/// on every platform: a vault written on one platform reads back identical
/// on another.
DateTime utcMillis(DateTime time) {
  final utc = time.toUtc();
  return utc.microsecond == 0
      ? utc
      : DateTime.fromMillisecondsSinceEpoch(
          utc.millisecondsSinceEpoch,
          isUtc: true,
        );
}

/// ISO-8601 form of a UTC timestamp, e.g. `2026-11-02T10:00:00.000Z`.
String formatUtc(DateTime time) => utcMillis(time).toIso8601String();

/// Reads the field [key] of [json] as a [T]. Throws [VaultFormatException]
/// naming only the field, never its value.
T readField<T>(Map<String, Object?> json, String key, String context) {
  final value = json[key];
  if (value is T) return value;
  throw VaultFormatException('Malformed $context field "$key"');
}

/// Like [readField], but returns [fallback] when the field is absent.
T readOptionalField<T>(
  Map<String, Object?> json,
  String key,
  String context,
  T fallback,
) => json.containsKey(key) ? readField<T>(json, key, context) : fallback;

/// Reads a UTC ISO-8601 timestamp field.
DateTime readUtc(Map<String, Object?> json, String key, String context) {
  final time = DateTime.tryParse(readField<String>(json, key, context));
  if (time == null || !time.isUtc) {
    throw VaultFormatException('Malformed $context timestamp "$key"');
  }
  return utcMillis(time);
}

/// Reads [json] as a JSON object.
Map<String, Object?> readObject(Object? json, String context) {
  if (json is Map<String, Object?>) return json;
  throw VaultFormatException('Malformed $context');
}

/// Reads the list field [key], converting each element with [convert].
List<T> readList<T>(
  Map<String, Object?> json,
  String key,
  String context,
  T Function(Object? element) convert, {
  bool optional = false,
}) {
  if (optional && !json.containsKey(key)) return const [];
  return [
    for (final element in readField<List<Object?>>(json, key, context))
      convert(element),
  ];
}
