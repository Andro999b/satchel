import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/app.dart';
import 'package:satchel/src/l10n/l10n.dart';

/// A [MaterialApp] with the app's theme and localizations around [home].
Widget testApp(Widget home) => MaterialApp(
  theme: satchelTheme(Brightness.light),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

/// Lets real (async) crypto run inside a widget test: alternates real async
/// work and frames until [busy] disappears, then settles.
Future<void> settleCrypto(WidgetTester tester, Finder busy) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
    if (busy.evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}
