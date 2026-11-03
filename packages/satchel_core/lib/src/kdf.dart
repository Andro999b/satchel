import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';

import 'vault_exceptions.dart';

/// Argon2id parameters of a vault file, stored in its header.
@immutable
final class KdfParams {
  KdfParams({
    required this.memoryKiB,
    required this.iterations,
    required this.parallelism,
    required List<int> salt,
  }) : salt = Uint8List.fromList(salt);

  /// Fresh parameters with a random salt. The defaults follow OWASP's
  /// Argon2id recommendation (46 MiB, 1 pass, 1 lane): about one second in a
  /// browser, the slowest platform every file must open on.
  factory KdfParams.generate({
    int memoryKiB = defaultMemoryKiB,
    int iterations = defaultIterations,
    int parallelism = defaultParallelism,
    Random? random,
  }) {
    final rng = random ?? Random.secure();
    return KdfParams(
      memoryKiB: memoryKiB,
      iterations: iterations,
      parallelism: parallelism,
      salt: [for (var i = 0; i < saltLength; i++) rng.nextInt(256)],
    )..validate();
  }

  static const algorithm = 'argon2id';
  static const defaultMemoryKiB = 47104;
  static const defaultIterations = 1;
  static const defaultParallelism = 1;
  static const saltLength = 16;

  // Bounds accepted when reading a file, so a crafted header can't make the
  // app allocate unbounded memory or spin forever.
  static const maxMemoryKiB = 128 * 1024;
  static const maxIterations = 64;
  static const maxParallelism = 16;

  final int memoryKiB;
  final int iterations;
  final int parallelism;
  final Uint8List salt;

  /// Throws [VaultFormatException] if the parameters are out of bounds.
  void validate() {
    if (parallelism < 1 || parallelism > maxParallelism) {
      throw VaultFormatException('Invalid Argon2 parallelism $parallelism');
    }
    if (iterations < 1 || iterations > maxIterations) {
      throw VaultFormatException('Invalid Argon2 iterations $iterations');
    }
    if (memoryKiB < 8 * parallelism || memoryKiB > maxMemoryKiB) {
      throw VaultFormatException('Invalid Argon2 memory $memoryKiB KiB');
    }
    if (salt.length < saltLength) {
      throw const VaultFormatException('Argon2 salt is too short');
    }
  }

  Map<String, Object?> toJson() => {
    'algorithm': algorithm,
    'memoryKiB': memoryKiB,
    'iterations': iterations,
    'parallelism': parallelism,
    'salt': base64.encode(salt),
  };

  /// Parses and validates [toJson] output.
  static KdfParams fromJson(Object? json) {
    if (json case {
      'algorithm': algorithm,
      'memoryKiB': final int memoryKiB,
      'iterations': final int iterations,
      'parallelism': final int parallelism,
      'salt': final String salt,
    }) {
      final Uint8List saltBytes;
      try {
        saltBytes = base64.decode(salt);
      } on FormatException {
        throw const VaultFormatException('Malformed Argon2 salt');
      }
      return KdfParams(
        memoryKiB: memoryKiB,
        iterations: iterations,
        parallelism: parallelism,
        salt: saltBytes,
      )..validate();
    }
    throw const VaultFormatException('Unsupported key derivation parameters');
  }

  @override
  bool operator ==(Object other) =>
      other is KdfParams &&
      other.memoryKiB == memoryKiB &&
      other.iterations == iterations &&
      other.parallelism == parallelism &&
      _bytesEqual(other.salt, salt);

  @override
  int get hashCode =>
      Object.hash(memoryKiB, iterations, parallelism, Object.hashAll(salt));

  @override
  String toString() =>
      'KdfParams(argon2id, m=$memoryKiB KiB, t=$iterations, p=$parallelism)';
}

/// Derives vault keys from a password.
abstract final class KeyDerivation {
  static const keyLength = 32;

  /// Runs Argon2id over [password].
  ///
  /// The returned buffer holds key material: zero it after use.
  static Future<Uint8List> deriveKey({
    required String password,
    required KdfParams params,
  }) async {
    final secret = kdfSecret(password);
    final secretKey = SecretKeyData(secret, overwriteWhenDestroyed: true);
    SecretKey? derived;
    try {
      derived = await Argon2id(
        memory: params.memoryKiB,
        iterations: params.iterations,
        parallelism: params.parallelism,
        hashLength: keyLength,
      ).deriveKey(secretKey: secretKey, nonce: params.salt);
      return Uint8List.fromList(await derived.extractBytes());
    } finally {
      secretKey.destroy();
      derived?.destroy();
    }
  }

  /// The Argon2id input: the UTF-8 password, prefixed with its 4-byte
  /// big-endian length.
  ///
  /// Holds the password: zero it after use.
  @visibleForTesting
  static Uint8List kdfSecret(String password) {
    final builder = BytesBuilder();
    final pwBytes = utf8.encode(password);
    builder
      ..add((ByteData(4)..setUint32(0, pwBytes.length)).buffer.asUint8List())
      ..add(pwBytes);
    final secret = builder.takeBytes();
    // The UTF-8 copy of the password is no longer needed.
    pwBytes.fillRange(0, pwBytes.length, 0);
    return secret;
  }
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
