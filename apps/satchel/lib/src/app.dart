import 'package:flutter/material.dart';

import 'l10n/l10n.dart';
import 'navigation/app_shell.dart';

class SatchelApp extends StatelessWidget {
  const SatchelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (context) => context.l10n.appTitle,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(colorSchemeSeed: Colors.brown),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.brown,
        brightness: Brightness.dark,
      ),
      home: const AppShell(),
    );
  }
}
