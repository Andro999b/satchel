import 'package:flutter/foundation.dart';

import 'storage_provider_kind.dart';

/// Non-secret settings of one configured storage: which [kind] it is, its
/// user-facing name and, for kinds that need them, its [location] and
/// [accountId].
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
    this.locationName,
    this.accountId,
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
      final locationName = json['locationName'];
      final accountId = json['accountId'];
      if (location is! String? ||
          locationName is! String? ||
          accountId is! String?) {
        throw const FormatException('Storage settings must be strings');
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
        locationName: locationName,
        accountId: accountId,
      );
    }
    throw const FormatException('Malformed storage config');
  }

  /// Stable identifier, also used as the provider id.
  final String id;

  final StorageProviderKind kind;

  final String displayName;

  /// Kind-specific location, e.g. a directory path, an Android SAF tree URI
  /// or a Drive folder id. `null` for kinds that don't need one.
  final String? location;

  /// Human-readable [location] for kinds whose location is an opaque id,
  /// e.g. "My Drive / Satchel".
  final String? locationName;

  /// Account the storage belongs to, e.g. the `GoogleAccount.id` of a Drive
  /// storage.
  final String? accountId;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'displayName': displayName,
    if (location != null) 'location': location,
    if (locationName != null) 'locationName': locationName,
    if (accountId != null) 'accountId': accountId,
  };

  @override
  bool operator ==(Object other) =>
      other is StorageConfig &&
      other.id == id &&
      other.kind == kind &&
      other.displayName == displayName &&
      other.location == location &&
      other.locationName == locationName &&
      other.accountId == accountId;

  @override
  int get hashCode =>
      Object.hash(id, kind, displayName, location, locationName, accountId);

  @override
  String toString() => 'StorageConfig($id, ${kind.name}, $displayName)';
}
