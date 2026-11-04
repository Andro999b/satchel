import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/files/files_pane.dart';
import 'package:satchel/src/navigation/app_location.dart';
import 'package:satchel/src/pin/biometric_store.dart';
import 'package:satchel/src/pin/pin_store.dart';
import 'package:satchel/src/pin/pin_unlock.dart';
import 'package:satchel/src/secrets/secrets_pane.dart';
import 'package:satchel/src/storage/storage_providers.dart';
import 'package:satchel/src/vault/unlocked_vaults.dart';
import 'package:satchel/src/vault/vault_providers.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../fakes.dart';
import '../test_app.dart';

void main() {
  late FakeStorageProvider storage;
  late MemoryPinStore pins;
  late FakeBiometricStore biometrics;
  late ProviderContainer container;
  const vault = VaultRef('s', 'personal.satchel');

  /// Pumps [child]. With [withPin], the file has the PIN 123456, and with
  /// [withBiometric] also biometric unlock.
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    StoragePlatform platform = StoragePlatform.android,
    bool withPin = false,
    bool withBiometric = false,
  }) async {
    storage = FakeStorageProvider(id: 's');
    pins = MemoryPinStore();
    biometrics = FakeBiometricStore();
    await tester.runAsync(() async {
      await putVault(storage, vault.path, 'hunter22');
      if (!withPin) return;
      final opened = await VaultCodec.decrypt(
        storage.blobs[vault.path]!.bytes,
        password: 'hunter22',
      );
      final wrapped = await PinKeyWrap.wrap(
        opened.key,
        pin: '123456',
        deviceSecret: await pins.deviceSecret(),
        memoryKiB: 64,
        iterations: 1,
      );
      if (withBiometric) {
        biometrics.entries['bio'] = Uint8List.fromList(opened.key.bytes);
      }
      opened.key.destroy();
      pins.records[vault] = PinRecord(
        wrappedKey: wrapped.encode(),
        biometricId: withBiometric ? 'bio' : null,
      );
    });
    final android = platform == StoragePlatform.android;
    container = ProviderContainer(
      overrides: [
        ...storageOverrides(
          platform: platform,
          store: MemoryStorageConfigStore([directoryConfig('s', '/s')]),
          pins: android ? pins : null,
          biometrics: android ? biometrics : null,
        ),
        storageProvidersProvider.overrideWith((ref) async => [storage]),
        vaultCryptoProvider.overrideWithValue(
          const VaultCrypto(memoryKiB: 64, pinMemoryKiB: 64, pinIterations: 1),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(currentLocationProvider.notifier).openFile('s', vault.path);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testApp(child)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> unlock(WidgetTester tester) async {
    await tester.runAsync(
      () => container
          .read(unlockedVaultsProvider.notifier)
          .unlock(vault, 'hunter22'),
    );
    await tester.pumpAndSettle();
  }

  Finder menuItem(String label) => find.widgetWithText(MenuItemButton, label);

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byType(SecretsPane),
        matching: find.byTooltip('More actions'),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool isUnlocked() =>
      container.read(unlockedVaultsProvider).containsKey(vault);

  group('file menu', () {
    // The files pane shows which files have a PIN. The outer Scaffold shows
    // snack bars once, as the app shell does.
    const panes = Scaffold(
      body: Row(
        children: [
          Expanded(child: FilesPane(storageId: 's')),
          Expanded(
            child: SecretsPane(storageId: 's', path: 'personal.satchel'),
          ),
        ],
      ),
    );

    testWidgets('offers no PIN outside Android', (tester) async {
      await pump(tester, panes, platform: StoragePlatform.linux);
      await unlock(tester);

      await openMenu(tester);

      expect(menuItem('Import'), findsOneWidget);
      expect(menuItem('Set up PIN'), findsNothing);
    });

    testWidgets('sets up a PIN', (tester) async {
      await pump(tester, panes);
      await unlock(tester);

      await openMenu(tester);
      expect(menuItem('Remove PIN'), findsNothing);
      await tester.tap(menuItem('Set up PIN'));
      await tester.pumpAndSettle();
      expect(find.text('PIN for "personal"'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('newPin')), '12345');
      await tester.enterText(find.byKey(const Key('confirmPin')), '12345');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      expect(find.text('Enter 6 to 8 digits'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('newPin')), '12ab3456');
      await tester.enterText(find.byKey(const Key('confirmPin')), '123457');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      expect(find.text("The PINs don't match"), findsOneWidget);

      await tester.enterText(find.byKey(const Key('confirmPin')), '123456');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settleCrypto(tester, find.byType(AlertDialog));

      expect(pins.records.keys, [vault]);
      expect(
        find.text('You can now unlock "personal" with its PIN'),
        findsOneWidget,
      );
      expect(find.text('PIN unlock'), findsOneWidget);
      await openMenu(tester);
      expect(menuItem('Change PIN'), findsOneWidget);
    });

    testWidgets('removes the PIN', (tester) async {
      await pump(tester, panes, withPin: true);
      await unlock(tester);

      await openMenu(tester);
      expect(menuItem('Change PIN'), findsOneWidget);
      await tester.tap(menuItem('Remove PIN'));
      await tester.pumpAndSettle();

      expect(pins.records, isEmpty);
      expect(find.text('Removed the PIN of "personal"'), findsOneWidget);
      expect(find.text('PIN unlock'), findsNothing);
    });

    testWidgets('turns biometric unlock on and off', (tester) async {
      await pump(tester, panes, withPin: true);
      await unlock(tester);

      await openMenu(tester);
      await tester.tap(menuItem('Turn on biometric unlock'));
      await tester.pumpAndSettle();

      expect(biometrics.prompts, ['Turn on biometric unlock']);
      expect(biometrics.entries, hasLength(1));
      expect(
        find.text('You can now unlock "personal" with biometrics'),
        findsOneWidget,
      );
      expect(find.text('PIN and biometric unlock'), findsOneWidget);

      await openMenu(tester);
      await tester.tap(menuItem('Turn off biometric unlock'));
      await tester.pumpAndSettle();

      expect(biometrics.entries, isEmpty);
      expect(find.text('PIN unlock'), findsOneWidget);
    });

    testWidgets('offers biometrics only with a PIN', (tester) async {
      await pump(tester, panes);
      await unlock(tester);

      await openMenu(tester);

      expect(menuItem('Set up PIN'), findsOneWidget);
      expect(menuItem('Turn on biometric unlock'), findsNothing);
    });

    testWidgets('offers biometrics only when enrolled', (tester) async {
      await pump(tester, panes, withPin: true);
      biometrics.available = false;
      await unlock(tester);

      await openMenu(tester);

      expect(menuItem('Change PIN'), findsOneWidget);
      expect(menuItem('Turn on biometric unlock'), findsNothing);
    });
  });

  group('unlock form', () {
    const pane = SecretsPane(storageId: 's', path: 'personal.satchel');
    Finder unlockButton() => find.widgetWithText(FilledButton, 'Unlock');

    Future<void> enterPin(WidgetTester tester, String pin) async {
      await tester.enterText(find.byKey(const Key('unlockPin')), pin);
      await tester.pump();
      await tester.tap(unlockButton());
      await settleCrypto(tester, find.text('Unlocking…'));
    }

    testWidgets('asks for the PIN of a file that has one', (tester) async {
      await pump(tester, pane, withPin: true);

      expect(find.text('Use biometrics'), findsNothing);
      expect(
        find.text('This file is locked. Enter its PIN to open it.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('unlockPassword')), findsNothing);
      await tester.enterText(find.byKey(const Key('unlockPin')), '12345');
      await tester.pump();
      expect(tester.widget<FilledButton>(unlockButton()).onPressed, isNull);

      await enterPin(tester, '123456');

      expect(isUnlocked(), isTrue);
    });

    testWidgets('unlocks with biometrics', (tester) async {
      await pump(tester, pane, withPin: true, withBiometric: true);

      await tester.tap(find.text('Use biometrics'));
      await settleCrypto(tester, find.text('Unlocking…'));

      expect(isUnlocked(), isTrue);
      expect(biometrics.prompts, ['Unlock "personal"']);
    });

    testWidgets('a dismissed prompt leaves the PIN field', (tester) async {
      await pump(tester, pane, withPin: true, withBiometric: true);
      biometrics.error = const BiometricCancelledException();

      await tester.tap(find.text('Use biometrics'));
      await settleCrypto(tester, find.text('Unlocking…'));

      expect(isUnlocked(), isFalse);
      expect(find.byKey(const Key('unlockPin')), findsOneWidget);
      expect(find.textContaining('Biometric'), findsNothing);
    });

    testWidgets('explains when biometrics were turned off', (tester) async {
      await pump(tester, pane, withPin: true, withBiometric: true);
      biometrics.invalidate();

      await tester.tap(find.text('Use biometrics'));
      await settleCrypto(tester, find.text('Unlocking…'));

      expect(
        find.text(
          'Biometrics on this device changed, so biometric unlock was turned '
          'off. Enter the PIN.',
        ),
        findsOneWidget,
      );
      expect(find.text('Use biometrics'), findsNothing);
      await enterPin(tester, '123456');
      expect(isUnlocked(), isTrue);
    });

    testWidgets('counts wrong PINs', (tester) async {
      await pump(tester, pane, withPin: true);

      await enterPin(tester, '654321');

      expect(isUnlocked(), isFalse);
      expect(find.text('Wrong PIN. 4 attempts left.'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('unlockPin')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller!.text, isEmpty);
      expect(field.focusNode!.hasFocus, isTrue);
    });

    testWidgets('asks for the password after too many wrong PINs', (
      tester,
    ) async {
      await pump(tester, pane, withPin: true);

      for (var i = 0; i < maxPinAttempts; i++) {
        await enterPin(tester, '000000');
      }

      expect(pins.records, isEmpty);
      expect(find.byKey(const Key('unlockPin')), findsNothing);
      expect(
        find.text(
          'Too many wrong PINs, so the PIN was removed. Enter the password.',
        ),
        findsOneWidget,
      );
      expect(find.text('Use PIN instead'), findsNothing);
    });

    testWidgets('can switch to the password and back', (tester) async {
      await pump(tester, pane, withPin: true);

      await tester.tap(find.text('Use password instead'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('unlockPin')), findsNothing);
      expect(find.byKey(const Key('unlockPassword')), findsOneWidget);

      await tester.tap(find.text('Use PIN instead'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('unlockPin')), findsOneWidget);

      await tester.tap(find.text('Use password instead'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('unlockPassword')),
        'hunter22',
      );
      await tester.pump();
      await tester.tap(unlockButton());
      await settleCrypto(tester, find.text('Unlocking…'));
      expect(isUnlocked(), isTrue);
    });
  });
}
