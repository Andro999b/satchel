import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/files/files_pane.dart';
import 'package:satchel/src/navigation/app_location.dart';
import 'package:satchel/src/navigation/app_shell.dart';
import 'package:satchel/src/settings/auto_lock_settings.dart';
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

  group('auto-lock setting', () {
    late MemoryAutoLockStore autoLock;

    Future<void> pump(WidgetTester tester) async {
      autoLock = MemoryAutoLockStore();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...storageOverrides(
              platform: StoragePlatform.linux,
              store: store,
              autoLock: autoLock,
            ),
            ...googleAccountOverrides(store: MemoryGoogleAccountStore()),
          ],
          child: testApp(const AppShell()),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> openPicker(WidgetTester tester, String item) async {
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the delay and changes it in a dialog', (tester) async {
      await pump(tester);

      await openPicker(tester, 'Auto-lock · 5 min');

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.text(
          'Lock all files after Satchel has been in the background for:',
        ),
        findsOneWidget,
      );
      final radios = tester.widget<RadioGroup<AutoLockDelay>>(
        find.byType(RadioGroup<AutoLockDelay>),
      );
      expect(radios.groupValue, AutoLockDelay.fiveMinutes);
      for (final label in ['1 minute', '30 minutes', '1 hour', 'Never']) {
        expect(find.text(label), findsOneWidget);
      }

      await tester.tap(find.text('15 minutes'));
      await tester.pumpAndSettle();

      expect(autoLock.delay, AutoLockDelay.fifteenMinutes);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Auto-lock · 15 min'), findsOneWidget);
    });

    testWidgets('uses a bottom sheet on compact screens', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(tester);

      await openPicker(tester, 'Auto-lock · 5 min');

      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.tap(find.text('Never'));
      await tester.pumpAndSettle();

      expect(autoLock.delay, AutoLockDelay.never);
      expect(find.byType(BottomSheet), findsNothing);
    });
  });

  testWidgets('opens Google account management from settings', (tester) async {
    await pumpStorages(tester, StoragePlatform.linux);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Google accounts'));
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
    expect(find.byTooltip('More actions'), findsNothing);
    expect(find.text('Add storage'), findsNothing);
  });

  testWidgets('app bar actions line up with the tiles trailing icons', (
    tester,
  ) async {
    double centerX(Finder finder) => tester.getCenter(finder.first).dx;

    store.configs = [directoryConfig('a', '/x', name: 'Personal')];
    await pumpStorages(tester, StoragePlatform.linux);
    expect(
      centerX(find.byIcon(Icons.more_vert)),
      centerX(find.byIcon(Icons.settings_outlined)),
    );
    // Titles and tiles start 16 from the edge.
    expect(tester.getTopLeft(find.text('Satchel')).dx, 16);
    expect(
      tester
          .getTopLeft(
            find
                .descendant(
                  of: find.byType(ListTile),
                  matching: find.byType(Icon),
                )
                .first,
          )
          .dx,
      16,
    );

    await pumpStorages(tester, StoragePlatform.web);
    expect(
      centerX(find.byIcon(Icons.chevron_right)),
      centerX(find.byIcon(Icons.settings_outlined)),
    );
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
    expect(find.byTooltip('More actions'), findsNWidgets(2));
  });

  for (final config in [
    directoryConfig('a', '/x', name: 'Personal'),
    driveConfig(
      'a',
      'folder',
      accountId: 'ada',
      name: 'Personal',
      locationName: 'My Drive / Vaults',
    ),
  ]) {
    testWidgets('${config.kind.name} has a focused rename/delete menu', (
      tester,
    ) async {
      store.configs = [config];
      await pumpStorages(tester, StoragePlatform.linux, fakeStorages: true);

      final tile = find.byKey(ValueKey(config.id));
      final anchor = find.descendant(
        of: tile,
        matching: find.byType(MenuAnchor),
      );
      final focus = tester.widget<Focus>(
        find.ancestor(of: anchor, matching: find.byType(Focus)).first,
      );
      expect(focus.parentNode, FocusScope.of(tester.element(tile)));
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNWidgets(2));
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      expect(find.text('Rename "Personal"'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Personal',
      );
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Rename'))
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField), '  Renamed  ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.widgetWithText(ListTile, 'Renamed'), findsOneWidget);
      expect(store.configs.single.displayName, 'Renamed');
      expect(store.configs.single.id, config.id);
      expect(store.configs.single.location, config.location);
      expect(store.configs.single.locationName, config.locationName);
      expect(store.configs.single.accountId, config.accountId);
    });

    testWidgets('deletes ${config.kind.name} only after confirmation', (
      tester,
    ) async {
      store.configs = [config];
      await pumpStorages(tester, StoragePlatform.linux, fakeStorages: true);

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Satchel will forget this storage. Files in it are not deleted.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.configs, [config]);

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(store.configs, isEmpty);
    });
  }

  testWidgets('cancelling rename keeps the storage name', (tester) async {
    store.configs = [directoryConfig('a', '/x', name: 'Personal')];
    await pumpStorages(tester, StoragePlatform.linux);

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Changed');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(store.configs.single.displayName, 'Personal');
  });

  testWidgets('reports a failed removal and keeps the storage', (tester) async {
    store.configs = [directoryConfig('a', '/x', name: 'Personal')];
    store.saveError = Exception('save failed');
    await pumpStorages(tester, StoragePlatform.linux);

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not remove the storage. Try again.'),
      findsOneWidget,
    );
    expect(store.configs.single.displayName, 'Personal');
    expect(picker.released, isEmpty);
  });

  testWidgets('reports a failed rename and keeps the original name', (
    tester,
  ) async {
    store.configs = [directoryConfig('a', '/x', name: 'Personal')];
    store.saveError = Exception('save failed');
    await pumpStorages(tester, StoragePlatform.linux);

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Changed');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not rename the storage. Try again.'),
      findsOneWidget,
    );
    expect(store.configs.single.displayName, 'Personal');
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

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Remove "Old"?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.configs, hasLength(1));

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ListTile, 'Old'), findsNothing);
    expect(store.configs, isEmpty);
    expect(picker.released, ['/x']);
  });
}
