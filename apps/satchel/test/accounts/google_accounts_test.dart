import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/accounts/google_account_store.dart';
import 'package:satchel/src/accounts/google_accounts.dart';
import 'package:satchel_storage/satchel_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../fakes.dart';

const _ada = GoogleAccount(id: 'ada', email: 'ada@example.com');
const _bob = GoogleAccount(
  id: 'bob',
  email: 'bob@example.com',
  displayName: 'Bob',
);

void main() {
  late MemoryGoogleAccountStore store;
  late FakeGoogleAuth auth;

  setUp(() {
    store = MemoryGoogleAccountStore();
    auth = FakeGoogleAuth();
  });

  ProviderContainer container({bool configured = true}) {
    final c = ProviderContainer(
      overrides: googleAccountOverrides(
        store: store,
        auth: configured ? auth : null,
      ),
    );
    addTearDown(c.dispose);
    return c;
  }

  GoogleAccounts notifier(ProviderContainer c) =>
      c.read(googleAccountsProvider.notifier);

  test('loads the linked accounts', () async {
    store.accounts = [_ada, _bob];

    expect(await container().read(googleAccountsProvider.future), [_ada, _bob]);
  });

  test('add links the account the user signed in with', () async {
    final c = container();
    await c.read(googleAccountsProvider.future);
    auth.next = _ada;

    final linked = await notifier(c).add();

    expect(linked, (account: _ada, reconnected: false));
    expect(store.accounts, [_ada]);
    expect(c.read(googleAccountsProvider).value, [_ada]);
  });

  test('adding a linked account again renews it in place', () async {
    store.accounts = [_ada, _bob];
    final c = container();
    await c.read(googleAccountsProvider.future);
    const renamed = GoogleAccount(id: 'ada', email: 'ada@new.example');
    auth.next = renamed;

    final linked = await notifier(c).add();

    expect(linked, (account: renamed, reconnected: true));
    expect(store.accounts, [renamed, _bob]);
  });

  test('add changes nothing when the user cancels', () async {
    final c = container();
    await c.read(googleAccountsProvider.future);

    expect(await notifier(c).add(), isNull);
    expect(store.accounts, isEmpty);
  });

  test('add passes sign-in failures on and links nothing', () async {
    final c = container();
    await c.read(googleAccountsProvider.future);
    auth.signInError = const GoogleDriveAccessDeniedException();

    await expectLater(
      notifier(c).add(),
      throwsA(isA<GoogleDriveAccessDeniedException>()),
    );
    expect(store.accounts, isEmpty);
  });

  test('add needs Google sign-in to be configured', () async {
    final c = container(configured: false);
    await c.read(googleAccountsProvider.future);

    await expectLater(notifier(c).add(), throwsStateError);
  });

  test('cancelAdd stops the sign-in', () {
    notifier(container()).cancelAdd();

    expect(auth.cancelCalls, 1);
  });

  test('remove signs out and forgets the account', () async {
    store.accounts = [_ada, _bob];
    final c = container();
    await c.read(googleAccountsProvider.future);

    await notifier(c).remove('ada');
    await notifier(c).remove('unknown');

    expect(auth.signedOut, [_ada]);
    expect(store.accounts, [_bob]);
    expect(c.read(googleAccountsProvider).value, [_bob]);
  });

  test('remove keeps the account if signing out fails', () async {
    store.accounts = [_ada];
    final c = container();
    await c.read(googleAccountsProvider.future);
    auth.signOutError = Exception('keyring locked');

    await expectLater(notifier(c).remove('ada'), throwsException);
    expect(store.accounts, [_ada]);
  });

  group('SharedPreferencesGoogleAccountStore', () {
    setUp(() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    test('starts empty and round-trips accounts', () async {
      final store = SharedPreferencesGoogleAccountStore();
      expect(await store.load(), isEmpty);

      await store.save([_ada, _bob]);

      expect(await SharedPreferencesGoogleAccountStore().load(), [_ada, _bob]);
    });

    test('skips entries this version cannot read', () async {
      await SharedPreferencesAsync().setString(
        SharedPreferencesGoogleAccountStore.key,
        '[{"id":"ada","email":"ada@example.com"},{"id":3},42]',
      );

      expect(await SharedPreferencesGoogleAccountStore().load(), [_ada]);
    });
  });
}
