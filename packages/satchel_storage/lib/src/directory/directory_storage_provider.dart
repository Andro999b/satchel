import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:satchel_core/satchel_core.dart';

import '../storage_exceptions.dart';
import '../storage_provider.dart';
import 'directory_backend.dart';

/// [StorageProvider] storing each blob as a `*.satchel` file in a
/// user-chosen directory (Android, Linux, Windows).
///
/// The directory may hold other files, and other tools (sync clients, file
/// managers) may change it, so:
/// - only files with [fileExtension] are listed, and paths must be plain file
///   names with that extension;
/// - a blob's revision is the SHA-256 of its contents, recomputed on every
///   access, so external changes are detected as conflicts;
/// - conditional writes and deletes re-read the file right before changing
///   it. Operations of all providers in this app on the same directory are
///   serialized; other processes can still race in the short window between
///   the check and the write.
final class DirectoryStorageProvider implements StorageProvider {
  DirectoryStorageProvider({
    required this.id,
    required this.displayName,
    required this._backend,
  });

  /// Extension of the files this provider manages.
  static const fileExtension = vaultFileExtension;

  static final _locks = <String, Completer<void>>{};

  @override
  final String id;

  @override
  final String displayName;

  final DirectoryBackend _backend;

  /// Whether [path] is a name this provider can store.
  static bool isValidPath(String path) =>
      isVaultFileName(path) && isValidVaultName(vaultNameFromPath(path));

  @override
  Future<List<StorageEntry>> list() => _guarded('', () async {
    final names = [
      for (final name in await _backend.listFileNames())
        if (isValidPath(name)) name,
    ]..sort();
    final entries = <StorageEntry>[];
    for (final name in names) {
      // The file may vanish between listing and reading it.
      final bytes = await _backend.read(name);
      if (bytes != null) {
        entries.add(StorageEntry(path: name, revision: _revision(bytes)));
      }
    }
    return entries;
  });

  @override
  Future<StoredBlob> read(String path) {
    _checkPath(path);
    return _guarded(path, () async {
      final bytes = await _backend.read(path);
      if (bytes == null) throw StorageNotFoundException(path);
      return StoredBlob(
        entry: StorageEntry(path: path, revision: _revision(bytes)),
        bytes: bytes,
      );
    });
  }

  @override
  Future<StorageEntry> write(
    String path,
    Uint8List bytes, {
    required String? expectedRevision,
  }) {
    _checkPath(path);
    final data = Uint8List.fromList(bytes);
    return _guarded(path, () async {
      final current = await _currentRevision(path);
      if (current != expectedRevision) {
        throw StorageConflictException(
          path,
          expectedRevision: expectedRevision,
          actualRevision: current,
        );
      }
      await _backend.write(path, data);
      return StorageEntry(path: path, revision: _revision(data));
    });
  }

  @override
  Future<void> delete(String path, {required String expectedRevision}) {
    _checkPath(path);
    return _guarded(path, () async {
      final current = await _currentRevision(path);
      if (current == null) throw StorageNotFoundException(path);
      if (current != expectedRevision) {
        throw StorageConflictException(
          path,
          expectedRevision: expectedRevision,
          actualRevision: current,
        );
      }
      await _backend.delete(path);
    });
  }

  Future<String?> _currentRevision(String path) async {
    final bytes = await _backend.read(path);
    return bytes == null ? null : _revision(bytes);
  }

  static String _revision(Uint8List bytes) => sha256.convert(bytes).toString();

  static void _checkPath(String path) {
    if (!isValidPath(path)) {
      throw ArgumentError.value(
        path,
        'path',
        'Must be a valid vault name followed by $fileExtension',
      );
    }
  }

  /// Runs [action] exclusively for this directory and maps backend failures
  /// to [StorageBackendException].
  Future<T> _guarded<T>(String path, Future<T> Function() action) async {
    final key = _backend.lockKey;
    final previous = _locks[key];
    final done = Completer<void>();
    _locks[key] = done;
    try {
      await previous?.future;
      return await action();
    } on StorageException {
      rethrow;
    } catch (e) {
      throw StorageBackendException(path, e.toString());
    } finally {
      done.complete();
      if (identical(_locks[key], done)) _locks.remove(key);
    }
  }
}
