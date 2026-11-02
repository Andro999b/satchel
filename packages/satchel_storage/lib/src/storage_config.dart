import 'package:flutter/foundation.dart';

import 'storage_provider_kind.dart';

/// Non-secret settings of one configured storage: which [kind] it is, its
/// user-facing name and, for kinds that need one, its [location].
///
/// Safe to persist in plain app preferences: it never contains passwords,
/// keys or vault contents.
@immutable
final class StorageConfig {
  const StorageConfig({
    required this.id,
    required this.kind,
    required this.displayName,
    this.location,
  });

  /// Parses [toJson] output. Throws [FormatException] on malformed input or
  /// an unknown kind.
  factory StorageConfig.fromJson(Map<String, Object?> json) {
    if (json case {
      'id': final String id,
      'kind': final String kindName,
      'displayName': final String displayName,
    }) {
      final location = json['location'];
      if (location is! String?) {
        throw const FormatException('Storage location must be a string');
      }
      final kind = StorageProviderKind.values.asNameMap()[kindName];
      if (kind == null) {
        throw FormatException('Unknown storage kind', kindName);
      }
      return StorageConfig(
        id: id,
        kind: kind,
        displayName: displayName,
        location: location,
      );
    }
    throw const FormatException('Malformed storage config');
  }

  /// Stable identifier, also used as the provider id.
  final String id;

  final StorageProviderKind kind;

  final String displayName;

  /// Kind-specific location, e.g. a directory path or an Android SAF tree
  /// URI. `null` for kinds that don't need one.
  final String? location;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'displayName': displayName,
    if (location != null) 'location': location,
  };

  @override
  bool operator ==(Object other) =>
      other is StorageConfig &&
      other.id == id &&
      other.kind == kind &&
      other.displayName == displayName &&
      other.location == location;

  @override
  int get hashCode => Object.hash(id, kind, displayName, location);

  @override
  String toString() => 'StorageConfig($id, ${kind.name}, $displayName)';
}
