import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:satchel_core/satchel_core.dart';

import '../storage_exceptions.dart';
import '../storage_provider.dart';
import 'google_drive_api.dart';

/// [StorageProvider] keeping each blob as a `*.satchel` file in one Google
/// Drive folder, through the Drive v3 REST API.
///
/// - A blob's revision is `<file id>:<MD5 of the content>`, so it changes
///   with the content, and a recreated file gets a new id. Drive's `version`
///   can't be used: it also rises on server-side changes that leave the
///   content alone, which would turn the next save into a false conflict.
/// - Drive v3 has no conditional writes, so writes and deletes check the
///   current revision right before changing the file. Operations of this
///   app on the same folder are serialized; other devices can still race in
///   the short window between the check and the write.
/// - Drive allows several files with the same name in a folder (e.g. two
///   devices creating one at the same moment). The oldest is used.
/// - Deleting moves the file to the Drive trash.
final class GoogleDriveStorageProvider implements StorageProvider {
  GoogleDriveStorageProvider({
    required this.id,
    required this.displayName,
    required this.folderId,
    required this._api,
  });

  static final _locks = <String, Completer<void>>{};

  @override
  final String id;

  @override
  final String displayName;

  /// The Drive folder holding the vault files.
  final String folderId;

  final GoogleDriveApi _api;

  /// Whether [path] is a name this provider can store.
  static bool isValidPath(String path) =>
      isVaultFileName(path) && isValidVaultName(vaultNameFromPath(path));

  static String _revision(DriveFile file) => '${file.id}:${file.md5Checksum}';

  static String _contentRevision(String fileId, Uint8List bytes) =>
      '$fileId:${md5.convert(bytes)}';

  @override
  Future<List<StorageEntry>> list() => _locked(() async {
    await _checkFolder();
    final seen = <String>{};
    return [
      // Oldest first, so the oldest of files sharing a name wins.
      for (final file in await _api.listFiles(folderId))
        if (isValidPath(file.name) && seen.add(file.name))
          StorageEntry(path: file.name, revision: _revision(file)),
    ];
  });

  @override
  Future<StoredBlob> read(String path) {
    _checkPath(path);
    return _locked(() async {
      final file = await _find(path);
      if (file == null) throw StorageNotFoundException(path);
      final bytes = await _api.download(file.id, path: path);
      // Computed from the bytes themselves, so it always belongs to them.
      return StoredBlob(
        entry: StorageEntry(
          path: path,
          revision: _contentRevision(file.id, bytes),
        ),
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
    return _locked(() async {
      final current = await _find(path);
      final actualRevision = current == null ? null : _revision(current);
      if (actualRevision != expectedRevision) {
        throw StorageConflictException(
          path,
          expectedRevision: expectedRevision,
          actualRevision: actualRevision,
        );
      }
      final written = current == null
          ? await _api.create(folderId, path, data, path: path)
          : await _api.update(current.id, data, path: path);
      return StorageEntry(
        path: path,
        revision: _contentRevision(written.id, data),
      );
    });
  }

  @override
  Future<void> delete(String path, {required String expectedRevision}) {
    _checkPath(path);
    return _locked(() async {
      final current = await _find(path);
      if (current == null) throw StorageNotFoundException(path);
      final actualRevision = _revision(current);
      if (actualRevision != expectedRevision) {
        throw StorageConflictException(
          path,
          expectedRevision: expectedRevision,
          actualRevision: actualRevision,
        );
      }
      await _api.trash(current.id, path: path);
    });
  }

  /// The file at [path]: the oldest one with that name.
  Future<DriveFile?> _find(String path) async =>
      (await _api.listFiles(folderId, name: path)).firstOrNull;

  Future<void> _checkFolder() async {
    if (folderId == driveRootFolderId) return;
    if (await _api.file(folderId) == null) {
      throw const StorageBackendException('', 'The Drive folder is gone');
    }
  }

  static void _checkPath(String path) {
    if (!isValidPath(path)) {
      throw ArgumentError.value(
        path,
        'path',
        'Must be a valid vault name followed by $vaultFileExtension',
      );
    }
  }

  /// Runs [action] exclusively for this folder.
  Future<T> _locked<T>(Future<T> Function() action) async {
    final previous = _locks[folderId];
    final done = Completer<void>();
    _locks[folderId] = done;
    try {
      await previous?.future;
      return await action();
    } finally {
      done.complete();
      if (identical(_locks[folderId], done)) _locks.remove(folderId);
    }
  }
}
