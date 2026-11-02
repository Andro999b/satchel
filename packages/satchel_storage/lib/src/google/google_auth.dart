import 'package:flutter/foundation.dart';

import '../storage_provider_kind.dart';
import 'google_account.dart';

/// Scope that lets Satchel see and manage only the Drive files it created.
const googleDriveFileScope = 'https://www.googleapis.com/auth/drive.file';

/// Scopes used to identify the account being linked.
const googleIdentityScopes = ['openid', 'email', 'profile'];

/// OAuth client ids from the Google Cloud project. Client ids are public;
/// [desktopClientSecret] belongs to a "Desktop app" client, which Google does
/// not treat as confidential. Never put a web client's secret here.
@immutable
final class GoogleOAuthConfig {
  const GoogleOAuthConfig({
    this.webClientId = '',
    this.desktopClientId = '',
    this.desktopClientSecret = '',
  });

  /// "Web application" client: used by the web app, and on Android as the
  /// server client id.
  final String webClientId;

  /// "Desktop app" client, used by Linux and Windows.
  final String desktopClientId;
  final String desktopClientSecret;

  /// Whether Google sign-in can be used on [platform] with this config.
  bool isConfiguredFor(StoragePlatform? platform) => switch (platform) {
    StoragePlatform.web || StoragePlatform.android => webClientId.isNotEmpty,
    StoragePlatform.linux || StoragePlatform.windows =>
      desktopClientId.isNotEmpty && desktopClientSecret.isNotEmpty,
    null => false,
  };

  @override
  String toString() => 'GoogleOAuthConfig($webClientId, $desktopClientId)';
}

/// Google sign-in for one platform. Several accounts can be linked at once;
/// each gets its own Drive access tokens.
abstract interface class GoogleAuth {
  /// Lets the user choose a Google account and grant Satchel access to the
  /// Drive files it creates. Shows UI, so call it from a user action.
  ///
  /// Returns `null` if the user cancels. Throws
  /// [GoogleDriveAccessDeniedException] if Drive access wasn't granted.
  Future<GoogleAccount?> signIn();

  /// Cancels a [signIn] that waits for the user in an external browser; it
  /// then returns `null`. Does nothing elsewhere.
  void cancelSignIn();

  /// A Drive access token for [account].
  ///
  /// Without [interactive] this never shows UI and throws
  /// [GoogleReauthRequiredException] when the user has to sign in again. With
  /// it, it may show UI (call it from a user action) and throws
  /// [GoogleAuthCancelledException] if the user cancels.
  Future<String> accessToken(GoogleAccount account, {bool interactive = false});

  /// Drops [accessToken] of [account] from caches, e.g. after Drive rejected
  /// it, so the next [accessToken] gets a fresh one.
  Future<void> invalidateToken(GoogleAccount account, String accessToken);

  /// Forgets the credentials kept for [account] on this device. Satchel's
  /// access isn't revoked, because that would also sign out its other
  /// devices; users can revoke it in their Google Account settings.
  Future<void> signOut(GoogleAccount account);
}

/// Keeps desktop refresh tokens in the platform's secure storage.
abstract interface class GoogleTokenStore {
  Future<String?> read(String accountId);

  Future<void> write(String accountId, String refreshToken);

  Future<void> delete(String accountId);
}

/// Google sign-in failures. Messages never contain tokens.
sealed class GoogleAuthException implements Exception {
  const GoogleAuthException();
}

/// The account has to sign in again (e.g. access was revoked or, on web, the
/// session expired).
final class GoogleReauthRequiredException extends GoogleAuthException {
  const GoogleReauthRequiredException(this.email);

  final String email;

  @override
  String toString() => 'GoogleReauthRequiredException: $email';
}

/// The user cancelled an interactive sign-in.
final class GoogleAuthCancelledException extends GoogleAuthException {
  const GoogleAuthCancelledException();

  @override
  String toString() => 'GoogleAuthCancelledException';
}

/// The user signed in but didn't grant access to Drive.
final class GoogleDriveAccessDeniedException extends GoogleAuthException {
  const GoogleDriveAccessDeniedException();

  @override
  String toString() => 'GoogleDriveAccessDeniedException';
}

/// The user signed in again with another account than the one requested.
final class GoogleAccountMismatchException extends GoogleAuthException {
  const GoogleAccountMismatchException(this.expectedEmail);

  final String expectedEmail;

  @override
  String toString() => 'GoogleAccountMismatchException: $expectedEmail';
}

/// Sign-in failed: network, configuration or an unexpected response.
final class GoogleAuthFailedException extends GoogleAuthException {
  const GoogleAuthFailedException(this.message);

  /// Error code or description. Never contains tokens.
  final String message;

  @override
  String toString() => 'GoogleAuthFailedException: $message';
}
