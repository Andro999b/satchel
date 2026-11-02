import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/storage/storage_config_store.dart';
import 'package:satchel_storage/satchel_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../fakes.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('starts empty and round-trips configs', () async {
    final store = SharedPreferencesStorageConfigStore();
    expect(await store.load(), isEmpty);

    final configs = [
      directoryConfig('a', '/home/me/vaults', name: 'Personal'),
      directoryConfig('b', 'content://x/tree/primary%3AVaults'),
    ];
    await store.save(configs);

    expect(await SharedPreferencesStorageConfigStore().load(), configs);
  });

  test('skips entries this version cannot read', () async {
    await SharedPreferencesAsync().setString(
      SharedPreferencesStorageConfigStore.key,
      '[{"id":"a","kind":"directory","displayName":"A","location":"/a"},'
      '{"id":"b","kind":"teleport","displayName":"B"}, 42]',
    );

    final configs = await SharedPreferencesStorageConfigStore().load();

    expect(configs, [
      const StorageConfig(
        id: 'a',
        kind: StorageProviderKind.directory,
        displayName: 'A',
        location: '/a',
      ),
    ]);
  });
}
