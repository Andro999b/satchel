import 'package:satchel_core/satchel_core.dart';

/// A vault file in a storage, as seen without unlocking it: only its
/// location is known; name, timestamps and secrets are inside the encrypted
/// payload.
final class VaultFile {
  const VaultFile({
    required this.storageId,
    required this.path,
    required this.revision,
  });

  final String storageId;

  /// Provider-relative path, e.g. `personal.satchel`.
  final String path;

  /// Storage revision at the time the file was listed.
  final String revision;

  /// Display name until the vault is unlocked: the path without extension.
  String get name => vaultNameFromPath(path);

  @override
  bool operator ==(Object other) =>
      other is VaultFile &&
      other.storageId == storageId &&
      other.path == path &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(storageId, path, revision);

  @override
  String toString() => 'VaultFile($storageId:$path@$revision)';
}
