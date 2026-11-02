import 'dart:async';

import 'package:google_identity_services_web/loader.dart';
import 'package:google_identity_services_web/oauth2.dart';
import 'package:http/http.dart' as http;

import 'google_account.dart';
import 'google_auth.dart';
import 'google_oauth_common.dart';

/// Google sign-in on the web with the Google Identity Services token client.
///
/// Browsers get no refresh token: access tokens last about an hour and are
/// kept in memory only, so a new one needs a user action
/// ([GoogleAuth.accessToken] with `interactive`) once it expires.
final class GisGoogleAuth implements GoogleAuth {
  GisGoogleAuth({
    required this.clientId,
    http.Client? httpClient,
    DateTime Function()? now,
  }) : _http = httpClient ?? http.Client(),
       _now = now ?? DateTime.now {
    // Load early: the popup must open while the click still counts as a user
    // action.
    unawaited(_load().then((_) {}, onError: (_) {}));
  }

  final String clientId;
  final http.Client _http;
  final DateTime Function() _now;

  static const _expiryMargin = Duration(minutes: 1);

  final _accessTokens = <String, ({String token, DateTime expiresAt})>{};
  Future<void>? _sdk;

  Future<void> _load() => _sdk ??= loadWebSdk().catchError((Object error) {
    _sdk = null;
    throw const GoogleAuthFailedException('Could not load Google sign-in');
  });

  @override
  Future<GoogleAccount?> signIn() async {
    final token = await _requestToken(prompt: 'select_account');
    if (token == null) return null;
    final account = await fetchGoogleAccount(_http, token.token);
    _accessTokens[account.id] = token;
    return account;
  }

  @override
  void cancelSignIn() {}

  @override
  Future<String> accessToken(
    GoogleAccount account, {
    bool interactive = false,
  }) async {
    final cached = _accessTokens[account.id];
    if (cached != null && _now().isBefore(cached.expiresAt)) {
      return cached.token;
    }
    if (!interactive) throw GoogleReauthRequiredException(account.email);
    final token = await _requestToken(prompt: '', loginHint: account.email);
    if (token == null) throw const GoogleAuthCancelledException();
    final signedIn = await fetchGoogleAccount(_http, token.token);
    if (signedIn.id != account.id) {
      throw GoogleAccountMismatchException(account.email);
    }
    _accessTokens[account.id] = token;
    return token.token;
  }

  @override
  Future<void> invalidateToken(
    GoogleAccount account,
    String accessToken,
  ) async {
    if (_accessTokens[account.id]?.token == accessToken) {
      _accessTokens.remove(account.id);
    }
  }

  @override
  Future<void> signOut(GoogleAccount account) async {
    _accessTokens.remove(account.id);
  }

  /// Opens Google's popup. Returns `null` if the user closes it or denies.
  Future<({String token, DateTime expiresAt})?> _requestToken({
    required String prompt,
    String? loginHint,
  }) async {
    await _load();
    final response = Completer<TokenResponse?>();
    final client = oauth2.initTokenClient(
      TokenClientConfig(
        client_id: clientId,
        scope: [...googleIdentityScopes, googleDriveFileScope],
        prompt: prompt,
        login_hint: loginHint,
        include_granted_scopes: false,
        callback: (token) {
          if (!response.isCompleted) response.complete(token);
        },
        error_callback: (error) {
          if (response.isCompleted) return;
          switch (error?.type) {
            case GoogleIdentityServicesErrorType.popup_closed:
              response.complete(null);
            case final type:
              response.completeError(
                GoogleAuthFailedException(
                  'Google sign-in failed: ${type?.name ?? 'unknown'}',
                ),
              );
          }
        },
      ),
    );
    client.requestAccessToken();

    final token = await response.future;
    if (token == null) return null;
    if (token.error case final error?) {
      if (error == 'access_denied') return null;
      throw GoogleAuthFailedException('Authorization failed: $error');
    }
    final accessToken = token.access_token;
    if (accessToken == null) {
      throw const GoogleAuthFailedException('No access token');
    }
    if (!oauth2.hasGrantedAllScopes(token, [googleDriveFileScope])) {
      throw const GoogleDriveAccessDeniedException();
    }
    final expiresIn = Duration(seconds: token.expires_in ?? 0);
    return (
      token: accessToken,
      expiresAt: _now().add(expiresIn - _expiryMargin),
    );
  }
}
