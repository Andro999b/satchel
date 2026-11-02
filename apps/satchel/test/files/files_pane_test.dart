import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/files/files_pane.dart';
import 'package:satchel/src/navigation/app_location.dart';
import 'package:satchel/src/files/new_vault_file_dialog.dart';
import 'package:satchel/src/storage/storage_providers.dart';
import 'package:satchel/src/vault/unlocked_vaults.dart';
import 'package:satchel/src/vault/vault_providers.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../fakes.dart';
import '../test_app.dart';

void main() {
  late FakeStorageProvider storage;

  setUp(() {
    storage = FakeStorageProvider(id: 's', displayName: 'Sync folder');
  });

  Future<void> pumpFiles(
    WidgetTester tester, {
    String storageId = 's',
    VoidCallback? onBack,
    StorageConfig? config,
    List<GoogleAccount> accounts = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...storageOverrides(
            platform: StoragePlatform.linux,
            store: MemoryStorageConfigStore([
              config ?? directoryConfig('s', '/s', name: 'Sync folder'),
            ]),
          ),
          ...googleAccountOverrides(
            store: MemoryGoogleAccountStore(accounts),
            auth: FakeGoogleAuth(),
          ),
          storageProvidersProvider.overrideWith((ref) async => [storage]),
          vaultCryptoProvider.overrideWithValue(
            const VaultCrypto(memoryKiB: 64),
          ),
        ],
        child: testApp(FilesPane(storageId: storageId, onBack: onBack)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists the vault files of the storage', (tester) async {
    storage.paths = ['work.satchel', 'readme.md', 'personal.satchel'];

    await pumpFiles(tester);

    expect(find.text('Sync folder'), findsOneWidget);
    final names = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((tile) => (tile.title! as Text).data);
    expect(names, ['personal', 'work']);
  });

  testWidgets('shows an empty state', (tester) async {
    await pumpFiles(tester);

    expect(find.text('No vault files in this storage yet'), findsOneWidget);
  });

  group('Google Drive', () {
    const ada = GoogleAccount(id: 'ada', email: 'ada@example.com');
    final config = driveConfig('s', 'folder', accountId: 'ada', name: 'Drive');

    testWidgets('asks to sign in again, and lists after signing in', (
      tester,
    ) async {
      storage.listError = const StorageAuthRequiredException(
        '',
        accountId: 'ada',
      );
      await pumpFiles(tester, config: config, accounts: [ada]);

      expect(
        find.text('Sign in to Google to open this storage'),
        findsOneWidget,
      );
      storage
        ..listError = null
        ..paths = ['personal.satchel'];
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('personal'), findsOneWidget);
    });

    testWidgets('points to Accounts when the account is gone', (tester) async {
      storage.listError = const StorageAuthRequiredException(
        '',
        accountId: 'ada',
      );
      await pumpFiles(tester, config: config);

      expect(
        find.text(
          "The Google account of this storage isn't connected. "
          'Add it again under Accounts.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Accounts'));
      await tester.pumpAndSettle();

      expect(find.text('Google accounts'), findsOneWidget);
    });
  });

  testWidgets('shows storage errors and retries', (tester) async {
    storage.listError = const StorageBackendException('', 'Permission denied');

    await pumpFiles(tester);

    expect(find.text('Could not read this storage'), findsOneWidget);
    expect(find.text('Permission denied'), findsOneWidget);

    storage
      ..listError = null
      ..paths = ['personal.satchel'];
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('personal'), findsOneWidget);
  });

  testWidgets('explains when the storage no longer exists', (tester) async {
    await pumpFiles(tester, storageId: 'removed');

    expect(find.text('This storage no longer exists'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('refresh button re-reads the storage', (tester) async {
    storage.paths = ['a.satchel'];
    await pumpFiles(tester);

    storage.paths = ['a.satchel', 'b.satchel'];
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();

    expect(find.text('b'), findsOneWidget);
    expect(storage.listCalls, 2);
  });

  testWidgets('pull to refresh re-reads the storage', (tester) async {
    await pumpFiles(tester);

    storage.paths = ['new.satchel'];
    await tester.fling(
      find.text('No vault files in this storage yet'),
      const Offset(0, 400),
      1000,
    );
    await tester.pumpAndSettle();

    expect(find.text('new'), findsOneWidget);
  });

  testWidgets('opening a file updates and highlights the location', (
    tester,
  ) async {
    storage.paths = ['personal.satchel', 'work.satchel'];
    await pumpFiles(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(FilesPane)),
    );

    await tester.tap(find.text('personal'));
    await tester.pumpAndSettle();

    expect(
      container.read(currentLocationProvider),
      const AppLocation(storageId: 's', filePath: 'personal.satchel'),
    );
    bool selected(String name) =>
        tester.widget<ListTile>(find.widgetWithText(ListTile, name)).selected;
    expect(selected('personal'), isTrue);
    expect(selected('work'), isFalse);
  });

  testWidgets('shows whether each file is locked', (tester) async {
    storage.paths = ['personal.satchel', 'work.satchel'];
    await pumpFiles(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(FilesPane)),
    );
    Icon iconOf(String name) => tester.widget<Icon>(
      find
          .descendant(
            of: find.widgetWithText(ListTile, name),
            matching: find.byType(Icon),
          )
          .first,
    );

    expect(iconOf('personal').icon, Icons.lock_outline);
    expect(iconOf('personal').semanticLabel, 'Locked');
    expect(find.byTooltip('Locked'), findsNWidgets(2));

    final key = await tester.runAsync(
      () => VaultKey.create(password: 'x', memoryKiB: 64),
    );
    container
        .read(unlockedVaultsProvider.notifier)
        .adopt(
          const VaultRef('s', 'personal.satchel'),
          payload: VaultPayload.create(name: 'personal'),
          key: key!,
          revision: 'r',
        );
    await tester.pump();

    expect(iconOf('personal').icon, Icons.lock_open);
    expect(iconOf('personal').semanticLabel, 'Unlocked');
    expect(iconOf('work').icon, Icons.lock_outline);

    container
        .read(unlockedVaultsProvider.notifier)
        .lock(const VaultRef('s', 'personal.satchel'));
    await tester.pump();
    expect(iconOf('personal').icon, Icons.lock_outline);
  });

  testWidgets('shows a back button only when asked to', (tester) async {
    await pumpFiles(tester);
    expect(find.byType(BackButton), findsNothing);

    var backs = 0;
    await pumpFiles(tester, onBack: () => backs++);
    await tester.tap(find.byType(BackButton));

    expect(backs, 1);
  });

  group('new file', () {
    Future<void> openDialog(WidgetTester tester) async {
      await tester.tap(find.text('New file'));
      await tester.pumpAndSettle();
    }

    Future<void> fill(
      WidgetTester tester, {
      String name = 'Personal',
      String password = 'hunter22',
      String? confirm,
    }) async {
      await tester.enterText(find.byKey(const Key('name')), name);
      await tester.enterText(find.byKey(const Key('password')), password);
      await tester.enterText(
        find.byKey(const Key('confirm')),
        confirm ?? password,
      );
    }

    /// Taps Create and lets the (real, cheap) encryption finish.
    Future<void> create(WidgetTester tester) async {
      await tester.tap(find.text('Create'));
      await settleCrypto(tester, find.text('Encrypting…'));
    }

    testWidgets('is offered once the storage is read', (tester) async {
      storage.listError = const StorageBackendException('', 'offline');
      await pumpFiles(tester);
      expect(find.text('New file'), findsNothing);

      storage.listError = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('New file'), findsOneWidget);
    });

    testWidgets('creates an encrypted vault and opens it', (tester) async {
      await pumpFiles(tester);
      await openDialog(tester);
      await fill(tester);

      await create(tester);

      expect(find.byType(NewVaultFileDialog), findsNothing);
      expect(find.text('Personal'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(FilesPane)),
      );
      expect(
        container.read(currentLocationProvider),
        const AppLocation(storageId: 's', filePath: 'Personal.satchel'),
      );
      final opened = await tester.runAsync(
        () => VaultCodec.decrypt(
          storage.blobs['Personal.satchel']!.bytes,
          password: 'hunter22',
        ),
      );
      expect(opened!.payload.name, 'Personal');
      expect(
        container.read(unlockedVaultsProvider),
        contains(const VaultRef('s', 'Personal.satchel')),
      );
      expect(find.byTooltip('Unlocked'), findsOneWidget);
    });

    testWidgets('validates the form before creating', (tester) async {
      await pumpFiles(tester);
      await openDialog(tester);

      await fill(tester, name: '', password: 'short');
      await tester.tap(find.text('Create'));
      await tester.pump();
      expect(find.text('Enter a name'), findsOneWidget);
      expect(find.text('Use at least 8 characters'), findsOneWidget);

      await fill(tester, name: 'a/b', confirm: 'hunter23');
      await tester.tap(find.text('Create'));
      await tester.pump();
      expect(find.textContaining("Can't contain"), findsOneWidget);
      expect(find.text("Passwords don't match"), findsOneWidget);
      expect(storage.paths, isEmpty);
    });

    testWidgets('trims the name', (tester) async {
      await pumpFiles(tester);
      await openDialog(tester);
      await fill(tester, name: '  Personal  ');

      await create(tester);

      expect(storage.paths, ['Personal.satchel']);
    });

    testWidgets('reports a name that already exists', (tester) async {
      storage.paths = ['personal.satchel'];
      await pumpFiles(tester);
      await openDialog(tester);
      await fill(tester);

      await create(tester);

      expect(find.byType(NewVaultFileDialog), findsOneWidget);
      expect(find.text('A file with this name already exists'), findsOneWidget);
      expect(storage.paths, ['personal.satchel']);
    });

    testWidgets('reports storage failures and stays open', (tester) async {
      await pumpFiles(tester);
      storage.writeError = const StorageBackendException('', 'disk full');
      await openDialog(tester);
      await fill(tester);

      await create(tester);

      expect(find.byType(NewVaultFileDialog), findsOneWidget);
      expect(find.textContaining('Could not create the file'), findsOneWidget);

      storage.writeError = null;
      await create(tester);
      expect(find.byType(NewVaultFileDialog), findsNothing);
      expect(storage.paths, ['Personal.satchel']);
    });

    testWidgets('cancel creates nothing', (tester) async {
      await pumpFiles(tester);
      await openDialog(tester);
      await fill(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(NewVaultFileDialog), findsNothing);
      expect(storage.paths, isEmpty);
    });

    testWidgets('password visibility can be toggled', (tester) async {
      await pumpFiles(tester);
      await openDialog(tester);
      bool obscured() => tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const Key('password')),
              matching: find.byType(EditableText),
            ),
          )
          .obscureText;

      expect(obscured(), isTrue);
      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();
      expect(obscured(), isFalse);
    });
  });

  testWidgets('file actions are collapsed into a menu', (tester) async {
    storage.paths = ['personal.satchel'];
    await pumpFiles(tester);

    expect(find.byTooltip('Delete file'), findsNothing);
    expect(find.byTooltip('More actions'), findsOneWidget);
  });
}
