import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'kdf.dart';
import 'vault_exceptions.dart';
import 'vault_format.dart';
import 'vault_key.dart';
import 'vault_payload.dart';

/// A decrypted vault and the key to save it again.
final class OpenedVault {
  const OpenedVault({required this.payload, required this.key});

  final VaultPayload payload;
  final VaultKey key;
}

/// Reads and writes vault files.
///
/// Layout (format version 1):
///
/// ```text
/// magic "SATCHEL\0" (8) | format version (u16 BE) | header length (u32 BE)
/// | header (UTF-8 JSON) | AES-256-GCM ciphertext | tag (16)
/// ```
///
/// Everything before the ciphertext is the AES-GCM associated data, so any
/// change to the version, KDF parameters, flags or nonce fails decryption.
/// The plaintext is the JSON of a [VaultPayload].
abstract final class VaultCodec {
  static final magic = Uint8List.fromList(ascii.encode('SATCHEL\x00'));
  static const cipher = 'aes-256-gcm';
  static const nonceLength = 12;
  static const tagLength = 16;
  static const _prefixLength = 8 + 2 + 4;
  static const _maxHeaderLength = 64 * 1024;

  static final _aesGcm = AesGcm.with256bits();

  /// Encrypts [payload] with [key] and a fresh random nonce.
  static Future<Uint8List> encrypt(
    VaultPayload payload,
    VaultKey key, {
    Random? random,
  }) async {
    final rng = random ?? Random.secure();
    final nonce = Uint8List.fromList([
      for (var i = 0; i < nonceLength; i++) rng.nextInt(256),
    ]);
    final header = utf8.encode(
      jsonEncode({
        'kdf': key.params.toJson(),
        'cipher': cipher,
        'nonce': base64.encode(nonce),
      }),
    );
    final prefix = BytesBuilder()
      ..add(magic)
      ..add(
        (ByteData(
          2,
        )..setUint16(0, currentVaultFormatVersion)).buffer.asUint8List(),
      )
      ..add((ByteData(4)..setUint32(0, header.length)).buffer.asUint8List())
      ..add(header);
    final aad = prefix.takeBytes();

    final plaintext = utf8.encode(jsonEncode(payload.toJson()));
    final secretKey = SecretKeyData(
      Uint8List.fromList(key.bytes),
      overwriteWhenDestroyed: true,
    );
    try {
      final box = await _aesGcm.encrypt(
        plaintext,
        secretKey: secretKey,
        nonce: nonce,
        aad: aad,
      );
      return (BytesBuilder(copy: false)
            ..add(aad)
            ..add(box.cipherText)
            ..add(box.mac.bytes))
          .takeBytes();
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
      secretKey.destroy();
    }
  }

  /// Derives the key from [password] and decrypts [bytes].
  ///
  /// Throws [VaultFormatException], [UnsupportedVaultVersionException], or
  /// [VaultAuthenticationException].
  static Future<OpenedVault> decrypt(
    Uint8List bytes, {
    required String password,
  }) async {
    final parsed = _parse(bytes);
    final key = await VaultKey.derive(
      password: password,
      params: parsed.params,
    );
    try {
      return OpenedVault(payload: await _decryptWith(parsed, key), key: key);
    } catch (_) {
      key.destroy();
      rethrow;
    }
  }

  /// Decrypts [bytes] with an already derived [key], e.g. to verify a write.
  /// The file must use the key's KDF parameters.
  static Future<VaultPayload> decryptWithKey(
    Uint8List bytes,
    VaultKey key,
  ) async {
    final parsed = _parse(bytes);
    if (parsed.params != key.params) {
      throw const VaultAuthenticationException();
    }
    return _decryptWith(parsed, key);
  }

  static Future<VaultPayload> _decryptWith(
    _ParsedVault parsed,
    VaultKey key,
  ) async {
    final secretKey = SecretKeyData(
      Uint8List.fromList(key.bytes),
      overwriteWhenDestroyed: true,
    );
    final List<int> plaintext;
    try {
      plaintext = await _aesGcm.decrypt(
        SecretBox(parsed.cipherText, nonce: parsed.nonce, mac: Mac(parsed.tag)),
        secretKey: secretKey,
        aad: parsed.aad,
      );
    } on SecretBoxAuthenticationError {
      throw const VaultAuthenticationException();
    } finally {
      secretKey.destroy();
    }
    try {
      return VaultPayload.fromJson(jsonDecode(utf8.decode(plaintext)));
    } on FormatException {
      throw const VaultFormatException('Malformed vault payload');
    } finally {
      if (plaintext is Uint8List) plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  static _ParsedVault _parse(Uint8List bytes) {
    if (bytes.length < _prefixLength ||
        !_listEquals(bytes.sublist(0, magic.length), magic)) {
      throw const VaultFormatException('Not a Satchel vault file');
    }
    final data = ByteData.sublistView(bytes);
    final version = data.getUint16(magic.length);
    if (version != currentVaultFormatVersion) {
      throw UnsupportedVaultVersionException(version);
    }
    final headerLength = data.getUint32(magic.length + 2);
    final headerEnd = _prefixLength + headerLength;
    if (headerLength > _maxHeaderLength ||
        headerEnd + tagLength > bytes.length) {
      throw const VaultFormatException('Truncated vault file');
    }

    final Object? header;
    try {
      header = jsonDecode(utf8.decode(bytes.sublist(_prefixLength, headerEnd)));
    } on FormatException {
      throw const VaultFormatException('Malformed vault header');
    }
    if (header case {
      'kdf': final Object kdf,
      'cipher': cipher,
      'nonce': final String nonce,
    }) {
      final Uint8List nonceBytes;
      try {
        nonceBytes = base64.decode(nonce);
      } on FormatException {
        throw const VaultFormatException('Malformed nonce');
      }
      if (nonceBytes.length != nonceLength) {
        throw const VaultFormatException('Invalid nonce length');
      }
      final tagStart = bytes.length - tagLength;
      return _ParsedVault(
        params: KdfParams.fromJson(kdf),
        nonce: nonceBytes,
        aad: bytes.sublist(0, headerEnd),
        cipherText: bytes.sublist(headerEnd, tagStart),
        tag: bytes.sublist(tagStart),
      );
    }
    throw const VaultFormatException('Unsupported vault header');
  }
}

final class _ParsedVault {
  const _ParsedVault({
    required this.params,
    required this.nonce,
    required this.aad,
    required this.cipherText,
    required this.tag,
  });

  final KdfParams params;
  final Uint8List nonce;
  final Uint8List aad;
  final Uint8List cipherText;
  final Uint8List tag;
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
