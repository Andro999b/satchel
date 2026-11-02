import 'dart:math';
import 'dart:typed_data';

import 'kdf.dart';

/// A derived vault key together with the parameters that produced it.
///
/// Kept while a vault is unlocked so it can be re-saved (with a fresh nonce)
/// without re-running the slow key derivation. Call [destroy] when locking.
final class VaultKey {
  VaultKey._(this.params, List<String> extraInputIds, this._bytes)
    : extraInputIds = List.unmodifiable(extraInputIds.toList()..sort());

  /// Derives a key for a new vault, or a new password, with a fresh salt.
  static Future<VaultKey> create({
    required String password,
    Map<String, List<int>> extraInputs = const {},
    int memoryKiB = KdfParams.defaultMemoryKiB,
    int iterations = KdfParams.defaultIterations,
    int parallelism = KdfParams.defaultParallelism,
    Random? random,
  }) => derive(
    password: password,
    extraInputs: extraInputs,
    params: KdfParams.generate(
      memoryKiB: memoryKiB,
      iterations: iterations,
      parallelism: parallelism,
      random: random,
    ),
  );

  /// Derives the key for existing [params].
  static Future<VaultKey> derive({
    required String password,
    required KdfParams params,
    Map<String, List<int>> extraInputs = const {},
  }) async {
    final bytes = await KeyDerivation.deriveKey(
      password: password,
      params: params,
      extraInputs: extraInputs,
    );
    return VaultKey._(params, extraInputs.keys.toList(), bytes);
  }

  final KdfParams params;

  /// Ids of the extra inputs mixed into the key, sorted.
  final List<String> extraInputIds;

  final Uint8List _bytes;
  bool _destroyed = false;

  bool get isDestroyed => _destroyed;

  /// The raw key. Throws [StateError] after [destroy].
  Uint8List get bytes {
    if (_destroyed) throw StateError('Vault key was destroyed');
    return _bytes;
  }

  /// Overwrites the key with zeros.
  void destroy() {
    _bytes.fillRange(0, _bytes.length, 0);
    _destroyed = true;
  }

  @override
  String toString() => 'VaultKey(<redacted>, $params)';
}
