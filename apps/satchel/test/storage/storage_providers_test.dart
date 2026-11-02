import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/storage/storage_providers.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../fakes.dart';

void main() {
  late MemoryStorageConfigStore store;
  late FakeDirectoryPicker picker;

  setUp(() {
    store = MemoryStorageConfigStore();
    picker = FakeDirectoryPicker();
  });

  ProviderContainer container(StoragePlatform? platform) {
    final container = ProviderContainer(
      overrides: storageOverrides(
        platform: platform,
        store: store,
        picker: picker,
      ),
    );
    addTearDown(container.dispose);
    return container;
  }

  test('web has the built-in browser storage and nothing to add', () async {
    final c = container(StoragePlatform.web);

    expect(c.read(availableStorageKindsProvider), [
      StorageProviderKind.indexedDb,
    ]);
    expect(c.read(addableStorageKindsProvider), isEmpty);
    final configs = await c.read(storageConfigsProvider.future);
    expect(configs.single.id, browserStorageId);
    expect(configs.single.displayName, 'This browser');
    final storages = await c.read(storageProvidersProvider.future);
    expect(storages.single, isA<IndexedDbStorageProvider>());
  });

  for (final platform in [
    StoragePlatform.android,
    StoragePlatform.linux,
    StoragePlatform.windows,
  ]) {
    test('$platform offers directories and no IndexedDB', () async {
      final c = container(platform);

      expect(c.read(availableStorageKindsProvider), [
        StorageProviderKind.directory,
      ]);
      expect(c.read(addableStorageKindsProvider), [
        StorageProviderKind.directory,
      ]);
      expect(await c.read(storageConfigsProvider.future), isEmpty);
    });
  }

  test('loads saved storages supported on this platform', () async {
    store.configs = [directoryConfig('a', '/a'), directoryConfig('b', '/b')];

    final desktop = container(StoragePlatform.linux);
    expect(await desktop.read(storageConfigsProvider.future), store.configs);
    final storages = await desktop.read(storageProvidersProvider.future);
    expect(storages.map((s) => s.id), ['a', 'b']);
    expect(storages, everyElement(isA<DirectoryStorageProvider>()));

    final web = container(StoragePlatform.web);
    expect((await web.read(storageConfigsProvider.future)).map((c) => c.id), [
      browserStorageId,
    ]);
  });

  test('adds several directory storages and persists them', () async {
    final c = container(StoragePlatform.linux);
    final notifier = c.read(storageConfigsProvider.notifier);

    final a = await notifier.add(
      kind: StorageProviderKind.directory,
      displayName: 'Personal',
      location: '/home/me/vaults',
    );
    final b = await notifier.add(
      kind: StorageProviderKind.directory,
      displayName: 'Work',
      location: '/mnt/work',
    );

    expect(a.id, isNot(b.id));
    expect(await c.read(storageConfigsProvider.future), [a, b]);
    expect(store.configs, [a, b]);
    expect(
      (await c.read(storageProvidersProvider.future)).map((s) => s.displayName),
      ['Personal', 'Work'],
    );
  });

  test('rejects duplicate locations and built-in kinds', () async {
    store.configs = [directoryConfig('a', '/a')];
    final notifier = container(StoragePlatform.linux)
        .read(storageConfigsProvider.notifier);

    expect(await notifier.hasLocation('/a'), isTrue);
    await expectLater(
      notifier.add(
        kind: StorageProviderKind.directory,
        displayName: 'again',
        location: '/a',
      ),
      throwsArgumentError,
    );
    await expectLater(
      notifier.add(kind: StorageProviderKind.indexedDb, displayName: 'x'),
      throwsArgumentError,
    );
    await expectLater(
      notifier.add(kind: StorageProviderKind.directory, displayName: 'x'),
      throwsArgumentError,
    );
    expect(store.configs, hasLength(1));
  });

  test('removing forgets the storage and releases its folder', () async {
    store.configs = [directoryConfig('a', '/a'), directoryConfig('b', '/b')];
    final c = container(StoragePlatform.android);

    await c.read(storageConfigsProvider.notifier).remove('a');

    expect(store.configs.map((c) => c.id), ['b']);
    expect((await c.read(storageConfigsProvider.future)).map((c) => c.id), [
      'b',
    ]);
    expect(picker.released, ['/a']);
  });

  test('removing keeps access while another storage uses the folder', () async {
    store.configs = [directoryConfig('a', '/x'), directoryConfig('b', '/x')];

    await container(StoragePlatform.android)
        .read(storageConfigsProvider.notifier)
        .remove('a');

    expect(picker.released, isEmpty);
  });
}
