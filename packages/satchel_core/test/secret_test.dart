import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:test/test.dart';

import 'secret_fixtures.dart';

Matcher _throwsFormat() => throwsA(isA<VaultFormatException>());

void main() {
  group('JSON', () {
    test('every type round-trips', () {
      for (final secret in allSecretTypes) {
        final json = jsonDecode(jsonEncode(secret.toJson()));
        final parsed = Secret.fromJson(json);

        expect(parsed, secret, reason: secret.type.name);
        expect(parsed.runtimeType, secret.runtimeType);
      }
    });

    test('pins the stored schema', () {
      expect(allSecretTypes[1].toJson(), {
        'type': 'login',
        'id': '22222222-2222-4222-8222-222222222222',
        'title': 'Example Bank',
        'tags': ['finance'],
        'createdAt': '2026-03-01T09:30:00.000Z',
        'updatedAt': '2026-10-15T18:45:12.345Z',
        'expiresAt': '2027-01-01T00:00:00.000Z',
        'notes': 'Shared with Ann.\nRotate yearly.',
        'customFields': [
          {'label': 'Customer number', 'value': '12345', 'concealed': false},
          {'label': 'Security answer', 'value': 'Rex', 'concealed': true},
        ],
        'username': 'ann@example.com',
        'password': 'p@ss wörd 🔑',
        'url': 'https://bank.example.com/login',
        'totp':
            'otpauth://totp/Example:ann?secret=JBSWY3DPEHPK3PXP&issuer=Example',
      });
      expect(allSecretTypes[0].toJson()['type'], 'password');
      expect(allSecretTypes[2].toJson()['type'], 'pem');
      expect(allSecretTypes[3].toJson()['codes'], [
        {'code': '1111-2222', 'used': true},
        {'code': '3333-4444', 'used': false},
        {'code': '5555-6666', 'used': false},
      ]);
      expect(allSecretTypes[3].toJson()['type'], 'recoveryCodes');
      expect(allSecretTypes[4].toJson()['type'], 'note');
    });

    test('omits unset optional common fields', () {
      final json = NoteSecret(info: info('n'), text: 't').toJson();

      expect(json.keys, [
        'type',
        'id',
        'title',
        'createdAt',
        'updatedAt',
        'text',
      ]);
      expect(Secret.fromJson(json), isA<NoteSecret>());
    });

    test('rejects malformed secrets without revealing values', () {
      final valid = allSecretTypes[1].toJson();
      final bad = <Object?>[
        'not an object',
        {...valid, 'type': 'creditCard'},
        {...valid}..remove('type'),
        {...valid}..remove('id'),
        {...valid}..remove('password'),
        {...valid, 'username': 42},
        {...valid, 'tags': 'finance'},
        {
          ...valid,
          'tags': [1],
        },
        {...valid, 'createdAt': 'yesterday'},
        {...valid, 'updatedAt': '2026-01-01T00:00:00'},
        {...valid, 'expiresAt': null},
        {
          ...valid,
          'customFields': [
            {'label': 'x'},
          ],
        },
        {
          ...allSecretTypes[3].toJson(),
          'codes': [
            {'code': 'x'},
          ],
        },
        {...valid, 'id': ''},
      ];
      for (final json in bad) {
        expect(
          () => Secret.fromJson(json),
          anyOf(_throwsFormat(), throwsArgumentError),
          reason: '$json',
        );
      }
      try {
        Secret.fromJson({...valid, 'username': 42});
      } on VaultFormatException catch (e) {
        expect(e.message, contains('"username"'));
        expect(e.message, isNot(contains('42')));
      }
    });
  });

  group('SecretInfo', () {
    test('create sets a fresh id and both timestamps to now', () {
      final now = DateTime.utc(2026, 11, 2, 12);
      final a = SecretInfo.create(title: 'A', clock: Clock.fixed(now));
      final b = SecretInfo.create(title: 'A', clock: Clock.fixed(now));

      expect(a.id, matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(a.id, isNot(b.id));
      expect(a.createdAt, now);
      expect(a.updatedAt, now);
      expect(a.expiresAt, isNull);
      expect(a.notes, isEmpty);
      expect(a.customFields, isEmpty);
    });

    test('stores timestamps in UTC with millisecond precision', () {
      final local = DateTime(2026, 11, 2, 12, 0, 0, 1, 999);
      final i = SecretInfo(
        id: 'x',
        title: 't',
        createdAt: local,
        updatedAt: local,
        expiresAt: local,
      );

      for (final time in [i.createdAt, i.updatedAt, i.expiresAt!]) {
        expect(time.isUtc, isTrue);
        expect(time.microsecond, 0);
        expect(time.millisecondsSinceEpoch, local.millisecondsSinceEpoch);
      }
    });

    test('normalizes tags', () {
      final i = info('x', tags: [' Work ', 'home', '', 'work', 'Bank', '  ']);

      expect(i.tags, ['Bank', 'home', 'Work']);
      expect(() => i.tags.add('x'), throwsUnsupportedError);
    });

    test('copyWith can set and clear the expiry', () {
      final expiry = DateTime.utc(2027);
      final withExpiry = info('x').copyWith(expiresAt: () => expiry);

      expect(withExpiry.expiresAt, expiry);
      expect(withExpiry.copyWith(title: 'y').expiresAt, expiry);
      expect(withExpiry.copyWith(expiresAt: () => null).expiresAt, isNull);
    });

    test('rejects an empty id', () {
      expect(() => info(''), throwsArgumentError);
    });
  });

  group('equality', () {
    test('compares all fields', () {
      for (final secret in allSecretTypes) {
        expect(Secret.fromJson(secret.toJson()), secret);
        expect(Secret.fromJson(secret.toJson()).hashCode, secret.hashCode);
      }
      expect(allSecretTypes.toSet(), hasLength(allSecretTypes.length));
    });

    test('sameContentAs ignores id and timestamps only', () {
      final login = allSecretTypes[1] as LoginSecret;
      final copy = login.withInfo(
        login.info.copyWith(
          id: 'other',
          createdAt: DateTime.utc(2020),
          updatedAt: DateTime.utc(2021),
        ),
      );

      expect(copy, isNot(login));
      expect(copy.sameContentAs(login), isTrue);
      for (final changed in <Secret>[
        login.copyWith(password: 'x'),
        login.copyWith(totp: ''),
        login.withInfo(login.info.copyWith(title: 'x')),
        login.withInfo(login.info.copyWith(tags: [])),
        login.withInfo(login.info.copyWith(notes: '')),
        login.withInfo(login.info.copyWith(expiresAt: () => null)),
        login.withInfo(
          login.info.copyWith(
            customFields: [login.customFields.first.copyWith(concealed: true)],
          ),
        ),
      ]) {
        expect(changed.sameContentAs(login), isFalse);
        expect(changed, isNot(login));
      }
    });

    test('secrets of different types never match', () {
      final password = PasswordSecret(info: info('x'), password: 'p');
      final login = LoginSecret(info: info('x'), password: 'p');

      expect(password.sameContentAs(login), isFalse);
      expect(password, isNot(login));
    });
  });

  test('toString never reveals titles or values', () {
    for (final secret in allSecretTypes) {
      final text = [
        secret.toString(),
        secret.info.toString(),
        for (final field in secret.customFields) field.toString(),
        if (secret case RecoveryCodesSecret(:final codes))
          for (final code in codes) code.toString(),
      ].join(' ');

      expect(text, contains(secret.id));
      for (final value in [
        secret.title,
        ...secret.tags,
        if (secret.notes.isNotEmpty) secret.notes,
        for (final field in secret.customFields) ...[field.label, field.value],
        ...switch (secret) {
          PasswordSecret(:final password) => [password],
          LoginSecret(
            :final username,
            :final password,
            :final url,
            :final totp,
          ) =>
            [username, password, url, totp],
          PemSecret(:final pem) => [pem, 'PRIVATE'],
          RecoveryCodesSecret(:final codes) => [for (final c in codes) c.code],
          NoteSecret(:final text) => [text],
        },
      ]) {
        expect(text, isNot(contains(value)), reason: secret.type.name);
      }
    }
  });

  group('expiryStatus', () {
    final expiry = DateTime.utc(2026, 12, 1);
    final secret = NoteSecret(
      info: info('x', expiresAt: expiry),
      text: '',
    );

    test('is none without an expiry', () {
      expect(
        NoteSecret(info: info('x'), text: '').expiryStatus(DateTime.utc(2099)),
        ExpiryStatus.none,
      );
    });

    test('reports valid, expiring soon and expired', () {
      expect(
        secret.expiryStatus(DateTime.utc(2026, 10, 1)),
        ExpiryStatus.valid,
      );
      expect(
        secret.expiryStatus(DateTime.utc(2026, 11, 17)),
        ExpiryStatus.expiringSoon,
      );
      expect(
        secret.expiryStatus(DateTime.utc(2026, 11, 30)),
        ExpiryStatus.expiringSoon,
      );
      expect(secret.expiryStatus(expiry), ExpiryStatus.expired);
      expect(secret.expiryStatus(DateTime.utc(2027)), ExpiryStatus.expired);
    });

    test('accepts a custom warning period', () {
      expect(
        secret.expiryStatus(
          DateTime.utc(2026, 11, 1),
          warning: const Duration(days: 7),
        ),
        ExpiryStatus.valid,
      );
    });
  });

  group('edits', () {
    final later = DateTime.utc(2026, 11, 2, 12);
    final clock = Clock.fixed(later);
    final original = allSecretTypes[1] as LoginSecret;

    test('applyEdit stamps changed content with now', () {
      final edited = Secret.applyEdit(
        original,
        original.copyWith(password: 'new'),
        clock: clock,
      );

      expect(edited.password, 'new');
      expect(edited.id, original.id);
      expect(edited.createdAt, original.createdAt);
      expect(edited.updatedAt, later);
    });

    test('applyEdit keeps the original when nothing changed', () {
      final edited = Secret.applyEdit(
        original,
        original.withInfo(
          original.info.copyWith(updatedAt: DateTime.utc(2030)),
        ),
        clock: clock,
      );

      expect(identical(edited, original), isTrue);
    });

    test('applyEdit keeps createdAt even if the edit changed it', () {
      final edited = Secret.applyEdit(
        original,
        original
            .copyWith(username: 'bob')
            .withInfo(original.info.copyWith(createdAt: DateTime.utc(2000))),
        clock: clock,
      );

      expect(edited.createdAt, original.createdAt);
    });

    test('applyEdit rejects another secret', () {
      expect(
        () => Secret.applyEdit(
          original,
          original.withInfo(original.info.copyWith(id: 'other')),
          clock: clock,
        ),
        throwsArgumentError,
      );
    });

    test('duplicate gets a new id and new timestamps', () {
      final copy = original.duplicate(clock: clock);

      expect(copy, isA<LoginSecret>());
      expect(copy.id, isNot(original.id));
      expect(copy.createdAt, later);
      expect(copy.updatedAt, later);
      expect(copy.sameContentAs(original), isTrue);
    });
  });

  group('PemSecret', () {
    PemSecret pem(String text) => PemSecret(info: info('p'), pem: text);

    test('detects private keys', () {
      for (final header in [
        'PRIVATE KEY',
        'RSA PRIVATE KEY',
        'EC PRIVATE KEY',
        'ENCRYPTED PRIVATE KEY',
        'OPENSSH PRIVATE KEY',
      ]) {
        expect(
          pem('-----BEGIN $header-----\nabc\n-----END $header-----')
              .containsPrivateKey,
          isTrue,
          reason: header,
        );
      }
      expect(
        pem('-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----')
            .containsPrivateKey,
        isFalse,
      );
      expect(pem('-----BEGIN PUBLIC KEY-----').containsPrivateKey, isFalse);
    });

    test('detects a private key anywhere in a chain', () {
      expect(
        pem(
          '-----BEGIN CERTIFICATE-----\na\n-----END CERTIFICATE-----\n'
          '-----BEGIN EC PRIVATE KEY-----\nb\n-----END EC PRIVATE KEY-----',
        ).containsPrivateKey,
        isTrue,
      );
    });
  });

  group('RecoveryCodesSecret', () {
    final codes = allSecretTypes[3] as RecoveryCodesSecret;

    test('counts remaining codes', () {
      expect(codes.remaining, 2);
      expect(RecoveryCodesSecret(info: info('r')).remaining, 0);
    });

    test('marks codes used and unused', () {
      final used = codes.withCodeUsed(1);

      expect(used.remaining, 1);
      expect(used.codes[1], const RecoveryCode('3333-4444', used: true));
      expect(used.withCodeUsed(0, used: false).remaining, 2);
      expect(codes.remaining, 2, reason: 'original unchanged');
    });

    test('codes are unmodifiable', () {
      expect(
        () => codes.codes.add(const RecoveryCode('x')),
        throwsUnsupportedError,
      );
    });
  });

  test('handlers can switch exhaustively over secret types', () {
    String describe(Secret secret) => switch (secret) {
      PasswordSecret() => 'password',
      LoginSecret() => 'login',
      PemSecret() => 'pem',
      RecoveryCodesSecret() => 'recoveryCodes',
      NoteSecret() => 'note',
    };

    expect(
      allSecretTypes.map(describe),
      SecretType.values.map((type) => type.name),
    );
  });
}
