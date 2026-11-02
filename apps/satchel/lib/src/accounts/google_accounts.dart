import 'dart:convert';
import 'dart:ui';

import 'package:flutter/widgets.dart' show basicLocaleListResolution;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:satchel_storage/satchel_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../storage/storage_providers.dart';
import 'google_account_store.dart';

part 'google_accounts.g.dart';

/// OAuth clients passed at build time, e.g. with
/// `--dart-define-from-file=google_oauth.json`.
const _environmentConfig = GoogleOAuthConfig(
  webClientId: String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'),
  desktopClientId: String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_ID'),
  desktopClientSecret: String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_SECRET'),
);

@Riverpod(keepAlive: true)
GoogleOAuthConfig googleOAuthConfig(Ref ref) => _environmentConfig;

/// Google sign-in for this platform, or `null` if this build has no OAuth
/// client for it.
@Riverpod(keepAlive: true)
GoogleAuth? googleAuth(Ref ref) {
  final platform = ref.watch(storagePlatformProvider);
  final config = ref.watch(googleOAuthConfigProvider);
  if (platform == null || !config.isConfiguredFor(platform)) return null;
  return createPlatformGoogleAuth(
    config: config,
    platform: platform,
    openBrowser: _openBrowser,
    loopbackPage: _loopbackPage,
  );
}

Future<void> _openBrowser(Uri url) async {
  if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
    throw const GoogleAuthFailedException('Could not open the browser');
  }
}

/// Page shown in the browser after a desktop sign-in, in the system language.
String _loopbackPage({required bool success}) {
  final l10n = lookupAppLocalizations(
    basicLocaleListResolution(
      PlatformDispatcher.instance.locales,
      AppLocalizations.supportedLocales,
    ),
  );
  final text = const HtmlEscape().convert(
    success ? l10n.googleBrowserSignInDone : l10n.googleBrowserSignInFailed,
  );
  final title = const HtmlEscape().convert(l10n.appTitle);
  return '<!doctype html><html><head><meta charset="utf-8">'
      '<title>$title</title></head>'
      '<body style="font-family:sans-serif;text-align:center;margin-top:4em">'
      '<p>$text</p></body></html>';
}

@Riverpod(keepAlive: true)
GoogleAccountStore googleAccountStore(Ref ref) =>
    SharedPreferencesGoogleAccountStore();

/// Result of [GoogleAccounts.add].
typedef LinkedGoogleAccount = ({GoogleAccount account, bool reconnected});

/// Google accounts linked to Satchel, in the order they were added. Several
/// can be linked at once. Holds identities only, so it is kept alive.
@Riverpod(keepAlive: true)
class GoogleAccounts extends _$GoogleAccounts {
  @override
  Future<List<GoogleAccount>> build() =>
      ref.watch(googleAccountStoreProvider).load();

  GoogleAuth get _auth =>
      ref.read(googleAuthProvider) ??
      (throw StateError('Google sign-in is not configured'));

  /// Lets the user sign in with a Google account and links it. Signing in
  /// with a linked account again renews its credentials ([reconnected]).
  ///
  /// Returns `null` if the user cancels. Throws `GoogleAuthException`s.
  Future<LinkedGoogleAccount?> add() async {
    final account = await _auth.signIn();
    if (account == null) return null;
    final store = ref.read(googleAccountStoreProvider);
    final saved = await store.load();
    final reconnected = saved.any((a) => a.id == account.id);
    final updated = [
      for (final a in saved) a.id == account.id ? account : a,
      if (!reconnected) account,
    ];
    await store.save(updated);
    state = AsyncData(updated);
    return (account: account, reconnected: reconnected);
  }

  /// Stops an [add] that waits for the user in the browser.
  void cancelAdd() => ref.read(googleAuthProvider)?.cancelSignIn();

  /// Unlinks account [id] and forgets its credentials on this device.
  Future<void> remove(String id) async {
    final store = ref.read(googleAccountStoreProvider);
    final saved = await store.load();
    final account = saved.where((a) => a.id == id).firstOrNull;
    if (account == null) return;
    await ref.read(googleAuthProvider)?.signOut(account);
    final remaining = [
      for (final a in saved)
        if (a.id != id) a,
    ];
    await store.save(remaining);
    state = AsyncData(remaining);
  }
}

/// Opens the Drive folders Satchel can see for an account. Signs in again
/// if needed, so use it from user actions.
@Riverpod(keepAlive: true)
DriveFolderSource Function(GoogleAccount account) driveFolderSource(Ref ref) {
  final auth = ref.watch(googleAuthProvider);
  return (account) => GoogleDriveFolderSource(
    GoogleDriveApi(GoogleDriveTokens(auth: auth, account: account)),
  );
}
