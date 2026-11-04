import 'dart:convert';
import 'dart:typed_data';

import 'package:satchel_core/satchel_core.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

final _secret = Uint8List.fromList(List.generate(32, (i) => i));
final _otherSecret = Uint8List.fromList(List.generate(32, (i) => i + 1));

Future<VaultKey> _vaultKey() =>
    VaultKey.create(password: 'pw', memoryKiB: 64, iterations: 1);

Future<PinWrappedKey> _wrap(VaultKey key, {String pin = '123456'}) =>
    PinKeyWrap.wrap(
      key,
      pin: pin,
      deviceSecret: _secret,
      memoryKiB: 64,
      iterations: 1,
    );

/// Replaces the [field] value in the record JSON.
String _patch(PinWrappedKey wrapped, String field, Object? value) {
  final json = jsonDecode(wrapped.encode()) as Map<String, Object?>;
  json[field] = value;
  return jsonEncode(json);
}

void main() {
  test('isValidPin accepts 6 to 8 digits only', () {
    expect(isValidPin('123456'), isTrue);
    expect(isValidPin('12345678'), isTrue);
    expect(isValidPin('12345'), isFalse);
    expect(isValidPin('123456789'), isFalse);
    expect(isValidPin('12345a'), isFalse);
    expect(isValidPin('١٢٣٤٥٦'), isFalse);
    expect(isValidPin(' 123456'), isFalse);
  });

  test('round-trips a key through encode and decode', () async {
    final key = await _vaultKey();
    final wrapped = await _wrap(key);

    final unwrapped = await PinKeyWrap.unwrap(
      PinWrappedKey.decode(wrapped.encode()),
      pin: '123456',
      deviceSecret: _secret,
    );

    expect(unwrapped.bytes, key.bytes);
    expect(unwrapped.params, key.params);
    expect(wrapped.vaultParams, key.params);
  });

  test('the record contains neither the key nor the PIN', () async {
    final key = await _vaultKey();
    final encoded = (await _wrap(key, pin: '987654')).encode();

    expect(encoded, isNot(contains(base64.encode(key.bytes))));
    expect(encoded, isNot(contains('987654')));
    expect((await _wrap(key)).toString(), contains('<redacted>'));
  });

  test('every wrap uses a fresh salt and nonce', () async {
    final key = await _vaultKey();
    final a = jsonDecode((await _wrap(key)).encode()) as Map;
    final b = jsonDecode((await _wrap(key)).encode()) as Map;

    expect(a['nonce'], isNot(b['nonce']));
    expect((a['kdf'] as Map)['salt'], isNot((b['kdf'] as Map)['salt']));
  });

  test('wrap rejects an invalid PIN or device secret', () async {
    final key = await _vaultKey();

    expect(_wrap(key, pin: '1234'), throwsArgumentError);
    expect(
      PinKeyWrap.wrap(key, pin: '123456', deviceSecret: Uint8List(16)),
      throwsArgumentError,
    );
  });

  test('generateDeviceSecret returns 32 random bytes', () {
    final a = PinKeyWrap.generateDeviceSecret();
    final b = PinKeyWrap.generateDeviceSecret();

    expect(a, hasLength(32));
    expect(a, isNot(b));
  });

  test('known answer', () async {
    final keyBytes = Uint8List.fromList(List.generate(32, (i) => 0xa0 + i));
    final vaultParams = KdfParams(
      memoryKiB: 64,
      iterations: 1,
      parallelism: 1,
      salt: List.generate(16, (i) => 0x10 + i),
    );
    final wrapped = await PinKeyWrap.wrap(
      VaultKey.fromBytes(vaultParams, Uint8List.fromList(keyBytes)),
      pin: '24681357',
      deviceSecret: _secret,
      memoryKiB: 64,
      iterations: 2,
      random: SequenceRandom(List.generate(28, (i) => 0x40 + i)),
    );

    expect(wrapped.encode(), _knownAnswer);
    final unwrapped = await PinKeyWrap.unwrap(
      PinWrappedKey.decode(_knownAnswer),
      pin: '24681357',
      deviceSecret: _secret,
    );
    expect(unwrapped.bytes, keyBytes);
  });

  group('rejects', () {
    late PinWrappedKey wrapped;

    setUp(() async => wrapped = await _wrap(await _vaultKey()));

    Matcher throwsAuth() => throwsA(isA<VaultAuthenticationException>());
    Matcher throwsFormat() => throwsA(isA<VaultFormatException>());

    Future<VaultKey> unwrap(
      PinWrappedKey record, {
      String pin = '123456',
      Uint8List? deviceSecret,
    }) => PinKeyWrap.unwrap(
      record,
      pin: pin,
      deviceSecret: deviceSecret ?? _secret,
    );

    test('a wrong PIN', () {
      expect(unwrap(wrapped, pin: '123457'), throwsAuth());
      expect(unwrap(wrapped, pin: '12345'), throwsAuth());
    });

    test('a wrong device secret', () {
      expect(unwrap(wrapped, deviceSecret: _otherSecret), throwsAuth());
    });

    test('a tampered wrapped key', () {
      final key = base64.decode(
        (jsonDecode(wrapped.encode()) as Map)['key'] as String,
      );
      key[0] ^= 1;
      final record = PinWrappedKey.decode(
        _patch(wrapped, 'key', base64.encode(key)),
      );

      expect(unwrap(record), throwsAuth());
    });

    test('tampered vault parameters', () {
      final vaultKdf = Map<String, Object?>.of(
        (jsonDecode(wrapped.encode()) as Map)['vaultKdf']
            as Map<String, Object?>,
      )..['iterations'] = 2;
      final record = PinWrappedKey.decode(
        _patch(wrapped, 'vaultKdf', vaultKdf),
      );

      expect(unwrap(record), throwsAuth());
    });

    test('a tampered nonce', () {
      final nonce = base64.decode(
        (jsonDecode(wrapped.encode()) as Map)['nonce'] as String,
      );
      nonce[0] ^= 1;
      final record = PinWrappedKey.decode(
        _patch(wrapped, 'nonce', base64.encode(nonce)),
      );

      expect(unwrap(record), throwsAuth());
    });

    test('an unknown version', () {
      expect(
        () => PinWrappedKey.decode(_patch(wrapped, 'v', 2)),
        throwsFormat(),
      );
    });

    test('malformed records', () {
      expect(() => PinWrappedKey.decode('nope'), throwsFormat());
      expect(() => PinWrappedKey.decode('{}'), throwsFormat());
      expect(
        () => PinWrappedKey.decode(_patch(wrapped, 'key', 'AAAA')),
        throwsFormat(),
      );
      expect(
        () => PinWrappedKey.decode(_patch(wrapped, 'nonce', '%%')),
        throwsFormat(),
      );
    });
  });
}

// Cross-checked with Python's argon2-cffi and cryptography (HKDF, AESGCM).
const _knownAnswer =
    '{"v":1,"kdf":{"algorithm":"argon2id","memoryKiB":64,"iterations":2,'
    '"parallelism":1,"salt":"QEFCQ0RFRkdISUpLTE1OTw=="},"vaultKdf":'
    '{"algorithm":"argon2id","memoryKiB":64,"iterations":1,"parallelism":1,'
    '"salt":"EBESExQVFhcYGRobHB0eHw=="},"nonce":"UFFSU1RVVldYWVpb","key":'
    '"2bBLioFHLLGzdFwzLuREubEP2KSJI2zYcTmPNJ4qUAIOO0Qpqb46PI6qZfP6P9Ep"}';
