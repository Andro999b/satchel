import '../storage_provider_kind.dart';
import 'gis_google_auth.dart';
import 'google_auth.dart';

GoogleAuth createPlatformGoogleAuth({
  required GoogleOAuthConfig config,
  required StoragePlatform platform,
  required Future<void> Function(Uri url) openBrowser,
  required String Function({required bool success}) loopbackPage,
}) => GisGoogleAuth(clientId: config.webClientId);
