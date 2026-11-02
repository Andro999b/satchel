import 'dart:convert';

import 'package:satchel_storage/satchel_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the Google accounts linked to Satchel. Identity only: tokens are
/// kept by `GoogleAuth` in secure storage, never here.
abstract interface class GoogleAccountStore {
  Future<List<GoogleAccount>> load();

  Future<void> save(List<GoogleAccount> accounts);
}

/// [GoogleAccountStore] in the platform's app preferences.
final class SharedPreferencesGoogleAccountStore implements GoogleAccountStore {
  SharedPreferencesGoogleAccountStore([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const key = 'satchel.googleAccounts.v1';

  final SharedPreferencesAsync _preferences;

  /// Entries this app version can't read are skipped.
  @override
  Future<List<GoogleAccount>> load() async {
    final raw = await _preferences.getString(key);
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List<Object?>) {
      throw const FormatException('Stored accounts must be a JSON list');
    }
    return [for (final entry in decoded) ?_parse(entry)];
  }

  @override
  Future<void> save(List<GoogleAccount> accounts) => _preferences.setString(
    key,
    jsonEncode([for (final account in accounts) account.toJson()]),
  );

  static GoogleAccount? _parse(Object? entry) {
    if (entry is! Map<String, Object?>) return null;
    try {
      return GoogleAccount.fromJson(entry);
    } on FormatException {
      return null;
    }
  }
}
