import 'package:clock/clock.dart';
import 'package:meta/meta.dart';

import 'ids.dart';
import 'json_utils.dart';
import 'secret.dart';
import 'vault_exceptions.dart';

/// The decrypted content of a vault file.
@immutable
final class VaultPayload {
  /// Throws [ArgumentError] if two secrets share an id.
  VaultPayload({
    required this.fileId,
    required this.name,
    required DateTime createdAt,
    required DateTime updatedAt,
    Iterable<Secret> secrets = const [],
  }) : createdAt = utcMillis(createdAt),
       updatedAt = utcMillis(updatedAt),
       secrets = List.unmodifiable(secrets) {
    final ids = <String>{};
    for (final secret in this.secrets) {
      if (!ids.add(secret.id)) {
        throw ArgumentError.value(secret, 'secrets', 'Duplicate secret id');
      }
    }
  }

  /// An empty vault named [name], created now.
  factory VaultPayload.create({
    required String name,
    Clock clock = const Clock(),
  }) {
    final now = clock.now();
    return VaultPayload(
      fileId: newId(),
      name: name,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Schema version of the JSON document, tied to the vault format version.
  static const schemaVersion = 1;

  /// Stable id of the vault, kept across copies, moves and exports.
  final String fileId;

  final String name;

  /// When the vault was created, in UTC. Never changes.
  final DateTime createdAt;

  /// When the content last changed, in UTC.
  final DateTime updatedAt;

  /// Secrets in the order they were added. Ids are unique.
  final List<Secret> secrets;

  /// The secret with [id], or `null`.
  Secret? secretById(String id) =>
      secrets.where((secret) => secret.id == id).firstOrNull;

  /// Adds [secret], or replaces the secret with its id in place, and sets
  /// the file's `updatedAt` to now. Returns this payload if [secret] is
  /// already stored unchanged.
  ///
  /// The secret's own timestamps are kept: stamp edits with
  /// [Secret.applyEdit] first.
  VaultPayload withSecret(Secret secret, {Clock clock = const Clock()}) {
    final index = secrets.indexWhere((s) => s.id == secret.id);
    if (index >= 0 && secrets[index] == secret) return this;
    return _withSecrets(
      index < 0
          ? [...secrets, secret]
          : [
              ...secrets.sublist(0, index),
              secret,
              ...secrets.sublist(index + 1),
            ],
      clock,
    );
  }

  /// Removes the secret with [id] and sets the file's `updatedAt` to now.
  /// Returns this payload if there is no such secret.
  VaultPayload withoutSecret(String id, {Clock clock = const Clock()}) {
    if (secretById(id) == null) return this;
    return _withSecrets([
      for (final secret in secrets)
        if (secret.id != id) secret,
    ], clock);
  }

  /// Renames the vault and sets its `updatedAt` to now. Returns this payload
  /// if [name] is unchanged.
  VaultPayload withName(String name, {Clock clock = const Clock()}) {
    if (name == this.name) return this;
    return VaultPayload(
      fileId: fileId,
      name: name,
      createdAt: createdAt,
      updatedAt: clock.now(),
      secrets: secrets,
    );
  }

  /// This vault with only the secrets whose id is in [ids], e.g. to export
  /// them. Ids, timestamps and order are kept, as nothing was edited.
  VaultPayload withOnlySecrets(Set<String> ids) => VaultPayload(
    fileId: fileId,
    name: name,
    createdAt: createdAt,
    updatedAt: updatedAt,
    secrets: secrets.where((secret) => ids.contains(secret.id)),
  );

  VaultPayload _withSecrets(List<Secret> secrets, Clock clock) => VaultPayload(
    fileId: fileId,
    name: name,
    createdAt: createdAt,
    updatedAt: clock.now(),
    secrets: secrets,
  );

  Map<String, Object?> toJson() => {
    'version': schemaVersion,
    'fileId': fileId,
    'name': name,
    'createdAt': formatUtc(createdAt),
    'updatedAt': formatUtc(updatedAt),
    'secrets': [for (final secret in secrets) secret.toJson()],
  };

  /// Parses [toJson] output. Throws [VaultFormatException] if malformed.
  static VaultPayload fromJson(Object? json) {
    const context = 'vault payload';
    final map = readObject(json, context);
    if (map['version'] != schemaVersion) {
      throw const VaultFormatException('Unsupported vault payload version');
    }
    final secrets = readList(map, 'secrets', context, Secret.fromJson);
    final ids = <String>{};
    if (!secrets.every((secret) => ids.add(secret.id))) {
      throw const VaultFormatException('Duplicate secret id');
    }
    return VaultPayload(
      fileId: readField<String>(map, 'fileId', context),
      name: readField<String>(map, 'name', context),
      createdAt: readUtc(map, 'createdAt', context),
      updatedAt: readUtc(map, 'updatedAt', context),
      secrets: secrets,
    );
  }

  /// Never includes the name or secrets.
  @override
  String toString() => 'VaultPayload($fileId, ${secrets.length} secrets)';
}
