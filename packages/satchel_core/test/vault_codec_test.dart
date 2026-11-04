import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:satchel_core/satchel_core.dart';
import 'package:test/test.dart';

import 'golden_inputs.dart';

// Small parameters keep the tests fast; the defaults are covered in
// kdf_test.dart.
Future<VaultKey> _key(String password) =>
    VaultKey.create(password: password, memoryKiB: 64);

VaultPayload _payload() => VaultPayload(
  fileId: 'f1',
  name: 'Personal',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026, 6),
);

/// Replaces [from] with [to] (same length) in the header of [bytes].
Uint8List _patch(Uint8List bytes, String from, String to) {
  expect(from.length, to.length);
  final text = latin1.decode(bytes);
  final index = text.indexOf(from);
  expect(index, isNonNegative, reason: 'header contains $from');
  return Uint8List.fromList(bytes)..setAll(index, latin1.encode(to));
}

void main() {
  group('golden files (format version 1)', () {
    for (final golden in v1Goldens) {
      final bytes = File('test/golden/v1/${golden.file}').readAsBytesSync();

      test('${golden.file} decrypts', () async {
        final opened = await VaultCodec.decrypt(
          bytes,
          password: golden.password,
        );

        expect(opened.payload.toJson(), golden.payload.toJson());
        expect(opened.key.params, golden.params);
      });

      test('${golden.file} is reproduced exactly (known answer)', () async {
        final key = await VaultKey.derive(
          password: golden.password,
          params: golden.params,
        );

        final encrypted = await VaultCodec.encrypt(
          golden.payload,
          key,
          random: golden.nonceRandom(),
        );

        expect(encrypted, bytes);
      });
    }
  });

  test('round-trips a payload', () async {
    final key = await _key('pw');
    final bytes = await VaultCodec.encrypt(_payload(), key);

    final opened = await VaultCodec.decrypt(bytes, password: 'pw');

    expect(opened.payload.toJson(), _payload().toJson());
    expect(opened.key.params, key.params);
    expect(opened.key.bytes, key.bytes);
    expect(await VaultCodec.decryptWithKey(bytes, key), isA<VaultPayload>());
  });

  test('readKdfParams reads the header without a key', () async {
    final key = await _key('pw');
    final bytes = await VaultCodec.encrypt(_payload(), key);

    expect(VaultCodec.readKdfParams(bytes), key.params);
    expect(
      () => VaultCodec.readKdfParams(Uint8List(4)),
      throwsA(isA<VaultFormatException>()),
    );
  });

  test('VaultKey.fromBytes opens a file with raw key bytes', () async {
    final key = await _key('pw');
    final bytes = await VaultCodec.encrypt(_payload(), key);
    final raw = Uint8List.fromList(key.bytes);

    final copy = VaultKey.fromBytes(key.params, raw);

    expect((await VaultCodec.decryptWithKey(bytes, copy)).name, 'Personal');
    copy.destroy();
    expect(raw, everyElement(0));
    expect(
      () => VaultKey.fromBytes(key.params, Uint8List(16)),
      throwsArgumentError,
    );
  });

  test('uses the default KDF parameters for new keys', () async {
    final key = await VaultKey.create(password: 'pw');

    expect(key.params.memoryKiB, KdfParams.defaultMemoryKiB);
    expect(key.params.iterations, KdfParams.defaultIterations);
    expect(key.params.parallelism, KdfParams.defaultParallelism);
  });

  test('every write uses a fresh nonce and keeps the salt', () async {
    final key = await _key('pw');
    final a = await VaultCodec.encrypt(_payload(), key);
    final b = await VaultCodec.encrypt(_payload(), key);

    String header(Uint8List bytes) =>
        latin1.decode(bytes.sublist(14, 14 + 200));
    String nonce(Uint8List bytes) =>
        RegExp(r'"nonce":"([^"]+)"').firstMatch(header(bytes))!.group(1)!;
    String salt(Uint8List bytes) =>
        RegExp(r'"salt":"([^"]+)"').firstMatch(header(bytes))!.group(1)!;

    expect(nonce(a), isNot(nonce(b)));
    expect(salt(a), salt(b));
    expect((await VaultCodec.decryptWithKey(b, key)).name, 'Personal');
  });

  test('ciphertext does not contain the plaintext', () async {
    final bytes = await VaultCodec.encrypt(_payload(), await _key('pw'));

    expect(latin1.decode(bytes), isNot(contains('Personal')));
  });

  group('rejects', () {
    late VaultKey key;
    late Uint8List bytes;

    setUp(() async {
      key = await _key('pw');
      bytes = await VaultCodec.encrypt(_payload(), key);
    });

    Matcher throwsAuth() => throwsA(isA<VaultAuthenticationException>());

    test('a wrong password', () {
      expect(VaultCodec.decrypt(bytes, password: 'Pw'), throwsAuth());
    });

    test('a tampered header', () async {
      final tampered = _patch(bytes, '"iterations":1', '"iterations":2');

      await expectLater(
        VaultCodec.decrypt(tampered, password: 'pw'),
        throwsAuth(),
      );
    });

    test('a tampered nonce', () async {
      final nonce = RegExp(r'"nonce":"(.)').firstMatch(latin1.decode(bytes))!;
      final flipped = nonce.group(1) == 'A' ? 'B' : 'A';

      await expectLater(
        VaultCodec.decrypt(
          _patch(bytes, nonce.group(0)!, '"nonce":"$flipped'),
          password: 'pw',
        ),
        throwsAuth(),
      );
    });

    test('truncated ciphertext', () async {
      await expectLater(
        VaultCodec.decrypt(bytes.sublist(0, bytes.length - 1), password: 'pw'),
        throwsAuth(),
      );
    });

    test('tampered ciphertext or tag', () async {
      for (final index in [bytes.length - 20, bytes.length - 1]) {
        final tampered = Uint8List.fromList(bytes)..[index] ^= 1;
        await expectLater(
          VaultCodec.decrypt(tampered, password: 'pw'),
          throwsAuth(),
          reason: 'byte $index',
        );
      }
    });

    test('an unknown format version', () async {
      final newer = Uint8List.fromList(bytes)..[9] = 2;

      await expectLater(
        VaultCodec.decrypt(newer, password: 'pw'),
        throwsA(
          isA<UnsupportedVaultVersionException>().having(
            (e) => e.version,
            'version',
            2,
          ),
        ),
      );
    });

    test('data that is not a vault file', () async {
      for (final bad in [
        Uint8List(0),
        Uint8List.fromList(utf8.encode('just some text that is long enough')),
        bytes.sublist(0, 30),
        Uint8List.fromList(bytes)..[10] = 0xff,
      ]) {
        await expectLater(
          VaultCodec.decrypt(bad, password: 'pw'),
          throwsA(isA<VaultFormatException>()),
        );
      }
    });

    test('unsafe KDF parameters before deriving a key', () async {
      final tampered = _patch(bytes, '"parallelism":1', '"parallelism":0');

      await expectLater(
        VaultCodec.decrypt(tampered, password: 'pw'),
        throwsA(isA<VaultFormatException>()),
      );
    });

    test('decryptWithKey with a key for other parameters', () async {
      expect(VaultCodec.decryptWithKey(bytes, await _key('pw')), throwsAuth());
    });
  });

  group('VaultKey', () {
    test('destroy zeroes the key', () async {
      final key = await _key('pw');
      final bytes = key.bytes;

      key.destroy();

      expect(bytes, everyElement(0));
      expect(key.isDestroyed, isTrue);
      expect(() => key.bytes, throwsStateError);
    });

    test('toString does not reveal the key', () async {
      final key = await _key('pw');

      expect(key.toString(), contains('redacted'));
      expect(key.toString(), isNot(contains(key.bytes.join(', '))));
    });
  });
}
