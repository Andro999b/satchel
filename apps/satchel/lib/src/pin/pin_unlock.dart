import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../storage/storage_providers.dart';
import '../vault/unlocked_vaults.dart';
import '../vault/vault_providers.dart';
import 'biometric_store.dart';
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

/// The file's biometric key is gone, e.g. because biometrics were enrolled on
/// the device since it was stored. Biometric unlock was turned off; the PIN
/// still works.
final class BiometricRemovedException implements Exception {
  const BiometricRemovedException();
}

/// PIN data for this platform, or `null` where PIN unlock isn't offered
/// (everywhere but Android).
@Riverpod(keepAlive: true)
PinStore? pinStore(Ref ref) =>
    ref.watch(storagePlatformProvider) == StoragePlatform.android
    ? SecurePinStore()
    : null;

/// Biometric keys, or `null` where PIN unlock isn't offered.
@Riverpod(keepAlive: true)
BiometricStore? biometricStore(Ref ref) =>
    ref.watch(pinStoreProvider) == null ? null : const SecureBiometricStore();

/// Whether this device has strong biometrics for biometric unlock.
@riverpod
Future<bool> biometricAvailable(Ref ref) async =>
    await ref.watch(biometricStoreProvider)?.isAvailable() ?? false;

/// How [vault] can be unlocked without its password.
@riverpod
QuickUnlock quickUnlock(Ref ref, VaultRef vault) =>
    ref.watch(pinUnlockProvider).value?[vault] ?? QuickUnlock.none;

/// How a vault file can be unlocked without its password.
enum QuickUnlock {
  none,
  pin,
  pinAndBiometric;

  bool get hasPin => this != none;

  static QuickUnlock of(PinRecord record) =>
      record.biometricId == null ? pin : pinAndBiometric;
}

/// The vault files that can be unlocked with a PIN, and whether also with
/// biometrics. Files without a PIN are absent; read one file's mode with
/// [quickUnlockProvider].
///
/// Each file's key is stored wrapped under its PIN and a device secret (see
/// [PinKeyWrap]), never its password. With biometric unlock, the key is also
/// kept in the [BiometricStore], which needs the PIN to be set. PIN data of
/// removed storages is dropped.
@Riverpod(keepAlive: true)
class PinUnlock extends _$PinUnlock {
  Future<void> _queue = Future.value();

  @override
  Future<Map<VaultRef, QuickUnlock>> build() async {
    final store = ref.watch(pinStoreProvider);
    if (store == null) return const {};
    final storageIds = {
      for (final config in await ref.watch(storageConfigsProvider.future))
        config.id,
    };
    return _serialized(() async {
      final records = await store.loadAll();
      final kept = <VaultRef, QuickUnlock>{};
      for (final MapEntry(key: vault, value: record) in records.entries) {
        if (storageIds.contains(vault.storageId)) {
          kept[vault] = QuickUnlock.of(record);
        } else {
          await store.delete(vault);
          await _deleteBiometric(record.biometricId);
        }
      }
      return Map.unmodifiable(kept);
    });
  }

  /// Lets the unlocked vault [vault] be unlocked with [pin] from now on,
  /// replacing any earlier PIN. Biometric unlock stays as it was.
  Future<void> enable(VaultRef vault, String pin) async {
    if (!isValidPin(pin)) throw ArgumentError('Invalid PIN');
    final store = _store;
    await future;
    await _serialized(() async {
      final key = ref.read(unlockedVaultsProvider)[vault]?.key;
      if (key == null) throw StateError('Vault is locked');
      final secret = await store.deviceSecret();
      final String? biometricId;
      try {
        final wrapped = await ref
            .read(vaultCryptoProvider)
            .wrapWithPin(key, pin: pin, deviceSecret: secret);
        final previous = await store.read(vault);
        biometricId = _sameKey(previous, key) ? previous?.biometricId : null;
        await store.write(
          vault,
          PinRecord(wrappedKey: wrapped.encode(), biometricId: biometricId),
        );
        if (biometricId == null) await _deleteBiometric(previous?.biometricId);
      } finally {
        secret.fillRange(0, secret.length, 0);
      }
      _update(
        (vaults) => vaults[vault] = biometricId == null
            ? QuickUnlock.pin
            : QuickUnlock.pinAndBiometric,
      );
    });
  }

  /// Lets the unlocked vault [vault], which has a PIN, also be unlocked with
  /// biometrics. Shows the biometric prompt with [prompt].
  ///
  /// Throws the exceptions of [BiometricStore.write], e.g.
  /// [BiometricCancelledException].
  Future<void> enableBiometric(
    VaultRef vault,
    BiometricPromptText prompt,
  ) async {
    final store = _store;
    final biometrics = _biometrics;
    await future;
    await _serialized(() async {
      final key = ref.read(unlockedVaultsProvider)[vault]?.key;
      if (key == null) throw StateError('Vault is locked');
      final record = await store.read(vault);
      if (record == null) throw StateError('Biometric unlock needs a PIN');
      if (!_sameKey(record, key)) {
        await _delete(store, vault);
        throw const PinRemovedException(PinRemovedReason.passwordChanged);
      }
      final id = record.biometricId ?? newId();
      await biometrics.write(id, key.bytes, prompt);
      await store.write(vault, record.withBiometricId(id));
      _update((vaults) => vaults[vault] = QuickUnlock.pinAndBiometric);
    });
  }

  /// Turns biometric unlock off for [vault]; its PIN stays.
  Future<void> disableBiometric(VaultRef vault) async {
    final store = _store;
    await future;
    await _serialized(() async {
      final record = await store.read(vault);
      if (record == null) return;
      await store.write(vault, record.withBiometricId(null));
      await _deleteBiometric(record.biometricId);
      _update((vaults) => vaults[vault] = QuickUnlock.pin);
    });
  }

  /// Removes the PIN of [vault], and with it biometric unlock.
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
            ..[to] = QuickUnlock.of(record),
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

  /// Unlocks [vault] with biometrics, showing the prompt with [prompt].
  ///
  /// Doesn't count PIN attempts: the system limits biometric attempts.
  /// Throws [BiometricRemovedException], [PinRemovedException] if the
  /// password changed, the exceptions of [BiometricStore.read], and those of
  /// [UnlockedVaults.unlockWithKey].
  Future<void> unlockWithBiometric(
    VaultRef vault,
    BiometricPromptText prompt,
  ) async {
    final store = _store;
    final biometrics = _biometrics;
    await future;
    await ref
        .read(unlockedVaultsProvider.notifier)
        .unlockWithKey(
          vault,
          (params) => _serialized(() async {
            final record = await store.read(vault);
            final id = record?.biometricId;
            if (record == null || id == null) {
              _update((vaults) {
                if (vaults.containsKey(vault)) vaults[vault] = QuickUnlock.pin;
              });
              throw const BiometricRemovedException();
            }
            final wrapped = await _checkedWrappedKey(
              store,
              vault,
              record,
              params,
            );
            final bytes = await biometrics.read(id, prompt);
            if (bytes == null) {
              await store.write(vault, record.withBiometricId(null));
              _update((vaults) => vaults[vault] = QuickUnlock.pin);
              throw const BiometricRemovedException();
            }
            return VaultKey.fromBytes(wrapped.vaultParams, bytes);
          }),
        );
  }

  /// The wrapped key of [record], if it still matches the file's
  /// [fileParams]. Otherwise removes the PIN and throws
  /// [PinRemovedException].
  Future<PinWrappedKey> _checkedWrappedKey(
    PinStore store,
    VaultRef vault,
    PinRecord record,
    KdfParams fileParams,
  ) async {
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
    return wrapped;
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
    final wrapped = await _checkedWrappedKey(store, vault, record, fileParams);
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

  BiometricStore get _biometrics =>
      ref.read(biometricStoreProvider) ??
      (throw UnsupportedError('Biometric unlock is not available'));

  /// Whether [record] holds the same vault key as [key], so its biometric
  /// entry still opens the file.
  static bool _sameKey(PinRecord? record, VaultKey key) {
    if (record == null) return false;
    try {
      return PinWrappedKey.decode(record.wrappedKey).vaultParams == key.params;
    } on VaultFormatException {
      return false;
    }
  }

  Future<void> _delete(PinStore store, VaultRef vault) async {
    final biometricId = (await store.read(vault))?.biometricId;
    await store.delete(vault);
    await _deleteBiometric(biometricId);
    _update((vaults) => vaults.remove(vault));
  }

  /// Best effort: an orphaned entry is unreadable without its PIN record.
  Future<void> _deleteBiometric(String? id) async {
    if (id == null) return;
    try {
      await ref.read(biometricStoreProvider)?.delete(id);
    } on Exception catch (e) {
      debugPrint('Could not delete a biometric key: $e');
    }
  }

  void _update(void Function(Map<VaultRef, QuickUnlock> vaults) change) {
    if (!ref.mounted) return;
    final vaults = {...?state.value};
    change(vaults);
    state = AsyncData(Map.unmodifiable(vaults));
  }

  /// Runs [task] after every earlier PIN operation, so attempt counts
  /// aren't lost between concurrent unlocks.
  Future<T> _serialized<T>(Future<T> Function() task) {
    final next = _queue.catchError((Object _) {}).then((_) => task());
    _queue = next.then((_) {}, onError: (Object _) {});
    return next;
  }
}
