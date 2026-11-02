import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../files/vault_files_providers.dart';
import '../storage/storage_providers.dart';
import 'vault_providers.dart';

part 'unlocked_vaults.g.dart';

/// Identifies a vault file: its storage and path.
@immutable
final class VaultRef {
  const VaultRef(this.storageId, this.path);

  final String storageId;
  final String path;

  @override
  bool operator ==(Object other) =>
      other is VaultRef && other.storageId == storageId && other.path == path;

  @override
  int get hashCode => Object.hash(storageId, path);

  @override
  String toString() => 'VaultRef($storageId:$path)';
}

/// A vault file to import needs its password: it isn't encrypted with the
/// key of the file it is imported into.
final class ImportPasswordRequiredException implements Exception {
  const ImportPasswordRequiredException();
}

/// The file to import is neither a vault file nor a plain export.
final class UnsupportedImportException implements Exception {
  const UnsupportedImportException();
}

/// A decrypted vault: its content, the key to save it again, and the storage
/// revision it was read at (for conditional writes).
final class UnlockedVault {
  const UnlockedVault({
    required this.ref,
    required this.payload,
    required this.key,
    required this.revision,
  });

  final VaultRef ref;
  final VaultPayload payload;

  /// Owned by the session: destroyed when the vault is locked.
  final VaultKey key;
  final String revision;

  @override
  String toString() => 'UnlockedVault($ref)';
}

/// The unlocked-vault session: every vault file the user has unlocked.
///
/// This is the only place decrypted vaults and keys live. It is kept alive
/// so unlocked files stay unlocked while their panes are closed; locking a
/// file (or removing its storage, or disposing the app) zeroes its key and
/// drops its content.
@Riverpod(keepAlive: true)
class UnlockedVaults extends _$UnlockedVaults {
  var _vaults = const <VaultRef, UnlockedVault>{};
  final _saving = <VaultRef, Future<void>>{};

  @override
  Map<VaultRef, UnlockedVault> build() {
    ref.onDispose(() => _destroyAll(_vaults.values));
    ref.listen(storageConfigsProvider, (_, next) {
      final ids = next.value?.map((config) => config.id).toSet();
      if (ids == null) return;
      _remove((vault) => !ids.contains(vault.storageId));
    });
    return _vaults;
  }

  void _set(Map<VaultRef, UnlockedVault> vaults) {
    _vaults = Map.unmodifiable(vaults);
    state = _vaults;
  }

  /// Reads the vault [vault] and decrypts it with [password].
  ///
  /// Does nothing if it is already unlocked. Throws the `VaultException`s of
  /// [VaultCodec.decrypt] (e.g. [VaultAuthenticationException] for a wrong
  /// password) and the `StorageException`s of reading the file.
  Future<void> unlock(VaultRef vault, String password) async {
    if (_vaults.containsKey(vault)) return;
    final storage = await _storage(vault.storageId);
    final blob = await storage.read(vault.path);
    final opened = await VaultCodec.decrypt(blob.bytes, password: password);
    adopt(
      vault,
      payload: opened.payload,
      key: opened.key,
      revision: blob.entry.revision,
    );
  }

  /// Adds an already decrypted vault, e.g. one that was just created. Takes
  /// ownership of [key].
  void adopt(
    VaultRef vault, {
    required VaultPayload payload,
    required VaultKey key,
    required String revision,
  }) {
    if (!ref.mounted || _vaults.containsKey(vault)) {
      key.destroy();
      return;
    }
    _set({
      ..._vaults,
      vault: UnlockedVault(
        ref: vault,
        payload: payload,
        key: key,
        revision: revision,
      ),
    });
  }

  /// Adds [secret] to the unlocked vault [vault], or replaces the secret
  /// with its id, and saves the file. See [save].
  Future<void> putSecret(VaultRef vault, Secret secret) => save(
    vault,
    (payload) => payload.withSecret(secret, clock: ref.read(appClockProvider)),
  );

  /// Applies [change] to the content of the unlocked vault [vault] and saves
  /// it: encrypts it with the session key and a fresh nonce, writes it only
  /// if the file is still at the revision this session last read or wrote,
  /// then reads it back and decrypts it to verify.
  ///
  /// Saves of the same vault run one after another. Throws [StateError] if
  /// the vault is locked, [StorageConflictException] if the file was changed
  /// elsewhere, and a `VaultException` if the written file does not verify.
  /// The session only shows the new content once it is safely stored.
  Future<void> save(
    VaultRef vault,
    VaultPayload Function(VaultPayload payload) change,
  ) => _serialized(vault, () => _save(vault, change));

  /// Runs [task] after every earlier write of [vault] has finished.
  Future<T> _serialized<T>(VaultRef vault, Future<T> Function() task) {
    final previous = _saving[vault] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) => task());
    _saving[vault] = next;
    return next.whenComplete(() {
      if (identical(_saving[vault], next)) _saving.remove(vault);
    });
  }

  Future<void> _save(
    VaultRef vault,
    VaultPayload Function(VaultPayload payload) change,
  ) async {
    final current = _vaults[vault];
    if (current == null) throw StateError('Vault is locked');
    final payload = change(current.payload);
    if (identical(payload, current.payload)) return;

    final storage = await _storage(vault.storageId);
    final bytes = await VaultCodec.encrypt(payload, current.key);
    final entry = await storage.write(
      vault.path,
      bytes,
      expectedRevision: current.revision,
    );
    final written = await storage.read(vault.path);
    try {
      await VaultCodec.decryptWithKey(written.bytes, current.key);
    } on VaultException {
      // Keep the previous content, but track the new revision so saving
      // again overwrites the bad copy.
      _replace(current, revision: written.entry.revision);
      rethrow;
    }
    _replace(current, payload: payload, revision: entry.revision);
  }

  /// Renames the unlocked vault [vault] to [name] and returns its new path.
  ///
  /// A move within the storage: writes the renamed vault to the new path,
  /// reads it back to verify, and only then deletes the old file, if it is
  /// still at the session's revision. If any step fails the new copy is
  /// removed and the old file is left as it was. Throws [StateError] if the
  /// vault is locked, [VaultFileExistsException] if the name is taken
  /// (ignoring case), and [StorageConflictException] if the file was changed
  /// elsewhere.
  Future<String> rename(VaultRef vault, String name) =>
      _serialized(vault, () => _rename(vault, name));

  Future<String> _rename(VaultRef vault, String name) async {
    final current = _vaults[vault];
    if (current == null) throw StateError('Vault is locked');
    final path = vaultPathForName(name);
    if (path == vault.path) return path;

    final storage = await _storage(vault.storageId);
    final taken = (await storage.list()).any(
      (entry) =>
          entry.path != vault.path &&
          isVaultFileName(entry.path) &&
          vaultNameFromPath(entry.path).toLowerCase() == name.toLowerCase(),
    );
    if (taken) throw VaultFileExistsException(name);

    final payload = current.payload.withName(
      name,
      clock: ref.read(appClockProvider),
    );
    final bytes = await VaultCodec.encrypt(payload, current.key);
    final StorageEntry entry;
    try {
      entry = await storage.write(path, bytes, expectedRevision: null);
    } on StorageConflictException {
      throw VaultFileExistsException(name);
    }
    try {
      final written = await storage.read(path);
      await VaultCodec.decryptWithKey(written.bytes, current.key);
      try {
        await storage.delete(vault.path, expectedRevision: current.revision);
      } on StorageNotFoundException {
        // Already gone: nothing left to delete.
      }
    } catch (_) {
      try {
        await storage.delete(path, expectedRevision: entry.revision);
      } on Exception catch (e) {
        debugPrint('Could not remove the renamed copy $path: $e');
      }
      rethrow;
    }

    if (ref.mounted && identical(_vaults[vault], current)) {
      final renamed = VaultRef(vault.storageId, path);
      _set({
        for (final e in _vaults.entries)
          if (e.key != vault) e.key: e.value,
        renamed: UnlockedVault(
          ref: renamed,
          payload: payload,
          key: current.key,
          revision: entry.revision,
        ),
      });
    }
    if (ref.mounted) ref.invalidate(vaultFilesProvider(vault.storageId));
    return path;
  }

  /// Re-encrypts the vault [vault] under [newPassword], with a new salt,
  /// after checking [currentPassword] against the stored file.
  ///
  /// Works whether the vault is locked or not, and keeps that state. The
  /// written file is read back to verify; if that fails the original bytes
  /// are put back. Throws the `VaultException`s of [VaultCodec.decrypt]
  /// (e.g. [VaultAuthenticationException] for a wrong current password),
  /// and [StorageConflictException] if the file was changed since it was
  /// unlocked.
  Future<void> changePassword(
    VaultRef vault, {
    required String currentPassword,
    required String newPassword,
  }) => _serialized(
    vault,
    () => _changePassword(vault, currentPassword, newPassword),
  );

  Future<void> _changePassword(
    VaultRef vault,
    String currentPassword,
    String newPassword,
  ) async {
    final storage = await _storage(vault.storageId);
    final blob = await storage.read(vault.path);
    final opened = await VaultCodec.decrypt(
      blob.bytes,
      password: currentPassword,
    );
    SealedVault? sealed;
    try {
      final session = _vaults[vault];
      if (session != null && session.revision != blob.entry.revision) {
        throw StorageConflictException(
          vault.path,
          expectedRevision: session.revision,
          actualRevision: blob.entry.revision,
        );
      }
      sealed = await ref
          .read(vaultCryptoProvider)
          .seal(opened.payload, newPassword);
      final entry = await storage.write(
        vault.path,
        sealed.bytes,
        expectedRevision: blob.entry.revision,
      );
      try {
        final written = await storage.read(vault.path);
        await VaultCodec.decryptWithKey(written.bytes, sealed.key);
      } catch (_) {
        try {
          final restored = await storage.write(
            vault.path,
            blob.bytes,
            expectedRevision: entry.revision,
          );
          // Same content as the session's, so it can keep saving.
          if (session != null) _replace(session, revision: restored.revision);
        } on Exception catch (e) {
          debugPrint('Could not restore ${vault.path}: $e');
        }
        rethrow;
      }

      if (ref.mounted) ref.invalidate(vaultFilesProvider(vault.storageId));
      if (session != null &&
          ref.mounted &&
          identical(_vaults[vault], session)) {
        _set({
          ..._vaults,
          vault: UnlockedVault(
            ref: vault,
            payload: session.payload,
            key: sealed.key,
            revision: entry.revision,
          ),
        });
        session.key.destroy();
        sealed = null;
      }
    } finally {
      opened.key.destroy();
      sealed?.key.destroy();
    }
  }

  /// The unlocked vault [vault] as a standard vault file, with only the
  /// secrets in [secretIds] if given. Encrypted with the session key, or
  /// under [newPassword] with a new salt if given.
  Future<Uint8List> exportEncrypted(
    VaultRef vault, {
    Set<String>? secretIds,
    String? newPassword,
  }) async {
    final payload = _exportPayload(vault, secretIds);
    if (newPassword == null) {
      return VaultCodec.encrypt(payload, _vaults[vault]!.key);
    }
    final sealed = await ref
        .read(vaultCryptoProvider)
        .seal(payload, newPassword);
    sealed.key.destroy();
    return sealed.bytes;
  }

  /// The unlocked vault [vault] as unencrypted JSON, with only the secrets
  /// in [secretIds] if given. The bytes hold secrets: zero them after use.
  Uint8List exportPlain(VaultRef vault, {Set<String>? secretIds}) =>
      PlainExport.encode(_exportPayload(vault, secretIds));

  VaultPayload _exportPayload(VaultRef vault, Set<String>? secretIds) {
    final payload = _vaults[vault]?.payload;
    if (payload == null) throw StateError('Vault is locked');
    return secretIds == null ? payload : payload.withOnlySecrets(secretIds);
  }

  /// Reads the file [fileName] with [bytes] to import into the unlocked
  /// vault [vault], by extension: a plain export (`.json`), or a vault file
  /// (`.satchel`) opened with [vault]'s own key, else with [password].
  ///
  /// Throws [ImportPasswordRequiredException] if a vault file needs a
  /// password, [UnsupportedImportException] for other extensions, and the
  /// `VaultException`s of reading the file (e.g.
  /// [VaultAuthenticationException] for a wrong password).
  Future<VaultPayload> readImport(
    VaultRef vault,
    String fileName,
    Uint8List bytes, {
    String? password,
  }) async {
    final key = _vaults[vault]?.key;
    if (key == null) throw StateError('Vault is locked');
    final name = fileName.toLowerCase();
    if (name.endsWith('.${PlainExport.extension}')) {
      return PlainExport.decode(bytes);
    }
    if (!name.endsWith(vaultFileExtension)) {
      throw const UnsupportedImportException();
    }
    if (password == null) {
      // Exports of this file use its key, so they need no password.
      try {
        return await VaultCodec.decryptWithKey(bytes, key);
      } on VaultAuthenticationException {
        throw const ImportPasswordRequiredException();
      }
    }
    final opened = await VaultCodec.decrypt(bytes, password: password);
    opened.key.destroy();
    return opened.payload;
  }

  /// What importing [incoming] into the unlocked vault [vault] would do.
  MergePlan planImport(VaultRef vault, VaultPayload incoming) {
    final payload = _vaults[vault]?.payload;
    if (payload == null) throw StateError('Vault is locked');
    return planMerge(source: incoming, destination: payload);
  }

  /// Applies [plan] with the user's [resolutions] to the unlocked vault
  /// [vault] and saves it. See [save].
  Future<void> applyImport(
    VaultRef vault,
    MergePlan plan,
    Map<String, ConflictResolution> resolutions,
  ) => save(
    vault,
    (payload) => applyMerge(
      payload,
      plan,
      resolutions,
      clock: ref.read(appClockProvider),
    ),
  );

  /// Updates [current] in the session, unless it was locked meanwhile.
  void _replace(
    UnlockedVault current, {
    VaultPayload? payload,
    required String revision,
  }) {
    if (!ref.mounted || !identical(_vaults[current.ref], current)) return;
    _set({
      ..._vaults,
      current.ref: UnlockedVault(
        ref: current.ref,
        payload: payload ?? current.payload,
        key: current.key,
        revision: revision,
      ),
    });
  }

  /// Locks [vault]: zeroes its key and drops its content.
  void lock(VaultRef vault) => _remove((ref) => ref == vault);

  /// Locks every vault.
  void lockAll() => _remove((_) => true);

  void _remove(bool Function(VaultRef vault) test) {
    final removed = [
      for (final entry in _vaults.entries)
        if (test(entry.key)) entry.value,
    ];
    if (removed.isEmpty) return;
    _destroyAll(removed);
    _set({
      for (final entry in _vaults.entries)
        if (!test(entry.key)) entry.key: entry.value,
    });
  }

  static void _destroyAll(Iterable<UnlockedVault> vaults) {
    for (final vault in vaults) {
      vault.key.destroy();
    }
  }

  /// The storage [storageId], kept alive while it is in use here.
  Future<StorageProvider> _storage(String storageId) async {
    final subscription = ref.listen(
      storageByIdProvider(storageId).future,
      (_, _) {},
    );
    try {
      return await subscription.read();
    } finally {
      subscription.close();
    }
  }
}
