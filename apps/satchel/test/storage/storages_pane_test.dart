import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/files/files_pane.dart';
import 'package:satchel/src/navigation/app_location.dart';
import 'package:satchel/src/navigation/app_shell.dart';
import 'package:satchel/src/storage/storage_providers.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../fakes.dart';
import '../test_app.dart';

void main() {
  late MemoryStorageConfigStore store;
  late FakeDirectoryPicker picker;

  setUp(() {
    store = MemoryStorageConfigStore();
    picker = FakeDirectoryPicker();
  });

  Future<void> pumpStorages(
    WidgetTester tester,
    StoragePlatform platform, {
    List<StorageProvider>? storages,
    bool fakeStorages = false,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...storageOverrides(platform: platform, store: store, picker: picker),
          ...googleAccountOverrides(store: MemoryGoogleAccountStore()),
          if (storages != null)
            storageProvidersProvider.overrideWith((ref) async => storages)
          else if (fakeStorages)
            // An empty in-memory storage for every configured one.
            storageProvidersProvider.overrideWith(
              (ref) async => [
                for (final config in await ref.watch(
                  storageConfigsProvider.future,
                ))
                  FakeStorageProvider(
                    id: config.id,
                    displayName: config.displayName,
                  ),
              ],
            ),
        ],
        child: testApp(const AppShell()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows empty state without storages', (tester) async {
    await pumpStorages(tester, StoragePlatform.linux);

    expect(find.text('No storage configured yet'), findsOneWidget);
    expect(find.text('Add storage'), findsOneWidget);
  });

  testWidgets('opens Google account management from settings', (tester) async {
    await pumpStorages(tester, StoragePlatform.linux);

    await tester.tap(find.byTooltip('Accounts and settings'));
    await tester.pumpAndSettle();

    expect(find.text('Google accounts'), findsOneWidget);
    expect(find.text('No Google accounts connected'), findsOneWidget);
    expect(
      find.text("Google sign-in isn't set up in this build of Satchel."),
      findsOneWidget,
    );
  });

  testWidgets('web lists the built-in browser storage only', (tester) async {
    await pumpStorages(tester, StoragePlatform.web);

    expect(find.text('This browser'), findsOneWidget);
    expect(find.byTooltip('Remove'), findsNothing);
    expect(find.text('Add storage'), findsNothing);
  });

  testWidgets('lists configured folders with their location', (tester) async {
    store.configs = [
      directoryConfig('a', '/home/me/vaults', name: 'Personal'),
      directoryConfig(
        'b',
        'content://com.android.externalstorage.documents/tree/'
            'primary%3ADocuments%2FVaults',
        name: 'Phone',
      ),
    ];

    await pumpStorages(tester, StoragePlatform.android);

    expect(find.text('Personal'), findsOneWidget);
    expect(find.text('/home/me/vaults'), findsOneWidget);
    expect(find.text('Phone'), findsOneWidget);
    expect(find.text('primary:Documents/Vaults'), findsOneWidget);
    expect(find.byTooltip('Remove'), findsNWidgets(2));
  });

  testWidgets('opens the files of a storage', (tester) async {
    store.configs = [directoryConfig('a', '/x', name: 'Personal')];
    await pumpStorages(
      tester,
      StoragePlatform.linux,
      storages: [
        FakeStorageProvider(
          id: 'a',
          displayName: 'Personal',
          paths: ['bank.satchel'],
        ),
      ],
    );

    expect(find.text('Select a storage'), findsOneWidget);

    await tester.tap(find.text('Personal'));
    await tester.pumpAndSettle();

    expect(find.byType(FilesPane), findsOneWidget);
    expect(find.text('bank'), findsOneWidget);
  });

  testWidgets('adds a folder picked by the user and opens it', (tester) async {
    picker.next = const PickedDirectory(
      location: '/home/me/Sync',
      name: 'Sync',
    );
    await pumpStorages(tester, StoragePlatform.linux, fakeStorages: true);

    await tester.tap(find.text('Add storage'));
    await tester.pumpAndSettle();
    expect(find.text('/home/me/Sync'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '  Synced vaults ');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(store.configs.single.displayName, 'Synced vaults');
    expect(store.configs.single.location, '/home/me/Sync');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AppShell)),
    );
    expect(
      container.read(currentLocationProvider),
      AppLocation(storageId: store.configs.single.id),
    );
    expect(find.byType(FilesPane), findsOneWidget);
    expect(find.text('Select a storage'), findsNothing);
  });

  testWidgets('cancelling the picker adds nothing', (tester) async {
    await pumpStorages(tester, StoragePlatform.linux);

    await tester.tap(find.text('Add storage'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(store.configs, isEmpty);
  });

  testWidgets('cancelling the name dialog adds nothing', (tester) async {
    picker.next = const PickedDirectory(location: '/x', name: 'x');
    await pumpStorages(tester, StoragePlatform.linux);

    await tester.tap(find.text('Add storage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(store.configs, isEmpty);
    expect(find.text('Select a storage'), findsOneWidget);
  });

  testWidgets('refuses a folder that is already added', (tester) async {
    store.configs = [directoryConfig('a', '/x')];
    picker.next = const PickedDirectory(location: '/x', name: 'x');
    await pumpStorages(tester, StoragePlatform.linux);

    await tester.tap(find.text('Add storage'));
    await tester.pumpAndSettle();

    expect(find.text('This folder is already added'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(store.configs, hasLength(1));
  });

  testWidgets('reports picker failures', (tester) async {
    picker.error = Exception('no picker');
    await pumpStorages(tester, StoragePlatform.linux);

    await tester.tap(find.text('Add storage'));
    await tester.pumpAndSettle();

    expect(find.text('Could not add the folder'), findsOneWidget);
  });

  testWidgets('removes a folder after confirmation', (tester) async {
    store.configs = [directoryConfig('a', '/x', name: 'Old')];
    await pumpStorages(tester, StoragePlatform.android);

    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove "Old"?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.configs, hasLength(1));

    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ListTile, 'Old'), findsNothing);
    expect(store.configs, isEmpty);
    expect(picker.released, ['/x']);
  });
}
