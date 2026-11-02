@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:satchel_storage/satchel_storage.dart';
import 'package:satchel_storage/src/google/loopback_google_auth.dart';

final class MemoryTokenStore implements GoogleTokenStore {
  final tokens = <String, String>{};

  @override
  Future<String?> read(String accountId) async => tokens[accountId];

  @override
  Future<void> write(String accountId, String refreshToken) async =>
      tokens[accountId] = refreshToken;

  @override
  Future<void> delete(String accountId) async => tokens.remove(accountId);
}

const _ada = GoogleAccount(id: 'ada-id', email: 'ada@example.com');
const _scopes = 'openid email profile $googleDriveFileScope';

void main() {
  late MemoryTokenStore store;
  late DateTime now;
  late List<http.Request> requests;

  /// Responses of the fake Google token and user info endpoints.
  late Map<String, Object?> Function(http.Request request) tokenResponse;
  late int tokenStatus;
  late Map<String, Object?> userInfo;

  /// What the fake browser does with the authorization URL.
  late Future<void> Function(Uri url) browser;
  late List<Uri> opened;

  setUp(() {
    store = MemoryTokenStore();
    now = DateTime.utc(2026, 11, 2, 12);
    requests = [];
    tokenStatus = 200;
    tokenResponse = (_) => {
      'access_token': 'access-1',
      'expires_in': 3599,
      'refresh_token': 'refresh-1',
      'scope': _scopes,
      'token_type': 'Bearer',
    };
    userInfo = {'sub': 'ada-id', 'email': 'ada@example.com', 'name': 'Ada'};
    opened = [];
    browser = (url) => _redirect(url, {'code': 'the-code'});
  });

  LoopbackGoogleAuth createAuth({Duration? timeout}) => LoopbackGoogleAuth(
    clientId: 'client-id',
    clientSecret: 'client-secret',
    tokenStore: store,
    openBrowser: (url) async {
      opened.add(url);
      // Like a browser: the redirect arrives after the URL was opened.
      unawaited(browser(url));
    },
    responsePage: ({required success}) => success ? 'Signed in' : 'Failed',
    httpClient: MockClient((request) async {
      requests.add(request);
      if (request.url == LoopbackGoogleAuth.tokenEndpoint) {
        return http.Response(jsonEncode(tokenResponse(request)), tokenStatus);
      }
      if (request.url.path == '/oauth2/v3/userinfo') {
        return http.Response(jsonEncode(userInfo), 200);
      }
      return http.Response('', 404);
    }),
    now: () => now,
    timeout: timeout ?? const Duration(seconds: 10),
  );

  List<http.Request> tokenRequests() => [
    for (final request in requests)
      if (request.url == LoopbackGoogleAuth.tokenEndpoint) request,
  ];

  test('signs in through the browser with PKCE', () async {
    final auth = createAuth();

    final account = await auth.signIn();

    expect(
      account,
      const GoogleAccount(
        id: 'ada-id',
        email: 'ada@example.com',
        displayName: 'Ada',
      ),
    );
    final url = opened.single;
    expect(url.origin, 'https://accounts.google.com');
    final params = url.queryParameters;
    expect(params['client_id'], 'client-id');
    expect(params['response_type'], 'code');
    expect(params['scope']!.split(' '), contains(googleDriveFileScope));
    expect(params['access_type'], 'offline');
    expect(params['prompt'], 'select_account consent');
    expect(params['code_challenge_method'], 'S256');
    expect(params['redirect_uri'], startsWith('http://127.0.0.1:'));
    expect(params, isNot(contains('login_hint')));

    final exchange = tokenRequests().single.bodyFields;
    expect(exchange['grant_type'], 'authorization_code');
    expect(exchange['code'], 'the-code');
    expect(exchange['redirect_uri'], params['redirect_uri']);
    expect(exchange['client_id'], 'client-id');
    expect(exchange['client_secret'], 'client-secret');
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(exchange['code_verifier']!)).bytes)
        .replaceAll('=', '');
    expect(params['code_challenge'], challenge);

    expect(store.tokens, {'ada-id': 'refresh-1'});
    expect(await auth.accessToken(account!), 'access-1');
    expect(tokenRequests(), hasLength(1));
  });

  test('shows the result page in the browser', () async {
    late Future<String> page;
    browser = (url) async {
      page = _redirect(url, {'code': 'c'});
    };

    await createAuth().signIn();

    expect(await page, 'Signed in');
  });

  test('ignores requests without the right state', () async {
    browser = (url) async {
      final redirectUri = Uri.parse(url.queryParameters['redirect_uri']!);
      final wrong = await _get(
        redirectUri.replace(queryParameters: {'code': 'evil', 'state': 'x'}),
      );
      expect(wrong.status, HttpStatus.notFound);
      await _redirect(url, {'code': 'the-code'});
    };

    expect(await createAuth().signIn(), isNotNull);
    expect(tokenRequests().single.bodyFields['code'], 'the-code');
  });

  test('returns null when the user denies access', () async {
    browser = (url) => _redirect(url, {'error': 'access_denied'});

    expect(await createAuth().signIn(), isNull);
    expect(requests, isEmpty);
    expect(store.tokens, isEmpty);
  });

  test('throws when Drive access was not granted', () async {
    tokenResponse = (_) => {
      'access_token': 'a',
      'expires_in': 3599,
      'refresh_token': 'r',
      'scope': 'openid email profile',
    };

    await expectLater(
      createAuth().signIn(),
      throwsA(isA<GoogleDriveAccessDeniedException>()),
    );
    expect(store.tokens, isEmpty);
  });

  test('cancelSignIn stops waiting for the browser', () async {
    final browserOpened = Completer<void>();
    browser = (_) async => browserOpened.complete();
    final auth = createAuth();

    final signIn = auth.signIn();
    await browserOpened.future;
    auth.cancelSignIn();

    expect(await signIn, isNull);
    expect(store.tokens, isEmpty);
  });

  test('gives up after the timeout', () async {
    browser = (_) async {};

    expect(
      await createAuth(timeout: const Duration(milliseconds: 50)).signIn(),
      isNull,
    );
  });

  test('reports token endpoint errors without the response body', () async {
    tokenStatus = 500;
    tokenResponse = (_) => {'error': 'server_error', 'access_token': 'leak'};

    await expectLater(
      createAuth().signIn(),
      throwsA(
        isA<GoogleAuthFailedException>()
            .having((e) => e.message, 'message', contains('server_error'))
            .having((e) => e.toString(), 'toString', isNot(contains('leak'))),
      ),
    );
  });

  group('accessToken', () {
    test('refreshes an expired token with the stored refresh token', () async {
      final auth = createAuth();
      final account = (await auth.signIn())!;
      tokenResponse = (_) => {
        'access_token': 'access-2',
        'expires_in': 3599,
        'scope': _scopes,
      };

      now = now.add(const Duration(minutes: 59));
      expect(await auth.accessToken(account), 'access-2');

      final refresh = tokenRequests().last.bodyFields;
      expect(refresh['grant_type'], 'refresh_token');
      expect(refresh['refresh_token'], 'refresh-1');
      expect(refresh['client_secret'], 'client-secret');
      expect(store.tokens, {'ada-id': 'refresh-1'});
    });

    test('uses a refresh token kept from an earlier run', () async {
      store.tokens['ada-id'] = 'stored';
      tokenResponse = (_) => {'access_token': 'fresh', 'expires_in': 3599};

      expect(await createAuth().accessToken(_ada), 'fresh');
      expect(tokenRequests().single.bodyFields['refresh_token'], 'stored');
    });

    test('requires a new sign-in when the refresh token was revoked', () async {
      store.tokens['ada-id'] = 'revoked';
      tokenStatus = 400;
      tokenResponse = (_) => {'error': 'invalid_grant'};

      await expectLater(
        createAuth().accessToken(_ada),
        throwsA(
          isA<GoogleReauthRequiredException>().having(
            (e) => e.email,
            'email',
            'ada@example.com',
          ),
        ),
      );
      expect(store.tokens, isEmpty);
      expect(opened, isEmpty);
    });

    test('requires a new sign-in without a refresh token', () {
      expect(
        createAuth().accessToken(_ada),
        throwsA(isA<GoogleReauthRequiredException>()),
      );
    });

    test('signs the same account in again when interactive', () async {
      final token = await createAuth().accessToken(_ada, interactive: true);

      expect(token, 'access-1');
      expect(opened.single.queryParameters['login_hint'], 'ada@example.com');
      expect(opened.single.queryParameters['prompt'], 'consent');
      expect(store.tokens, {'ada-id': 'refresh-1'});
    });

    test('refuses another account when signing in again', () async {
      userInfo = {'sub': 'bob-id', 'email': 'bob@example.com'};

      await expectLater(
        createAuth().accessToken(_ada, interactive: true),
        throwsA(isA<GoogleAccountMismatchException>()),
      );
      expect(store.tokens, isEmpty);
    });

    test('throws when an interactive sign-in is cancelled', () async {
      browser = (url) => _redirect(url, {'error': 'access_denied'});

      await expectLater(
        createAuth().accessToken(_ada, interactive: true),
        throwsA(isA<GoogleAuthCancelledException>()),
      );
    });

    test('invalidateToken drops a rejected token', () async {
      final auth = createAuth();
      final account = (await auth.signIn())!;
      tokenResponse = (_) => {'access_token': 'access-2', 'expires_in': 3599};

      await auth.invalidateToken(account, 'other');
      expect(await auth.accessToken(account), 'access-1');
      await auth.invalidateToken(account, 'access-1');
      expect(await auth.accessToken(account), 'access-2');
    });
  });

  test('signOut forgets the tokens of the account', () async {
    final auth = createAuth();
    final account = (await auth.signIn())!;
    store.tokens['other'] = 'kept';

    await auth.signOut(account);

    expect(store.tokens, {'other': 'kept'});
    await expectLater(
      auth.accessToken(account),
      throwsA(isA<GoogleReauthRequiredException>()),
    );
  });
}

/// Follows Google's redirect back to the app with [params] and the request's
/// state. Returns the page the app answered with.
Future<String> _redirect(Uri authorizationUrl, Map<String, String> params) {
  final query = authorizationUrl.queryParameters;
  final redirectUri = Uri.parse(query['redirect_uri']!);
  return _get(
    redirectUri.replace(queryParameters: {...params, 'state': query['state']}),
  ).then((response) => response.body);
}

Future<({int status, String body})> _get(Uri url) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(url)).close();
    return (
      status: response.statusCode,
      body: await response.transform(utf8.decoder).join(),
    );
  } finally {
    client.close();
  }
}
