import 'dart:typed_data';

/// Metadata of a blob stored by a [StorageProvider].
final class StorageEntry {
  const StorageEntry({required this.path, required this.revision});

  /// Provider-relative path of the blob.
  final String path;

  /// Opaque revision token (etag, Drive revision id, counter, ...). Changes on
  /// every write and is used for optimistic concurrency.
  final String revision;

  @override
  bool operator ==(Object other) =>
      other is StorageEntry && other.path == path && other.revision == revision;

  @override
  int get hashCode => Object.hash(path, revision);

  @override
  String toString() => 'StorageEntry($path@$revision)';
}

/// An encrypted blob together with the revision it was read at.
final class StoredBlob {
  const StoredBlob({required this.entry, required this.bytes});

  final StorageEntry entry;

  /// Encrypted bytes. Never plaintext.
  final Uint8List bytes;
}

/// A configured storage location (local disk, Google Drive, ...).
///
/// Implementations deal with opaque encrypted bytes only. Writes and deletes
/// are conditional on the caller's last known revision so concurrent changes
/// surface as a [StorageConflictException] instead of being overwritten.
abstract interface class StorageProvider {
  /// Stable identifier of this configured provider.
  String get id;

  /// User-facing name, e.g. "Google Drive – personal".
  String get displayName;

  Future<List<StorageEntry>> list();

  /// Throws [StorageNotFoundException] if [path] does not exist.
  Future<StoredBlob> read(String path);

  /// Writes [bytes] to [path].
  ///
  /// [expectedRevision] must be the revision last read, or `null` to create a
  /// new blob. Throws [StorageConflictException] if the current state differs.
  Future<StorageEntry> write(
    String path,
    Uint8List bytes, {
    required String? expectedRevision,
  });

  /// Deletes [path] if it is still at [expectedRevision].
  ///
  /// Throws [StorageNotFoundException] or [StorageConflictException].
  Future<void> delete(String path, {required String expectedRevision});
}
