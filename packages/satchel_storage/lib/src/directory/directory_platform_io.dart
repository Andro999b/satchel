import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import 'directory_backend.dart';
import 'io_directory_backend.dart';
import 'saf_directory_backend.dart';

/// Backend for a `StorageConfig.location`: SAF for Android `content://` tree
/// URIs, `dart:io` for filesystem paths.
DirectoryBackend directoryBackendFor(String location) =>
    location.startsWith('content://')
    ? SafDirectoryBackend(location)
    : IoDirectoryBackend(location);

/// The directory picker for this platform.
DirectoryPicker createPlatformDirectoryPicker() =>
    Platform.isAndroid ? SafDirectoryPicker() : FileSelectorDirectoryPicker();

/// Desktop directory picker using the native dialog. Filesystem paths need no
/// long-term permission, so [release] does nothing.
final class FileSelectorDirectoryPicker implements DirectoryPicker {
  @override
  Future<PickedDirectory?> pick() async {
    final path = await getDirectoryPath(confirmButtonText: 'Use folder');
    if (path == null) return null;
    return PickedDirectory(location: path, name: p.basename(path));
  }

  @override
  Future<void> release(String location) async {}
}
