import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:satchel_storage/satchel_storage.dart';

part 'export_providers.g.dart';

/// Saves exported files on this platform. Override in tests.
@Riverpod(keepAlive: true)
FileExporter fileExporter(Ref ref) => createPlatformFileExporter();
