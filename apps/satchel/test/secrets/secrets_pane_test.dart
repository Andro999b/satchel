import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/export/export_providers.dart';
import 'package:satchel/src/export/export_secrets.dart';
import 'package:satchel/src/navigation/app_location.dart';
import 'package:satchel/src/secrets/secrets_pane.dart';
import 'package:satchel/src/storage/storage_providers.dart';
import 'package:satchel/src/vault/unlocked_vaults.dart';
import 'package:satchel/src/vault/vault_providers.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../fakes.dart';
import '../test_app.dart';

SecretInfo _info(String id, String title) => SecretInfo(
  id: id,
  title: title,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

final _secrets = <Secret>[
  LoginSecret(info: _info('l1', 'Example Bank'), username: 'ann'),
  NoteSecret(info: _info('n1', 'Safe'), text: '12-34-56'),
];

void main() {
  late FakeStorageProvider storage;
  late FakeFileExporter exporter;
  late ProviderContainer container;
  const vault = VaultRef('s', 'personal.satchel');
  const lockedMessage = 'This file is locked. Enter its password to open it.';

  Finder unlockButton() => find.widgetWithText(FilledButton, 'Unlock');

  Future<void> pumpPane(
    WidgetTester tester, {
    List<Secret> secrets = const [],
  }) async {
    storage = FakeStorageProvider(id: 's');
    exporter = FakeFileExporter();
    await tester.runAsync(
      () => putVault(storage, vault.path, 'hunter22', secrets: secrets),
    );
    container = ProviderContainer(
      overrides: [
        ...storageOverrides(
          platform: StoragePlatform.linux,
          store: MemoryStorageConfigStore([
            directoryConfig('s', '/s', name: 'Sync folder'),
          ]),
        ),
        storageProvidersProvider.overrideWith((ref) async => [storage]),
        fileExporterProvider.overrideWithValue(exporter),
        vaultCryptoProvider.overrideWithValue(const VaultCrypto(memoryKiB: 64)),
      ],
    );
    addTearDown(container.dispose);
    container.read(currentLocationProvider.notifier).openFile('s', vault.path);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: testApp(
          const SecretsPane(storageId: 's', path: 'personal.satchel'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> unlockWith(WidgetTester tester, String password) async {
    await tester.enterText(find.byKey(const Key('unlockPassword')), password);
    await tester.pump();
    await tester.tap(unlockButton());
    await settleCrypto(tester, find.text('Unlocking…'));
  }

  bool isUnlocked() =>
      container.read(unlockedVaultsProvider).containsKey(vault);

  testWidgets('a locked file asks for its password', (tester) async {
    await pumpPane(tester);

    expect(find.text('personal'), findsOneWidget);
    expect(find.text(lockedMessage), findsOneWidget);
    expect(find.byTooltip('Lock'), findsNothing);
    expect(tester.widget<FilledButton>(unlockButton()).onPressed, isNull);

    await tester.enterText(find.byKey(const Key('unlockPassword')), 'x');
    await tester.pump();
    expect(tester.widget<FilledButton>(unlockButton()).onPressed, isNotNull);
  });

  testWidgets('unlocks with the right password and lists secrets', (
    tester,
  ) async {
    await pumpPane(tester, secrets: _secrets);

    await unlockWith(tester, 'hunter22');

    expect(isUnlocked(), isTrue);
    expect(find.text(lockedMessage), findsNothing);
    expect(find.text('Example Bank'), findsOneWidget);
    expect(find.text('Safe'), findsOneWidget);
    expect(find.byIcon(Icons.account_circle_outlined), findsOneWidget);
    expect(find.byIcon(Icons.sticky_note_2_outlined), findsOneWidget);
    expect(find.byTooltip('Lock'), findsOneWidget);
  });

  testWidgets('pressing Enter unlocks', (tester) async {
    await pumpPane(tester);

    await tester.enterText(find.byKey(const Key('unlockPassword')), 'hunter22');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleCrypto(tester, find.text('Unlocking…'));

    expect(isUnlocked(), isTrue);
    expect(find.text('No secrets in this file yet'), findsOneWidget);
  });

  testWidgets('a wrong password shows an error and stays locked', (
    tester,
  ) async {
    await pumpPane(tester);

    await unlockWith(tester, 'hunter23');

    expect(isUnlocked(), isFalse);
    expect(find.text('Wrong password, or the file is damaged'), findsOneWidget);
    expect(find.text(lockedMessage), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const Key('unlockPassword')),
    );
    expect(field.focusNode!.hasFocus, isTrue);
    expect(
      field.controller!.selection,
      const TextSelection(baseOffset: 0, extentOffset: 8),
    );

    await unlockWith(tester, 'hunter22');
    expect(isUnlocked(), isTrue);
  });

  testWidgets('explains files that cannot be read', (tester) async {
    await pumpPane(tester);
    storage.blobs[vault.path] = (
      bytes: Uint8List.fromList(utf8.encode('this is certainly not a vault')),
      revision: 'x',
    );

    await unlockWith(tester, 'hunter22');
    expect(find.text('This is not a valid Satchel file'), findsOneWidget);

    storage.readError = const StorageBackendException('', 'offline');
    await unlockWith(tester, 'hunter22');
    expect(
      find.text('Could not read the file. Check the storage and try again.'),
      findsOneWidget,
    );
    expect(isUnlocked(), isFalse);
  });

  testWidgets('lock button locks the file again', (tester) async {
    await pumpPane(tester, secrets: _secrets);
    await unlockWith(tester, 'hunter22');
    final key = container.read(unlockedVaultsProvider)[vault]!.key;

    await tester.tap(find.byTooltip('Lock'));
    await tester.pumpAndSettle();

    expect(isUnlocked(), isFalse);
    expect(key.isDestroyed, isTrue);
    expect(find.text(lockedMessage), findsOneWidget);
    expect(find.text('Example Bank'), findsNothing);
    final field = tester.widget<TextField>(
      find.byKey(const Key('unlockPassword')),
    );
    expect(field.controller!.text, isEmpty);
  });

  testWidgets('tapping a secret opens it, and locking closes it', (
    tester,
  ) async {
    await pumpPane(tester, secrets: _secrets);
    await unlockWith(tester, 'hunter22');

    await tester.tap(find.text('Safe'));
    await tester.pumpAndSettle();
    expect(container.read(currentLocationProvider).secretId, 'n1');
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Safe')).selected,
      isTrue,
    );

    await tester.tap(find.byTooltip('Lock'));
    await tester.pumpAndSettle();
    expect(
      container.read(currentLocationProvider),
      const AppLocation(storageId: 's', filePath: 'personal.satchel'),
    );
  });

  testWidgets('highlights expired and soon expiring secrets', (tester) async {
    final now = DateTime.now().toUtc();
    SecretInfo expiring(String id, String title, Duration left) => SecretInfo(
      id: id,
      title: title,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      expiresAt: now.add(left),
    );
    await pumpPane(
      tester,
      secrets: [
        NoteSecret(
          info: expiring('a', 'Old', const Duration(days: -1)),
          text: 'x',
        ),
        NoteSecret(
          info: expiring('b', 'Soon', const Duration(days: 5)),
          text: 'x',
        ),
        NoteSecret(
          info: expiring('c', 'Later', const Duration(days: 300)),
          text: 'x',
        ),
      ],
    );
    await unlockWith(tester, 'hunter22');

    final colors = Theme.of(tester.element(find.byType(SecretsPane)))
        .colorScheme;
    ListTile tile(String title) =>
        tester.widget<ListTile>(find.widgetWithText(ListTile, title));
    Finder highlight(String title) => find.descendant(
      of: find.widgetWithText(ListTile, title),
      matching: find.byKey(const Key('expiryHighlight')),
    );

    expect(tile('Old').tileColor, colors.errorContainer);
    expect(tile('Old').textColor, colors.onErrorContainer);
    expect(
      find.descendant(
        of: highlight('Old'),
        matching: find.text('Expired yesterday'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: highlight('Old'),
        matching: find.byIcon(Icons.event_busy),
      ),
      findsOneWidget,
    );

    expect(tile('Soon').tileColor, colors.tertiaryContainer);
    expect(
      find.descendant(
        of: highlight('Soon'),
        matching: find.text('Expires in 5 days'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: highlight('Soon'),
        matching: find.byIcon(Icons.schedule),
      ),
      findsOneWidget,
    );

    expect(tile('Later').tileColor, isNull);
    expect(highlight('Later'), findsNothing);
  });

  testWidgets('a selected expired secret keeps its tint', (tester) async {
    await pumpPane(
      tester,
      secrets: [
        NoteSecret(
          info: SecretInfo(
            id: 'a',
            title: 'Old',
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
            expiresAt: DateTime.utc(2000),
          ),
          text: 'x',
        ),
      ],
    );
    await unlockWith(tester, 'hunter22');
    await tester.tap(find.text('Old'));
    await tester.pumpAndSettle();

    final tile = tester.widget<ListTile>(find.widgetWithText(ListTile, 'Old'));
    final colors = Theme.of(tester.element(find.byType(SecretsPane)))
        .colorScheme;
    expect(tile.selected, isTrue);
    expect(tile.selectedTileColor, colors.errorContainer);
  });

  group('secret menu', () {
    Future<void> choose(WidgetTester tester, String title, String item) async {
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, title),
          matching: find.byTooltip('More actions'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, item));
      await tester.pumpAndSettle();
    }

    testWidgets('edit opens the editor for that secret', (tester) async {
      await pumpPane(tester, secrets: _secrets);
      await unlockWith(tester, 'hunter22');

      await choose(tester, 'Safe', 'Edit');

      expect(find.text('Edit secure note'), findsOneWidget);
      expect(container.read(currentLocationProvider).secretId, isNull);
    });

    testWidgets('delete removes the secret after confirming', (tester) async {
      await pumpPane(tester, secrets: _secrets);
      await unlockWith(tester, 'hunter22');

      await choose(tester, 'Safe', 'Delete');
      expect(find.text('Delete "Safe"?'), findsOneWidget);
      await tester.tap(find.text('Delete').last);
      await settleCrypto(tester, find.text('never shown'));

      expect(
        container
            .read(unlockedVaultsProvider)[vault]!
            .payload
            .secrets
            .map((s) => s.id),
        ['l1'],
      );
      expect(find.text('Deleted "Safe"'), findsOneWidget);
    });
  });

  group('select and export', () {
    Future<void> selectByLongPress(WidgetTester tester, String title) async {
      await tester.longPress(find.text(title));
      await tester.pumpAndSettle();
    }

    Future<void> exportWith(
      WidgetTester tester, {
      bool plain = false,
      String? newPassword,
    }) async {
      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
      if (plain) {
        await tester.tap(find.text('Plain JSON'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('exportPlainAcknowledged')));
        await tester.pump();
      }
      if (newPassword != null) {
        await tester.tap(find.byKey(const Key('exportNewPassword')));
        await tester.pump();
        await tester.enterText(find.byKey(const Key('password')), newPassword);
        await tester.enterText(find.byKey(const Key('confirm')), newPassword);
      }
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Export'),
        ),
      );
      await settleCrypto(tester, find.byType(ExportSecretsDialog));
    }

    testWidgets('selecting shows Export instead of the file actions', (
      tester,
    ) async {
      await pumpPane(tester, secrets: _secrets);
      await unlockWith(tester, 'hunter22');
      expect(find.text('Export'), findsNothing);

      await selectByLongPress(tester, 'Safe');

      expect(find.text('1 selected'), findsOneWidget);
      expect(find.text('Export'), findsOneWidget);
      expect(find.byTooltip('Lock'), findsNothing);
      expect(find.text('New secret'), findsNothing);
      expect(container.read(currentLocationProvider).secretId, isNull);

      // Taps toggle while selecting.
      await tester.tap(find.text('Example Bank'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
      await tester.tap(find.text('Example Bank'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.byTooltip('Select all'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear selection'));
      await tester.pumpAndSettle();
      expect(find.text('Export'), findsNothing);
      expect(find.byTooltip('Lock'), findsOneWidget);
    });

    testWidgets('the row menu can start a selection', (tester) async {
      await pumpPane(tester, secrets: _secrets);
      await unlockWith(tester, 'hunter22');

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Safe'),
          matching: find.byTooltip('More actions'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Select'));
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('exports the selected secrets encrypted', (tester) async {
      await pumpPane(tester, secrets: _secrets);
      await unlockWith(tester, 'hunter22');
      await selectByLongPress(tester, 'Safe');

      await exportWith(tester);

      final file = exporter.saved.single;
      expect(file.name, 'personal.satchel');
      final opened = await tester.runAsync(
        () => VaultCodec.decrypt(file.bytes, password: 'hunter22'),
      );
      expect(opened!.payload.secrets.map((s) => s.id), ['n1']);
      expect(find.text('Exported to "personal.satchel"'), findsOneWidget);
      expect(find.text('1 selected'), findsNothing);
    });

    testWidgets('can encrypt the export with another password', (tester) async {
      await pumpPane(tester, secrets: _secrets);
      await unlockWith(tester, 'hunter22');
      await selectByLongPress(tester, 'Safe');

      await exportWith(tester, newPassword: 'correct horse');

      final opened = await tester.runAsync(
        () => VaultCodec.decrypt(
          exporter.saved.single.bytes,
          password: 'correct horse',
        ),
      );
      expect(opened!.payload.secrets.map((s) => s.id), ['n1']);
    });

    testWidgets('a plain export needs the warning acknowledged', (
      tester,
    ) async {
      await pumpPane(tester, secrets: _secrets);
      await unlockWith(tester, 'hunter22');
      await selectByLongPress(tester, 'Safe');
      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plain JSON'));
      await tester.pumpAndSettle();

      expect(find.textContaining('This file is not encrypted'), findsOneWidget);
      final export = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Export'),
      );
      expect(tester.widget<FilledButton>(export).onPressed, isNull);

      await tester.tap(find.byKey(const Key('exportPlainAcknowledged')));
      await tester.pump();
      expect(tester.widget<FilledButton>(export).onPressed, isNotNull);
    });

    testWidgets('exports plain JSON', (tester) async {
      await pumpPane(tester, secrets: _secrets);
      await unlockWith(tester, 'hunter22');
      await selectByLongPress(tester, 'Safe');
      await tester.tap(find.byTooltip('Select all'));
      await tester.pumpAndSettle();

      await exportWith(tester, plain: true);

      final file = exporter.saved.single;
      expect(file.name, 'personal.json');
      expect(file.mimeType, 'application/json');
      expect(PlainExport.decode(file.bytes).secrets, _secrets);
    });

    testWidgets('stays open when saving is cancelled or fails', (tester) async {
      await pumpPane(tester, secrets: _secrets);
      await unlockWith(tester, 'hunter22');
      await selectByLongPress(tester, 'Safe');

      exporter.cancel = true;
      await exportWith(tester);
      expect(find.byType(ExportSecretsDialog), findsOneWidget);
      expect(exporter.saved, isEmpty);

      exporter
        ..cancel = false
        ..error = Exception('disk full');
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Export'),
        ),
      );
      await settleCrypto(tester, find.byType(LinearProgressIndicator));
      expect(find.text('Could not export. Try again.'), findsOneWidget);
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('locking clears the selection', (tester) async {
      await pumpPane(tester, secrets: _secrets);
      await unlockWith(tester, 'hunter22');
      await selectByLongPress(tester, 'Safe');

      container.read(unlockedVaultsProvider.notifier).lock(vault);
      await tester.pumpAndSettle();
      await unlockWith(tester, 'hunter22');

      expect(find.text('1 selected'), findsNothing);
      expect(find.byTooltip('Lock'), findsOneWidget);
    });
  });
}
