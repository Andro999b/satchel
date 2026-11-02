import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/files/files_pane.dart';
import 'package:satchel/src/import/import_providers.dart';
import 'package:satchel/src/import/import_secrets.dart';
import 'package:satchel/src/storage/storage_providers.dart';
import 'package:satchel/src/vault/unlocked_vaults.dart';
import 'package:satchel/src/vault/vault_providers.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../fakes.dart';
import '../test_app.dart';

LoginSecret _login({String username = 'ann', DateTime? updatedAt}) =>
    LoginSecret(
      info: SecretInfo(
        id: 'l1',
        title: 'Bank',
        createdAt: DateTime.utc(2026),
        updatedAt: updatedAt ?? DateTime.utc(2026, 3),
      ),
      username: username,
    );

final _note = NoteSecret(
  info: SecretInfo(
    id: 'n1',
    title: 'Safe',
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  ),
  text: '12-34-56',
);

void main() {
  late FakeStorageProvider storage;
  late FakeFileImporter importer;
  late ProviderContainer container;
  const vault = VaultRef('s', 'personal.satchel');

  Future<void> pumpFiles(WidgetTester tester) async {
    storage = FakeStorageProvider(id: 's');
    importer = FakeFileImporter();
    await tester.runAsync(
      () => putVault(storage, vault.path, 'hunter22', secrets: [_login()]),
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
        vaultCryptoProvider.overrideWithValue(const VaultCrypto(memoryKiB: 64)),
        fileImporterProvider.overrideWithValue(importer),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: testApp(const FilesPane(storageId: 's')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => container
          .read(unlockedVaultsProvider.notifier)
          .unlock(vault, 'hunter22'),
    );
    await tester.pumpAndSettle();
  }

  UnlockedVaults notifier() => container.read(unlockedVaultsProvider.notifier);
  List<Secret> secrets() =>
      container.read(unlockedVaultsProvider)[vault]!.payload.secrets;

  VaultPayload incoming(List<Secret> secrets) => VaultPayload(
    fileId: 'other',
    name: 'Other',
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    secrets: secrets,
  );

  /// Picks [name] with [bytes] from the file menu.
  Future<void> startImport(
    WidgetTester tester,
    String name,
    Uint8List bytes,
  ) async {
    importer.next = PickedFile(name: name, bytes: bytes);
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Import'));
    await settleCrypto(tester, find.text('never shown'));
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await settleCrypto(tester, find.byType(ImportReviewDialog));
  }

  testWidgets('needs the file unlocked', (tester) async {
    await pumpFiles(tester);
    notifier().lock(vault);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<MenuItemButton>(find.widgetWithText(MenuItemButton, 'Import'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('imports new secrets from a plain export', (tester) async {
    await pumpFiles(tester);

    await startImport(
      tester,
      'Other.JSON',
      PlainExport.encode(incoming([_login(), _note])),
    );

    expect(find.text('Import "Other.JSON"'), findsOneWidget);
    expect(find.text('1 new secret will be added'), findsOneWidget);
    expect(
      find.text('1 secret is already in this file and is skipped'),
      findsOneWidget,
    );
    await confirm(tester);

    expect(secrets().map((s) => s.id), ['l1', 'n1']);
    // Imported secrets keep their own timestamps.
    expect(secrets().last.updatedAt, _note.updatedAt);
    expect(find.text('Imported 1 secret'), findsOneWidget);
  });

  testWidgets('opens exports of the same file without a password', (
    tester,
  ) async {
    await pumpFiles(tester);
    final bytes = await tester.runAsync(
      () => notifier().exportEncrypted(vault),
    );

    await startImport(tester, 'personal.satchel', bytes!);

    expect(find.byType(ImportPasswordDialog), findsNothing);
    expect(
      find.text(
        'Nothing to import: every secret in this file is already here.',
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Import'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(ImportReviewDialog), findsNothing);
  });

  testWidgets('asks for the password of another vault file', (tester) async {
    await pumpFiles(tester);
    final bytes = await tester.runAsync(() async {
      final key = await VaultKey.create(password: 'other-pw', memoryKiB: 64);
      try {
        return await VaultCodec.encrypt(incoming([_note]), key);
      } finally {
        key.destroy();
      }
    });

    await startImport(tester, 'Other.satchel', bytes!);
    expect(find.text('Password for "Other.satchel"'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('importPassword')), 'wrong');
    await tester.pump();
    await tester.tap(find.text('Open'));
    await tester.pump();
    await settleCrypto(tester, find.text('Unlocking…'));
    expect(find.text('Wrong password, or the file is damaged'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('importPassword')), 'other-pw');
    await tester.tap(find.text('Open'));
    await tester.pump();
    await settleCrypto(tester, find.text('Unlocking…'));
    expect(find.text('1 new secret will be added'), findsOneWidget);

    await confirm(tester);
    expect(secrets().map((s) => s.id), ['l1', 'n1']);
  });

  group('conflicts', () {
    final newer = _login(username: 'bob', updatedAt: DateTime.utc(2026, 9));
    final older = _login(username: 'bob', updatedAt: DateTime.utc(2026, 1));

    ConflictResolution? chosen(WidgetTester tester) => tester
        .widget<SegmentedButton<ConflictResolution>>(
          find.byType(SegmentedButton<ConflictResolution>),
        )
        .selected
        .single;

    testWidgets('shows both versions and suggests the newer one', (
      tester,
    ) async {
      await pumpFiles(tester);

      await startImport(
        tester,
        'o.json',
        PlainExport.encode(incoming([newer])),
      );

      expect(
        find.text(
          '1 secret differs from the one in this file. '
          'Choose which version to keep:',
        ),
        findsOneWidget,
      );
      expect(find.text('Current'), findsOneWidget);
      expect(find.text('Imported'), findsOneWidget);
      expect(
        find.byTooltip(RegExp(r'^Bank · updated .* · newer$')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.update), findsOneWidget);
      expect(chosen(tester), ConflictResolution.useIncoming);
    });

    testWidgets('keeps the current version when chosen', (tester) async {
      await pumpFiles(tester);
      await startImport(
        tester,
        'o.json',
        PlainExport.encode(incoming([newer])),
      );

      await tester.tap(find.text('Current'));
      await tester.pump();
      await confirm(tester);

      expect((secrets().single as LoginSecret).username, 'ann');
      expect(find.text('Import done, nothing changed'), findsOneWidget);
    });

    testWidgets('replaces with the imported version when chosen', (
      tester,
    ) async {
      await pumpFiles(tester);
      await startImport(
        tester,
        'o.json',
        PlainExport.encode(incoming([older])),
      );
      expect(chosen(tester), ConflictResolution.keepExisting);

      await tester.tap(find.text('Imported'));
      await tester.pump();
      await confirm(tester);

      expect(secrets().single, older);
      expect(find.text('Imported 1 secret'), findsOneWidget);
    });

    testWidgets('cancelling changes nothing', (tester) async {
      await pumpFiles(tester);
      final revision = storage.blobs[vault.path]!.revision;
      await startImport(
        tester,
        'o.json',
        PlainExport.encode(incoming([newer])),
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(storage.blobs[vault.path]!.revision, revision);
      expect((secrets().single as LoginSecret).username, 'ann');
    });
  });

  testWidgets('rejects other file types', (tester) async {
    await pumpFiles(tester);

    await startImport(tester, 'notes.txt', Uint8List.fromList([1, 2, 3]));

    expect(find.text('Choose a .satchel or .json file'), findsOneWidget);
  });

  testWidgets('rejects broken files', (tester) async {
    await pumpFiles(tester);

    await startImport(tester, 'x.json', Uint8List.fromList([1, 2, 3]));

    expect(find.text('This is not a Satchel file or export'), findsOneWidget);
  });

  testWidgets('zeroes the bytes of the picked file', (tester) async {
    await pumpFiles(tester);
    final bytes = PlainExport.encode(incoming([_note]));

    await startImport(tester, 'o.json', bytes);

    expect(bytes.every((b) => b == 0), isTrue);
  });
}
