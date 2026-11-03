import 'dart:convert';
import 'dart:typed_data';

import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_core/src/kdf.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('kdfSecret', () {
    test('length-prefixes the password', () {
      expect(KeyDerivation.kdfSecret('pw'), [0, 0, 0, 2, 0x70, 0x77]);
    });
  });

  test(
    'derives the Argon2id known answer (cross-checked with argon2-cffi)',
    () async {
      final key = await KeyDerivation.deriveKey(
        password: 'password',
        params: KdfParams(
          memoryKiB: 47104,
          iterations: 1,
          parallelism: 1,
          salt: List.generate(16, (i) => i),
        ),
      );

      expect(
        _hex(key),
        'b4cb08902958e09fc35212c5268ca4e70a42d005017c6b641f5a26d03fbc20a3',
      );
    },
  );

  group('KdfParams', () {
    test('generates the defaults with a random salt', () {
      final params = KdfParams.generate(random: SequenceRandom([7]));

      expect(params.memoryKiB, 47104);
      expect(params.iterations, 1);
      expect(params.parallelism, 1);
      expect(params.salt, List.filled(16, 7));
      expect(KdfParams.generate().salt, isNot(KdfParams.generate().salt));
    });

    test('round-trips through JSON', () {
      final params = KdfParams.generate();

      expect(KdfParams.fromJson(params.toJson()), params);
    });

    test('rejects unknown algorithms and unsafe values', () {
      Map<String, Object?> json({
        String algorithm = 'argon2id',
        int memoryKiB = 1024,
        int iterations = 1,
        int parallelism = 1,
        List<int>? salt,
      }) => {
        'algorithm': algorithm,
        'memoryKiB': memoryKiB,
        'iterations': iterations,
        'parallelism': parallelism,
        'salt': base64.encode(salt ?? Uint8List(16)),
      };

      expect(KdfParams.fromJson(json()).memoryKiB, 1024);
      for (final bad in [
        json(algorithm: 'scrypt'),
        json(memoryKiB: 4),
        json(memoryKiB: 4 * 1024 * 1024),
        json(iterations: 0),
        json(iterations: 1000),
        json(parallelism: 0),
        json(parallelism: 64),
        json(salt: Uint8List(8)),
        {...json(), 'salt': '%%%'},
        <String, Object?>{},
      ]) {
        expect(
          () => KdfParams.fromJson(bad),
          throwsA(isA<VaultFormatException>()),
          reason: '$bad',
        );
      }
    });
  });
}
