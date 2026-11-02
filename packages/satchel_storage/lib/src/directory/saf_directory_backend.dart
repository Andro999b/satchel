import 'dart:math';
import 'dart:typed_data';

import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';

import 'directory_backend.dart';

/// [DirectoryBackend] for an Android Storage Access Framework tree URI
/// (`content://…`), obtained from the system folder picker with a persisted
/// read/write permission.
///
/// SAF has no atomic replace, so a write puts the data in a hidden temporary
/// file first, then deletes the old file and renames the temporary one. If
/// the app dies in between, the new contents survive in the temporary
/// `.<name>.<random>.tmp` file instead of being lost.
final class SafDirectoryBackend implements DirectoryBackend {
  SafDirectoryBackend(this.treeUri, {SafUtil? util, SafStream? stream})
    : _util = util ?? SafUtil(),
      _stream = stream ?? SafStream();

  final String treeUri;
  final SafUtil _util;
  final SafStream _stream;

  static const _mimeType = 'application/octet-stream';
  static final _random = Random.secure();

  @override
  String get lockKey => 'saf:$treeUri';

  @override
  Future<List<String>> listFileNames() async => [
    for (final document in await _util.list(treeUri))
      if (!document.isDir) document.name,
  ];

  @override
  Future<Uint8List?> read(String name) async {
    final document = await _util.child(treeUri, [name]);
    if (document == null || document.isDir) return null;
    return _stream.readFileBytes(document.uri);
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    final suffix = _random.nextInt(1 << 32).toRadixString(16);
    final temp = await _stream.writeFileBytes(
      treeUri,
      '.$name.$suffix.tmp',
      _mimeType,
      bytes,
      overwrite: false,
    );
    final tempUri = temp.uri.toString();
    try {
      final existing = await _util.child(treeUri, [name]);
      if (existing != null) await _util.delete(existing.uri, existing.isDir);
    } catch (_) {
      // The old file is untouched; drop the unused copy.
      await _util.delete(tempUri, false);
      rethrow;
    }
    final renamed = await _util.rename(tempUri, false, name);
    if (renamed.name != name) {
      throw StateError(
        'Storage renamed "$name" to "${renamed.name}"; the data is in '
        '"${renamed.name}"',
      );
    }
  }

  @override
  Future<void> delete(String name) async {
    final document = await _util.child(treeUri, [name]);
    if (document != null) await _util.delete(document.uri, document.isDir);
  }
}

/// Picks and releases SAF tree URIs with persisted read/write permission.
final class SafDirectoryPicker implements DirectoryPicker {
  SafDirectoryPicker({SafUtil? util}) : _util = util ?? SafUtil();

  final SafUtil _util;

  @override
  Future<PickedDirectory?> pick() async {
    final directory = await _util.pickDirectory(
      writePermission: true,
      persistablePermission: true,
    );
    if (directory == null) return null;
    return PickedDirectory(location: directory.uri, name: directory.name);
  }

  @override
  Future<void> release(String location) =>
      _util.releasePersistedPermission(location, read: true, write: true);
}
