import 'file_exporter.dart';

/// No file system or browser to save to.
FileExporter createPlatformFileExporter() =>
    throw UnsupportedError('Exporting files is not available here');
