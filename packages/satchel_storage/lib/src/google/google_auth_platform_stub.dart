import '../storage_provider_kind.dart';
import 'google_auth.dart';

/// Google sign-in for [platform], configured by [config].
///
/// [openBrowser] opens a URL in the user's browser and [loopbackPage] is the
/// page shown there once a desktop sign-in finished. Check
/// `config.isConfiguredFor(platform)` first.
GoogleAuth createPlatformGoogleAuth({
  required GoogleOAuthConfig config,
  required StoragePlatform platform,
  required Future<void> Function(Uri url) openBrowser,
  required String Function({required bool success}) loopbackPage,
}) => throw UnsupportedError('Google sign-in is not available here');
