import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/accounts/google_accounts.dart';
import 'package:satchel/src/files/files_pane.dart';
import 'package:satchel/src/navigation/app_location.dart';
import 'package:satchel/src/navigation/app_shell.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../fakes.dart';
import '../test_app.dart';

const _ada = GoogleAccount(id: 'ada', email: 'ada@example.com');
const _vaults = DriveFolder(id: 'f1', name: 'Vaults');

void main() {
  late MemoryStorageConfigStore store;
  late MemoryGoogleAccountStore accounts;
  late FakeGoogleAuth auth;
  late FakeDriveFolderSource folders;
  late List<GoogleAccount> browsedAs;

  setUp(() {
    store = MemoryStorageConfigStore();
    accounts = MemoryGoogleAccountStore([_ada]);
    auth = FakeGoogleAuth();
    folders = FakeDriveFolderSource()..folders[driveRootFolderId] = [_vaults];
    browsedAs = [];
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    StoragePlatform platform = StoragePlatform.web,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...storageOverrides(platform: platform, store: store),
          ...googleAccountOverrides(store: accounts, auth: auth),
          driveFolderSourceProvider.overrideWithValue((account) {
            browsedAs.add(account);
            return folders;
          }),
        ],
        child: testApp(const AppShell()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.text('Add storage'));
    await tester.pumpAndSettle();
    expect(find.text('Add Google Drive'), findsOneWidget);
  }

  Future<void> chooseAda(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('ada@example.com'),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapButton(WidgetTester tester, String label) async {
    await tester.tap(
      find.ancestor(
        of: find.text(label),
        matching: find.bySubtype<ButtonStyleButton>(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('adds a folder of the chosen account', (tester) async {
    await pumpShell(tester);
    await openDialog(tester);

    await chooseAda(tester);
    expect(browsedAs, [_ada]);
    expect(find.text('My Drive'), findsOneWidget);
    await tester.tap(find.text('Vaults'));
    await tester.pumpAndSettle();
    expect(find.text('My Drive / Vaults'), findsOneWidget);
    expect(find.text('No folders here that Satchel can use'), findsOneWidget);
    await tapButton(tester, 'Use this folder');

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Vaults',
    );
    await tester.enterText(find.byType(TextField), ' Synced ');
    await tapButton(tester, 'Add');

    final config = store.configs.single;
    expect(config.kind, StorageProviderKind.googleDrive);
    expect(config.displayName, 'Synced');
    expect(config.location, 'f1');
    expect(config.locationName, 'My Drive / Vaults');
    expect(config.accountId, 'ada');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AppShell)),
    );
    expect(
      container.read(currentLocationProvider),
      AppLocation(storageId: config.id),
    );
    expect(find.byType(FilesPane), findsOneWidget);
    expect(find.text('Synced'), findsOneWidget);
  });

  testWidgets('goes up and can use My Drive itself', (tester) async {
    await pumpShell(tester);
    await openDialog(tester);
    await chooseAda(tester);
    await tester.tap(find.text('Vaults'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Up'));
    await tester.pumpAndSettle();
    expect(find.text('Vaults'), findsOneWidget);
    await tapButton(tester, 'Use this folder');
    await tapButton(tester, 'Add');

    final config = store.configs.single;
    expect(config.location, driveRootFolderId);
    expect(config.locationName, 'My Drive');
    expect(config.displayName, 'Google Drive');
  });

  testWidgets('creates a folder and opens it', (tester) async {
    await pumpShell(tester);
    await openDialog(tester);
    await chooseAda(tester);

    await tapButton(tester, 'New folder');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Satchel',
    );
    await tester.enterText(find.byType(TextField), 'Passwords');
    await tapButton(tester, 'Create');

    expect(folders.created, [(driveRootFolderId, 'Passwords')]);
    expect(find.text('My Drive / Passwords'), findsOneWidget);
  });

  testWidgets('can connect an account first', (tester) async {
    accounts.accounts = [];
    auth.next = _ada;
    await pumpShell(tester);
    await openDialog(tester);

    expect(
      find.text('No Google account is connected yet. Add one to continue.'),
      findsOneWidget,
    );
    await tapButton(tester, 'Add account');

    expect(accounts.accounts, [_ada]);
    expect(browsedAs, [_ada]);
    expect(find.text('Use this folder'), findsOneWidget);
  });

  testWidgets('refuses a folder that is already added', (tester) async {
    store.configs = [driveConfig('d', driveRootFolderId, accountId: 'ada')];
    await pumpShell(tester);
    await openDialog(tester);
    await chooseAda(tester);

    await tapButton(tester, 'Use this folder');

    expect(find.text('This folder is already added'), findsOneWidget);
    expect(find.text('Use this folder'), findsOneWidget);
  });

  testWidgets('reports folder errors and retries', (tester) async {
    folders.listError = const StorageBackendException('', 'offline');
    await pumpShell(tester);
    await openDialog(tester);
    await chooseAda(tester);

    expect(find.text('Could not load the folders.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Use this folder'),
          )
          .onPressed,
      isNull,
    );

    folders.listError = null;
    await tapButton(tester, 'Retry');
    expect(find.text('Vaults'), findsOneWidget);
  });

  testWidgets('cancelling adds nothing', (tester) async {
    await pumpShell(tester);
    await openDialog(tester);
    await chooseAda(tester);

    await tapButton(tester, 'Cancel');

    expect(find.text('Add Google Drive'), findsNothing);
    expect(store.configs, isEmpty);
  });

  testWidgets('is offered next to folders on desktop', (tester) async {
    await pumpShell(tester, platform: StoragePlatform.linux);

    await tester.tap(find.text('Add storage'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MenuItemButton, 'Folder'), findsOneWidget);
    await tester.tap(find.widgetWithText(MenuItemButton, 'Google Drive'));
    await tester.pumpAndSettle();

    expect(find.text('Add Google Drive'), findsOneWidget);
  });
}
