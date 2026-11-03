import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/secrets/copy_secrets.dart';
import 'package:satchel/src/secrets/secrets_pane.dart';
import 'package:satchel/src/storage/storage_providers.dart';
import 'package:satchel/src/vault/unlocked_vaults.dart';
import 'package:satchel/src/vault/vault_providers.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../fakes.dart';
import '../test_app.dart';

SecretInfo _info(String id, String title, {DateTime? updatedAt}) => SecretInfo(
  id: id,
  title: title,
  createdAt: DateTime.utc(2026),
  updatedAt: updatedAt ?? DateTime.utc(2026),
);

final _login = LoginSecret(info: _info('l1', 'Example Bank'), username: 'ann');
final _note = NoteSecret(
  info: _info('n1', 'Safe', updatedAt: DateTime.utc(2026, 5)),
  text: '12-34-56',
);

void main() {
  late FakeStorageProvider storage;
  late FakeStorageProvider backup;
  late ProviderContainer container;
  const source = VaultRef('s', 'personal.satchel');
  const work = VaultRef('s', 'work.satchel');
  const other = VaultRef('b', 'other.satchel');

  Future<void> pumpPane(
    WidgetTester tester, {
    List<Secret> otherSecrets = const [],
  }) async {
    storage = FakeStorageProvider(id: 's');
    backup = FakeStorageProvider(id: 'b');
    await tester.runAsync(() async {
      await putVault(
        storage,
        source.path,
        'hunter22',
        secrets: [_login, _note],
      );
      await putVault(storage, work.path, 'work-pass');
      await putVault(backup, other.path, 'other-pass', secrets: otherSecrets);
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
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: testApp(
          const SecretsPane(storageId: 's', path: 'personal.satchel'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('unlockPassword')), 'hunter22');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleCrypto(tester, find.text('Unlocking…'));
  }

  /// Selects "Safe" and picks [file] in [storage] as the target.
  Future<void> copyTo(WidgetTester tester, String storage, String file) async {
    await tester.longPress(find.text('Safe'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Copy to another file'));
    await tester.pumpAndSettle();
    expect(find.text('Copy 1 secret to'), findsOneWidget);
    await tester.tap(find.text(storage));
    await tester.pumpAndSettle();
    await tester.tap(find.text(file));
    await tester.pumpAndSettle();
  }

  Future<void> unlockTarget(WidgetTester tester, String password) async {
    await tester.enterText(
      find.byKey(const Key('unlockTargetPassword')),
      password,
    );
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byType(UnlockVaultDialog),
        matching: find.widgetWithText(FilledButton, 'Unlock'),
      ),
    );
    await settleCrypto(tester, find.text('Unlocking…'));
  }

  Future<void> confirmCopy(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Copy'),
      ),
    );
    await settleCrypto(tester, find.byType(LinearProgressIndicator));
  }

  List<Secret>? secretsOf(VaultRef vault) =>
      container.read(unlockedVaultsProvider)[vault]?.payload.secrets;

  testWidgets('the row menu copies one secret', (tester) async {
    await pumpPane(tester);

    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Example Bank'),
        matching: find.byTooltip('More actions'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Copy to…'));
    await tester.pumpAndSettle();
    expect(find.text('Copy 1 secret to'), findsOneWidget);
    await tester.tap(find.text('Backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('other'));
    await tester.pumpAndSettle();
    await unlockTarget(tester, 'other-pass');
    await confirmCopy(tester);

    expect(secretsOf(other), [_login]);
    expect(find.text('Copied 1 secret to "other"'), findsOneWidget);
  });

  testWidgets('lists the files of a storage except the source', (tester) async {
    await pumpPane(tester);
    await tester.longPress(find.text('Safe'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Copy to another file'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sync folder'));
    await tester.pumpAndSettle();

    final dialog = find.byType(CopySecretsDialog);
    expect(
      find.descendant(of: dialog, matching: find.text('work')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('personal')),
      findsNothing,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(CopySecretsDialog), findsNothing);
    expect(find.text('1 selected'), findsOneWidget);
  });

  testWidgets('unlocks a locked target, then copies into it', (tester) async {
    await pumpPane(tester);

    await copyTo(tester, 'Backup', 'other');
    expect(find.text('Unlock "other"'), findsOneWidget);

    await unlockTarget(tester, 'wrong password');
    expect(find.text('Wrong password, or the file is damaged'), findsOneWidget);
    await unlockTarget(tester, 'other-pass');

    expect(find.text('Copy to "other"'), findsOneWidget);
    expect(find.text('1 new secret will be added'), findsOneWidget);
    await confirmCopy(tester);

    expect(secretsOf(other), [_note]);
    expect(secretsOf(source), [_login, _note]);
    expect(find.text('Copied 1 secret to "other"'), findsOneWidget);
    expect(find.text('1 selected'), findsNothing);

    // Now unlocked, so it isn't asked for again.
    await copyTo(tester, 'Backup', 'other');
    expect(find.byType(UnlockVaultDialog), findsNothing);
    expect(
      find.text(
        'Nothing to copy: every selected secret is already in that file.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('cancelling the unlock copies nothing', (tester) async {
    await pumpPane(tester);

    await copyTo(tester, 'Sync folder', 'work');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(container.read(unlockedVaultsProvider).containsKey(work), isFalse);
    expect(find.text('1 selected'), findsOneWidget);
  });

  testWidgets('conflicts are resolved as in an import', (tester) async {
    final older = NoteSecret(
      info: _info('n1', 'Safe', updatedAt: DateTime.utc(2026, 2)),
      text: 'old combination',
    );
    await pumpPane(tester, otherSecrets: [older]);

    await copyTo(tester, 'Backup', 'other');
    await unlockTarget(tester, 'other-pass');

    expect(
      find.text(
        '1 secret differs from the one in this file. '
        'Choose which version to keep:',
      ),
      findsOneWidget,
    );
    expect(find.text('Copied'), findsOneWidget);

    await tester.tap(find.text('Current'));
    await tester.pumpAndSettle();
    await confirmCopy(tester);
    expect(secretsOf(other), [older]);
    expect(find.text('Copy done, "other" did not change'), findsOneWidget);
  });

  testWidgets('the newer copied version is suggested', (tester) async {
    final older = NoteSecret(
      info: _info('n1', 'Safe', updatedAt: DateTime.utc(2026, 2)),
      text: 'old combination',
    );
    await pumpPane(tester, otherSecrets: [older]);

    await copyTo(tester, 'Backup', 'other');
    await unlockTarget(tester, 'other-pass');
    await confirmCopy(tester);

    expect(secretsOf(other), [_note]);
    expect(find.text('Copied 1 secret to "other"'), findsOneWidget);
  });
}
