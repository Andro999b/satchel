/// Satchel domain model, vault file format, crypto and merge planning.
///
/// Pure Dart: no Flutter and no I/O. Storage and UI layers use only the
/// high-level API exported here.
library;

export 'src/ids.dart';
export 'src/kdf.dart' show KdfParams;
export 'src/merge.dart';
export 'src/password_generator.dart';
export 'src/pin_key_wrap.dart';
export 'src/plain_export.dart';
export 'src/secret.dart';
export 'src/secret_info.dart';
export 'src/vault_codec.dart';
export 'src/vault_exceptions.dart';
export 'src/vault_format.dart';
export 'src/vault_key.dart';
export 'src/vault_payload.dart';
