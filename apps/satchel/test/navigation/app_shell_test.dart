import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/files/files_pane.dart';
import 'package:satchel/src/navigation/app_location.dart';
import 'package:satchel/src/navigation/app_shell.dart';
import 'package:satchel/src/secrets/secret_pane.dart';
import 'package:satchel/src/secrets/secrets_pane.dart';
import 'package:satchel/src/storage/storage_providers.dart';
import 'package:satchel/src/storage/storages_pane.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../fakes.dart';
import '../test_app.dart';

void main() {
  late ProviderContainer container;

  Future<void> pumpShell(WidgetTester tester, double width) async {
    tester.view
      ..physicalSize = Size(width, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      overrides: [
        ...storageOverrides(
          platform: StoragePlatform.linux,
          store: MemoryStorageConfigStore([
            directoryConfig('s', '/s', name: 'Personal'),
          ]),
        ),
        storageProvidersProvider.overrideWith(
          (ref) async => [
            FakeStorageProvider(
              id: 's',
              displayName: 'Personal',
              paths: ['bank.satchel'],
            ),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: testApp(const AppShell()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.widgetWithText(ListTile, text));
    await tester.pumpAndSettle();
  }

  /// Types of the visible panes, left to right.
  List<Type> panes(WidgetTester tester) {
    final row = tester.widget<Row>(
      find
          .descendant(of: find.byType(AppShell), matching: find.byType(Row))
          .first,
    );
    return [
      for (final child in row.children)
        if (child is! VerticalDivider)
          switch (child) {
            SizedBox(:final child?) ||
            Expanded(:final child) => child.runtimeType,
            _ => child.runtimeType,
          },
    ];
  }

  group('compact window', () {
    testWidgets('shows one level at a time', (tester) async {
      await pumpShell(tester, 400);
      expect(panes(tester), [StoragesPane]);

      await tapText(tester, 'Personal');
      expect(panes(tester), [FilesPane]);
      expect(find.byType(BackButton), findsOneWidget);

      await tapText(tester, 'bank');
      expect(panes(tester), [SecretsPane]);
      expect(
        find.text('This file is locked. Enter its password to open it.'),
        findsOneWidget,
      );
    });

    testWidgets('back buttons go up one level', (tester) async {
      await pumpShell(tester, 400);
      await tapText(tester, 'Personal');
      await tapText(tester, 'bank');

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(panes(tester), [FilesPane]);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(panes(tester), [StoragesPane]);
    });

    testWidgets('system back goes up one level', (tester) async {
      await pumpShell(tester, 400);
      await tapText(tester, 'Personal');

      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(handled, isTrue);
      expect(panes(tester), [StoragesPane]);
    });
  });

  group('medium window', () {
    testWidgets('shows the current level and the next one', (tester) async {
      await pumpShell(tester, 700);
      expect(panes(tester).first, StoragesPane);
      expect(find.text('Select a storage'), findsOneWidget);

      await tapText(tester, 'Personal');
      expect(panes(tester).first, FilesPane);
      expect(find.text('Select a vault file'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
    });
  });

  group('expanded window', () {
    testWidgets('hides the storages once a file is open', (tester) async {
      await pumpShell(tester, 1000);
      await tapText(tester, 'Personal');
      expect(panes(tester).take(2), [StoragesPane, FilesPane]);
      expect(find.byType(BackButton), findsNothing);

      await tapText(tester, 'bank');
      expect(panes(tester).take(2), [FilesPane, SecretsPane]);
      expect(find.text('Select a secret'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(panes(tester).take(2), [StoragesPane, FilesPane]);
    });
  });

  group('large window', () {
    testWidgets('shows every level side by side', (tester) async {
      await pumpShell(tester, 1400);
      await tapText(tester, 'Personal');
      await tapText(tester, 'bank');

      expect(panes(tester).take(3), [StoragesPane, FilesPane, SecretsPane]);
      expect(find.text('Select a secret'), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      bool selected(String text) =>
          tester.widget<ListTile>(find.widgetWithText(ListTile, text)).selected;
      expect(selected('Personal'), isTrue);
      expect(selected('bank'), isTrue);

      container.read(currentLocationProvider.notifier).openSecret('x');
      await tester.pumpAndSettle();
      expect(panes(tester), [StoragesPane, FilesPane, SecretsPane, SecretPane]);
    });

    testWidgets('every pane gets an equal, fixed share', (tester) async {
      await pumpShell(tester, 1920);
      double width(Type pane) => tester.getSize(find.byType(pane)).width;
      const quarter = (1920 - 3) / 4;

      // Only storages and the files placeholder: the placeholder fills the rest.
      expect(width(StoragesPane), moreOrLessEquals(quarter));
      expect(
        tester.getCenter(find.text('Select a storage')).dx,
        moreOrLessEquals((quarter + 1 + 1920) / 2, epsilon: 1),
      );

      await tapText(tester, 'Personal');
      await tapText(tester, 'bank');
      container.read(currentLocationProvider.notifier).openSecret('x');
      await tester.pumpAndSettle();

      expect(width(StoragesPane), moreOrLessEquals(quarter));
      expect(width(FilesPane), moreOrLessEquals(quarter));
      expect(width(SecretsPane), moreOrLessEquals(quarter));
      expect(width(SecretPane), moreOrLessEquals(quarter));
    });
  });

  testWidgets('resizing keeps what is open', (tester) async {
    await pumpShell(tester, 1400);
    await tapText(tester, 'Personal');
    await tapText(tester, 'bank');

    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpAndSettle();
    expect(panes(tester), [SecretsPane]);

    tester.view.physicalSize = const Size(1400, 800);
    await tester.pumpAndSettle();
    expect(panes(tester).take(3), [StoragesPane, FilesPane, SecretsPane]);
  });
}
