import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:test/test.dart';

import 'secret_fixtures.dart';

void main() {
  final now = DateTime.utc(2026, 11, 2, 12);
  final clock = Clock.fixed(now);

  VaultPayload payload([List<Secret> secrets = const []]) => VaultPayload(
    fileId: 'f',
    name: 'My Private Vault Name',
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026, 2),
    secrets: secrets,
  );

  test('create sets an id and both timestamps from the clock', () {
    final created = VaultPayload.create(name: 'Personal', clock: clock);

    expect(created.fileId, matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(created.name, 'Personal');
    expect(created.createdAt, now);
    expect(created.updatedAt, now);
    expect(created.secrets, isEmpty);
  });

  test('stores timestamps in UTC with millisecond precision', () {
    final local = DateTime(2026, 11, 2, 12, 0, 0, 5, 7);
    final p = VaultPayload(
      fileId: 'f',
      name: 'n',
      createdAt: local,
      updatedAt: local,
    );

    expect(p.createdAt.isUtc, isTrue);
    expect(p.createdAt.microsecond, 0);
    expect(p.createdAt.millisecondsSinceEpoch, local.millisecondsSinceEpoch);
    expect(p.toJson()['createdAt'], endsWith('Z'));
  });

  test('round-trips every secret type through JSON', () {
    final original = payload(allSecretTypes);

    final parsed = VaultPayload.fromJson(
      jsonDecode(jsonEncode(original.toJson())),
    );

    expect(parsed.secrets, allSecretTypes);
    expect(parsed.toJson(), original.toJson());
  });

  test('rejects duplicate secret ids', () {
    final secret = allSecretTypes.first;

    expect(() => payload([secret, secret]), throwsArgumentError);
    final json = payload([secret]).toJson();
    expect(
      () => VaultPayload.fromJson({
        ...json,
        'secrets': [secret.toJson(), secret.toJson()],
      }),
      throwsA(isA<VaultFormatException>()),
    );
  });

  test('rejects malformed documents', () {
    final valid = payload(allSecretTypes).toJson();
    for (final bad in [
      {...valid, 'version': 2},
      {...valid, 'createdAt': 'yesterday'},
      {...valid, 'createdAt': '2026-01-01T00:00:00'},
      {
        ...valid,
        'secrets': [1],
      },
      {
        ...valid,
        'secrets': [
          {'type': 'unknown'},
        ],
      },
      {...valid}..remove('fileId'),
      'not a map',
    ]) {
      expect(
        () => VaultPayload.fromJson(bad),
        throwsA(isA<VaultFormatException>()),
        reason: '$bad',
      );
    }
  });

  test('withName renames and bumps updatedAt, keeping the rest', () {
    final original = payload(allSecretTypes);
    final renamed = original.withName('Work', clock: clock);

    expect(renamed.name, 'Work');
    expect(renamed.updatedAt, now);
    expect(renamed.createdAt, original.createdAt);
    expect(renamed.fileId, original.fileId);
    expect(renamed.secrets, original.secrets);
    expect(identical(original.withName(original.name), original), isTrue);
  });

  group('secrets', () {
    final a = allSecretTypes[0];
    final b = allSecretTypes[1];

    test('withSecret adds and bumps the file updatedAt', () {
      final updated = payload([a]).withSecret(b, clock: clock);

      expect(updated.secrets, [a, b]);
      expect(updated.updatedAt, now);
      expect(updated.createdAt, DateTime.utc(2026));
      expect(updated.fileId, 'f');
    });

    test('withSecret replaces in place by id', () {
      final edited = (b as LoginSecret).copyWith(username: 'bob');

      final updated = payload([a, b, allSecretTypes[2]])
          .withSecret(edited, clock: clock);

      expect(updated.secrets.map((s) => s.id), [
        a.id,
        b.id,
        allSecretTypes[2].id,
      ]);
      expect(updated.secretById(b.id), edited);
      expect(updated.updatedAt, now);
    });

    test('withSecret of an unchanged secret changes nothing', () {
      final original = payload([a, b]);

      expect(identical(original.withSecret(b, clock: clock), original), isTrue);
    });

    test('withoutSecret removes and bumps the file updatedAt', () {
      final updated = payload([a, b]).withoutSecret(a.id, clock: clock);

      expect(updated.secrets, [b]);
      expect(updated.updatedAt, now);
    });

    test('withoutSecret of an unknown id changes nothing', () {
      final original = payload([a]);

      expect(
        identical(original.withoutSecret('nope', clock: clock), original),
        isTrue,
      );
    });

    test('secretById finds secrets', () {
      expect(payload([a, b]).secretById(b.id), b);
      expect(payload([a]).secretById('nope'), isNull);
    });

    test('secrets are unmodifiable', () {
      expect(() => payload([a]).secrets.add(b), throwsUnsupportedError);
    });
  });

  test('toString never contains the name or secrets', () {
    final text = payload(allSecretTypes).toString();

    expect(text, isNot(contains('Private')));
    expect(text, isNot(contains('Example Bank')));
    expect(text, contains('5 secrets'));
  });
}
