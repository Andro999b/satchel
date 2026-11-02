import 'package:flutter/material.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../l10n/l10n.dart';

IconData storageIcon(StorageProviderKind kind) => switch (kind) {
  StorageProviderKind.indexedDb => Icons.public,
  StorageProviderKind.directory => Icons.folder_outlined,
  StorageProviderKind.googleDrive => Icons.add_to_drive,
};

/// Localized name of a storage kind.
String storageKindName(AppLocalizations l10n, StorageProviderKind kind) =>
    switch (kind) {
      StorageProviderKind.indexedDb => l10n.storageKindIndexedDb,
      StorageProviderKind.directory => l10n.storageKindDirectory,
      StorageProviderKind.googleDrive => l10n.storageKindGoogleDrive,
    };

/// Where [config] keeps its files, e.g. a folder path, or the account and
/// folder of a Drive storage. `null` for built-in storages.
String? storageLocationText(StorageConfig config, {String? accountEmail}) =>
    switch (config.kind) {
      StorageProviderKind.indexedDb => null,
      StorageProviderKind.directory => switch (config.location) {
        final location? => describeLocation(location),
        null => null,
      },
      StorageProviderKind.googleDrive => switch ([
        ?accountEmail,
        ?config.locationName,
      ]) {
        [] => null,
        final parts => parts.join(' · '),
      },
    };

/// Name to show for [config]: the user's name for storages they added, the
/// localized kind name for built-in ones.
String storageName(AppLocalizations l10n, StorageConfig config) =>
    config.kind.userAddable
    ? config.displayName
    : storageKindName(l10n, config.kind);

/// Human-readable form of a `StorageConfig.location`.
///
/// Android SAF tree URIs end in an encoded document id such as
/// `primary:Documents/Vaults`, which is shown instead of the whole URI.
String describeLocation(String location) {
  if (!location.startsWith('content://')) return location;
  final segments = Uri.parse(location).pathSegments;
  return segments.isEmpty ? location : segments.last;
}
