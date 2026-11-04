import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/export/export_providers.dart';
import 'package:satchel/src/files/change_vault_password.dart';
import 'package:satchel/src/files/copy_vault_file.dart';
import 'package:satchel/src/files/delete_vault_file.dart';
import 'package:satchel/src/files/files_pane.dart';
import 'package:satchel/src/files/rename_vault_file.dart';
import 'package:satchel/src/files/vault_files_providers.dart';
import 'package:satchel/src/navigation/app_location.dart';
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
  late FakeStorageProvider backup;
  late FakeFileExporter exporter;
  late ProviderContainer container;
  const vault = VaultRef('s', 'personal.satchel');

  Future<void> pumpFiles(WidgetTester tester) async {
    storage = FakeStorageProvider(id: 's');
    backup = FakeStorageProvider(id: 'b');
    exporter = FakeFileExporter();
    await tester.runAsync(() async {
      await putVault(storage, vault.path, 'hunter22');
      await putVault(storage, 'work.satchel', 'hunter22');
    });
    container = ProviderContainer(
      overrides: [
        ...storageOverrides(
          platform: StoragePlatform.linux,
          store: MemoryStorageConfigStore([
            directoryConfig('s', '/s', name: 'Sync folder'),
            directoryConfig('b', '/b', name: 'Backup'),
          ]),
        ),
        storageProvidersProvider.overrideWith((ref) async => [storage, backup]),
        vaultCryptoProvider.overrideWithValue(const VaultCrypto(memoryKiB: 64)),
        fileExporterProvider.overrideWithValue(exporter),
      ],
    );
    addTearDown(container.dispose);
    container.read(currentLocationProvider.notifier).openFile('s', vault.path);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: testApp(
          Scaffold(
            body: Row(
              children: [
                const Expanded(child: FilesPane(storageId: 's')),
                Expanded(
                  child: SecretsPane(storageId: 's', path: vault.path),
                ),
              ],
            ),
          ),
        ),
      ),
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

  bool isUnlocked([VaultRef ref = vault]) =>
      container.read(unlockedVaultsProvider).containsKey(ref);

  Finder menuItem(String label) => find.widgetWithText(MenuItemButton, label);

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, 'personal'),
        matching: find.byTooltip('More actions'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(menuItem(label));
    await tester.pumpAndSettle();
  }

  /// Chooses [label] in the open file's menu in the secrets pane.
  Future<void> chooseInFile(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(SecretsPane),
        matching: find.byTooltip('More actions'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(menuItem(label));
    await tester.pumpAndSettle();
  }

  testWidgets('each file has a menu of actions', (tester) async {
    await pumpFiles(tester);

    expect(find.byTooltip('More actions'), findsNWidgets(2));
    await tester.tap(find.byTooltip('More actions').first);
    await tester.pumpAndSettle();

    bool enabled(String label) =>
        tester.widget<MenuItemButton>(menuItem(label)).onPressed != null;
    expect(menuItem('Rename'), findsNothing);
    expect(enabled('Change password'), isTrue);
    expect(enabled('Delete'), isTrue);
    expect(menuItem('Lock'), findsNothing);
    expect(menuItem('Export'), findsNothing);
    expect(menuItem('Import'), findsNothing);
  });

  testWidgets('locks an unlocked file from its menu', (tester) async {
    await pumpFiles(tester);
    await unlock(tester);

    await choose(tester, 'Lock');

    expect(isUnlocked(), isFalse);
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, 'personal'),
        matching: find.byIcon(Icons.lock_outline),
      ),
      findsOneWidget,
    );
  });

  group('rename', () {
    Future<void> renameTo(WidgetTester tester, String name) async {
      await chooseInFile(tester, 'Rename');
      await tester.enterText(find.byKey(const Key('name')), name);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Rename'),
        ),
      );
      await settleCrypto(tester, find.byType(LinearProgressIndicator));
    }

    testWidgets('renames the file and keeps it open and unlocked', (
      tester,
    ) async {
      await pumpFiles(tester);
      await unlock(tester);

      await chooseInFile(tester, 'Rename');
      expect(find.text('Rename "personal"'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('name')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller!.text, 'personal');

      await tester.enterText(find.byKey(const Key('name')), 'Home');
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Rename'),
        ),
      );
      await settleCrypto(tester, find.byType(LinearProgressIndicator));

      expect(find.byType(RenameVaultFileDialog), findsNothing);
      expect(storage.paths, unorderedEquals(['Home.satchel', 'work.satchel']));
      expect(find.text('Home'), findsOneWidget);
      expect(isUnlocked(const VaultRef('s', 'Home.satchel')), isTrue);
      expect(
        container.read(currentLocationProvider),
        const AppLocation(storageId: 's', filePath: 'Home.satchel'),
      );
    });

    testWidgets('reports a name that is taken', (tester) async {
      await pumpFiles(tester);
      await unlock(tester);

      await renameTo(tester, 'Work');

      expect(find.byType(RenameVaultFileDialog), findsOneWidget);
      expect(find.text('A file with this name already exists'), findsOneWidget);
      expect(storage.paths, unorderedEquals([vault.path, 'work.satchel']));
    });

    testWidgets('validates the name', (tester) async {
      await pumpFiles(tester);
      await unlock(tester);

      await renameTo(tester, 'a/b');

      expect(find.textContaining("Can't contain"), findsOneWidget);
      expect(storage.paths, unorderedEquals([vault.path, 'work.satchel']));
    });
  });

  group('change password', () {
    Future<void> change(
      WidgetTester tester, {
      String current = 'hunter22',
      String password = 'correct horse',
    }) async {
      await choose(tester, 'Change password');
      await tester.enterText(find.byKey(const Key('currentPassword')), current);
      await tester.enterText(find.byKey(const Key('password')), password);
      await tester.enterText(find.byKey(const Key('confirm')), password);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Change password'),
        ),
      );
      await settleCrypto(tester, find.text('Encrypting…'));
    }

    Future<void> expectPassword(WidgetTester tester, String password) async {
      final opened = await tester.runAsync(
        () => VaultCodec.decrypt(
          storage.blobs[vault.path]!.bytes,
          password: password,
        ),
      );
      expect(opened, isNotNull);
    }

    testWidgets('re-encrypts a locked file', (tester) async {
      await pumpFiles(tester);

      await change(tester);

      expect(find.byType(ChangeVaultPasswordDialog), findsNothing);
      expect(find.text('Changed the password of "personal"'), findsOneWidget);
      await expectPassword(tester, 'correct horse');
      expect(isUnlocked(), isFalse);
    });

    testWidgets('keeps an unlocked file unlocked', (tester) async {
      await pumpFiles(tester);
      await unlock(tester);

      await change(tester);

      await expectPassword(tester, 'correct horse');
      expect(isUnlocked(), isTrue);
    });

    testWidgets('reports a wrong current password', (tester) async {
      await pumpFiles(tester);
      final before = storage.blobs[vault.path]!.revision;

      await change(tester, current: 'hunter23');

      expect(find.byType(ChangeVaultPasswordDialog), findsOneWidget);
      expect(
        find.text('Wrong password, or the file is damaged'),
        findsOneWidget,
      );
      expect(storage.blobs[vault.path]!.revision, before);
    });

    testWidgets('validates the new password', (tester) async {
      await pumpFiles(tester);
      final before = storage.blobs[vault.path]!.revision;

      await change(tester, password: 'short');

      expect(find.text('Use at least 8 characters'), findsOneWidget);
      expect(storage.blobs[vault.path]!.revision, before);
    });
  });

  group('copy', () {
    Future<void> copyTo(WidgetTester tester, String storage) async {
      await choose(tester, 'Copy to…');
      expect(find.text('Copy "personal" to'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(CopyVaultFileDialog),
          matching: find.text('Sync folder'),
        ),
        findsNothing,
      );
      await tester.tap(find.text(storage));
      await tester.pumpAndSettle();
    }

    testWidgets('copies a locked file to another storage', (tester) async {
      await pumpFiles(tester);

      await copyTo(tester, 'Backup');

      expect(find.byType(CopyVaultFileDialog), findsNothing);
      expect(backup.paths, [vault.path]);
      expect(backup.blobs[vault.path]!.bytes, storage.blobs[vault.path]!.bytes);
      expect(find.text('Copied "personal" to "Backup"'), findsOneWidget);
    });

    testWidgets('asks before replacing a file with the same name', (
      tester,
    ) async {
      await pumpFiles(tester);
      await tester.runAsync(() => putVault(backup, vault.path, 'other'));
      final before = backup.blobs[vault.path]!;

      await copyTo(tester, 'Backup');

      expect(find.text('Replace "personal"?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(backup.blobs[vault.path], same(before));
      expect(find.byType(SnackBar), findsNothing);

      await copyTo(tester, 'Backup');
      await tester.tap(find.text('Replace'));
      await tester.pumpAndSettle();

      expect(backup.blobs[vault.path]!.bytes, storage.blobs[vault.path]!.bytes);
      expect(find.text('Copied "personal" to "Backup"'), findsOneWidget);
    });

    testWidgets('reports storage failures', (tester) async {
      await pumpFiles(tester);
      backup.writeError = const StorageBackendException('', 'read-only');

      await copyTo(tester, 'Backup');

      expect(backup.paths, isEmpty);
      expect(
        find.text(
          'Could not copy "personal" to "Backup". Check the storages and try '
          'again.',
        ),
        findsOneWidget,
      );
    });
  });

  group('delete', () {
    Future<void> deleteAndConfirm(WidgetTester tester) async {
      await choose(tester, 'Delete');
      await tester.tap(
        find.descendant(
          of: find.byType(DeleteVaultFileDialog),
          matching: find.text('Delete'),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('asks for confirmation naming the file and storage', (
      tester,
    ) async {
      await pumpFiles(tester);

      await choose(tester, 'Delete');

      expect(find.text('Delete "personal"?'), findsOneWidget);
      expect(
        find.text(
          'The file and all secrets in it will be permanently deleted from '
          '"Sync folder". This can\'t be undone.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(DeleteVaultFileDialog), findsNothing);
      expect(storage.paths, unorderedEquals([vault.path, 'work.satchel']));
    });

    testWidgets('deletes a locked file and closes it', (tester) async {
      await pumpFiles(tester);

      await deleteAndConfirm(tester);

      expect(storage.paths, ['work.satchel']);
      expect(find.text('Deleted "personal"'), findsOneWidget);
      expect(
        container.read(currentLocationProvider),
        const AppLocation(storageId: 's'),
      );
    });

    testWidgets('shows progress until the delete finishes', (tester) async {
      await pumpFiles(tester);
      final gate = Completer<void>();
      storage.deleteGate = gate.future;

      await choose(tester, 'Delete');
      await tester.tap(
        find.descendant(
          of: find.byType(DeleteVaultFileDialog),
          matching: find.text('Delete'),
        ),
      );
      await tester.pump();

      expect(
        find.descendant(
          of: find.byType(DeleteVaultFileDialog),
          matching: find.byType(LinearProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
            .onPressed,
        isNull,
      );
      expect(storage.paths, contains(vault.path));

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.byType(DeleteVaultFileDialog), findsNothing);
      expect(storage.paths, ['work.satchel']);
      expect(find.text('Deleted "personal"'), findsOneWidget);
    });

    testWidgets('deletes an unlocked file and locks it', (tester) async {
      await pumpFiles(tester);
      await unlock(tester);
      final key = container.read(unlockedVaultsProvider)[vault]!.key;

      await deleteAndConfirm(tester);

      expect(storage.paths, ['work.satchel']);
      expect(isUnlocked(), isFalse);
      expect(key.isDestroyed, isTrue);
    });

    testWidgets('keeps an unlocked file that changed after unlocking', (
      tester,
    ) async {
      await pumpFiles(tester);
      await unlock(tester);
      // Another app replaces the file; the list sees the new version.
      final current = storage.blobs[vault.path]!;
      storage.blobs[vault.path] = (bytes: current.bytes, revision: 'newer');
      container.invalidate(vaultFilesProvider('s'));
      await tester.pumpAndSettle();

      await deleteAndConfirm(tester);

      expect(storage.paths, contains(vault.path));
      expect(
        find.text(
          '"personal" was changed since it was listed, so it was not deleted. '
          'Check it and try again.',
        ),
        findsOneWidget,
      );
      expect(isUnlocked(), isTrue);
    });

    testWidgets('reports storage failures', (tester) async {
      await pumpFiles(tester);
      storage.deleteError = const StorageBackendException('', 'read-only');

      await deleteAndConfirm(tester);

      expect(storage.paths, contains(vault.path));
      expect(
        find.text(
          'Could not delete "personal". Check the storage and try again.',
        ),
        findsOneWidget,
      );
    });
  });
}
