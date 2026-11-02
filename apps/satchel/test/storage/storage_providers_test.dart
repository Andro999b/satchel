import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/accounts/google_accounts.dart';
import 'package:satchel/src/storage/storage_providers.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../fakes.dart';

void main() {
  late MemoryStorageConfigStore store;
  late FakeDirectoryPicker picker;
  late MemoryGoogleAccountStore accounts;

  setUp(() {
    store = MemoryStorageConfigStore();
    picker = FakeDirectoryPicker();
    accounts = MemoryGoogleAccountStore();
  });

  ProviderContainer container(StoragePlatform? platform, {GoogleAuth? auth}) {
    final container = ProviderContainer(
      overrides: [
        ...storageOverrides(platform: platform, store: store, picker: picker),
        ...googleAccountOverrides(store: accounts, auth: auth),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('web has the built-in browser storage and nothing to add', () async {
    final c = container(StoragePlatform.web);

    expect(c.read(availableStorageKindsProvider), [
      StorageProviderKind.indexedDb,
      StorageProviderKind.googleDrive,
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
        StorageProviderKind.googleDrive,
      ]);
      expect(c.read(addableStorageKindsProvider), [
        StorageProviderKind.directory,
      ]);
      expect(await c.read(storageConfigsProvider.future), isEmpty);
    });
  }

  test('Google Drive can be added where Google sign-in is set up', () {
    for (final platform in StoragePlatform.values) {
      final c = container(platform, auth: FakeGoogleAuth());

      expect(
        c.read(addableStorageKindsProvider),
        contains(StorageProviderKind.googleDrive),
        reason: '$platform',
      );
    }
  });

  group('Google Drive storages', () {
    const ada = GoogleAccount(id: 'ada', email: 'ada@example.com');

    test('are added with their account and folder', () async {
      final c = container(StoragePlatform.web, auth: FakeGoogleAuth());

      final config = await c
          .read(storageConfigsProvider.notifier)
          .add(
            kind: StorageProviderKind.googleDrive,
            displayName: 'Vaults',
            location: 'folder-1',
            locationName: 'My Drive / Vaults',
            accountId: 'ada',
          );

      expect(store.configs, [config]);
      expect(config.accountId, 'ada');
      expect(config.locationName, 'My Drive / Vaults');
    });

    test('need an account and allow a folder once per account', () async {
      store.configs = [driveConfig('d', 'root', accountId: 'ada')];
      final notifier = container(
        StoragePlatform.linux,
        auth: FakeGoogleAuth(),
      ).read(storageConfigsProvider.notifier);

      await expectLater(
        notifier.add(
          kind: StorageProviderKind.googleDrive,
          displayName: 'x',
          location: 'folder',
        ),
        throwsArgumentError,
      );
      expect(await notifier.hasLocation('root', accountId: 'ada'), isTrue);
      expect(await notifier.hasLocation('root', accountId: 'bob'), isFalse);
      expect(await notifier.hasLocation('root'), isFalse);
      await notifier.add(
        kind: StorageProviderKind.googleDrive,
        displayName: 'Bob',
        location: 'root',
        accountId: 'bob',
      );
      expect(store.configs, hasLength(2));
    });

    test('sign in with their linked account', () async {
      store.configs = [
        driveConfig('d', 'folder', accountId: 'ada'),
        driveConfig('gone', 'folder', accountId: 'removed'),
      ];
      accounts.accounts = [ada];
      final auth = FakeGoogleAuth();
      final c = container(StoragePlatform.linux, auth: auth);

      final storages = await c.read(storageProvidersProvider.future);

      expect(storages, everyElement(isA<GoogleDriveStorageProvider>()));
      await expectLater(
        storages.last.list(),
        throwsA(isA<StorageAuthRequiredException>()),
      );
    });

    test('are rebuilt when an account is linked', () async {
      store.configs = [driveConfig('d', 'folder', accountId: 'ada')];
      final auth = FakeGoogleAuth()..next = ada;
      final c = container(StoragePlatform.linux, auth: auth);
      final before = await c.read(storageProvidersProvider.future);

      await c.read(googleAccountsProvider.notifier).add();

      expect(
        await c.read(storageProvidersProvider.future),
        isNot(same(before)),
      );
    });
  });

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
