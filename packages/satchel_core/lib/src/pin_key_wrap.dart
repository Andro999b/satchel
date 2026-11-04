import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'kdf.dart';
import 'vault_exceptions.dart';
import 'vault_key.dart';

/// Whether [pin] is a valid PIN: [PinKeyWrap.minPinLength] to
/// [PinKeyWrap.maxPinLength] ASCII digits.
bool isValidPin(String pin) => _pinPattern.hasMatch(pin);

final _pinPattern = RegExp(
  '^[0-9]{${PinKeyWrap.minPinLength},${PinKeyWrap.maxPinLength}}\$',
);

/// A vault key encrypted under a PIN and a device secret.
///
/// Serialized with [encode] as JSON with the fields `v` (1), `kdf` (the PIN's
/// KdfParams), `vaultKdf` (the vault key's), `nonce`, and `key` (AES-256-GCM
/// ciphertext + tag), bytes in base64. Every field except `key` is the
/// associated data, so tampering fails unwrapping.
final class PinWrappedKey {
  PinWrappedKey._({
    required this.pinParams,
    required this.vaultParams,
    required this._nonce,
    required this._wrapped,
  });

  static const version = 1;

  /// Argon2id parameters (with a random salt) applied to the PIN.
  final KdfParams pinParams;

  /// The parameters of the wrapped vault key. If a vault file's header has
  /// different ones, its password changed and this key no longer opens it.
  final KdfParams vaultParams;

  final Uint8List _nonce;
  final Uint8List _wrapped;

  String encode() =>
      jsonEncode({..._metadata(), 'key': base64.encode(_wrapped)});

  /// Parses [encode] output. Throws [VaultFormatException].
  static PinWrappedKey decode(String encoded) {
    final Object? json;
    try {
      json = jsonDecode(encoded);
    } on FormatException {
      throw const VaultFormatException('Malformed PIN record');
    }
    if (json case {'v': final int v} when v != version) {
      throw VaultFormatException('Unsupported PIN record version $v');
    }
    if (json case {
      'v': version,
      'kdf': final Object kdf,
      'vaultKdf': final Object vaultKdf,
      'nonce': final String nonce,
      'key': final String key,
    }) {
      final Uint8List nonceBytes;
      final Uint8List keyBytes;
      try {
        nonceBytes = base64.decode(nonce);
        keyBytes = base64.decode(key);
      } on FormatException {
        throw const VaultFormatException('Malformed PIN record');
      }
      if (nonceBytes.length != PinKeyWrap._nonceLength ||
          keyBytes.length != KeyDerivation.keyLength + PinKeyWrap._tagLength) {
        throw const VaultFormatException('Malformed PIN record');
      }
      return PinWrappedKey._(
        pinParams: KdfParams.fromJson(kdf),
        vaultParams: KdfParams.fromJson(vaultKdf),
        nonce: nonceBytes,
        wrapped: keyBytes,
      );
    }
    throw const VaultFormatException('Malformed PIN record');
  }

  Map<String, Object?> _metadata() => {
    'v': version,
    'kdf': pinParams.toJson(),
    'vaultKdf': vaultParams.toJson(),
    'nonce': base64.encode(_nonce),
  };

  Uint8List get _aad => utf8.encode(jsonEncode(_metadata()));

  @override
  String toString() => 'PinWrappedKey(<redacted>, $vaultParams)';
}

/// Encrypts vault keys under a short PIN plus a random device secret.
///
/// A PIN alone has too little entropy, so the wrapping key is
/// HKDF-SHA256(Argon2id(PIN) ‖ device secret). The device secret lives in
/// platform secure storage, so guessing PINs offline needs that device.
abstract final class PinKeyWrap {
  static const minPinLength = 6;
  static const maxPinLength = 8;
  static const deviceSecretLength = 32;

  // OWASP's lighter Argon2id option; the device secret carries the entropy.
  static const defaultMemoryKiB = 19456;
  static const defaultIterations = 2;

  static const _nonceLength = 12;
  static const _tagLength = 16;
  static final _info = utf8.encode('satchel-pin-wrap-v1');
  static final _aesGcm = AesGcm.with256bits();

  /// A fresh random device secret.
  static Uint8List generateDeviceSecret({Random? random}) {
    final rng = random ?? Random.secure();
    return Uint8List.fromList([
      for (var i = 0; i < deviceSecretLength; i++) rng.nextInt(256),
    ]);
  }

  /// Encrypts [key] under [pin] and [deviceSecret].
  ///
  /// Throws [ArgumentError] for an invalid PIN or device secret.
  static Future<PinWrappedKey> wrap(
    VaultKey key, {
    required String pin,
    required Uint8List deviceSecret,
    int memoryKiB = defaultMemoryKiB,
    int iterations = defaultIterations,
    Random? random,
  }) async {
    if (!isValidPin(pin)) throw ArgumentError('Invalid PIN');
    _checkDeviceSecret(deviceSecret);
    final rng = random ?? Random.secure();
    final pinParams = KdfParams.generate(
      memoryKiB: memoryKiB,
      iterations: iterations,
      parallelism: 1,
      random: rng,
    );
    final nonce = Uint8List.fromList([
      for (var i = 0; i < _nonceLength; i++) rng.nextInt(256),
    ]);
    final unsealed = PinWrappedKey._(
      pinParams: pinParams,
      vaultParams: key.params,
      nonce: nonce,
      wrapped: Uint8List(0),
    );
    final wrappingKey = await _wrappingKey(pin, deviceSecret, pinParams);
    try {
      final box = await _aesGcm.encrypt(
        key.bytes,
        secretKey: wrappingKey,
        nonce: nonce,
        aad: unsealed._aad,
      );
      return PinWrappedKey._(
        pinParams: pinParams,
        vaultParams: key.params,
        nonce: nonce,
        wrapped: Uint8List.fromList([...box.cipherText, ...box.mac.bytes]),
      );
    } finally {
      wrappingKey.destroy();
    }
  }

  /// Decrypts the vault key in [wrapped].
  ///
  /// Throws [VaultAuthenticationException] for a wrong PIN or device secret,
  /// or a modified record.
  static Future<VaultKey> unwrap(
    PinWrappedKey wrapped, {
    required String pin,
    required Uint8List deviceSecret,
  }) async {
    if (!isValidPin(pin)) throw const VaultAuthenticationException();
    _checkDeviceSecret(deviceSecret);
    final wrappingKey = await _wrappingKey(
      pin,
      deviceSecret,
      wrapped.pinParams,
    );
    final cipherLength = wrapped._wrapped.length - _tagLength;
    final List<int> keyBytes;
    try {
      keyBytes = await _aesGcm.decrypt(
        SecretBox(
          wrapped._wrapped.sublist(0, cipherLength),
          nonce: wrapped._nonce,
          mac: Mac(wrapped._wrapped.sublist(cipherLength)),
        ),
        secretKey: wrappingKey,
        aad: wrapped._aad,
      );
    } on SecretBoxAuthenticationError {
      throw const VaultAuthenticationException();
    } finally {
      wrappingKey.destroy();
    }
    final bytes = Uint8List.fromList(keyBytes);
    if (keyBytes is Uint8List) keyBytes.fillRange(0, keyBytes.length, 0);
    return VaultKey.fromBytes(wrapped.vaultParams, bytes);
  }

  static Future<SecretKeyData> _wrappingKey(
    String pin,
    Uint8List deviceSecret,
    KdfParams pinParams,
  ) async {
    final pinKey = await KeyDerivation.deriveKey(
      password: pin,
      params: pinParams,
    );
    final ikm = SecretKeyData(
      Uint8List(pinKey.length + deviceSecret.length)
        ..setAll(0, pinKey)
        ..setAll(pinKey.length, deviceSecret),
      overwriteWhenDestroyed: true,
    );
    pinKey.fillRange(0, pinKey.length, 0);
    SecretKey? derived;
    try {
      derived = await Hkdf(
        hmac: Hmac.sha256(),
        outputLength: 32,
      ).deriveKey(secretKey: ikm, nonce: pinParams.salt, info: _info);
      return SecretKeyData(
        Uint8List.fromList(await derived.extractBytes()),
        overwriteWhenDestroyed: true,
      );
    } finally {
      ikm.destroy();
      derived?.destroy();
    }
  }

  static void _checkDeviceSecret(Uint8List deviceSecret) {
    if (deviceSecret.length != deviceSecretLength) {
      throw ArgumentError('Invalid device secret');
    }
  }
}
