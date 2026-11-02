import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:satchel_core/satchel_core.dart';

part 'vault_providers.g.dart';

/// Source of the current time for timestamps. Override in tests.
@Riverpod(keepAlive: true)
Clock appClock(Ref ref) => const Clock();

/// Encrypted bytes of a vault and the key they were sealed with.
final class SealedVault {
  const SealedVault({required this.bytes, required this.key});

  final Uint8List bytes;

  /// Destroy once the bytes are written and verified.
  final VaultKey key;
}

/// Derives keys and encrypts vaults with the configured KDF parameters.
final class VaultCrypto {
  const VaultCrypto({
    this.memoryKiB = KdfParams.defaultMemoryKiB,
    this.iterations = KdfParams.defaultIterations,
    this.parallelism = KdfParams.defaultParallelism,
  });

  final int memoryKiB;
  final int iterations;
  final int parallelism;

  /// Derives a new key for [password] (slow by design) and encrypts
  /// [payload] with it.
  Future<SealedVault> seal(VaultPayload payload, String password) async {
    final key = await VaultKey.create(
      password: password,
      memoryKiB: memoryKiB,
      iterations: iterations,
      parallelism: parallelism,
    );
    try {
      return SealedVault(
        bytes: await VaultCodec.encrypt(payload, key),
        key: key,
      );
    } catch (_) {
      key.destroy();
      rethrow;
    }
  }
}

/// Override with cheaper KDF parameters in tests.
@Riverpod(keepAlive: true)
VaultCrypto vaultCrypto(Ref ref) => const VaultCrypto();
