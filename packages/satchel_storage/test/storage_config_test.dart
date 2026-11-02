import 'package:flutter_test/flutter_test.dart';
import 'package:satchel_storage/satchel_storage.dart';

void main() {
  test('round-trips through JSON', () {
    const configs = [
      StorageConfig(
        id: '1',
        kind: StorageProviderKind.directory,
        displayName: 'Sync',
        location: '/home/me/Sync',
      ),
      StorageConfig(
        id: '2',
        kind: StorageProviderKind.indexedDb,
        displayName: 'This browser',
      ),
    ];

    for (final config in configs) {
      expect(StorageConfig.fromJson(config.toJson()), config);
    }
    expect(configs.last.toJson(), isNot(contains('location')));
  });

  test('rejects unknown kinds and malformed input', () {
    expect(
      () => StorageConfig.fromJson({
        'id': '1',
        'kind': 'ftp',
        'displayName': 'x',
      }),
      throwsFormatException,
    );
    expect(
      () => StorageConfig.fromJson({'id': '1', 'kind': 'directory'}),
      throwsFormatException,
    );
    expect(
      () => StorageConfig.fromJson({
        'id': '1',
        'kind': 'directory',
        'displayName': 'x',
        'location': 42,
      }),
      throwsFormatException,
    );
  });
}
