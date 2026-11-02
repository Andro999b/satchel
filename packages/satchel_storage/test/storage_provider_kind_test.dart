import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel_storage/satchel_storage.dart';

import 'fake_google_drive.dart';

void main() {
  test('IndexedDB is supported on web only', () {
    final kind = StorageProviderKind.indexedDb;

    expect(kind.isSupportedOn(StoragePlatform.web), isTrue);
    for (final platform in [
      StoragePlatform.android,
      StoragePlatform.linux,
      StoragePlatform.windows,
      null,
    ]) {
      expect(kind.isSupportedOn(platform), isFalse, reason: '$platform');
    }
  });

  test('directory storage is supported on Android and desktop only', () {
    final kind = StorageProviderKind.directory;

    expect(kind.isSupportedOn(StoragePlatform.android), isTrue);
    expect(kind.isSupportedOn(StoragePlatform.linux), isTrue);
    expect(kind.isSupportedOn(StoragePlatform.windows), isTrue);
    expect(kind.isSupportedOn(StoragePlatform.web), isFalse);
    expect(kind.isSupportedOn(null), isFalse);
  });

  test('Google Drive is supported on every platform', () {
    for (final platform in StoragePlatform.values) {
      expect(
        StorageProviderKind.googleDrive.isSupportedOn(platform),
        isTrue,
        reason: '$platform',
      );
    }
    expect(StorageProviderKind.googleDrive.isSupportedOn(null), isFalse);
  });

  test('supportedOn lists the kinds available on a platform', () {
    expect(StorageProviderKind.supportedOn(StoragePlatform.web), [
      StorageProviderKind.indexedDb,
      StorageProviderKind.googleDrive,
    ]);
    for (final platform in [
      StoragePlatform.android,
      StoragePlatform.linux,
      StoragePlatform.windows,
    ]) {
      expect(StorageProviderKind.supportedOn(platform), [
        StorageProviderKind.directory,
        StorageProviderKind.googleDrive,
      ]);
    }
  });

  test('folders and Drive are added by the user', () {
    expect(StorageProviderKind.indexedDb.userAddable, isFalse);
    expect(StorageProviderKind.indexedDb.requiresLocation, isFalse);
    expect(StorageProviderKind.indexedDb.requiresAccount, isFalse);
    expect(StorageProviderKind.directory.userAddable, isTrue);
    expect(StorageProviderKind.directory.requiresLocation, isTrue);
    expect(StorageProviderKind.directory.requiresAccount, isFalse);
    expect(StorageProviderKind.googleDrive.userAddable, isTrue);
    expect(StorageProviderKind.googleDrive.requiresLocation, isTrue);
    expect(StorageProviderKind.googleDrive.requiresAccount, isTrue);
  });

  group('Google Drive', () {
    const account = GoogleAccount(id: 'ada', email: 'ada@example.com');
    const config = StorageConfig(
      id: 'd',
      kind: StorageProviderKind.googleDrive,
      displayName: 'Drive',
      location: 'folder',
      accountId: 'ada',
    );

    test('create builds a Drive provider for the folder', () {
      final storage = StorageProviderKind.googleDrive.create(
        config,
        googleAuth: FakeTokenAuth(),
        googleAccount: account,
      );

      expect(
        storage,
        isA<GoogleDriveStorageProvider>()
            .having((s) => s.id, 'id', 'd')
            .having((s) => s.folderId, 'folderId', 'folder'),
      );
    });

    test('a storage without its account needs a sign-in', () {
      final storage = StorageProviderKind.googleDrive.create(config);

      expect(storage.list(), throwsA(isA<StorageAuthRequiredException>()));
    });

    test('create rejects configs without account or folder', () {
      const noAccount = StorageConfig(
        id: 'd',
        kind: StorageProviderKind.googleDrive,
        displayName: 'Drive',
        location: 'folder',
      );
      const noFolder = StorageConfig(
        id: 'd',
        kind: StorageProviderKind.googleDrive,
        displayName: 'Drive',
        accountId: 'ada',
      );

      expect(
        () => StorageProviderKind.googleDrive.create(noAccount),
        throwsArgumentError,
      );
      expect(
        () => StorageProviderKind.googleDrive.create(noFolder),
        throwsArgumentError,
      );
      expect(
        () => StorageProviderKind.googleDrive.create(
          config,
          googleAccount: const GoogleAccount(id: 'bob', email: 'b@b.c'),
        ),
        throwsArgumentError,
      );
    });
  });

  test('create builds the provider described by the config', () {
    final storage = StorageProviderKind.indexedDb.create(
      const StorageConfig(
        id: 'browser',
        kind: StorageProviderKind.indexedDb,
        displayName: 'This browser',
      ),
    );

    expect(storage, isA<IndexedDbStorageProvider>());
    expect(storage.id, 'browser');
    expect(storage.displayName, 'This browser');
  });

  test('create rejects configs of another kind or without location', () {
    const config = StorageConfig(
      id: 'x',
      kind: StorageProviderKind.directory,
      displayName: 'X',
    );

    expect(
      () => StorageProviderKind.indexedDb.create(config),
      throwsArgumentError,
    );
    expect(
      () => StorageProviderKind.directory.create(config),
      throwsArgumentError,
    );
  });

  test('current platform', () {
    if (kIsWeb) {
      expect(StoragePlatform.current, StoragePlatform.web);
      expect(StorageProviderKind.indexedDb.isSupported, isTrue);
      expect(StorageProviderKind.directory.isSupported, isFalse);
    } else {
      expect(StoragePlatform.current, isNot(StoragePlatform.web));
      expect(StorageProviderKind.indexedDb.isSupported, isFalse);
    }
  });

  test('current platform maps target platforms', () {
    const expected = {
      TargetPlatform.android: StoragePlatform.android,
      TargetPlatform.linux: StoragePlatform.linux,
      TargetPlatform.windows: StoragePlatform.windows,
      TargetPlatform.iOS: null,
      TargetPlatform.macOS: null,
      TargetPlatform.fuchsia: null,
    };
    try {
      for (final MapEntry(:key, :value) in expected.entries) {
        debugDefaultTargetPlatformOverride = key;
        expect(StoragePlatform.current, value, reason: '$key');
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }, testOn: 'vm');

  test('IndexedDB provider is unusable off the web', () {
    final storage = StorageProviderKind.indexedDb.create(
      const StorageConfig(
        id: 'browser',
        kind: StorageProviderKind.indexedDb,
        displayName: 'This browser',
      ),
    );

    expect(storage.list(), throwsUnsupportedError);
  }, testOn: 'vm');
}
