import 'dart:convert';

import 'package:satchel_core/satchel_core.dart';
import 'package:test/test.dart';

import 'secret_fixtures.dart';

void main() {
  final payload = VaultPayload(
    fileId: 'f',
    name: 'Personal',
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026, 2),
    secrets: allSecretTypes,
  );

  test('round-trips every secret type', () {
    final decoded = PlainExport.decode(PlainExport.encode(payload));

    expect(decoded.toJson(), payload.toJson());
  });

  test('is a readable JSON document marked as an export', () {
    final json = jsonDecode(
      utf8.decode(PlainExport.encode(payload)),
    ) as Map<String, Object?>;

    expect(json['satchelExport'], 1);
    expect(json['vault'], payload.toJson());
  });

  test('rejects documents that are not exports', () {
    for (final bad in [
      'not json',
      '[]',
      '{"vault": {}}',
      '{"satchelExport": 0, "vault": {}}',
      '{"satchelExport": 1, "vault": "x"}',
    ]) {
      expect(
        () => PlainExport.decode(utf8.encode(bad)),
        throwsA(isA<VaultFormatException>()),
        reason: bad,
      );
    }
  });

  test('rejects newer export versions', () {
    expect(
      () => PlainExport.decode(utf8.encode('{"satchelExport": 2}')),
      throwsA(isA<UnsupportedVaultVersionException>()),
    );
  });

  test('withOnlySecrets keeps the chosen secrets and everything else', () {
    final ids = {allSecretTypes[2].id, allSecretTypes[0].id};

    final subset = payload.withOnlySecrets(ids);

    expect(subset.secrets, [allSecretTypes[0], allSecretTypes[2]]);
    expect(subset.fileId, 'f');
    expect(subset.name, 'Personal');
    expect(subset.createdAt, payload.createdAt);
    expect(subset.updatedAt, payload.updatedAt);
  });
}
