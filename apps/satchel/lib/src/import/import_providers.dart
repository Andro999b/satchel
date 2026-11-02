import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:satchel_storage/satchel_storage.dart';

part 'import_providers.g.dart';

/// Picks files to import. Override in tests.
@Riverpod(keepAlive: true)
FileImporter fileImporter(Ref ref) => const FileSelectorImporter();
