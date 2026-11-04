import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:satchel_core/satchel_core.dart';

import '../vault/unlocked_vaults.dart';

/// The PIN data of one vault file: its key wrapped under the PIN
/// ([PinWrappedKey.encode]) and the failed attempts since the last unlock.
@immutable
final class PinRecord {
  const PinRecord({required this.wrappedKey, this.failedAttempts = 0});

  final String wrappedKey;
  final int failedAttempts;

  PinRecord withFailedAttempts(int failedAttempts) =>
      PinRecord(wrappedKey: wrappedKey, failedAttempts: failedAttempts);

  @override
  String toString() => 'PinRecord(<redacted>, $failedAttempts)';
}

/// Persists PIN records and the device secret in platform secure storage.
abstract interface class PinStore {
  /// The device secret, created on first use. Zero it after use.
  Future<Uint8List> deviceSecret();

  Future<Map<VaultRef, PinRecord>> loadAll();

  Future<PinRecord?> read(VaultRef vault);

  Future<void> write(VaultRef vault, PinRecord record);

  Future<void> delete(VaultRef vault);
}

/// [PinStore] in `flutter_secure_storage` (the Android Keystore).
final class SecurePinStore implements PinStore {
  SecurePinStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const deviceSecretKey = 'satchel.pin.deviceSecret';
  static const recordPrefix = 'satchel.pin.v1.';

  final FlutterSecureStorage _storage;

  @override
  Future<Uint8List> deviceSecret() async {
    final stored = await _storage.read(key: deviceSecretKey);
    if (stored != null) {
      final bytes = base64.decode(stored);
      if (bytes.length == PinKeyWrap.deviceSecretLength) return bytes;
    }
    final secret = PinKeyWrap.generateDeviceSecret();
    await _storage.write(key: deviceSecretKey, value: base64.encode(secret));
    return secret;
  }

  /// Entries this app version can't read are skipped.
  @override
  Future<Map<VaultRef, PinRecord>> loadAll() async {
    final all = await _storage.readAll();
    return {
      for (final MapEntry(:key, :value) in all.entries)
        if (key.startsWith(recordPrefix))
          if (_parse(value) case (final vault, final record)) vault: record,
    };
  }

  @override
  Future<PinRecord?> read(VaultRef vault) async {
    final value = await _storage.read(key: _key(vault));
    return value == null ? null : _parse(value)?.$2;
  }

  @override
  Future<void> write(VaultRef vault, PinRecord record) => _storage.write(
    key: _key(vault),
    value: jsonEncode({
      'storageId': vault.storageId,
      'path': vault.path,
      'wrappedKey': record.wrappedKey,
      'failedAttempts': record.failedAttempts,
    }),
  );

  @override
  Future<void> delete(VaultRef vault) => _storage.delete(key: _key(vault));

  static String _key(VaultRef vault) =>
      '$recordPrefix${base64Url.encode(utf8.encode(jsonEncode([vault.storageId, vault.path])))}';

  static (VaultRef, PinRecord)? _parse(String value) {
    try {
      if (jsonDecode(value) case {
        'storageId': final String storageId,
        'path': final String path,
        'wrappedKey': final String wrappedKey,
        'failedAttempts': final int failedAttempts,
      }) {
        return (
          VaultRef(storageId, path),
          PinRecord(wrappedKey: wrappedKey, failedAttempts: failedAttempts),
        );
      }
    } on FormatException {
      // Unreadable: treated as missing.
    }
    return null;
  }
}
