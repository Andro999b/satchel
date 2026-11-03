import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../storage/storage_providers.dart';
import '../vault/unlocked_vaults.dart';
import '../vault/vault_providers.dart';
import 'vault_file.dart';

part 'vault_files_providers.g.dart';

/// Thrown when a storage id doesn't match any configured storage, e.g. after
/// the storage was removed.
final class UnknownStorageException implements Exception {
  const UnknownStorageException(this.storageId);

  final String storageId;

  @override
  String toString() => 'UnknownStorageException: $storageId';
}

/// A vault file with this name (ignoring case) already exists.
final class VaultFileExistsException implements Exception {
  const VaultFileExistsException(this.name, {this.existing});

  final String name;

  /// The file in the way, when known (e.g. the target of a copy).
  final VaultFile? existing;

  @override
  String toString() => 'VaultFileExistsException: $name';
}

/// A copied file did not read back with the bytes that were written.
final class CopyVerificationException implements Exception {
  const CopyVerificationException(this.path);

  final String path;

  @override
  String toString() => 'CopyVerificationException: $path';
}

/// Storage reads are not retried automatically: failures such as a revoked
/// folder permission won't fix themselves, and the UI offers a retry.
Duration? _noRetry(int retryCount, Object error) => null;

/// The configured storage with [storageId].
@Riverpod(retry: _noRetry)
Future<StorageProvider> storageById(Ref ref, String storageId) async {
  final storages = await ref.watch(storageProvidersProvider.future);
  for (final storage in storages) {
    if (storage.id == storageId) return storage;
  }
  throw UnknownStorageException(storageId);
}

/// Vault files in the storage [storageId], sorted by name. Invalidate to
/// re-read the storage.
@Riverpod(retry: _noRetry)
class VaultFiles extends _$VaultFiles {
  @override
  Future<List<VaultFile>> build(String storageId) async {
    final storage = await ref.watch(storageByIdProvider(storageId).future);
    return _vaultFiles(storageId, await storage.list());
  }

  /// Creates an empty vault named [name] protected by [password] and adds
  /// it to the session unlocked.
  ///
  /// The written file is read back and decrypted before this returns, so a
  /// storage that corrupts data is caught right away. Throws
  /// [VaultFileExistsException] if the name is taken (ignoring case, as
  /// many file systems do).
  Future<VaultFile> create({
    required String name,
    required String password,
  }) async {
    final path = vaultPathForName(name);
    final storage = await ref.read(storageByIdProvider(storageId).future);
    final taken = _vaultFiles(
      storageId,
      await storage.list(),
    ).any((file) => file.name.toLowerCase() == name.toLowerCase());
    if (taken) throw VaultFileExistsException(name);

    final payload = VaultPayload.create(
      name: name,
      clock: ref.read(appClockProvider),
    );
    final sealed = await ref.read(vaultCryptoProvider).seal(payload, password);
    var adopted = false;
    try {
      final StorageEntry entry;
      try {
        entry = await storage.write(path, sealed.bytes, expectedRevision: null);
      } on StorageConflictException {
        throw VaultFileExistsException(name);
      }
      final written = await storage.read(path);
      try {
        await VaultCodec.decryptWithKey(written.bytes, sealed.key);
      } on VaultException {
        await _deleteQuietly(storage, path, written.entry.revision);
        rethrow;
      }
      // The user just chose the password: open the new vault unlocked.
      ref
          .read(unlockedVaultsProvider.notifier)
          .adopt(
            VaultRef(storageId, path),
            payload: payload,
            key: sealed.key,
            revision: entry.revision,
          );
      adopted = true;
      if (ref.mounted) ref.invalidateSelf();
      return VaultFile(
        storageId: storageId,
        path: path,
        revision: entry.revision,
      );
    } finally {
      if (!adopted) sealed.key.destroy();
    }
  }

  /// Deletes [file] from the storage and locks it.
  ///
  /// The delete only happens if the file is still at the revision it was
  /// listed with: if another app or tab changed it since, this throws
  /// [StorageConflictException] (and refreshes the list) instead. A file that
  /// is already gone counts as deleted.
  Future<void> delete(VaultFile file) async {
    final storage = await ref.read(storageByIdProvider(storageId).future);
    try {
      await storage.delete(file.path, expectedRevision: file.revision);
    } on StorageNotFoundException {
      // Already gone: nothing left to delete.
    } on StorageConflictException {
      if (ref.mounted) ref.invalidateSelf();
      rethrow;
    }
    ref
        .read(unlockedVaultsProvider.notifier)
        .lock(VaultRef(storageId, file.path));
    if (ref.mounted) ref.invalidateSelf();
  }

  static Future<void> _deleteQuietly(
    StorageProvider storage,
    String path,
    String revision,
  ) async {
    try {
      await storage.delete(path, expectedRevision: revision);
    } on Exception catch (e) {
      debugPrint('Could not remove unverified vault $path: $e');
    }
  }
}

List<VaultFile> _vaultFiles(String storageId, List<StorageEntry> entries) =>
    [
      for (final entry in entries)
        if (isVaultFileName(entry.path))
          VaultFile(
            storageId: storageId,
            path: entry.path,
            revision: entry.revision,
          ),
    ]..sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.path.compareTo(b.path);
    });
