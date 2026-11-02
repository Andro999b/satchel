import 'package:clock/clock.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'ids.dart';
import 'json_utils.dart';
import 'vault_exceptions.dart';

const _listEquality = ListEquality<Object?>();

/// A user-defined label/value pair on a secret, e.g. "Security question" /
/// "First pet".
@immutable
final class CustomField {
  const CustomField({
    required this.label,
    required this.value,
    this.concealed = true,
  });

  /// Parses [toJson] output. Throws `VaultFormatException` if malformed.
  factory CustomField.fromJson(Object? json) {
    final map = readObject(json, 'custom field');
    return CustomField(
      label: readField<String>(map, 'label', 'custom field'),
      value: readField<String>(map, 'value', 'custom field'),
      concealed: readField<bool>(map, 'concealed', 'custom field'),
    );
  }

  final String label;
  final String value;

  /// Whether the UI masks [value] until revealed.
  final bool concealed;

  CustomField copyWith({String? label, String? value, bool? concealed}) =>
      CustomField(
        label: label ?? this.label,
        value: value ?? this.value,
        concealed: concealed ?? this.concealed,
      );

  Map<String, Object?> toJson() => {
    'label': label,
    'value': value,
    'concealed': concealed,
  };

  @override
  bool operator ==(Object other) =>
      other is CustomField &&
      other.label == label &&
      other.value == value &&
      other.concealed == concealed;

  @override
  int get hashCode => Object.hash(label, value, concealed);

  @override
  String toString() => 'CustomField(<redacted>)';
}

/// The fields every secret type shares.
///
/// Timestamps are stored in UTC with millisecond precision. Tags are
/// normalized: trimmed, empty ones dropped, duplicates (ignoring case)
/// removed, and sorted, so equal tag sets compare equal.
@immutable
final class SecretInfo {
  SecretInfo({
    required this.id,
    required this.title,
    required DateTime createdAt,
    required DateTime updatedAt,
    Iterable<String> tags = const [],
    DateTime? expiresAt,
    this.notes = '',
    Iterable<CustomField> customFields = const [],
  }) : createdAt = utcMillis(createdAt),
       updatedAt = utcMillis(updatedAt),
       expiresAt = expiresAt == null ? null : utcMillis(expiresAt),
       tags = normalizeTags(tags),
       customFields = List.unmodifiable(customFields) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'Must not be empty');
  }

  /// Info for a new secret: a fresh id, and both timestamps set to now.
  factory SecretInfo.create({
    required String title,
    Iterable<String> tags = const [],
    DateTime? expiresAt,
    String notes = '',
    Iterable<CustomField> customFields = const [],
    Clock clock = const Clock(),
  }) {
    final now = clock.now();
    return SecretInfo(
      id: newId(),
      title: title,
      createdAt: now,
      updatedAt: now,
      tags: tags,
      expiresAt: expiresAt,
      notes: notes,
      customFields: customFields,
    );
  }

  /// Parses the common fields of a secret's JSON.
  factory SecretInfo.fromJson(Map<String, Object?> json) {
    const context = 'secret';
    return SecretInfo(
      id: readField<String>(json, 'id', context),
      title: readField<String>(json, 'title', context),
      createdAt: readUtc(json, 'createdAt', context),
      updatedAt: readUtc(json, 'updatedAt', context),
      tags: readList(
        json,
        'tags',
        context,
        (tag) => tag is String
            ? tag
            : throw const VaultFormatException('Malformed secret tag'),
        optional: true,
      ),
      expiresAt: json.containsKey('expiresAt')
          ? readUtc(json, 'expiresAt', context)
          : null,
      notes: readOptionalField<String>(json, 'notes', context, ''),
      customFields: readList(
        json,
        'customFields',
        context,
        CustomField.fromJson,
        optional: true,
      ),
    );
  }

  /// Stable id (UUID), kept when the secret is moved, copied or imported.
  final String id;

  final String title;

  /// Normalized tags, see [normalizeTags].
  final List<String> tags;

  /// When the secret was created, in UTC. Never changes.
  final DateTime createdAt;

  /// When the secret's content last changed, in UTC.
  final DateTime updatedAt;

  /// When the secret expires (e.g. a certificate or a password rotation
  /// deadline), in UTC.
  final DateTime? expiresAt;

  /// Free-text notes; empty if none.
  final String notes;

  final List<CustomField> customFields;

  /// Trims [tags], drops empty ones and duplicates (ignoring case, keeping the
  /// first spelling), and sorts them ignoring case.
  static List<String> normalizeTags(Iterable<String> tags) {
    final seen = <String>{};
    final result = <String>[];
    for (final tag in tags) {
      final trimmed = tag.trim();
      if (trimmed.isNotEmpty && seen.add(trimmed.toLowerCase())) {
        result.add(trimmed);
      }
    }
    result.sort((a, b) {
      final byLower = a.toLowerCase().compareTo(b.toLowerCase());
      return byLower != 0 ? byLower : a.compareTo(b);
    });
    return List.unmodifiable(result);
  }

  /// Copy with the given fields replaced. Pass `expiresAt: () => null` to
  /// remove the expiry.
  SecretInfo copyWith({
    String? id,
    String? title,
    Iterable<String>? tags,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? Function()? expiresAt,
    String? notes,
    Iterable<CustomField>? customFields,
  }) => SecretInfo(
    id: id ?? this.id,
    title: title ?? this.title,
    tags: tags ?? this.tags,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    expiresAt: expiresAt == null ? this.expiresAt : expiresAt(),
    notes: notes ?? this.notes,
    customFields: customFields ?? this.customFields,
  );

  /// Whether the user-editable fields are equal, ignoring the id and the
  /// timestamps that track the secret's history.
  bool sameContentAs(SecretInfo other) =>
      other.title == title &&
      _listEquality.equals(other.tags, tags) &&
      other.expiresAt == expiresAt &&
      other.notes == notes &&
      _listEquality.equals(other.customFields, customFields);

  /// Common fields of a secret's JSON. Optional fields are omitted when
  /// unset.
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    if (tags.isNotEmpty) 'tags': tags,
    'createdAt': formatUtc(createdAt),
    'updatedAt': formatUtc(updatedAt),
    if (expiresAt case final expiresAt?) 'expiresAt': formatUtc(expiresAt),
    if (notes.isNotEmpty) 'notes': notes,
    if (customFields.isNotEmpty)
      'customFields': [for (final field in customFields) field.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is SecretInfo &&
      other.id == id &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt &&
      sameContentAs(other);

  @override
  int get hashCode => Object.hash(
    id,
    title,
    Object.hashAll(tags),
    createdAt,
    updatedAt,
    expiresAt,
    notes,
    Object.hashAll(customFields),
  );

  /// Only the id: titles, notes and fields may be sensitive.
  @override
  String toString() => 'SecretInfo($id)';
}
