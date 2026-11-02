import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'directory_backend.dart';

/// [DirectoryBackend] for a filesystem path, using `dart:io` (desktop).
///
/// Writes go to a hidden temporary file in the same directory that is
/// flushed to disk and then renamed over the target, so the target is always
/// either the old or the new complete contents.
final class IoDirectoryBackend implements DirectoryBackend {
  IoDirectoryBackend(String directoryPath)
    : directoryPath = p.canonicalize(directoryPath);

  final String directoryPath;

  static final _random = Random.secure();

  @override
  String get lockKey => 'file:$directoryPath';

  File _file(String name) => File(p.join(directoryPath, name));

  @override
  Future<List<String>> listFileNames() async => [
    await for (final entity in Directory(
      directoryPath,
    ).list(followLinks: false))
      if (entity is File) p.basename(entity.path),
  ];

  @override
  Future<Uint8List?> read(String name) async {
    try {
      return await _file(name).readAsBytes();
    } on PathNotFoundException {
      return null;
    }
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    final suffix = _random.nextInt(1 << 32).toRadixString(16);
    final temp = _file('.$name.$suffix.tmp');
    try {
      final handle = await temp.open(mode: FileMode.writeOnly);
      try {
        await handle.writeFrom(bytes);
        await handle.flush();
      } finally {
        await handle.close();
      }
      await temp.rename(_file(name).path);
    } catch (_) {
      try {
        await temp.delete();
      } on FileSystemException {
        // Never created or already renamed.
      }
      rethrow;
    }
  }

  @override
  Future<void> delete(String name) async {
    try {
      await _file(name).delete();
    } on PathNotFoundException {
      // Already gone.
    }
  }
}
