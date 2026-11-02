import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/accounts/account_management_dialog.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../fakes.dart';
import '../test_app.dart';

const _ada = GoogleAccount(
  id: 'ada',
  email: 'ada@example.com',
  displayName: 'Ada Lovelace',
);
const _bob = GoogleAccount(id: 'bob', email: 'bob@example.com');

void main() {
  late MemoryGoogleAccountStore store;
  late FakeGoogleAuth auth;
  late MemoryStorageConfigStore storages;

  setUp(() {
    store = MemoryGoogleAccountStore();
    auth = FakeGoogleAuth();
    storages = MemoryStorageConfigStore();
  });

  Future<void> pumpDialog(
    WidgetTester tester, {
    StoragePlatform platform = StoragePlatform.android,
    bool configured = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...storageOverrides(platform: platform, store: storages),
          ...googleAccountOverrides(
            store: store,
            auth: configured ? auth : null,
          ),
        ],
        child: testApp(const Scaffold(body: AccountManagementDialog())),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder addButton() => find.widgetWithText(FilledButton, 'Add account');

  bool enabled(WidgetTester tester, Finder button) =>
      tester.widget<ButtonStyleButton>(button).onPressed != null;

  testWidgets('shows the empty state', (tester) async {
    await pumpDialog(tester);

    expect(find.text('No Google accounts connected'), findsOneWidget);
    expect(enabled(tester, addButton()), isTrue);
    expect(
      find.text("Google sign-in isn't set up in this build of Satchel."),
      findsNothing,
    );
  });

  testWidgets('explains when sign-in is not configured', (tester) async {
    await pumpDialog(tester, configured: false);

    expect(
      find.text("Google sign-in isn't set up in this build of Satchel."),
      findsOneWidget,
    );
    expect(enabled(tester, addButton()), isFalse);
  });

  testWidgets('lists the connected accounts', (tester) async {
    store.accounts = [_ada, _bob];
    await pumpDialog(tester);

    expect(find.text('Ada Lovelace'), findsOneWidget);
    expect(find.text('ada@example.com'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('bob@example.com'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.byTooltip('Remove account'), findsNWidgets(2));
    expect(find.text('No Google accounts connected'), findsNothing);
  });

  testWidgets('adds an account', (tester) async {
    auth.next = _ada;
    await pumpDialog(tester);

    await tester.tap(addButton());
    await tester.pumpAndSettle();

    expect(find.text('Connected ada@example.com'), findsOneWidget);
    expect(find.text('Ada Lovelace'), findsOneWidget);
    expect(store.accounts, [_ada]);
  });

  testWidgets('says when an account was signed in again', (tester) async {
    store.accounts = [_ada];
    auth.next = _ada;
    await pumpDialog(tester);

    await tester.tap(addButton());
    await tester.pumpAndSettle();

    expect(find.text('Signed in to ada@example.com again'), findsOneWidget);
    expect(find.text('Ada Lovelace'), findsOneWidget);
  });

  testWidgets('shows progress while signing in', (tester) async {
    auth.pending = Completer();
    await pumpDialog(tester);

    await tester.tap(addButton());
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Signing in…'), findsOneWidget);
    expect(enabled(tester, addButton()), isFalse);
    expect(find.text('Cancel'), findsNothing);

    auth.pending!.complete(_bob);
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Connected bob@example.com'), findsOneWidget);
  });

  testWidgets('desktop sign-in waits for the browser and can be cancelled', (
    tester,
  ) async {
    auth.pending = Completer();
    await pumpDialog(tester, platform: StoragePlatform.linux);

    await tester.tap(addButton());
    await tester.pump();
    expect(find.text('Continue in your browser to sign in.'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(auth.cancelCalls, 1);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Close'), findsOneWidget);
    expect(store.accounts, isEmpty);
  });

  testWidgets('closing the dialog cancels a browser sign-in', (tester) async {
    auth.pending = Completer();
    await pumpDialog(tester, platform: StoragePlatform.windows);

    await tester.tap(addButton());
    await tester.pump();
    await tester.pumpWidget(const SizedBox());

    expect(auth.cancelCalls, 1);
  });

  testWidgets('explains that Drive access is needed', (tester) async {
    auth.signInError = const GoogleDriveAccessDeniedException();
    await pumpDialog(tester);

    await tester.tap(addButton());
    await tester.pumpAndSettle();

    expect(find.textContaining('needs access to Google Drive'), findsOneWidget);
    expect(store.accounts, isEmpty);
  });

  testWidgets('reports sign-in failures', (tester) async {
    auth.signInError = const GoogleAuthFailedException('network');
    await pumpDialog(tester);

    await tester.tap(addButton());
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Could not sign in to Google. Check your connection and try again.',
      ),
      findsOneWidget,
    );
    expect(enabled(tester, addButton()), isTrue);
  });

  testWidgets('removes an account after confirmation', (tester) async {
    store.accounts = [_ada, _bob];
    await pumpDialog(tester);

    await tester.tap(find.byTooltip('Remove account').first);
    await tester.pumpAndSettle();
    expect(find.text('Remove ada@example.com?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.accounts, [_ada, _bob]);

    await tester.tap(find.byTooltip('Remove account').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(find.text('Ada Lovelace'), findsNothing);
    expect(find.text('bob@example.com'), findsOneWidget);
    expect(store.accounts, [_bob]);
    expect(auth.signedOut, [_ada]);
  });

  testWidgets('warns about Drive storages using the account', (tester) async {
    store.accounts = [_ada, _bob];
    storages.configs = [
      driveConfig('a', 'f1', accountId: 'ada'),
      driveConfig('b', 'f2', accountId: 'ada'),
      driveConfig('c', 'f3', accountId: 'bob'),
    ];
    await pumpDialog(tester);

    await tester.tap(find.byTooltip('Remove account').first);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('2 Google Drive storages use this account.'),
      findsOneWidget,
    );
  });

  testWidgets('reports a failed removal', (tester) async {
    store.accounts = [_ada];
    auth.signOutError = Exception('keyring locked');
    await pumpDialog(tester);

    await tester.tap(find.byTooltip('Remove account'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not remove the account. Try again.'),
      findsOneWidget,
    );
    expect(find.text('Ada Lovelace'), findsOneWidget);
    expect(store.accounts, [_ada]);
  });
}
