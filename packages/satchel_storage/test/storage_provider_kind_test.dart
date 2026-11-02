import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel_storage/satchel_storage.dart';

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

  test('supportedOn lists the kinds available on a platform', () {
    expect(StorageProviderKind.supportedOn(StoragePlatform.web), [
      StorageProviderKind.indexedDb,
    ]);
    for (final platform in [
      StoragePlatform.android,
      StoragePlatform.linux,
      StoragePlatform.windows,
    ]) {
      expect(StorageProviderKind.supportedOn(platform), [
        StorageProviderKind.directory,
      ]);
    }
  });

  test('only directory storages are added by the user', () {
    expect(StorageProviderKind.indexedDb.userAddable, isFalse);
    expect(StorageProviderKind.indexedDb.requiresLocation, isFalse);
    expect(StorageProviderKind.directory.userAddable, isTrue);
    expect(StorageProviderKind.directory.requiresLocation, isTrue);
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
