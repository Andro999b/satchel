import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../storage/storage_providers.dart';
import '../vault/unlocked_vaults.dart';
import '../vault/vault_providers.dart';
import 'pin_store.dart';

part 'pin_unlock.g.dart';

/// Failed PIN attempts after which a file's PIN is removed.
const maxPinAttempts = 5;

/// The PIN was wrong; [attemptsLeft] more tries before the PIN is removed.
final class WrongPinException implements Exception {
  const WrongPinException(this.attemptsLeft);

  final int attemptsLeft;

  @override
  String toString() => 'WrongPinException: $attemptsLeft left';
}

enum PinRemovedReason {
  /// [maxPinAttempts] wrong PINs in a row.
  tooManyAttempts,

  /// The file's password changed, so the stored key no longer opens it.
  passwordChanged,

  /// The PIN data is missing or unreadable.
  unavailable,
}

/// The file's PIN was removed: it needs its password.
final class PinRemovedException implements Exception {
  const PinRemovedException(this.reason);

  final PinRemovedReason reason;

  @override
  String toString() => 'PinRemovedException: ${reason.name}';
}

/// PIN data for this platform, or `null` where PIN unlock isn't offered
/// (everywhere but Android).
@Riverpod(keepAlive: true)
PinStore? pinStore(Ref ref) =>
    ref.watch(storagePlatformProvider) == StoragePlatform.android
    ? SecurePinStore()
    : null;

/// The vault files that can be unlocked with a PIN.
///
/// Each file's key is stored wrapped under its PIN and a device secret (see
/// [PinKeyWrap]), never its password. PIN data of removed storages is
/// dropped.
@Riverpod(keepAlive: true)
class PinUnlock extends _$PinUnlock {
  Future<void> _queue = Future.value();

  @override
  Future<Set<VaultRef>> build() async {
    final store = ref.watch(pinStoreProvider);
    if (store == null) return const {};
    final storageIds = {
      for (final config in await ref.watch(storageConfigsProvider.future))
        config.id,
    };
    return _serialized(() async {
      final records = await store.loadAll();
      for (final vault in records.keys) {
        if (!storageIds.contains(vault.storageId)) await store.delete(vault);
      }
      return {
        for (final vault in records.keys)
          if (storageIds.contains(vault.storageId)) vault,
      };
    });
  }

  /// Lets the unlocked vault [vault] be unlocked with [pin] from now on,
  /// replacing any earlier PIN.
  Future<void> enable(VaultRef vault, String pin) async {
    if (!isValidPin(pin)) throw ArgumentError('Invalid PIN');
    final store = _store;
    await future;
    await _serialized(() async {
      final key = ref.read(unlockedVaultsProvider)[vault]?.key;
      if (key == null) throw StateError('Vault is locked');
      final secret = await store.deviceSecret();
      try {
        final wrapped = await ref
            .read(vaultCryptoProvider)
            .wrapWithPin(key, pin: pin, deviceSecret: secret);
        await store.write(vault, PinRecord(wrappedKey: wrapped.encode()));
      } finally {
        secret.fillRange(0, secret.length, 0);
      }
      _update((vaults) => vaults.add(vault));
    });
  }

  /// Removes the PIN of [vault].
  Future<void> disable(VaultRef vault) async {
    final store = _store;
    await future;
    await _serialized(() => _delete(store, vault));
  }

  /// Removes the PIN of [vault], e.g. after its password changed. Never
  /// throws.
  Future<void> forget(VaultRef vault) async {
    final store = ref.read(pinStoreProvider);
    if (store == null) return;
    try {
      await future;
      await _serialized(() => _delete(store, vault));
    } on Exception catch (e) {
      debugPrint('Could not remove the PIN of $vault: $e');
    }
  }

  /// Keeps the PIN of a file renamed from [from] to [to]. Never throws.
  Future<void> moved(VaultRef from, VaultRef to) async {
    final store = ref.read(pinStoreProvider);
    if (store == null) return;
    try {
      await future;
      await _serialized(() async {
        final record = await store.read(from);
        if (record == null) return;
        await store.write(to, record);
        await store.delete(from);
        _update(
          (vaults) => vaults
            ..remove(from)
            ..add(to),
        );
      });
    } on Exception catch (e) {
      debugPrint('Could not move the PIN of $from: $e');
    }
  }

  /// Unlocks [vault] with [pin].
  ///
  /// Every attempt is counted before the PIN is checked. Throws
  /// [WrongPinException], [PinRemovedException] once the PIN can't be used
  /// anymore, and the exceptions of [UnlockedVaults.unlockWithKey].
  Future<void> unlock(VaultRef vault, String pin) async {
    final store = _store;
    await future;
    await ref
        .read(unlockedVaultsProvider.notifier)
        .unlockWithKey(
          vault,
          (params) => _serialized(() => _unwrap(store, vault, pin, params)),
        );
  }

  Future<VaultKey> _unwrap(
    PinStore store,
    VaultRef vault,
    String pin,
    KdfParams fileParams,
  ) async {
    final record = await store.read(vault);
    if (record == null) {
      _update((vaults) => vaults.remove(vault));
      throw const PinRemovedException(PinRemovedReason.unavailable);
    }
    final PinWrappedKey wrapped;
    try {
      wrapped = PinWrappedKey.decode(record.wrappedKey);
    } on VaultFormatException {
      await _delete(store, vault);
      throw const PinRemovedException(PinRemovedReason.unavailable);
    }
    if (wrapped.vaultParams != fileParams) {
      await _delete(store, vault);
      throw const PinRemovedException(PinRemovedReason.passwordChanged);
    }
    if (record.failedAttempts >= maxPinAttempts) {
      await _delete(store, vault);
      throw const PinRemovedException(PinRemovedReason.tooManyAttempts);
    }

    final attempts = record.failedAttempts + 1;
    await store.write(vault, record.withFailedAttempts(attempts));
    final secret = await store.deviceSecret();
    try {
      final key = await PinKeyWrap.unwrap(
        wrapped,
        pin: pin,
        deviceSecret: secret,
      );
      await store.write(vault, record.withFailedAttempts(0));
      return key;
    } on VaultAuthenticationException {
      if (attempts >= maxPinAttempts) {
        await _delete(store, vault);
        throw const PinRemovedException(PinRemovedReason.tooManyAttempts);
      }
      throw WrongPinException(maxPinAttempts - attempts);
    } finally {
      secret.fillRange(0, secret.length, 0);
    }
  }

  PinStore get _store =>
      ref.read(pinStoreProvider) ??
      (throw UnsupportedError('PIN unlock is not available'));

  Future<void> _delete(PinStore store, VaultRef vault) async {
    await store.delete(vault);
    _update((vaults) => vaults.remove(vault));
  }

  void _update(void Function(Set<VaultRef> vaults) change) {
    if (!ref.mounted) return;
    final vaults = {...?state.value};
    change(vaults);
    state = AsyncData(Set.unmodifiable(vaults));
  }

  /// Runs [task] after every earlier PIN operation, so attempt counts
  /// aren't lost between concurrent unlocks.
  Future<T> _serialized<T>(Future<T> Function() task) {
    final next = _queue.catchError((Object _) {}).then((_) => task());
    _queue = next.then((_) {}, onError: (Object _) {});
    return next;
  }
}
