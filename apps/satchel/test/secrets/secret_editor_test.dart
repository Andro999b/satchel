import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/navigation/app_location.dart';
import 'package:satchel/src/secrets/secret_editor.dart';
import 'package:satchel/src/secrets/secrets_pane.dart';
import 'package:satchel/src/storage/storage_providers.dart';
import 'package:satchel/src/vault/unlocked_vaults.dart';
import 'package:satchel/src/vault/vault_providers.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../fakes.dart';
import '../test_app.dart';

final _now = DateTime.utc(2026, 11, 2, 12);

void main() {
  late FakeStorageProvider storage;
  late ProviderContainer container;
  const vault = VaultRef('s', 'personal.satchel');

  Future<void> pumpPane(WidgetTester tester, {Size? size}) async {
    if (size != null) {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    storage = FakeStorageProvider(id: 's');
    await tester.runAsync(() => putVault(storage, vault.path, 'hunter22'));
    container = ProviderContainer(
      overrides: [
        ...storageOverrides(
          platform: StoragePlatform.linux,
          store: MemoryStorageConfigStore([directoryConfig('s', '/s')]),
        ),
        storageProvidersProvider.overrideWith((ref) async => [storage]),
        appClockProvider.overrideWithValue(Clock.fixed(_now)),
      ],
    );
    addTearDown(container.dispose);
    container.read(currentLocationProvider.notifier).openFile('s', vault.path);
    await tester.runAsync(
      () => container
          .read(unlockedVaultsProvider.notifier)
          .unlock(vault, 'hunter22'),
    );
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

  Future<void> openEditor(WidgetTester tester, String typeName) async {
    await tester.tap(find.text('New secret'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, typeName));
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester, String key, String text) async {
    final field = find.byKey(Key(key));
    await tester.ensureVisible(field);
    await tester.enterText(field, text);
  }

  /// Scrolls [finder] into view and taps it. Drops focus and lets the
  /// focused field's caret scrolling finish first, or it would scroll back.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> showMore(WidgetTester tester) =>
      tapVisible(tester, find.byKey(const Key('moreOptions')));

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settleCrypto(tester, find.byType(LinearProgressIndicator));
  }

  /// The secrets stored in the file, decrypted independently of the session.
  Future<List<Secret>> storedSecrets(WidgetTester tester) async {
    final opened = await tester.runAsync(
      () => VaultCodec.decrypt(
        storage.blobs[vault.path]!.bytes,
        password: 'hunter22',
      ),
    );
    return opened!.payload.secrets;
  }

  testWidgets('offers every secret type once the file is unlocked', (
    tester,
  ) async {
    await pumpPane(tester);

    await tester.tap(find.text('New secret'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widgetList<MenuItemButton>(find.byType(MenuItemButton))
          .map((item) => (item.child! as Text).data),
      [
        'Password',
        'Login',
        'Key or certificate',
        'Recovery codes',
        'Secure note',
      ],
    );

    container.read(unlockedVaultsProvider.notifier).lock(vault);
    await tester.pumpAndSettle();
    expect(find.text('New secret'), findsNothing);
  });

  testWidgets('creates a login, saves the file and opens the secret', (
    tester,
  ) async {
    await pumpPane(tester);
    await openEditor(tester, 'Login');
    expect(find.text('New login'), findsOneWidget);

    await enter(tester, 'title', '  Example Bank ');
    await enter(tester, 'username', ' ann@example.com ');
    await enter(tester, 'password', ' p@ss wörd ');
    await enter(tester, 'url', 'https://bank.example.com');
    await enter(tester, 'totp', 'JBSWY3DPEHPK3PXP');
    await showMore(tester);
    await enter(tester, 'tags', 'finance, Bank ,, finance');
    await enter(tester, 'notes', 'Shared with Ann.');
    await save(tester);

    expect(find.byType(SecretEditor), findsNothing);
    expect(find.widgetWithText(ListTile, 'Example Bank'), findsOneWidget);
    final login = (await storedSecrets(tester)).single as LoginSecret;
    expect(login.title, 'Example Bank');
    expect(login.username, 'ann@example.com');
    expect(login.password, ' p@ss wörd ', reason: 'kept exactly');
    expect(login.url, 'https://bank.example.com');
    expect(login.totp, 'JBSWY3DPEHPK3PXP');
    expect(login.tags, ['Bank', 'finance']);
    expect(login.notes, 'Shared with Ann.');
    expect(login.createdAt, _now);
    expect(login.updatedAt, _now);
    expect(login.expiresAt, isNull);
    expect(container.read(currentLocationProvider).secretId, login.id);
    expect(container.read(unlockedVaultsProvider)[vault]!.payload.secrets, [
      login,
    ]);
  });

  testWidgets('creates each of the other types', (tester) async {
    await pumpPane(tester);

    await openEditor(tester, 'Password');
    await enter(tester, 'title', 'Wi-Fi');
    await enter(tester, 'password', 'c0rrect-h0rse');
    await save(tester);

    await openEditor(tester, 'Key or certificate');
    await enter(tester, 'title', 'Server key');
    await enter(
      tester,
      'pem',
      '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n',
    );
    await save(tester);

    await openEditor(tester, 'Recovery codes');
    await enter(tester, 'title', 'Mail codes');
    await enter(tester, 'codes', ' 1111-2222 \n\n3333-4444\n  ');
    await save(tester);

    await openEditor(tester, 'Secure note');
    await enter(tester, 'title', 'Safe');
    await enter(tester, 'noteText', 'Combination: 12-34-56');
    await save(tester);

    final secrets = await storedSecrets(tester);
    expect(secrets.map((s) => s.title), [
      'Wi-Fi',
      'Server key',
      'Mail codes',
      'Safe',
    ]);
    expect((secrets[0] as PasswordSecret).password, 'c0rrect-h0rse');
    final pem = secrets[1] as PemSecret;
    expect(pem.pem, endsWith('-----END PRIVATE KEY-----'));
    expect(pem.containsPrivateKey, isTrue);
    expect((secrets[2] as RecoveryCodesSecret).codes, const [
      RecoveryCode('1111-2222'),
      RecoveryCode('3333-4444'),
    ]);
    expect((secrets[3] as NoteSecret).text, 'Combination: 12-34-56');
    expect(find.byType(ListTile), findsNWidgets(4));
  });

  testWidgets('validates required fields per type', (tester) async {
    await pumpPane(tester);
    final before = storage.blobs[vault.path]!.revision;

    Future<void> expectErrors(String type, List<String> errors) async {
      await openEditor(tester, type);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      for (final error in errors) {
        expect(find.text(error), findsOneWidget, reason: '$type: $error');
      }
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
    }

    await expectErrors('Password', ['Enter a title', 'Enter a password']);
    await expectErrors('Login', ['Enter a title']);
    await expectErrors('Key or certificate', [
      'Paste a PEM block starting with -----BEGIN',
    ]);
    await expectErrors('Recovery codes', ['Enter at least one code']);
    await expectErrors('Secure note', ['Enter the text']);
    expect(storage.blobs[vault.path]!.revision, before);
  });

  testWidgets('generates passwords', (tester) async {
    await pumpPane(tester);
    await openEditor(tester, 'Password');

    await tester.tap(find.byTooltip('Generate password'));
    await tester.pump();
    final field = tester.widget<TextFormField>(
      find.byKey(const Key('password')),
    );
    final first = field.controller!.text;
    expect(first, hasLength(20));

    await tester.tap(find.byTooltip('Generate password'));
    await tester.pump();
    expect(field.controller!.text, isNot(first));
  });

  testWidgets('adds, removes and masks custom fields', (tester) async {
    await pumpPane(tester);
    await openEditor(tester, 'Secure note');
    await enter(tester, 'title', 'Safe');
    await enter(tester, 'noteText', '1234');
    await showMore(tester);

    for (var i = 0; i < 3; i++) {
      await tapVisible(tester, find.text('Add field'));
    }
    await enter(tester, 'fieldLabel0', 'Location');
    await enter(tester, 'fieldValue0', 'Basement');
    await enter(tester, 'fieldLabel1', 'Remove me');
    await enter(tester, 'fieldLabel2', 'PIN');
    await enter(tester, 'fieldValue2', '0000');
    // Location is not sensitive: show it.
    await tapVisible(tester, find.byTooltip('Masked until revealed').first);
    await tapVisible(tester, find.byTooltip('Remove field').at(1));

    await save(tester);

    expect(tester.takeException(), isNull);
    expect((await storedSecrets(tester)).single.customFields, const [
      CustomField(label: 'Location', value: 'Basement', concealed: false),
      CustomField(label: 'PIN', value: '0000'),
    ]);
  });

  testWidgets('custom fields need a label', (tester) async {
    await pumpPane(tester);
    await openEditor(tester, 'Secure note');
    await enter(tester, 'title', 'Safe');
    await enter(tester, 'noteText', '1234');
    await showMore(tester);
    await tapVisible(tester, find.text('Add field'));

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    expect(find.text('Enter a label'), findsOneWidget);
    expect(find.byType(SecretEditor), findsOneWidget);
  });

  testWidgets('optional fields are collapsed by default', (tester) async {
    await pumpPane(tester);
    await openEditor(tester, 'Login');

    expect(find.text('More options'), findsOneWidget);
    expect(find.text('Tags, notes, expiry and custom fields'), findsOneWidget);
    expect(find.byKey(const Key('tags')), findsNothing);
    expect(find.byKey(const Key('validDays')), findsNothing);
    expect(find.text('Add field'), findsNothing);

    await showMore(tester);
    expect(find.byKey(const Key('tags')), findsOneWidget);
    expect(find.byKey(const Key('notes')), findsOneWidget);
    expect(find.byKey(const Key('validDays')), findsOneWidget);
    expect(find.text('Add field'), findsOneWidget);

    await showMore(tester);
    expect(find.byKey(const Key('tags')), findsNothing);
  });

  testWidgets('the validity in days sets the expiry date', (tester) async {
    await pumpPane(tester);
    await openEditor(tester, 'Password');
    await enter(tester, 'title', 'Rotating');
    await enter(tester, 'password', 'pw');
    await showMore(tester);
    expect(find.text('Never expires'), findsOneWidget);

    await enter(tester, 'validDays', '90');
    await tester.pump();
    final expected = _now.add(const Duration(days: 90));
    final context = tester.element(find.byType(SecretEditor));
    final date = MaterialLocalizations.of(context)
        .formatMediumDate(expected.toLocal());
    expect(find.text('Expires $date'), findsOneWidget);

    await save(tester);

    expect((await storedSecrets(tester)).single.expiresAt, expected);
  });

  testWidgets('validity presets fill in the days', (tester) async {
    await pumpPane(tester);
    await openEditor(tester, 'Password');
    await enter(tester, 'title', 'Rotating');
    await enter(tester, 'password', 'pw');
    await showMore(tester);

    expect(
      tester
          .widgetList<ActionChip>(find.byType(ActionChip))
          .map((chip) => (chip.label as Text).data),
      ['30 days', '60 days', '90 days', '180 days', '365 days'],
    );
    await tapVisible(tester, find.text('365 days'));
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('validDays')))
          .controller!
          .text,
      '365',
    );

    await save(tester);
    expect(
      (await storedSecrets(tester)).single.expiresAt,
      _now.add(const Duration(days: 365)),
    );
  });

  testWidgets('no validity means no expiry', (tester) async {
    await pumpPane(tester);
    await openEditor(tester, 'Password');
    await enter(tester, 'title', 'Forever');
    await enter(tester, 'password', 'pw');

    await save(tester);

    expect((await storedSecrets(tester)).single.expiresAt, isNull);
  });

  testWidgets('accepts only digits and a sane number of days', (tester) async {
    await pumpPane(tester);
    await openEditor(tester, 'Password');
    await showMore(tester);
    final field = tester.widget<TextFormField>(
      find.byKey(const Key('validDays')),
    );

    await enter(tester, 'validDays', '-1.5 days');
    expect(field.controller!.text, '15');

    await enter(tester, 'title', 'x');
    await enter(tester, 'password', 'pw');
    for (final bad in ['0', '36501']) {
      await enter(tester, 'validDays', bad);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      expect(find.text('Enter 1 to 36500 days'), findsOneWidget, reason: bad);
    }
  });

  testWidgets('hidden errors open the collapsed section', (tester) async {
    await pumpPane(tester);
    final before = storage.blobs[vault.path]!.revision;
    await openEditor(tester, 'Password');
    await enter(tester, 'title', 'x');
    await enter(tester, 'password', 'pw');
    await showMore(tester);
    await tapVisible(tester, find.text('Add field'));
    await showMore(tester);
    expect(find.text('Add field'), findsNothing, reason: 'collapsed');

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Add field'), findsOneWidget, reason: 'expanded');
    expect(find.text('Enter a label'), findsOneWidget);
    expect(storage.blobs[vault.path]!.revision, before);
  });

  testWidgets('a file changed elsewhere is not overwritten', (tester) async {
    await pumpPane(tester);
    final current = storage.blobs[vault.path]!;
    storage.blobs[vault.path] = (bytes: current.bytes, revision: 'elsewhere');
    await openEditor(tester, 'Password');
    await enter(tester, 'title', 'Wi-Fi');
    await enter(tester, 'password', 'pw');

    await save(tester);

    expect(find.byType(SecretEditor), findsOneWidget);
    expect(
      find.textContaining('was changed elsewhere since you unlocked it'),
      findsOneWidget,
    );
    expect(storage.blobs[vault.path]!.revision, 'elsewhere');
    expect(
      container.read(unlockedVaultsProvider)[vault]!.payload.secrets,
      isEmpty,
    );
  });

  testWidgets('storage failures can be retried', (tester) async {
    await pumpPane(tester);
    storage.writeError = const StorageBackendException('', 'disk full');
    await openEditor(tester, 'Password');
    await enter(tester, 'title', 'Wi-Fi');
    await enter(tester, 'password', 'pw');

    await save(tester);
    expect(
      find.text('Could not save. Check the storage and try again.'),
      findsOneWidget,
    );

    storage.writeError = null;
    await save(tester);
    expect(find.byType(SecretEditor), findsNothing);
    expect((await storedSecrets(tester)).single.title, 'Wi-Fi');
  });

  testWidgets('closing the editor saves nothing', (tester) async {
    await pumpPane(tester);
    final before = storage.blobs[vault.path]!.revision;
    await openEditor(tester, 'Password');
    await enter(tester, 'title', 'Wi-Fi');
    await enter(tester, 'password', 'pw');

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(find.byType(SecretEditor), findsNothing);
    expect(storage.blobs[vault.path]!.revision, before);
    expect(container.read(currentLocationProvider).secretId, isNull);
  });

  testWidgets('is full screen on compact windows only', (tester) async {
    await pumpPane(tester, size: const Size(400, 800));
    await openEditor(tester, 'Password');
    expect(
      tester.widget<Dialog>(find.byType(Dialog)).insetPadding,
      EdgeInsets.zero,
    );
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    await openEditor(tester, 'Password');
    expect(
      tester.widget<Dialog>(find.byType(Dialog)).insetPadding,
      isNot(EdgeInsets.zero),
    );
  });
}
