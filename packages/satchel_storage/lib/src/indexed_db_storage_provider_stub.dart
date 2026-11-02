import 'dart:typed_data';

import 'storage_provider.dart';

/// Non-web stand-in for the IndexedDB provider. IndexedDB exists only in
/// browsers: construction succeeds so configuration code stays
/// platform-agnostic, but every operation throws [UnsupportedError]. Check
/// `StorageProviderKind.indexedDb.isSupported` before offering it.
final class IndexedDbStorageProvider implements StorageProvider {
  IndexedDbStorageProvider({
    required this.id,
    required this.displayName,
    String? databaseName,
  }) : databaseName = databaseName ?? databaseNameFor(id);

  static String databaseNameFor(String id) => 'satchel_storage.$id';

  @override
  final String id;

  @override
  final String displayName;

  final String databaseName;

  @override
  Future<List<StorageEntry>> list() => _unsupported();

  @override
  Future<StoredBlob> read(String path) => _unsupported();

  @override
  Future<StorageEntry> write(
    String path,
    Uint8List bytes, {
    required String? expectedRevision,
  }) => _unsupported();

  @override
  Future<void> delete(String path, {required String expectedRevision}) =>
      _unsupported();

  Future<void> close() async {}

  Future<Never> _unsupported() async =>
      throw UnsupportedError('IndexedDB storage is only available on web');
}
