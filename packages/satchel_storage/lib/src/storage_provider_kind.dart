import 'package:flutter/foundation.dart';

import 'directory/directory_platform.dart';
import 'directory/directory_storage_provider.dart';
import 'google/google_account.dart';
import 'google/google_auth.dart';
import 'google/google_drive_api.dart';
import 'google/google_drive_storage_provider.dart';
import 'indexed_db_storage_provider.dart';
import 'storage_config.dart';
import 'storage_provider.dart';

/// Platforms Satchel targets.
enum StoragePlatform {
  web,
  android,
  linux,
  windows;

  /// The platform the app is running on, or `null` for platforms Satchel does
  /// not support (iOS, macOS, Fuchsia).
  ///
  /// Honors `debugDefaultTargetPlatformOverride` on native platforms, so tests
  /// can simulate Android, Linux or Windows.
  static StoragePlatform? get current {
    if (kIsWeb) return StoragePlatform.web;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => StoragePlatform.android,
      TargetPlatform.linux => StoragePlatform.linux,
      TargetPlatform.windows => StoragePlatform.windows,
      TargetPlatform.iOS ||
      TargetPlatform.macOS ||
      TargetPlatform.fuchsia => null,
    };
  }
}

/// The kinds of storage backends Satchel can use, with the platforms each one
/// works on.
enum StorageProviderKind {
  /// The browser's IndexedDB. Data stays in this browser profile for this
  /// site. Built in: the app provides a single instance on web.
  indexedDb(
    defaultDisplayName: 'This browser',
    platforms: {StoragePlatform.web},
    userAddable: false,
  ),

  /// A user-chosen directory: a filesystem path on desktop, a Storage Access
  /// Framework folder on Android. Users can add several.
  directory(
    defaultDisplayName: 'Folder',
    platforms: {
      StoragePlatform.android,
      StoragePlatform.linux,
      StoragePlatform.windows,
    },
    userAddable: true,
  ),

  /// A folder in the Google Drive of a linked Google account, through the
  /// Drive REST API. Users can add several.
  googleDrive(
    defaultDisplayName: 'Google Drive',
    platforms: {
      StoragePlatform.web,
      StoragePlatform.android,
      StoragePlatform.linux,
      StoragePlatform.windows,
    },
    userAddable: true,
  );

  const StorageProviderKind({
    required this.defaultDisplayName,
    required this.platforms,
    required this.userAddable,
  });

  /// English fallback name for storages of this kind, used as
  /// `StorageProvider.displayName` of built-in storages. Apps show a
  /// localized name instead.
  final String defaultDisplayName;

  /// Platforms on which this kind can be used.
  final Set<StoragePlatform> platforms;

  /// Whether users add (and remove) storages of this kind themselves, possibly
  /// several. Kinds that aren't are provided by the app.
  final bool userAddable;

  /// Whether `StorageConfig.location` must be set for this kind.
  bool get requiresLocation => this == directory || this == googleDrive;

  /// Whether `StorageConfig.accountId` must be set for this kind.
  bool get requiresAccount => this == googleDrive;

  bool isSupportedOn(StoragePlatform? platform) =>
      platform != null && platforms.contains(platform);

  /// Whether this kind can be used on the platform the app runs on.
  bool get isSupported => isSupportedOn(StoragePlatform.current);

  /// Kinds that can be used on [platform].
  static List<StorageProviderKind> supportedOn(StoragePlatform? platform) => [
    for (final kind in values)
      if (kind.isSupportedOn(platform)) kind,
  ];

  /// Creates the provider described by [config], which must be of this kind.
  ///
  /// Drive storages sign in with [googleAuth] as [googleAccount], the linked
  /// account with `config.accountId`. Without them the storage fails with
  /// `StorageAuthRequiredException`.
  ///
  /// Check [isSupported] first: on other platforms creating or using the
  /// provider throws [UnsupportedError].
  StorageProvider create(
    StorageConfig config, {
    GoogleAuth? googleAuth,
    GoogleAccount? googleAccount,
  }) {
    if (config.kind != this) {
      throw ArgumentError.value(config, 'config', 'Not a $name config');
    }
    final location = config.location;
    if (requiresLocation && location == null) {
      throw ArgumentError.value(config, 'config', 'Missing location');
    }
    if (requiresAccount && config.accountId == null) {
      throw ArgumentError.value(config, 'config', 'Missing account');
    }
    if (googleAccount != null && googleAccount.id != config.accountId) {
      throw ArgumentError.value(
        googleAccount,
        'googleAccount',
        'Other account',
      );
    }
    return switch (this) {
      indexedDb => IndexedDbStorageProvider(
        id: config.id,
        displayName: config.displayName,
      ),
      directory => DirectoryStorageProvider(
        id: config.id,
        displayName: config.displayName,
        backend: directoryBackendFor(location!),
      ),
      googleDrive => GoogleDriveStorageProvider(
        id: config.id,
        displayName: config.displayName,
        folderId: location!,
        api: GoogleDriveApi(
          GoogleDriveTokens(auth: googleAuth, account: googleAccount),
        ),
      ),
    };
  }
}
