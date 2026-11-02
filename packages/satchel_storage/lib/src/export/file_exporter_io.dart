import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';

import 'file_exporter.dart';

FileExporter createPlatformFileExporter() =>
    Platform.isAndroid ? SafFileExporter() : SaveDialogFileExporter();

/// Desktop: the native save dialog, then a plain file write.
final class SaveDialogFileExporter implements FileExporter {
  @override
  Future<String?> save(
    String fileName,
    Uint8List bytes, {
    required String mimeType,
  }) async {
    final location = await getSaveLocation(suggestedName: fileName);
    if (location == null) return null;
    await File(location.path).writeAsBytes(bytes, flush: true);
    return p.basename(location.path);
  }
}

/// Android: the user picks a folder, and the file is created in it. SAF
/// picks another name if [fileName] is taken, so nothing is overwritten.
final class SafFileExporter implements FileExporter {
  SafFileExporter({SafUtil? util, SafStream? stream})
    : _util = util ?? SafUtil(),
      _stream = stream ?? SafStream();

  final SafUtil _util;
  final SafStream _stream;

  @override
  Future<String?> save(
    String fileName,
    Uint8List bytes, {
    required String mimeType,
  }) async {
    final directory = await _util.pickDirectory(
      writePermission: true,
      persistablePermission: false,
    );
    if (directory == null) return null;
    final file = await _stream.writeFileBytes(
      directory.uri,
      fileName,
      mimeType,
      bytes,
      overwrite: false,
    );
    return file.fileName ?? fileName;
  }
}
