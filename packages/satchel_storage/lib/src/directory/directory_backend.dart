import 'dart:typed_data';

/// Raw file access inside one directory, implemented per platform (`dart:io`
/// on desktop, the Storage Access Framework on Android).
///
/// Backends know nothing about revisions or conflicts:
/// `DirectoryStorageProvider` builds those semantics on top. Names are plain
/// file names (no separators) that the provider has already validated.
abstract interface class DirectoryBackend {
  /// Key identifying the underlying directory. Providers sharing a key
  /// serialize their operations.
  String get lockKey;

  /// Names of the regular files directly inside the directory.
  Future<List<String>> listFileNames();

  /// Contents of [name], or `null` if it does not exist.
  Future<Uint8List?> read(String name);

  /// Creates or replaces [name] with [bytes], as atomically as the platform
  /// allows: a failed write must never leave a truncated file under [name].
  Future<void> write(String name, Uint8List bytes);

  /// Deletes [name]. Does nothing if it does not exist.
  Future<void> delete(String name);
}

/// A directory chosen by the user.
final class PickedDirectory {
  const PickedDirectory({required this.location, required this.name});

  /// Value for `StorageConfig.location`: a filesystem path on desktop, a SAF
  /// tree URI on Android.
  final String location;

  /// Directory name, suitable as a default display name.
  final String name;
}

/// Lets the user choose a directory and manages access to it.
abstract interface class DirectoryPicker {
  /// Shows the platform's directory picker. Returns `null` if cancelled.
  Future<PickedDirectory?> pick();

  /// Gives up long-term access to [location] once no storage uses it.
  Future<void> release(String location);
}
