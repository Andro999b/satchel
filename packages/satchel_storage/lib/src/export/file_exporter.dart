import 'dart:typed_data';

/// Saves an exported file where the user chooses, outside any storage.
abstract interface class FileExporter {
  /// Lets the user choose where to save [bytes], suggesting [fileName], and
  /// writes them there. Returns the name of the saved file, or `null` if the
  /// user cancelled.
  Future<String?> save(
    String fileName,
    Uint8List bytes, {
    required String mimeType,
  });
}
