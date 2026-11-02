import 'dart:convert';

import 'package:satchel_storage/satchel_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the storages the user added. Holds non-secret settings only.
abstract interface class StorageConfigStore {
  Future<List<StorageConfig>> load();

  Future<void> save(List<StorageConfig> configs);
}

/// [StorageConfigStore] in the platform's app preferences.
final class SharedPreferencesStorageConfigStore implements StorageConfigStore {
  SharedPreferencesStorageConfigStore([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const key = 'satchel.storages.v1';

  final SharedPreferencesAsync _preferences;

  /// Entries this app version can't read (e.g. a kind from a newer version)
  /// are skipped.
  @override
  Future<List<StorageConfig>> load() async {
    final raw = await _preferences.getString(key);
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List<Object?>) {
      throw const FormatException('Stored storages must be a JSON list');
    }
    return [for (final entry in decoded) ?_parse(entry)];
  }

  @override
  Future<void> save(List<StorageConfig> configs) => _preferences.setString(
    key,
    jsonEncode([for (final config in configs) config.toJson()]),
  );

  static StorageConfig? _parse(Object? entry) {
    if (entry is! Map<String, Object?>) return null;
    try {
      return StorageConfig.fromJson(entry);
    } on FormatException {
      return null;
    }
  }
}
