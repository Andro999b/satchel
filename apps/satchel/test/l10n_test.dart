import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/app.dart';
import 'package:satchel/src/l10n/l10n.dart';
import 'package:satchel/src/storage/storage_display.dart';
import 'package:satchel_storage/satchel_storage.dart';

import 'fakes.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  testWidgets('the app is set up for its supported locales', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: storageOverrides(
          platform: StoragePlatform.web,
          store: MemoryStorageConfigStore(),
        ),
        child: const SatchelApp(),
      ),
    );
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.supportedLocales, [const Locale('en')]);
    expect(
      app.localizationsDelegates,
      containsAll(AppLocalizations.localizationsDelegates),
    );
    expect(find.text('Satchel'), findsOneWidget);
    final context = tester.element(find.text('Satchel'));
    expect(app.onGenerateTitle!(context), 'Satchel');
    expect(MaterialLocalizations.of(context).okButtonLabel, 'OK');
  });

  test('plural messages', () {
    expect(l10n.passwordTooShort(1), 'Use at least 1 character');
    expect(l10n.passwordTooShort(8), 'Use at least 8 characters');
    expect(l10n.vaultNameTooLong(100), 'Use at most 100 characters');
    expect(
      l10n.passwordHelper(8),
      'At least 8 characters. It cannot be recovered if lost.',
    );
  });

  test('placeholders are inserted verbatim', () {
    expect(l10n.removeStorageTitle('Sync'), 'Remove "Sync"?');
    expect(
      l10n.vaultNameInvalidCharacter(r'< > : " / \ | ? *'),
      r'''Can't contain < > : " / \ | ? *''',
    );
  });

  test('built-in storages use the localized kind name', () {
    const browser = StorageConfig(
      id: 'browser',
      kind: StorageProviderKind.indexedDb,
      displayName: 'stored name',
    );

    expect(storageName(l10n, browser), 'This browser');
    expect(
      storageName(l10n, directoryConfig('a', '/a', name: 'My vaults')),
      'My vaults',
    );
    expect(
      StorageProviderKind.values.map((kind) => storageKindName(l10n, kind)),
      ['This browser', 'Folder', 'Google Drive'],
    );
  });
}
