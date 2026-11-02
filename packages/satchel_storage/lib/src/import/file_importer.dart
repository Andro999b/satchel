import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

/// A file the user picked: its name and contents.
final class PickedFile {
  const PickedFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// Opens a file from outside any storage, e.g. to import it.
abstract interface class FileImporter {
  /// Lets the user pick a vault file or plain export, offering files with
  /// [extensions] (without dots) under [typeLabel]. Returns `null` if the
  /// user cancelled.
  Future<PickedFile?> pick({
    required String typeLabel,
    required List<String> extensions,
  });
}

/// [FileImporter] using the platform's file picker, on every platform.
final class FileSelectorImporter implements FileImporter {
  const FileSelectorImporter();

  @override
  Future<PickedFile?> pick({
    required String typeLabel,
    required List<String> extensions,
  }) async {
    // Android filters by MIME type, which it doesn't know for ".satchel".
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final file = await openFile(
      acceptedTypeGroups: [
        if (!android) XTypeGroup(label: typeLabel, extensions: extensions),
      ],
    );
    if (file == null) return null;
    return PickedFile(name: file.name, bytes: await file.readAsBytes());
  }
}
