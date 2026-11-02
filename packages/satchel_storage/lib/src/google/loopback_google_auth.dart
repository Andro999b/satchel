import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'google_account.dart';
import 'google_auth.dart';
import 'google_oauth_common.dart';

typedef _Tokens = ({
  String accessToken,
  Duration expiresIn,
  String? refreshToken,
  Set<String> scopes,
});

/// Google sign-in for Linux and Windows: the OAuth installed-app flow in the
/// user's browser, with a loopback redirect and PKCE (RFC 8252).
///
/// Refresh tokens are kept in the [GoogleTokenStore], access tokens only in
/// memory.
final class LoopbackGoogleAuth implements GoogleAuth {
  LoopbackGoogleAuth({
    required this.clientId,
    required this.clientSecret,
    required this._tokenStore,
    required this._openBrowser,
    required this._responsePage,
    http.Client? httpClient,
    DateTime Function()? now,
    this.timeout = const Duration(minutes: 5),
  }) : _http = httpClient ?? http.Client(),
       _now = now ?? DateTime.now;

  static final authorizationEndpoint = Uri.https(
    'accounts.google.com',
    '/o/oauth2/v2/auth',
  );
  static final tokenEndpoint = Uri.https('oauth2.googleapis.com', '/token');

  /// Access tokens are renewed this long before they expire.
  static const expiryMargin = Duration(minutes: 1);

  final String clientId;
  final String clientSecret;

  /// How long to wait for the user to finish in the browser.
  final Duration timeout;

  final GoogleTokenStore _tokenStore;
  final Future<void> Function(Uri url) _openBrowser;
  final String Function({required bool success}) _responsePage;
  final http.Client _http;
  final DateTime Function() _now;

  final _accessTokens = <String, ({String token, DateTime expiresAt})>{};
  void Function()? _cancel;

  @override
  Future<GoogleAccount?> signIn() async {
    final result = await _authorize(prompt: 'select_account consent');
    if (result == null) return null;
    await _tokenStore.write(result.account.id, result.refreshToken);
    _cache(result.account.id, result.tokens);
    return result.account;
  }

  @override
  void cancelSignIn() => _cancel?.call();

  @override
  Future<String> accessToken(
    GoogleAccount account, {
    bool interactive = false,
  }) async {
    final cached = _accessTokens[account.id];
    if (cached != null && _now().isBefore(cached.expiresAt)) {
      return cached.token;
    }
    final refreshToken = await _tokenStore.read(account.id);
    if (refreshToken != null) {
      try {
        final tokens = await _requestTokens({
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
        });
        if (tokens.refreshToken case final rotated?) {
          await _tokenStore.write(account.id, rotated);
        }
        return _cache(account.id, tokens);
      } on _InvalidGrant {
        // Revoked or expired: forget it and sign in again.
        await _tokenStore.delete(account.id);
      }
    }
    if (!interactive) throw GoogleReauthRequiredException(account.email);

    final result = await _authorize(
      prompt: 'consent',
      loginHint: account.email,
    );
    if (result == null) throw const GoogleAuthCancelledException();
    if (result.account.id != account.id) {
      throw GoogleAccountMismatchException(account.email);
    }
    await _tokenStore.write(account.id, result.refreshToken);
    return _cache(account.id, result.tokens);
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
    await _tokenStore.delete(account.id);
  }

  String _cache(String accountId, _Tokens tokens) {
    _accessTokens[accountId] = (
      token: tokens.accessToken,
      expiresAt: _now().add(tokens.expiresIn - expiryMargin),
    );
    return tokens.accessToken;
  }

  /// Runs the browser flow. Returns `null` if the user cancels, denies, or
  /// doesn't finish within [timeout].
  Future<({GoogleAccount account, String refreshToken, _Tokens tokens})?>
  _authorize({required String prompt, String? loginHint}) async {
    cancelSignIn();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = Completer<Map<String, String>?>();
    void cancel() {
      if (!redirect.isCompleted) redirect.complete(null);
    }

    _cancel = cancel;
    final timer = Timer(timeout, cancel);
    try {
      final redirectUri = 'http://${server.address.address}:${server.port}';
      final verifier = _randomToken(32);
      final state = _randomToken(16);
      unawaited(
        _awaitRedirect(server, state).then(
          (params) {
            if (!redirect.isCompleted) redirect.complete(params);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!redirect.isCompleted) {
              redirect.completeError(error, stackTrace);
            }
          },
        ),
      );
      await _openBrowser(
        authorizationEndpoint.replace(
          queryParameters: {
            'client_id': clientId,
            'redirect_uri': redirectUri,
            'response_type': 'code',
            'scope': [...googleIdentityScopes, googleDriveFileScope].join(' '),
            'code_challenge': _challenge(verifier),
            'code_challenge_method': 'S256',
            'state': state,
            // A refresh token for this device, also when consented before.
            'access_type': 'offline',
            'prompt': prompt,
            'login_hint': ?loginHint,
          },
        ),
      );

      final params = await redirect.future;
      if (params == null) return null;
      if (params['error'] case final error?) {
        if (error == 'access_denied') return null;
        throw GoogleAuthFailedException('Authorization failed: $error');
      }
      final code = params['code'];
      if (code == null) {
        throw const GoogleAuthFailedException('No authorization code');
      }
      final tokens = await _requestTokens({
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirectUri,
        'code_verifier': verifier,
      });
      if (!tokens.scopes.contains(googleDriveFileScope)) {
        throw const GoogleDriveAccessDeniedException();
      }
      final refreshToken = tokens.refreshToken;
      if (refreshToken == null) {
        throw const GoogleAuthFailedException('No refresh token');
      }
      final account = await fetchGoogleAccount(_http, tokens.accessToken);
      return (account: account, refreshToken: refreshToken, tokens: tokens);
    } finally {
      timer.cancel();
      if (_cancel == cancel) _cancel = null;
      await server.close(force: true);
    }
  }

  /// Answers requests to the loopback server until Google redirects back
  /// with [state], and returns that redirect's query parameters.
  Future<Map<String, String>> _awaitRedirect(
    HttpServer server,
    String state,
  ) async {
    await for (final request in server) {
      final params = request.uri.queryParameters;
      final matches =
          request.method == 'GET' &&
          request.uri.path == '/' &&
          params['state'] == state;
      final response = request.response;
      try {
        if (matches) {
          response.headers
            ..contentType = ContentType.html
            ..set(HttpHeaders.cacheControlHeader, 'no-store');
          response.write(_responsePage(success: params.containsKey('code')));
        } else {
          response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      } on IOException {
        // The browser went away; the redirect parameters still count.
      }
      if (matches) return params;
    }
    throw const GoogleAuthFailedException('Sign-in was interrupted');
  }

  Future<_Tokens> _requestTokens(Map<String, String> body) async {
    final http.Response response;
    try {
      response = await _http.post(
        tokenEndpoint,
        body: {...body, 'client_id': clientId, 'client_secret': clientSecret},
      );
    } on Exception {
      throw const GoogleAuthFailedException('Could not reach Google');
    }
    final json = decodeJsonObject(response.body);
    if (response.statusCode != 200) {
      final error = json['error'];
      if (error == 'invalid_grant') throw const _InvalidGrant();
      throw GoogleAuthFailedException(
        'Token request failed: ${error is String ? error : response.statusCode}',
      );
    }
    if (json case {
      'access_token': final String accessToken,
      'expires_in': final num expiresIn,
    }) {
      final refreshToken = json['refresh_token'];
      final scope = json['scope'];
      return (
        accessToken: accessToken,
        expiresIn: Duration(seconds: expiresIn.toInt()),
        refreshToken: refreshToken is String ? refreshToken : null,
        scopes: scope is String ? scope.split(' ').toSet() : const <String>{},
      );
    }
    throw const GoogleAuthFailedException('Unexpected token response');
  }

  static final _random = Random.secure();

  /// URL-safe random string (RFC 7636 code verifier, OAuth state).
  static String _randomToken(int bytes) =>
      _base64Url([for (var i = 0; i < bytes; i++) _random.nextInt(256)]);

  static String _challenge(String verifier) =>
      _base64Url(sha256.convert(ascii.encode(verifier)).bytes);

  static String _base64Url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}

/// The refresh token is no longer valid.
final class _InvalidGrant implements Exception {
  const _InvalidGrant();
}
