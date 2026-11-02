import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart'
    show
        AuthorizationRequestDetails,
        ClientAuthorizationTokensForScopesParameters,
        GoogleSignInPlatform;

import 'google_account.dart';
import 'google_auth.dart';

/// Google sign-in on Android through the official plugin (Credential Manager
/// and the Identity authorization API). Google Play services keep and renew
/// the tokens, so nothing is stored by Satchel.
final class GoogleSignInAuth implements GoogleAuth {
  GoogleSignInAuth({required this.serverClientId});

  /// The "Web application" client id, required by Credential Manager.
  final String serverClientId;

  static const _driveScopes = [googleDriveFileScope];

  Future<void>? _initialized;

  Future<void> _initialize() => _initialized ??= GoogleSignIn.instance
      .initialize(serverClientId: serverClientId)
      .catchError((Object error) {
        _initialized = null;
        throw _failure(error);
      });

  @override
  Future<GoogleAccount?> signIn() async {
    await _initialize();
    final GoogleSignInAccount user;
    try {
      user = await GoogleSignIn.instance.authenticate(scopeHint: _driveScopes);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      throw _failure(e);
    }
    try {
      await user.authorizationClient.authorizeScopes(_driveScopes);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw const GoogleDriveAccessDeniedException();
      }
      throw _failure(e);
    }
    return GoogleAccount(
      id: user.id,
      email: user.email,
      displayName: user.displayName ?? '',
    );
  }

  @override
  void cancelSignIn() {}

  @override
  Future<String> accessToken(
    GoogleAccount account, {
    bool interactive = false,
  }) async {
    await _initialize();
    try {
      // The app-facing API only targets the current user; the platform API
      // takes any account, which keeps several accounts usable at once.
      final tokens = await GoogleSignInPlatform.instance
          .clientAuthorizationTokensForScopes(
            ClientAuthorizationTokensForScopesParameters(
              request: AuthorizationRequestDetails(
                scopes: _driveScopes,
                userId: account.id,
                email: account.email,
                promptIfUnauthorized: interactive,
              ),
            ),
          );
      if (tokens == null) throw GoogleReauthRequiredException(account.email);
      return tokens.accessToken;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw const GoogleAuthCancelledException();
      }
      throw _failure(e);
    }
  }

  @override
  Future<void> invalidateToken(
    GoogleAccount account,
    String accessToken,
  ) async {
    await _initialize();
    await GoogleSignIn.instance.authorizationClient.clearAuthorizationToken(
      accessToken: accessToken,
    );
  }

  @override
  Future<void> signOut(GoogleAccount account) async {}

  static GoogleAuthFailedException _failure(Object error) =>
      GoogleAuthFailedException(switch (error) {
        GoogleSignInException(:final code) => code.name,
        _ => 'Google sign-in failed',
      });
}
