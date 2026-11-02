import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../storage/storage_providers.dart';
import '../vault/unlocked_vaults.dart';

part 'app_location.g.dart';

/// Levels of the app's hierarchy, each shown as one pane.
enum AppLevel { storages, files, secrets, secret }

/// What the user has opened: a storage, a vault file in it, and a secret in
/// that file. Each is only set when its parent is. Holds ids only, never
/// secret data.
@immutable
final class AppLocation {
  const AppLocation({this.storageId, this.filePath, this.secretId})
    : assert(filePath == null || storageId != null),
      assert(secretId == null || filePath != null);

  final String? storageId;
  final String? filePath;
  final String? secretId;

  /// The deepest level with content: the pane the user is working in.
  AppLevel get level => switch (this) {
    AppLocation(storageId: null) => AppLevel.storages,
    AppLocation(filePath: null) => AppLevel.files,
    AppLocation(secretId: null) => AppLevel.secrets,
    _ => AppLevel.secret,
  };

  /// This location one level up.
  AppLocation get parent => switch (level) {
    AppLevel.storages || AppLevel.files => const AppLocation(),
    AppLevel.secrets => AppLocation(storageId: storageId),
    AppLevel.secret => AppLocation(storageId: storageId, filePath: filePath),
  };

  @override
  bool operator ==(Object other) =>
      other is AppLocation &&
      other.storageId == storageId &&
      other.filePath == filePath &&
      other.secretId == secretId;

  @override
  int get hashCode => Object.hash(storageId, filePath, secretId);

  @override
  String toString() => 'AppLocation($storageId/$filePath/$secretId)';
}

/// The current [AppLocation], shared by every layout so resizing the window
/// keeps what is open.
@Riverpod(keepAlive: true)
class CurrentLocation extends _$CurrentLocation {
  @override
  AppLocation build() {
    // Close a storage once it is removed.
    ref.listen(storageConfigsProvider, (_, next) {
      final storageId = state.storageId;
      final configs = next.value;
      if (storageId != null &&
          configs != null &&
          !configs.any((config) => config.id == storageId)) {
        state = const AppLocation();
      }
    });
    // Never show a secret of a locked file, or one that was deleted.
    ref.listen(unlockedVaultsProvider, (_, vaults) {
      final AppLocation(:storageId, :filePath, :secretId) = state;
      if (secretId == null) return;
      final vault = vaults[VaultRef(storageId!, filePath!)];
      if (vault?.payload.secretById(secretId) == null) state = state.parent;
    });
    return const AppLocation();
  }

  void openStorage(String storageId) {
    if (state.storageId != storageId) {
      state = AppLocation(storageId: storageId);
    }
  }

  void openFile(String storageId, String path) {
    if (state.storageId != storageId || state.filePath != path) {
      state = AppLocation(storageId: storageId, filePath: path);
    }
  }

  /// Closes the vault file at [path] in [storageId] if it is open, going
  /// back to its storage.
  void closeFile(String storageId, String path) {
    if (state.storageId == storageId && state.filePath == path) {
      state = AppLocation(storageId: storageId);
    }
  }

  /// Follows the vault file at [oldPath] in [storageId] to [newPath] after
  /// a rename, if it is open.
  void renameFile(String storageId, String oldPath, String newPath) {
    if (state.storageId == storageId && state.filePath == oldPath) {
      state = AppLocation(
        storageId: storageId,
        filePath: newPath,
        secretId: state.secretId,
      );
    }
  }

  void openSecret(String secretId) {
    final AppLocation(:storageId, :filePath) = state;
    if (filePath == null) throw StateError('No vault file is open');
    state = AppLocation(
      storageId: storageId,
      filePath: filePath,
      secretId: secretId,
    );
  }

  /// Goes one level up. Does nothing at the top.
  void up() => state = state.parent;
}
