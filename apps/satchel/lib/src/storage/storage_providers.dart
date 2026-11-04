import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../accounts/google_accounts.dart';
import 'storage_config_store.dart';

part 'storage_providers.g.dart';

/// The platform the app runs on. Override in tests to simulate another one.
@riverpod
StoragePlatform? storagePlatform(Ref ref) => StoragePlatform.current;

/// Storage kinds usable on this platform.
@riverpod
List<StorageProviderKind> availableStorageKinds(Ref ref) =>
    StorageProviderKind.supportedOn(ref.watch(storagePlatformProvider));

/// Storage kinds the user can add on this platform. Google Drive needs
/// Google sign-in to be configured in this build.
@riverpod
List<StorageProviderKind> addableStorageKinds(Ref ref) {
  final googleSignIn = ref.watch(googleAuthProvider) != null;
  return [
    for (final kind in ref.watch(availableStorageKindsProvider))
      if (kind.userAddable &&
          (kind != StorageProviderKind.googleDrive || googleSignIn))
        kind,
  ];
}

@Riverpod(keepAlive: true)
StorageConfigStore storageConfigStore(Ref ref) =>
    SharedPreferencesStorageConfigStore();

@Riverpod(keepAlive: true)
DirectoryPicker directoryPicker(Ref ref) => createPlatformDirectoryPicker();

/// Id of the built-in browser storage on web.
const browserStorageId = 'browser';

/// Storages available to the user: the built-in ones for this platform
/// followed by the ones the user added, in the order they were added.
///
/// Holds non-secret settings only, so it is kept alive.
@Riverpod(keepAlive: true)
class StorageConfigs extends _$StorageConfigs {
  @override
  Future<List<StorageConfig>> build() async {
    final platform = ref.watch(storagePlatformProvider);
    return _visible(
      await ref.watch(storageConfigStoreProvider).load(),
      platform,
    );
  }

  /// Shows the platform folder picker. Returns `null` if cancelled.
  Future<PickedDirectory?> pickDirectory() =>
      ref.read(directoryPickerProvider).pick();

  /// Whether a storage for [location] (of [accountId]) already exists.
  Future<bool> hasLocation(String location, {String? accountId}) async =>
      (await future).any(
        (config) =>
            config.location == location && config.accountId == accountId,
      );

  /// Adds a storage of a user-addable [kind] and persists it.
  Future<StorageConfig> add({
    required StorageProviderKind kind,
    required String displayName,
    String? location,
    String? locationName,
    String? accountId,
  }) async {
    if (!kind.userAddable) {
      throw ArgumentError.value(kind, 'kind', 'Cannot be added by the user');
    }
    if (kind.requiresLocation && location == null) {
      throw ArgumentError.notNull('location');
    }
    if (kind.requiresAccount && accountId == null) {
      throw ArgumentError.notNull('accountId');
    }
    if (location != null && await hasLocation(location, accountId: accountId)) {
      throw ArgumentError.value(location, 'location', 'Already added');
    }
    final config = StorageConfig(
      id: newId(),
      kind: kind,
      displayName: displayName,
      location: location,
      locationName: locationName,
      accountId: accountId,
    );
    final store = ref.read(storageConfigStoreProvider);
    final saved = [...await store.load(), config];
    await store.save(saved);
    state = AsyncData(_visible(saved, ref.read(storagePlatformProvider)));
    return config;
  }

  /// Renames a user-added storage without changing its identity or location.
  Future<void> rename(String id, String displayName) async {
    final name = displayName.trim();
    if (name.isEmpty) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'Must not be empty',
      );
    }
    final store = ref.read(storageConfigStoreProvider);
    final saved = await store.load();
    final index = saved.indexWhere((config) => config.id == id);
    if (index < 0 || !saved[index].kind.userAddable) {
      throw ArgumentError.value(id, 'id', 'Not a user-added storage');
    }
    final config = saved[index];
    if (config.displayName == name) return;
    saved[index] = StorageConfig(
      id: config.id,
      kind: config.kind,
      displayName: name,
      location: config.location,
      locationName: config.locationName,
      accountId: config.accountId,
    );
    await store.save(saved);
    state = AsyncData(_visible(saved, ref.read(storagePlatformProvider)));
  }

  /// Removes the user-added storage [id]. Its files stay where they are.
  Future<void> remove(String id) async {
    final store = ref.read(storageConfigStoreProvider);
    final saved = await store.load();
    final removed = saved.where((config) => config.id == id).firstOrNull;
    if (removed == null) return;
    final remaining = [
      for (final config in saved)
        if (config.id != id) config,
    ];
    await store.save(remaining);
    state = AsyncData(_visible(remaining, ref.read(storagePlatformProvider)));

    final location = removed.location;
    if (removed.kind == StorageProviderKind.directory &&
        location != null &&
        !remaining.any((config) => config.location == location)) {
      try {
        await ref.read(directoryPickerProvider).release(location);
      } catch (_) {
        // Best effort: the storage is already gone from the app.
      }
    }
  }

  static List<StorageConfig> _visible(
    List<StorageConfig> saved,
    StoragePlatform? platform,
  ) => [
    if (StorageProviderKind.indexedDb.isSupportedOn(platform))
      StorageConfig(
        id: browserStorageId,
        kind: StorageProviderKind.indexedDb,
        displayName: StorageProviderKind.indexedDb.defaultDisplayName,
      ),
    for (final config in saved)
      if (config.kind.userAddable && config.kind.isSupportedOn(platform))
        config,
  ];
}

/// Storage locations configured by the user. Top of the
/// provider → file → secret hierarchy.
///
/// Drive storages sign in with their linked Google account; one whose
/// account isn't linked (anymore) fails with `StorageAuthRequiredException`.
@riverpod
Future<List<StorageProvider>> storageProviders(Ref ref) async {
  final configs = await ref.watch(storageConfigsProvider.future);
  final usesGoogle = configs.any((config) => config.kind.requiresAccount);
  final googleAuth = usesGoogle ? ref.watch(googleAuthProvider) : null;
  final googleAccounts = usesGoogle
      ? await ref.watch(googleAccountsProvider.future)
      : const <GoogleAccount>[];
  final storages = [
    for (final config in configs)
      config.kind.create(
        config,
        googleAuth: googleAuth,
        googleAccount: googleAccounts
            .where((account) => account.id == config.accountId)
            .firstOrNull,
      ),
  ];
  ref.onDispose(() {
    for (final storage in storages) {
      if (storage is IndexedDbStorageProvider) unawaited(storage.close());
    }
  });
  return storages;
}
