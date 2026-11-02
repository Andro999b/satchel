import 'package:satchel_core/satchel_core.dart';

import 'secret_fixtures.dart';
import 'test_utils.dart';

/// Inputs of a committed golden vault file. Encrypting [payload] with these
/// inputs must reproduce the file byte for byte.
final class GoldenVault {
  GoldenVault({
    required this.file,
    required this.password,
    required this.params,
    required this.nonce,
    required this.payload,
    this.extraInputs = const {},
  });

  final String file;
  final String password;
  final KdfParams params;
  final List<int> nonce;
  final VaultPayload payload;
  final Map<String, List<int>> extraInputs;

  SequenceRandom nonceRandom() => SequenceRandom(nonce);
}

/// Format version 1 goldens. Never regenerate them: they pin the format.
/// Small KDF parameters keep the tests fast.
final v1Goldens = [
  GoldenVault(
    file: 'basic.satchel',
    password: 'pässwörd 🔑',
    params: KdfParams(
      memoryKiB: 1024,
      iterations: 2,
      parallelism: 1,
      salt: List.generate(16, (i) => i),
    ),
    nonce: List.generate(12, (i) => 0xa0 + i),
    payload: VaultPayload(
      fileId: '0b6f4a2e-6d3c-4f4e-9a51-2f0e8c1d7b42',
      name: 'Personal',
      createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5, 678),
      updatedAt: DateTime.utc(2026, 11, 2, 10, 0),
    ),
  ),
  GoldenVault(
    file: 'extra_input.satchel',
    password: 'correct horse battery staple',
    params: KdfParams(
      memoryKiB: 1024,
      iterations: 1,
      parallelism: 2,
      salt: List.generate(16, (i) => 0xf0 - i),
    ),
    nonce: List.generate(12, (i) => i * 7),
    extraInputs: {'keyfile': List.generate(32, (i) => 255 - i)},
    payload: VaultPayload(
      fileId: 'c5a1e7d0-3b8f-4c2a-8e6d-1f9b0a4c3d21',
      name: 'Work',
      createdAt: DateTime.utc(2026, 11, 2, 10, 0),
      updatedAt: DateTime.utc(2026, 11, 2, 10, 0),
    ),
  ),
  GoldenVault(
    file: 'secrets.satchel',
    password: 'golden secrets',
    params: KdfParams(
      memoryKiB: 1024,
      iterations: 1,
      parallelism: 1,
      salt: List.generate(16, (i) => i * 3),
    ),
    nonce: List.generate(12, (i) => 0x30 + i),
    payload: VaultPayload(
      fileId: 'e2d4c6b8-1a3f-4e5d-9c7b-0f2e4d6c8a1b',
      name: 'Everything',
      createdAt: DateTime.utc(2026, 3, 1, 9, 30),
      updatedAt: DateTime.utc(2026, 11, 2, 11, 0),
      secrets: allSecretTypes,
    ),
  ),
];
