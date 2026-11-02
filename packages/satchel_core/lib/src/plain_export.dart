import 'dart:convert';
import 'dart:typed_data';

import 'json_utils.dart';
import 'vault_exceptions.dart';
import 'vault_payload.dart';

/// Unencrypted exports: a JSON document holding a [VaultPayload].
///
/// The only plaintext format Satchel writes. Callers must have the user
/// confirm before writing one anywhere.
abstract final class PlainExport {
  /// File extension of plain exports, without the dot.
  static const extension = 'json';

  static const mimeType = 'application/json';

  /// Version of the export document.
  static const formatVersion = 1;

  /// [payload] as indented UTF-8 JSON. Holds secrets: zero it after use.
  static Uint8List encode(VaultPayload payload) => utf8.encode(
    const JsonEncoder.withIndent('  ')
        .convert({'satchelExport': formatVersion, 'vault': payload.toJson()}),
  );

  /// Parses [encode] output. Throws [VaultFormatException] if it isn't a
  /// Satchel export, or [UnsupportedVaultVersionException] if it is newer.
  static VaultPayload decode(List<int> bytes) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const VaultFormatException('Not a JSON document');
    }
    final document = readObject(json, 'export');
    final version = readField<int>(document, 'satchelExport', 'export');
    if (version > formatVersion) {
      throw UnsupportedVaultVersionException(version);
    }
    if (version < 1) throw const VaultFormatException('Malformed export');
    return VaultPayload.fromJson(document['vault']);
  }
}
