import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Texts of the system biometric prompt, already localized.
final class BiometricPromptText {
  const BiometricPromptText({required this.title, required this.cancel});

  final String title;

  /// The prompt's dismiss button.
  final String cancel;
}

/// The user dismissed the biometric prompt.
final class BiometricCancelledException implements Exception {
  const BiometricCancelledException();
}

/// Biometric authentication failed, e.g. too many attempts (the system then
/// locks biometrics for a while).
final class BiometricFailedException implements Exception {
  const BiometricFailedException();
}

/// Vault keys that only strong biometrics release (Android Keystore keys
/// requiring user authentication for every use).
abstract interface class BiometricStore {
  /// Whether strong biometrics are enrolled on this device.
  Future<bool> isAvailable();

  /// Stores [key] under [id], after a biometric prompt.
  Future<void> write(String id, Uint8List key, BiometricPromptText prompt);

  /// The key stored under [id], after a biometric prompt, or `null` if it is
  /// gone, e.g. because biometrics were enrolled since it was stored. Zero it
  /// after use.
  Future<Uint8List?> read(String id, BiometricPromptText prompt);

  /// Deletes [id] without a prompt.
  Future<void> delete(String id);
}

/// [BiometricStore] in a separate `flutter_secure_storage` namespace whose
/// Keystore key needs strong biometrics for each read and write, and is
/// invalidated when biometrics are enrolled.
final class SecureBiometricStore implements BiometricStore {
  const SecureBiometricStore();

  static const namespace = 'satchel_biometric';
  static const keyPrefix = 'satchel.biometric.v1.';
  static const _channel = MethodChannel('dev.satchel.satchel/biometrics');

  // Android BiometricPrompt error codes that mean the user dismissed it.
  static const _cancelCodes = {5, 10, 13};

  static FlutterSecureStorage _storage([BiometricPromptText? prompt]) =>
      FlutterSecureStorage(
        aOptions: AndroidOptions.biometric(
          enforceBiometrics: true,
          requireBiometricsPerOperation: true,
          biometricType: AndroidBiometricType.strongBiometricOnly,
          storageNamespace: namespace,
          biometricPromptTitle: prompt?.title,
          biometricPromptNegativeButton: prompt?.cancel,
        ),
      );

  @override
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isStrongBiometricAvailable') ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> write(String id, Uint8List key, BiometricPromptText prompt) =>
      _guard(
        () =>
            _storage(prompt)
                .write(key: '$keyPrefix$id', value: base64.encode(key)),
      );

  @override
  Future<Uint8List?> read(String id, BiometricPromptText prompt) async {
    final value = await _guard(
      () => _storage(prompt).read(key: '$keyPrefix$id'),
    );
    if (value == null) return null;
    try {
      final bytes = base64.decode(value);
      // The plugin may answer with a status text after resetting its data.
      return bytes.length == 32 ? bytes : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> delete(String id) => _storage().delete(key: '$keyPrefix$id');

  static Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on PlatformException catch (e) {
      final code = RegExp(r'Biometric authentication error \[(\d+)\]')
          .firstMatch('${e.message} ${e.details}')
          ?.group(1);
      if (code != null && _cancelCodes.contains(int.parse(code))) {
        throw const BiometricCancelledException();
      }
      throw const BiometricFailedException();
    }
  }
}
