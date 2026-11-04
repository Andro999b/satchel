import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'auto_lock_settings.g.dart';

/// How long the app may be in the background before every vault is locked.
enum AutoLockDelay {
  oneMinute(Duration(minutes: 1)),
  fiveMinutes(Duration(minutes: 5)),
  fifteenMinutes(Duration(minutes: 15)),
  thirtyMinutes(Duration(minutes: 30)),
  oneHour(Duration(hours: 1)),
  never(null);

  const AutoLockDelay(this.duration);

  /// `null` for [never].
  final Duration? duration;

  static const standard = fiveMinutes;
}

/// Persists the [AutoLockDelay]. Names are the stored values: never rename
/// them.
abstract interface class AutoLockStore {
  Future<AutoLockDelay?> load();

  Future<void> save(AutoLockDelay delay);
}

/// [AutoLockStore] in the platform's app preferences.
final class SharedPreferencesAutoLockStore implements AutoLockStore {
  SharedPreferencesAutoLockStore([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const key = 'satchel.autoLock.v1';

  final SharedPreferencesAsync _preferences;

  @override
  Future<AutoLockDelay?> load() async {
    final name = await _preferences.getString(key);
    return AutoLockDelay.values.where((d) => d.name == name).firstOrNull;
  }

  @override
  Future<void> save(AutoLockDelay delay) =>
      _preferences.setString(key, delay.name);
}

@Riverpod(keepAlive: true)
AutoLockStore autoLockStore(Ref ref) => SharedPreferencesAutoLockStore();

/// The chosen [AutoLockDelay], [AutoLockDelay.standard] until one is set.
@Riverpod(keepAlive: true)
class AutoLockSetting extends _$AutoLockSetting {
  @override
  Future<AutoLockDelay> build() async =>
      await ref.watch(autoLockStoreProvider).load() ?? AutoLockDelay.standard;

  Future<void> set(AutoLockDelay delay) async {
    await ref.read(autoLockStoreProvider).save(delay);
    state = AsyncData(delay);
  }
}
