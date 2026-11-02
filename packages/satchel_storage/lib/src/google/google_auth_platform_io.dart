import '../storage_provider_kind.dart';
import 'google_auth.dart';
import 'google_oauth_common.dart';
import 'google_sign_in_auth.dart';
import 'loopback_google_auth.dart';

GoogleAuth createPlatformGoogleAuth({
  required GoogleOAuthConfig config,
  required StoragePlatform platform,
  required Future<void> Function(Uri url) openBrowser,
  required String Function({required bool success}) loopbackPage,
}) => switch (platform) {
  StoragePlatform.android => GoogleSignInAuth(
    serverClientId: config.webClientId,
  ),
  StoragePlatform.linux || StoragePlatform.windows => LoopbackGoogleAuth(
    clientId: config.desktopClientId,
    clientSecret: config.desktopClientSecret,
    tokenStore: SecureGoogleTokenStore(),
    openBrowser: openBrowser,
    responsePage: loopbackPage,
  ),
  StoragePlatform.web => throw UnsupportedError('Not running on the web'),
};
