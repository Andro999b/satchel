import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/auto_lock_settings.dart';
import 'unlocked_vaults.dart';
import 'vault_providers.dart';

/// Locks every vault once the app has been in the background (hidden) for
/// the [AutoLockDelay]. Losing focus alone (e.g. to another window, or a
/// system dialog) doesn't count.
class AutoLock extends ConsumerStatefulWidget {
  const AutoLock({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AutoLock> createState() => _AutoLockState();
}

class _AutoLockState extends ConsumerState<AutoLock> {
  late final AppLifecycleListener _listener;
  Timer? _timer;
  DateTime? _hiddenAt;
  Duration? _delay;

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(onHide: _hidden, onShow: _shown);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _listener.dispose();
    super.dispose();
  }

  void _hidden() {
    final delay =
        (ref.read(autoLockSettingProvider).value ?? AutoLockDelay.standard)
            .duration;
    if (delay == null) return;
    _delay = delay;
    _hiddenAt = ref.read(appClockProvider).now();
    _timer?.cancel();
    _timer = Timer(delay, _lockAll);
  }

  void _shown() {
    _timer?.cancel();
    _timer = null;
    final hiddenAt = _hiddenAt;
    final delay = _delay;
    _hiddenAt = null;
    // Background timers may not run, e.g. while Android suspends the app.
    if (hiddenAt != null &&
        delay != null &&
        ref.read(appClockProvider).now().difference(hiddenAt) >= delay) {
      _lockAll();
    }
  }

  void _lockAll() => ref.read(unlockedVaultsProvider.notifier).lockAll();

  @override
  Widget build(BuildContext context) {
    // Load the setting early, so it is known when the app is hidden.
    ref.watch(autoLockSettingProvider);
    return widget.child;
  }
}
