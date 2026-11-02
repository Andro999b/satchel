import 'dart:typed_data';

import 'package:flutter_riverpod/misc.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel/src/storage/storage_config_store.dart';
import 'package:satchel/src/storage/storage_providers.dart';
import 'package:satchel_storage/satchel_storage.dart';

final class MemoryStorageConfigStore implements StorageConfigStore {
  MemoryStorageConfigStore([List<StorageConfig> configs = const []])
    : configs = [...configs];

  List<StorageConfig> configs;

  @override
  Future<List<StorageConfig>> load() async => [...configs];

  @override
  Future<void> save(List<StorageConfig> configs) async {
    this.configs = [...configs];
  }
}

final class FakeDirectoryPicker implements DirectoryPicker {
  PickedDirectory? next;
  Object? error;
  final released = <String>[];

  @override
  Future<PickedDirectory?> pick() async {
    if (error case final error?) throw error;
    return next;
  }

  @override
  Future<void> release(String location) async => released.add(location);
}

/// Hands out [next] instead of asking the user.
final class FakeFileImporter implements FileImporter {
  PickedFile? next;
  Object? error;

  @override
  Future<PickedFile?> pick({
    required String typeLabel,
    required List<String> extensions,
  }) async {
    if (error case final error?) throw error;
    return next;
  }
}

/// Records exported files instead of saving them.
final class FakeFileExporter implements FileExporter {
  final saved = <({String name, Uint8List bytes, String mimeType})>[];

  /// Simulates the user closing the save dialog.
  bool cancel = false;
  Object? error;

  @override
  Future<String?> save(
    String fileName,
    Uint8List bytes, {
    required String mimeType,
  }) async {
    if (error case final error?) throw error;
    if (cancel) return null;
    saved.add((
      name: fileName,
      bytes: Uint8List.fromList(bytes),
      mimeType: mimeType,
    ));
    return fileName;
  }
}

StorageConfig directoryConfig(String id, String location, {String? name}) =>
    StorageConfig(
      id: id,
      kind: StorageProviderKind.directory,
      displayName: name ?? id,
      location: location,
    );

/// Overrides for a fake platform, preference store and picker.
List<Override> storageOverrides({
  required StoragePlatform? platform,
  required StorageConfigStore store,
  DirectoryPicker? picker,
}) => [
  storagePlatformProvider.overrideWithValue(platform),
  storageConfigStoreProvider.overrideWithValue(store),
  directoryPickerProvider.overrideWithValue(picker ?? FakeDirectoryPicker()),
];

/// In-memory [StorageProvider] with the conditional write semantics of the
/// real providers, plus hooks to simulate failures.
final class FakeStorageProvider implements StorageProvider {
  FakeStorageProvider({
    this.id = 'fake',
    this.displayName = 'Fake',
    List<String> paths = const [],
  }) {
    this.paths = paths;
  }

  @override
  final String id;

  @override
  final String displayName;

  final blobs = <String, ({Uint8List bytes, String revision})>{};
  var _revision = 0;

  Object? listError;
  Object? readError;
  Object? writeError;
  Object? deleteError;

  /// Flips a byte of every written blob, like a storage corrupting data.
  bool corruptWrites = false;

  int listCalls = 0;

  List<String> get paths => blobs.keys.toList();

  /// Replaces the content with empty blobs at [paths] (revision `r-<path>`).
  set paths(List<String> paths) {
    blobs
      ..clear()
      ..addAll({
        for (final path in paths)
          path: (bytes: Uint8List(0), revision: 'r-$path'),
      });
  }

  @override
  Future<List<StorageEntry>> list() async {
    listCalls++;
    if (listError case final error?) throw error;
    return [
      for (final MapEntry(:key, :value) in blobs.entries)
        StorageEntry(path: key, revision: value.revision),
    ];
  }

  @override
  Future<StoredBlob> read(String path) async {
    if (readError case final error?) throw error;
    final blob = blobs[path];
    if (blob == null) throw StorageNotFoundException(path);
    return StoredBlob(
      entry: StorageEntry(path: path, revision: blob.revision),
      bytes: Uint8List.fromList(blob.bytes),
    );
  }

  @override
  Future<StorageEntry> write(
    String path,
    Uint8List bytes, {
    required String? expectedRevision,
  }) async {
    if (writeError case final error?) throw error;
    final current = blobs[path]?.revision;
    if (current != expectedRevision) {
      throw StorageConflictException(
        path,
        expectedRevision: expectedRevision,
        actualRevision: current,
      );
    }
    final stored = Uint8List.fromList(bytes);
    if (corruptWrites) stored[stored.length - 1] ^= 1;
    final revision = 'w${++_revision}';
    blobs[path] = (bytes: stored, revision: revision);
    return StorageEntry(path: path, revision: revision);
  }

  @override
  Future<void> delete(String path, {required String expectedRevision}) async {
    if (deleteError case final error?) throw error;
    final current = blobs[path]?.revision;
    if (current == null) throw StorageNotFoundException(path);
    if (current != expectedRevision) {
      throw StorageConflictException(
        path,
        expectedRevision: expectedRevision,
        actualRevision: current,
      );
    }
    blobs.remove(path);
  }
}

/// Encrypts a vault with [secrets] under [password] (cheap KDF parameters)
/// and stores it at [path] in [storage].
Future<void> putVault(
  FakeStorageProvider storage,
  String path,
  String password, {
  List<Secret> secrets = const [],
}) async {
  final key = await VaultKey.create(password: password, memoryKiB: 64);
  try {
    final payload = VaultPayload(
      fileId: newId(),
      name: vaultNameFromPath(path),
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      secrets: secrets,
    );
    await storage.write(
      path,
      await VaultCodec.encrypt(payload, key),
      expectedRevision: null,
    );
  } finally {
    key.destroy();
  }
}
