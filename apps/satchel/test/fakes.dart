import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/misc.dart';
import 'package:satchel/src/accounts/google_account_store.dart';
import 'package:satchel/src/accounts/google_accounts.dart';
import 'package:satchel/src/pin/pin_store.dart';
import 'package:satchel/src/pin/pin_unlock.dart';
import 'package:satchel/src/vault/unlocked_vaults.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel/src/storage/storage_config_store.dart';
import 'package:satchel/src/storage/storage_providers.dart';
import 'package:satchel_storage/satchel_storage.dart';

final class MemoryStorageConfigStore implements StorageConfigStore {
  MemoryStorageConfigStore([List<StorageConfig> configs = const []])
    : configs = [...configs];

  List<StorageConfig> configs;
  Object? saveError;

  @override
  Future<List<StorageConfig>> load() async => [...configs];

  @override
  Future<void> save(List<StorageConfig> configs) async {
    if (saveError case final error?) throw error;
    this.configs = [...configs];
  }
}

final class FakeDirectoryPicker implements DirectoryPicker {
  PickedDirectory? next;
  Object? error;
  final released = <String>[];

  @override
  Future<PickedDirectory?> pick() async {
    if (error case final error?) throw error;
    return next;
  }

  @override
  Future<void> release(String location) async => released.add(location);
}

/// Hands out [next] instead of asking the user.
final class FakeFileImporter implements FileImporter {
  PickedFile? next;
  Object? error;

  @override
  Future<PickedFile?> pick({
    required String typeLabel,
    required List<String> extensions,
  }) async {
    if (error case final error?) throw error;
    return next;
  }
}

/// Records exported files instead of saving them.
final class FakeFileExporter implements FileExporter {
  final saved = <({String name, Uint8List bytes, String mimeType})>[];

  /// Simulates the user closing the save dialog.
  bool cancel = false;
  Object? error;

  @override
  Future<String?> save(
    String fileName,
    Uint8List bytes, {
    required String mimeType,
  }) async {
    if (error case final error?) throw error;
    if (cancel) return null;
    saved.add((
      name: fileName,
      bytes: Uint8List.fromList(bytes),
      mimeType: mimeType,
    ));
    return fileName;
  }
}

StorageConfig directoryConfig(String id, String location, {String? name}) =>
    StorageConfig(
      id: id,
      kind: StorageProviderKind.directory,
      displayName: name ?? id,
      location: location,
    );

StorageConfig driveConfig(
  String id,
  String folderId, {
  required String accountId,
  String? name,
  String? locationName,
}) => StorageConfig(
  id: id,
  kind: StorageProviderKind.googleDrive,
  displayName: name ?? id,
  location: folderId,
  locationName: locationName,
  accountId: accountId,
);

/// Overrides for a fake platform, preference store and picker. PIN unlock is
/// off unless [pins] is given.
List<Override> storageOverrides({
  required StoragePlatform? platform,
  required StorageConfigStore store,
  DirectoryPicker? picker,
  PinStore? pins,
}) => [
  storagePlatformProvider.overrideWithValue(platform),
  storageConfigStoreProvider.overrideWithValue(store),
  directoryPickerProvider.overrideWithValue(picker ?? FakeDirectoryPicker()),
  pinStoreProvider.overrideWithValue(pins),
];

final class MemoryPinStore implements PinStore {
  final records = <VaultRef, PinRecord>{};
  Uint8List? secret;
  Object? writeError;

  @override
  Future<Uint8List> deviceSecret() async =>
      Uint8List.fromList(secret ??= PinKeyWrap.generateDeviceSecret());

  @override
  Future<Map<VaultRef, PinRecord>> loadAll() async => {...records};

  @override
  Future<PinRecord?> read(VaultRef vault) async => records[vault];

  @override
  Future<void> write(VaultRef vault, PinRecord record) async {
    if (writeError case final error?) throw error;
    records[vault] = record;
  }

  @override
  Future<void> delete(VaultRef vault) async => records.remove(vault);
}

final class MemoryGoogleAccountStore implements GoogleAccountStore {
  MemoryGoogleAccountStore([List<GoogleAccount> accounts = const []])
    : accounts = [...accounts];

  List<GoogleAccount> accounts;

  @override
  Future<List<GoogleAccount>> load() async => [...accounts];

  @override
  Future<void> save(List<GoogleAccount> accounts) async {
    this.accounts = [...accounts];
  }
}

/// [GoogleAuth] that signs in as [next] without any UI.
final class FakeGoogleAuth implements GoogleAuth {
  GoogleAccount? next;
  Object? signInError;
  Object? signOutError;

  /// While set, [signIn] waits for it, like a browser sign-in in progress.
  Completer<GoogleAccount?>? pending;

  int cancelCalls = 0;
  final signedOut = <GoogleAccount>[];

  @override
  Future<GoogleAccount?> signIn() async {
    if (signInError case final error?) throw error;
    if (pending case final pending?) return pending.future;
    return next;
  }

  @override
  void cancelSignIn() {
    cancelCalls++;
    if (pending case final pending? when !pending.isCompleted) {
      pending.complete(null);
    }
  }

  @override
  Future<String> accessToken(
    GoogleAccount account, {
    bool interactive = false,
  }) async => 'token-${account.id}';

  @override
  Future<void> invalidateToken(
    GoogleAccount account,
    String accessToken,
  ) async {}

  @override
  Future<void> signOut(GoogleAccount account) async {
    if (signOutError case final error?) throw error;
    signedOut.add(account);
  }
}

/// In-memory Drive folders, by parent folder id.
final class FakeDriveFolderSource implements DriveFolderSource {
  final folders = <String, List<DriveFolder>>{};
  Object? listError;
  Object? createError;
  final listed = <String>[];
  final created = <(String, String)>[];
  var _ids = 0;

  @override
  Future<List<DriveFolder>> list(String parentId) async {
    listed.add(parentId);
    if (listError case final error?) throw error;
    return [...?folders[parentId]];
  }

  @override
  Future<DriveFolder> create(String parentId, String name) async {
    if (createError case final error?) throw error;
    final folder = DriveFolder(id: 'new${++_ids}', name: name);
    (folders[parentId] ??= []).add(folder);
    created.add((parentId, name));
    return folder;
  }
}

/// Overrides for Google sign-in: [auth] `null` means not configured.
List<Override> googleAccountOverrides({
  required GoogleAccountStore store,
  GoogleAuth? auth,
}) => [
  googleAuthProvider.overrideWithValue(auth),
  googleAccountStoreProvider.overrideWithValue(store),
];

/// In-memory [StorageProvider] with the conditional write semantics of the
/// real providers, plus hooks to simulate failures.
final class FakeStorageProvider implements StorageProvider {
  FakeStorageProvider({
    this.id = 'fake',
    this.displayName = 'Fake',
    List<String> paths = const [],
  }) {
    this.paths = paths;
  }

  @override
  final String id;

  @override
  final String displayName;

  final blobs = <String, ({Uint8List bytes, String revision})>{};
  var _revision = 0;

  Object? listError;
  Object? readError;
  Object? writeError;
  Object? deleteError;

  /// If set, deletes wait for it to complete, so tests can see the progress.
  Future<void>? deleteGate;

  /// Flips a byte of every written blob, like a storage corrupting data.
  bool corruptWrites = false;

  int listCalls = 0;

  List<String> get paths => blobs.keys.toList();

  /// Replaces the content with empty blobs at [paths] (revision `r-<path>`).
  set paths(List<String> paths) {
    blobs
      ..clear()
      ..addAll({
        for (final path in paths)
          path: (bytes: Uint8List(0), revision: 'r-$path'),
      });
  }

  @override
  Future<List<StorageEntry>> list() async {
    listCalls++;
    if (listError case final error?) throw error;
    return [
      for (final MapEntry(:key, :value) in blobs.entries)
        StorageEntry(path: key, revision: value.revision),
    ];
  }

  @override
  Future<StoredBlob> read(String path) async {
    if (readError case final error?) throw error;
    final blob = blobs[path];
    if (blob == null) throw StorageNotFoundException(path);
    return StoredBlob(
      entry: StorageEntry(path: path, revision: blob.revision),
      bytes: Uint8List.fromList(blob.bytes),
    );
  }

  @override
  Future<StorageEntry> write(
    String path,
    Uint8List bytes, {
    required String? expectedRevision,
  }) async {
    if (writeError case final error?) throw error;
    final current = blobs[path]?.revision;
    if (current != expectedRevision) {
      throw StorageConflictException(
        path,
        expectedRevision: expectedRevision,
        actualRevision: current,
      );
    }
    final stored = Uint8List.fromList(bytes);
    if (corruptWrites) stored[stored.length - 1] ^= 1;
    final revision = 'w${++_revision}';
    blobs[path] = (bytes: stored, revision: revision);
    return StorageEntry(path: path, revision: revision);
  }

  @override
  Future<void> delete(String path, {required String expectedRevision}) async {
    if (deleteGate case final gate?) await gate;
    if (deleteError case final error?) throw error;
    final current = blobs[path]?.revision;
    if (current == null) throw StorageNotFoundException(path);
    if (current != expectedRevision) {
      throw StorageConflictException(
        path,
        expectedRevision: expectedRevision,
        actualRevision: current,
      );
    }
    blobs.remove(path);
  }
}

/// Encrypts a vault with [secrets] under [password] (cheap KDF parameters)
/// and stores it at [path] in [storage].
Future<void> putVault(
  FakeStorageProvider storage,
  String path,
  String password, {
  List<Secret> secrets = const [],
}) async {
  final key = await VaultKey.create(password: password, memoryKiB: 64);
  try {
    final payload = VaultPayload(
      fileId: newId(),
      name: vaultNameFromPath(path),
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      secrets: secrets,
    );
    await storage.write(
      path,
      await VaultCodec.encrypt(payload, key),
      expectedRevision: null,
    );
  } finally {
    key.destroy();
  }
}
