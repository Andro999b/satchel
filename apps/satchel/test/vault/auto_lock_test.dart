import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/settings/auto_lock_settings.dart';
import 'package:satchel/src/vault/auto_lock.dart';
import 'package:satchel/src/vault/unlocked_vaults.dart';
import 'package:satchel/src/vault/vault_providers.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../fakes.dart';

void main() {
  const vault = VaultRef('s', 'a.satchel');
  late DateTime now;
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, {AutoLockDelay? delay}) async {
    now = DateTime.utc(2026);
    container = ProviderContainer(
      overrides: [
        ...storageOverrides(
          platform: StoragePlatform.android,
          store: MemoryStorageConfigStore([directoryConfig('s', '/s')]),
          autoLock: MemoryAutoLockStore(delay),
        ),
        appClockProvider.overrideWithValue(Clock(() => now)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const AutoLock(child: SizedBox()),
      ),
    );
    await tester.pumpAndSettle();
    container
        .read(unlockedVaultsProvider.notifier)
        .adopt(
          vault,
          payload: VaultPayload.create(name: 'a', clock: Clock.fixed(now)),
          key: VaultKey.fromBytes(
            KdfParams.generate(memoryKiB: 64),
            Uint8List(32),
          ),
          revision: 'r1',
        );
  }

  bool unlocked() => container.read(unlockedVaultsProvider).containsKey(vault);

  void moveTo(WidgetTester tester, List<AppLifecycleState> states) {
    for (final state in states) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  void toBackground(WidgetTester tester) => moveTo(tester, [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]);

  void toForeground(WidgetTester tester) => moveTo(tester, [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]);

  tearDown(() {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets('locks every file after 5 minutes in the background', (
    tester,
  ) async {
    await pump(tester);

    toBackground(tester);
    await tester.pump(const Duration(minutes: 4, seconds: 59));
    expect(unlocked(), isTrue);

    await tester.pump(const Duration(seconds: 1));
    expect(unlocked(), isFalse);
  });

  testWidgets('losing focus alone keeps files unlocked', (tester) async {
    await pump(tester);

    moveTo(tester, [AppLifecycleState.inactive]);
    await tester.pump(const Duration(hours: 1));

    expect(unlocked(), isTrue);
  });

  testWidgets('coming back in time keeps files unlocked', (tester) async {
    await pump(tester);

    toBackground(tester);
    await tester.pump(const Duration(minutes: 4));
    toForeground(tester);
    await tester.pump(const Duration(hours: 1));

    expect(unlocked(), isTrue);
  });

  testWidgets('locks on return if the timer could not run', (tester) async {
    await pump(tester);

    toBackground(tester);
    now = now.add(const Duration(minutes: 6));
    toForeground(tester);
    await tester.pump();

    expect(unlocked(), isFalse);
  });

  testWidgets('follows the chosen delay', (tester) async {
    await pump(tester, delay: AutoLockDelay.oneMinute);

    toBackground(tester);
    await tester.pump(const Duration(minutes: 1));

    expect(unlocked(), isFalse);
  });

  testWidgets('never locks when set to never', (tester) async {
    await pump(tester, delay: AutoLockDelay.never);

    toBackground(tester);
    now = now.add(const Duration(days: 1));
    await tester.pump(const Duration(days: 1));
    toForeground(tester);
    await tester.pump();

    expect(unlocked(), isTrue);
  });
}
