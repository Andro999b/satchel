import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'file_exporter.dart';

FileExporter createPlatformFileExporter() => const DownloadFileExporter();

/// Saves through the browser's download, which picks the location.
final class DownloadFileExporter implements FileExporter {
  const DownloadFileExporter();

  @override
  Future<String?> save(
    String fileName,
    Uint8List bytes, {
    required String mimeType,
  }) async {
    final blob = web.Blob(
      <JSAny>[bytes.toJS].toJS,
      web.BlobPropertyBag(type: mimeType),
    );
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = fileName
      ..style.display = 'none';
    web.document.body!.append(anchor);
    anchor.click();
    anchor.remove();
    // Some browsers read the URL after click() returns.
    Timer(const Duration(seconds: 10), () => web.URL.revokeObjectURL(url));
    return fileName;
  }
}
