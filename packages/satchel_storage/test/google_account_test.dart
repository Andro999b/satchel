import 'package:flutter_test/flutter_test.dart';
import 'package:satchel_storage/satchel_storage.dart';

void main() {
  group('GoogleAccount', () {
    test('round-trips through JSON', () {
      const account = GoogleAccount(
        id: '123',
        email: 'ada@example.com',
        displayName: 'Ada',
      );

      expect(GoogleAccount.fromJson(account.toJson()), account);
      expect(
        GoogleAccount.fromJson(const {'id': '1', 'email': 'a@b.c'}),
        const GoogleAccount(id: '1', email: 'a@b.c'),
      );
    });

    test('omits an empty name', () {
      expect(const GoogleAccount(id: '1', email: 'a@b.c').toJson(), {
        'id': '1',
        'email': 'a@b.c',
      });
    });

    test('rejects malformed JSON', () {
      for (final json in <Map<String, Object?>>[
        {},
        {'id': '1'},
        {'id': 1, 'email': 'a@b.c'},
        {'id': '1', 'email': 'a@b.c', 'displayName': 3},
      ]) {
        expect(
          () => GoogleAccount.fromJson(json),
          throwsFormatException,
          reason: '$json',
        );
      }
    });
  });

  group('GoogleOAuthConfig', () {
    test('web and Android need the web client id', () {
      const config = GoogleOAuthConfig(webClientId: 'web');

      expect(config.isConfiguredFor(StoragePlatform.web), isTrue);
      expect(config.isConfiguredFor(StoragePlatform.android), isTrue);
      expect(config.isConfiguredFor(StoragePlatform.linux), isFalse);
      expect(config.isConfiguredFor(StoragePlatform.windows), isFalse);
      expect(config.isConfiguredFor(null), isFalse);
    });

    test('desktop needs the desktop client id and secret', () {
      const idOnly = GoogleOAuthConfig(desktopClientId: 'desktop');
      const full = GoogleOAuthConfig(
        desktopClientId: 'desktop',
        desktopClientSecret: 'secret',
      );

      expect(idOnly.isConfiguredFor(StoragePlatform.linux), isFalse);
      expect(full.isConfiguredFor(StoragePlatform.linux), isTrue);
      expect(full.isConfiguredFor(StoragePlatform.windows), isTrue);
      expect(full.isConfiguredFor(StoragePlatform.web), isFalse);
    });

    test('toString leaves out the client secret', () {
      const config = GoogleOAuthConfig(
        desktopClientId: 'desktop',
        desktopClientSecret: 'secret',
      );

      expect(config.toString(), isNot(contains('secret')));
    });
  });
}
