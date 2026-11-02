import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'google_account.dart';
import 'google_auth.dart';

final _userInfoUrl = Uri.https('www.googleapis.com', '/oauth2/v3/userinfo');

/// Looks up the account an access token belongs to. The token must include
/// the `email` and `profile` scopes.
Future<GoogleAccount> fetchGoogleAccount(
  http.Client client,
  String accessToken,
) async {
  final http.Response response;
  try {
    response = await client.get(
      _userInfoUrl,
      headers: {'Authorization': 'Bearer $accessToken'},
    );
  } on Exception {
    throw const GoogleAuthFailedException('Could not reach Google');
  }
  if (response.statusCode != 200) {
    throw GoogleAuthFailedException(
      'User info request failed (${response.statusCode})',
    );
  }
  final json = decodeJsonObject(response.body);
  if (json case {'sub': final String id, 'email': final String email}) {
    final name = json['name'];
    return GoogleAccount(
      id: id,
      email: email,
      displayName: name is String ? name : '',
    );
  }
  throw const GoogleAuthFailedException('Unexpected user info response');
}

/// Decodes a JSON object from a Google endpoint, or throws
/// [GoogleAuthFailedException] without echoing the body (it may hold tokens).
Map<String, Object?> decodeJsonObject(String body) {
  try {
    if (jsonDecode(body) case final Map<String, Object?> json) return json;
  } on FormatException {
    // Reported below.
  }
  throw const GoogleAuthFailedException('Unexpected response from Google');
}

/// [GoogleTokenStore] in the platform's secure storage (libsecret on Linux,
/// DPAPI-encrypted on Windows).
final class SecureGoogleTokenStore implements GoogleTokenStore {
  SecureGoogleTokenStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static String keyFor(String accountId) =>
      'satchel.google.refreshToken.$accountId';

  @override
  Future<String?> read(String accountId) =>
      _storage.read(key: keyFor(accountId));

  @override
  Future<void> write(String accountId, String refreshToken) =>
      _storage.write(key: keyFor(accountId), value: refreshToken);

  @override
  Future<void> delete(String accountId) =>
      _storage.delete(key: keyFor(accountId));
}
