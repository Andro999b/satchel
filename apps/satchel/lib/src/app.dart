import 'package:flutter/material.dart';

import 'l10n/l10n.dart';
import 'navigation/app_shell.dart';
import 'vault/auto_lock.dart';

class SatchelApp extends StatelessWidget {
  const SatchelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (context) => context.l10n.appTitle,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: satchelTheme(Brightness.light),
      darkTheme: satchelTheme(Brightness.dark),
      home: const AppShell(),
      builder: (context, child) => AutoLock(child: child!),
    );
  }
}

ThemeData satchelTheme(Brightness brightness) => ThemeData(
  colorSchemeSeed: Colors.brown,
  brightness: brightness,
  // The same 16 on both sides, so app bar actions line up with the list
  // tiles' trailing buttons.
  appBarTheme: const AppBarTheme(
    titleSpacing: 16,
    actionsPadding: EdgeInsetsDirectional.only(end: 16),
  ),
  listTileTheme: const ListTileThemeData(
    contentPadding: EdgeInsets.symmetric(horizontal: 16),
  ),
);
