import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/navigation/adaptive_layout.dart';
import 'package:satchel/src/navigation/app_location.dart';
import 'package:satchel/src/secrets/expiry_display.dart';
import 'package:satchel/src/secrets/secret_clipboard.dart';
import 'package:satchel/src/secrets/secret_editor.dart';
import 'package:satchel/src/secrets/secret_pane.dart';
import 'package:satchel/src/storage/storage_providers.dart';
import 'package:satchel/src/vault/unlocked_vaults.dart';
import 'package:satchel/src/vault/vault_providers.dart';
import 'package:satchel/src/widgets/destructive_dialog.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../fakes.dart';
import '../test_app.dart';

final _now = DateTime.utc(2026, 11, 2, 12);

SecretInfo _info(
  String id,
  String title, {
  DateTime? expiresAt,
  List<String> tags = const [],
  String notes = '',
  List<CustomField> customFields = const [],
}) => SecretInfo(
  id: id,
  title: title,
  createdAt: DateTime.utc(2026, 1, 15, 9, 30),
  updatedAt: DateTime.utc(2026, 3, 1, 18),
  expiresAt: expiresAt,
  tags: tags,
  notes: notes,
  customFields: customFields,
);

final _login = LoginSecret(
  info: _info(
    'login',
    'Example Bank',
    tags: ['finance', 'home'],
    notes: 'Shared with Ann.',
    customFields: const [
      CustomField(label: 'Customer no', value: '12345', concealed: false),
      CustomField(label: 'Security answer', value: 'Rex'),
    ],
  ),
  username: 'ann@example.com',
  password: 'p@ss wörd',
  url: 'https://bank.example.com',
  totp: 'JBSWY3DPEHPK3PXP',
);

final _password = PasswordSecret(
  info: _info('pw', 'Wi-Fi', expiresAt: DateTime.utc(2026, 11, 20)),
  password: 'c0rrect-h0rse',
);

final _key = PemSecret(
  info: _info('key', 'Server key', expiresAt: DateTime.utc(2026, 10, 1)),
  pem:
      '-----BEGIN PRIVATE KEY-----\nAAAA\nBBBB\nCCCC\nDDDD\n'
      '-----END PRIVATE KEY-----',
);

final _cert = PemSecret(
  info: _info('cert', 'Certificate'),
  pem: '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----',
);

final _codes = RecoveryCodesSecret(
  info: _info('codes', 'Mail codes'),
  codes: const [
    RecoveryCode('1111-2222', used: true),
    RecoveryCode('3333-4444'),
    RecoveryCode('5555-6666'),
    RecoveryCode('7777-8888'),
  ],
);

final _note = NoteSecret(info: _info('note', 'Safe'), text: '12-34-56');

void main() {
  late FakeStorageProvider storage;
  late ProviderContainer container;
  late List<String?> clipboard;
  const vault = VaultRef('s', 'personal.satchel');

  setUp(() {
    clipboard = [];
  });

  Future<void> pumpSecret(WidgetTester tester, Secret secret) async {
    tester.view
      ..physicalSize = const Size(800, 1600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            clipboard.add((call.arguments as Map)['text'] as String?);
          case 'Clipboard.getData':
            return {'text': clipboard.lastOrNull};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    storage = FakeStorageProvider(id: 's');
    await tester.runAsync(
      () => putVault(
        storage,
        vault.path,
        'hunter22',
        secrets: [_login, _password, _key, _cert, _codes, _note],
      ),
    );
    container = ProviderContainer(
      overrides: [
        ...storageOverrides(
          platform: StoragePlatform.linux,
          store: MemoryStorageConfigStore([directoryConfig('s', '/s')]),
        ),
        storageProvidersProvider.overrideWith((ref) async => [storage]),
        appClockProvider.overrideWithValue(Clock.fixed(_now)),
        secretClipboardProvider.overrideWithValue(
          SecretClipboard(clearAfter: const Duration(seconds: 2)),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(
      () => container
          .read(unlockedVaultsProvider.notifier)
          .unlock(vault, 'hunter22'),
    );
    container.read(currentLocationProvider.notifier)
      ..openFile('s', vault.path)
      ..openSecret(secret.id);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: testApp(
          Consumer(
            builder: (context, ref, _) {
              final id = ref.watch(currentLocationProvider).secretId;
              return id == null
                  ? const Scaffold(body: Text('closed'))
                  : SecretPane(
                      storageId: 's',
                      path: 'personal.satchel',
                      secretId: id,
                    );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder inTile(String key, Finder finder) =>
      find.descendant(of: find.byKey(Key(key)), matching: finder);

  Future<List<Secret>> stored(WidgetTester tester) async {
    final opened = await tester.runAsync(
      () => VaultCodec.decrypt(
        storage.blobs[vault.path]!.bytes,
        password: 'hunter22',
      ),
    );
    return opened!.payload.secrets;
  }

  group('login', () {
    testWidgets('keeps fields at most secretPaneMaxWidth wide', (tester) async {
      await pumpSecret(tester, _login);

      final field = tester.getRect(find.byKey(const Key('username')));
      expect(field.width, secretPaneMaxWidth);
      expect(field.left, 0, reason: 'aligned to the start');
    });

    testWidgets('shows every field, masking secret values', (tester) async {
      await pumpSecret(tester, _login);

      expect(find.text('Example Bank'), findsOneWidget);
      expect(find.text('Login'), findsOneWidget);
      expect(find.text('ann@example.com'), findsOneWidget);
      expect(find.text('https://bank.example.com'), findsOneWidget);
      expect(find.text('p@ss wörd'), findsNothing);
      expect(find.text('JBSWY3DPEHPK3PXP'), findsNothing);
      expect(inTile('password', find.text(maskedValue)), findsOneWidget);
      expect(inTile('totp', find.text(maskedValue)), findsOneWidget);
      expect(find.text('Shared with Ann.'), findsOneWidget);
      expect(find.text('12345'), findsOneWidget, reason: 'not concealed');
      expect(find.text('Rex'), findsNothing, reason: 'concealed');
      expect(find.text('finance'), findsOneWidget);
      expect(find.text('home'), findsOneWidget);
      expect(
        find.text(
          'Created Jan 15, 2026 ${_hm(DateTime.utc(2026, 1, 15, 9, 30))}',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Updated Mar 1, 2026'), findsOneWidget);
      expect(find.byKey(const Key('expiry')), findsNothing);
    });

    testWidgets('reveals and hides a value', (tester) async {
      await pumpSecret(tester, _login);

      await tester.tap(inTile('password', find.byTooltip('Show')));
      await tester.pump();
      expect(find.text('p@ss wörd'), findsOneWidget);

      await tester.tap(inTile('password', find.byTooltip('Hide')));
      await tester.pump();
      expect(find.text('p@ss wörd'), findsNothing);
    });

    testWidgets('copies a value and clears the clipboard later', (
      tester,
    ) async {
      await pumpSecret(tester, _login);

      await tester.tap(inTile('password', find.byTooltip('Copy')));
      await tester.pump();

      expect(clipboard, ['p@ss wörd']);
      expect(
        find.text('Password copied. The clipboard is cleared in 2 seconds.'),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 3));
      expect(clipboard, ['p@ss wörd', '']);
    });

    testWidgets('does not clear something copied elsewhere', (tester) async {
      await pumpSecret(tester, _login);

      await tester.tap(inTile('username', find.byTooltip('Copy')));
      await tester.pump();
      clipboard.add('copied by the user in another app');
      await tester.pump(const Duration(seconds: 3));

      expect(clipboard.last, 'copied by the user in another app');
    });

    testWidgets('offers to open web addresses only', (tester) async {
      await pumpSecret(tester, _login);

      expect(inTile('url', find.byTooltip('Open in browser')), findsOneWidget);
      expect(find.byTooltip('Open in browser'), findsOneWidget);
    });
  });

  testWidgets('a password shows its expiry status', (tester) async {
    await pumpSecret(tester, _password);

    expect(inTile('password', find.text(maskedValue)), findsOneWidget);
    final days = daysUntil(_password.expiresAt!, _now);
    expect(
      find.descendant(
        of: find.byKey(const Key('expiryBadge')),
        matching: find.text('Expires in $days days'),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('expiry'))).data,
      startsWith('Expires Nov 20, 2026'),
    );
  });

  group('PEM', () {
    testWidgets('a private key is masked until revealed', (tester) async {
      await pumpSecret(tester, _key);

      expect(find.text('Contains a private key'), findsOneWidget);
      expect(find.textContaining('BEGIN PRIVATE KEY'), findsNothing);
      final ago = -daysUntil(_key.expiresAt!, _now);
      expect(
        find.descendant(
          of: find.byKey(const Key('expiryBadge')),
          matching: find.text('Expired $ago days ago'),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('expiry'))).data,
        startsWith('Expired Oct 1, 2026'),
      );

      await tester.tap(inTile('pem', find.byTooltip('Show')));
      await tester.pump();
      final text = tester.widget<Text>(
        find.textContaining('BEGIN PRIVATE KEY'),
      );
      expect(text.maxLines, 4);

      await tester.tap(find.text('Show all'));
      await tester.pump();
      expect(
        tester.widget<Text>(find.textContaining('BEGIN PRIVATE KEY')).maxLines,
        isNull,
      );
    });

    testWidgets('a certificate is shown directly', (tester) async {
      await pumpSecret(tester, _cert);

      expect(find.textContaining('BEGIN CERTIFICATE'), findsOneWidget);
      expect(inTile('pem', find.byTooltip('Show')), findsNothing);
      expect(find.text('Show all'), findsNothing);
    });
  });

  group('recovery codes', () {
    testWidgets('shows a masked checklist with the codes left', (tester) async {
      await pumpSecret(tester, _codes);

      expect(find.text('3 codes left'), findsOneWidget);
      expect(find.textContaining('Few codes left'), findsNothing);
      expect(find.text('1111-2222'), findsNothing);
      expect(find.text(maskedValue), findsNWidgets(4));

      await tester.tap(inTile('recoveryCodes', find.byTooltip('Show')).first);
      await tester.pump();
      expect(find.text('3333-4444'), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(find.byKey(const Key('code0'))).value,
        isTrue,
      );
    });

    testWidgets('marking codes used saves and warns when few are left', (
      tester,
    ) async {
      await pumpSecret(tester, _codes);

      await tester.tap(find.byKey(const Key('code1')));
      await settleCrypto(tester, find.text('never shown'));

      expect(find.text('2 codes left'), findsOneWidget);
      expect(
        find.text('Few codes left. Generate new ones on the website soon.'),
        findsOneWidget,
      );
      final saved = (await stored(
        tester,
      )).singleWhere((s) => s.id == 'codes') as RecoveryCodesSecret;
      expect(saved.codes[1].used, isTrue);
      expect(saved.remaining, 2);
      expect(saved.updatedAt, _now);
      expect(saved.createdAt, _codes.createdAt);
    });
  });

  testWidgets('secrets that do not expire soon have no badge', (tester) async {
    await pumpSecret(tester, _login);

    expect(find.byKey(const Key('expiryBadge')), findsNothing);
  });

  testWidgets('a secure note is masked', (tester) async {
    await pumpSecret(tester, _note);

    expect(find.text('12-34-56'), findsNothing);
    await tester.tap(inTile('noteText', find.byTooltip('Show')));
    await tester.pump();
    expect(find.text('12-34-56'), findsOneWidget);
  });

  testWidgets('reveal states reset when another secret is shown', (
    tester,
  ) async {
    await pumpSecret(tester, _password);
    await tester.tap(inTile('password', find.byTooltip('Show')));
    await tester.pump();
    expect(find.text('c0rrect-h0rse'), findsOneWidget);

    container.read(currentLocationProvider.notifier).openSecret(_login.id);
    await tester.pumpAndSettle();
    container.read(currentLocationProvider.notifier).openSecret(_password.id);
    await tester.pumpAndSettle();

    expect(find.text('c0rrect-h0rse'), findsNothing);
  });

  group('edit', () {
    Future<void> openEditor(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
    }

    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settleCrypto(tester, find.byType(LinearProgressIndicator));
    }

    TextEditingController field(WidgetTester tester, String key) => tester
        .widget<TextFormField>(
          find.descendant(
            of: find.byType(SecretEditor),
            matching: find.byKey(Key(key)),
          ),
        )
        .controller!;

    testWidgets('opens the editor filled with the secret', (tester) async {
      await pumpSecret(tester, _login);

      await openEditor(tester);

      expect(find.text('Edit login'), findsOneWidget);
      expect(field(tester, 'title').text, 'Example Bank');
      expect(field(tester, 'username').text, 'ann@example.com');
      expect(field(tester, 'password').text, 'p@ss wörd');
      expect(field(tester, 'url').text, 'https://bank.example.com');
      expect(field(tester, 'totp').text, 'JBSWY3DPEHPK3PXP');
      expect(field(tester, 'tags').text, 'finance, home');
      expect(field(tester, 'notes').text, 'Shared with Ann.');
      expect(field(tester, 'fieldLabel1').text, 'Security answer');
      expect(field(tester, 'fieldValue1').text, 'Rex');
      expect(find.byKey(const Key('tags')), findsOneWidget, reason: 'expanded');
    });

    testWidgets('saves changes keeping the id and creation time', (
      tester,
    ) async {
      await pumpSecret(tester, _login);
      await openEditor(tester);

      await tester.enterText(
        find.descendant(
          of: find.byType(SecretEditor),
          matching: find.byKey(const Key('username')),
        ),
        'bob@example.com',
      );
      await save(tester);

      expect(find.byType(SecretEditor), findsNothing);
      expect(find.text('bob@example.com'), findsOneWidget);
      final saved = (await stored(tester)).first as LoginSecret;
      expect(saved.id, 'login');
      expect(saved.username, 'bob@example.com');
      expect(saved.password, 'p@ss wörd');
      expect(saved.customFields, _login.customFields);
      expect(saved.createdAt, _login.createdAt);
      expect(saved.updatedAt, _now);
      expect((await stored(tester)).map((s) => s.id), [
        'login',
        'pw',
        'key',
        'cert',
        'codes',
        'note',
      ]);
    });

    testWidgets('saving without changes writes nothing', (tester) async {
      await pumpSecret(tester, _login);
      final revision = storage.blobs[vault.path]!.revision;
      await openEditor(tester);

      await save(tester);

      expect(find.byType(SecretEditor), findsNothing);
      expect(storage.blobs[vault.path]!.revision, revision);
    });

    testWidgets('keeps the exact expiry unless the validity changes', (
      tester,
    ) async {
      await pumpSecret(tester, _password);
      await openEditor(tester);
      expect(field(tester, 'validDays').text, '18');
      await tester.enterText(
        find.descendant(
          of: find.byType(SecretEditor),
          matching: find.byKey(const Key('title')),
        ),
        'Home Wi-Fi',
      );
      await save(tester);

      var saved = (await stored(tester)).firstWhere((s) => s.id == 'pw');
      expect(saved.title, 'Home Wi-Fi');
      expect(saved.expiresAt, _password.expiresAt);

      await openEditor(tester);
      await tester.ensureVisible(find.text('90 days'));
      await tester.tap(find.text('90 days'));
      await tester.pump();
      await save(tester);

      saved = (await stored(tester)).firstWhere((s) => s.id == 'pw');
      expect(saved.expiresAt, _now.add(const Duration(days: 90)));
    });

    testWidgets('keeps the used state of recovery codes', (tester) async {
      await pumpSecret(tester, _codes);
      await openEditor(tester);
      expect(
        field(tester, 'codes').text,
        '1111-2222\n3333-4444\n5555-6666\n7777-8888',
      );

      await tester.enterText(
        find.descendant(
          of: find.byType(SecretEditor),
          matching: find.byKey(const Key('codes')),
        ),
        '1111-2222\n5555-6666\n9999-0000',
      );
      await save(tester);

      final saved = (await stored(
        tester,
      )).firstWhere((s) => s.id == 'codes') as RecoveryCodesSecret;
      expect(saved.codes, const [
        RecoveryCode('1111-2222', used: true),
        RecoveryCode('5555-6666'),
        RecoveryCode('9999-0000'),
      ]);
    });
  });

  group('delete', () {
    Future<void> tapDelete(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Delete secret'));
      await tester.pumpAndSettle();
    }

    testWidgets('asks for confirmation naming the secret and file', (
      tester,
    ) async {
      await pumpSecret(tester, _note);

      await tapDelete(tester);
      expect(find.text('Delete "Safe"?'), findsOneWidget);
      expect(
        find.text(
          'The secret will be permanently removed from "personal". '
          "This can't be undone.",
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await stored(tester)).map((s) => s.id), contains('note'));
    });

    testWidgets('removes the secret and closes it', (tester) async {
      await pumpSecret(tester, _note);

      await tapDelete(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(DestructiveDialog),
          matching: find.text('Delete'),
        ),
      );
      await settleCrypto(tester, find.text('never shown'));

      expect((await stored(tester)).map((s) => s.id), isNot(contains('note')));
      expect(container.read(currentLocationProvider).secretId, isNull);
      expect(find.text('closed'), findsOneWidget);
      expect(find.text('Deleted "Safe"'), findsOneWidget);
    });

    testWidgets('a file changed elsewhere keeps the secret', (tester) async {
      await pumpSecret(tester, _note);
      final current = storage.blobs[vault.path]!;
      storage.blobs[vault.path] = (bytes: current.bytes, revision: 'other');

      await tapDelete(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(DestructiveDialog),
          matching: find.text('Delete'),
        ),
      );
      await settleCrypto(tester, find.text('never shown'));

      expect(find.textContaining('was changed elsewhere'), findsOneWidget);
      expect(container.read(currentLocationProvider).secretId, 'note');
    });
  });

  testWidgets('a missing secret shows a message', (tester) async {
    await pumpSecret(tester, _note);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: testApp(
          const SecretPane(
            storageId: 's',
            path: 'personal.satchel',
            secretId: 'gone',
          ),
        ),
      ),
    );

    expect(find.text('This secret no longer exists'), findsOneWidget);
  });
}

String _hm(DateTime utc) {
  final local = utc.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}
