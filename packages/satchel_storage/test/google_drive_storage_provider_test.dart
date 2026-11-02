import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:satchel_storage/satchel_storage.dart';

import 'fake_google_drive.dart';
import 'storage_provider_contract.dart';

const _account = GoogleAccount(id: 'ada', email: 'ada@example.com');

void main() {
  late FakeGoogleDrive drive;
  late FakeTokenAuth auth;
  late String folderId;

  setUp(() {
    drive = FakeGoogleDrive();
    auth = FakeTokenAuth();
    folderId = drive.addFolder('Satchel').id;
  });

  GoogleDriveApi api({GoogleAuth? googleAuth, GoogleAccount? account}) =>
      GoogleDriveApi(
        GoogleDriveTokens(
          auth: googleAuth ?? auth,
          account: account ?? _account,
        ),
        httpClient: drive.client,
      );

  GoogleDriveStorageProvider provider({String? folder}) =>
      GoogleDriveStorageProvider(
        id: 'drive',
        displayName: 'Drive',
        folderId: folder ?? folderId,
        api: api(),
      );

  Uint8List bytes(List<int> values) => Uint8List.fromList(values);

  group('contract', () {
    storageProviderContractTests(() {
      drive = FakeGoogleDrive();
      auth = FakeTokenAuth();
      folderId = drive.addFolder('Satchel').id;
      return provider();
    });
  });

  test('stores vault files in the folder', () async {
    final entry = await provider().write(
      'a.satchel',
      bytes([1, 2]),
      expectedRevision: null,
    );

    final file = drive.filesIn(folderId).single;
    expect(file.name, 'a.satchel');
    expect(file.bytes, [1, 2]);
    expect(entry.revision, '${file.id}:${md5.convert([1, 2])}');
  });

  test('lists only valid vault files directly in the folder', () async {
    drive
      ..addFile('a.satchel', parent: folderId)
      ..addFile('notes.txt', parent: folderId)
      ..addFile('.hidden.satchel', parent: folderId)
      ..addFile('b.satchel', parent: driveRootFolderId)
      ..addFolder('c.satchel', parent: folderId)
      ..addFile('d.satchel', parent: folderId).trashed = true;

    final entries = await provider().list();

    expect(entries.map((e) => e.path), ['a.satchel']);
  });

  test('uses the oldest of files sharing a name', () async {
    final oldest = drive.addFile('a.satchel', parent: folderId, bytes: [1]);
    drive.addFile('a.satchel', parent: folderId, bytes: [2]);
    final storage = provider();

    expect(
      (await storage.list()).single.revision,
      '${oldest.id}:${md5.convert([1])}',
    );
    expect((await storage.read('a.satchel')).bytes, [1]);
  });

  test('updates keep the Drive file', () async {
    final storage = provider();
    final first = await storage.write(
      'a.satchel',
      bytes([1]),
      expectedRevision: null,
    );
    final second = await storage.write(
      'a.satchel',
      bytes([2]),
      expectedRevision: first.revision,
    );

    final file = drive.filesIn(folderId).single;
    expect(second.revision, '${file.id}:${md5.convert([2])}');
    expect(file.bytes, [2]);
  });

  test('delete moves the file to the trash', () async {
    final storage = provider();
    final entry = await storage.write(
      'a.satchel',
      bytes([1]),
      expectedRevision: null,
    );

    await storage.delete('a.satchel', expectedRevision: entry.revision);

    final file = drive.files.values.singleWhere((f) => f.name == 'a.satchel');
    expect(file.trashed, isTrue);
    expect(file.bytes, [1]);
  });

  test('handles names that need quoting', () async {
    final storage = provider();
    for (final name in ["Bob's.satchel", 'Bob and Alice.satchel']) {
      await storage.write(name, bytes([1]), expectedRevision: null);
      expect((await storage.read(name)).bytes, [1], reason: name);
    }
    expect((await storage.list()).map((e) => e.path), [
      "Bob's.satchel",
      'Bob and Alice.satchel',
    ]);
  });

  test('reads every page of a listing', () async {
    for (final name in ['a', 'b', 'c']) {
      drive.addFile('$name.satchel', parent: folderId);
    }
    drive.pageSize = 1;

    expect((await provider().list()).map((e) => e.path), [
      'a.satchel',
      'b.satchel',
      'c.satchel',
    ]);
  });

  test('changes Drive makes on its own are not conflicts', () async {
    final storage = provider();
    final first = await storage.write(
      'a.satchel',
      bytes([1]),
      expectedRevision: null,
    );
    // Drive raises `version` for changes the user can't see.
    drive.filesIn(folderId).single.version += 3;

    expect((await storage.read('a.satchel')).entry, first);
    expect((await storage.list()).single, first);
    final second = await storage.write(
      'a.satchel',
      bytes([2]),
      expectedRevision: first.revision,
    );
    await storage.delete('a.satchel', expectedRevision: second.revision);
    expect(drive.filesIn(folderId), isEmpty);
  });

  test('a read revision belongs to the downloaded bytes', () async {
    final file = drive.addFile('a.satchel', parent: folderId, bytes: [1]);
    // Another device writes right after the download.
    drive.onDownload = (file) => file.bytes = bytes([2]);
    final storage = provider();

    final blob = await storage.read('a.satchel');

    expect(blob.bytes, [1]);
    expect(blob.entry.revision, '${file.id}:${md5.convert([1])}');
    drive.onDownload = null;
    await expectLater(
      storage.write(
        'a.satchel',
        bytes([3]),
        expectedRevision: blob.entry.revision,
      ),
      throwsA(isA<StorageConflictException>()),
    );
    expect(file.bytes, [2]);
  });

  test('list fails when the folder was deleted', () async {
    drive.files[folderId]!.trashed = true;

    await expectLater(
      provider().list(),
      throwsA(isA<StorageBackendException>()),
    );
  });

  test('can use the root of My Drive', () async {
    final storage = provider(folder: driveRootFolderId);
    await storage.write('a.satchel', bytes([1]), expectedRevision: null);

    expect(drive.filesIn(driveRootFolderId).single.name, 'a.satchel');
    expect((await storage.list()).single.path, 'a.satchel');
  });

  group('access tokens', () {
    test('asks for tokens interactively', () async {
      await provider().list();

      expect(auth.interactiveCalls, everyElement(isTrue));
      expect(
        drive.requests.map((r) => r.headers['Authorization']),
        everyElement('Bearer token'),
      );
    });

    test('retries once with a new token when Drive rejects one', () async {
      auth
        ..token = 'expired'
        ..next = 'token';

      expect(await provider().list(), isEmpty);
    });

    test('needs a sign-in when Drive keeps rejecting the token', () async {
      auth.token = 'revoked';

      await expectLater(
        provider().list(),
        throwsA(
          isA<StorageAuthRequiredException>().having(
            (e) => e.accountId,
            'accountId',
            'ada',
          ),
        ),
      );
    });

    test('needs a sign-in when the user cancels it', () async {
      auth.error = const GoogleAuthCancelledException();

      await expectLater(
        provider().list(),
        throwsA(isA<StorageAuthRequiredException>()),
      );
      expect(drive.requests, isEmpty);
    });

    test('needs a sign-in without a linked account', () async {
      final storage = GoogleDriveStorageProvider(
        id: 'drive',
        displayName: 'Drive',
        folderId: folderId,
        api: GoogleDriveApi(
          GoogleDriveTokens(auth: auth, account: null),
          httpClient: drive.client,
        ),
      );

      await expectLater(
        storage.list(),
        throwsA(isA<StorageAuthRequiredException>()),
      );
    });

    test('reports sign-in failures as backend errors', () async {
      auth.error = const GoogleAuthFailedException('Could not reach Google');

      await expectLater(
        provider().list(),
        throwsA(
          isA<StorageBackendException>().having(
            (e) => e.message,
            'message',
            'Could not reach Google',
          ),
        ),
      );
    });
  });

  test('reports Drive errors with their message', () async {
    drive.intercept = (request) => http.Response(
      jsonEncode({
        'error': {'code': 403, 'message': 'Storage quota exceeded'},
      }),
      403,
    );

    await expectLater(
      provider().write('a.satchel', bytes([1]), expectedRevision: null),
      throwsA(
        isA<StorageBackendException>()
            .having((e) => e.message, 'message', 'Storage quota exceeded')
            .having((e) => e.path, 'path', ''),
      ),
    );
  });

  test('reports network failures', () async {
    drive.intercept = (_) => throw http.ClientException('offline');

    await expectLater(
      provider().list(),
      throwsA(isA<StorageBackendException>()),
    );
  });

  test('rejects paths that are not vault file names', () {
    final storage = provider();
    for (final path in ['a.txt', 'dir/a.satchel', '.a.satchel']) {
      expect(() => storage.read(path), throwsArgumentError, reason: path);
    }
  });

  group('folders', () {
    test('lists the folders in a folder by name', () async {
      drive
        ..addFolder('b', parent: folderId)
        ..addFolder('A', parent: folderId)
        ..addFile('c.satchel', parent: folderId)
        ..addFolder('elsewhere')
        ..addFolder('trashed', parent: folderId).trashed = true;

      final folders = await GoogleDriveFolderSource(api()).list(folderId);

      expect(folders.map((f) => f.name), ['A', 'b']);
    });

    test('creates a folder', () async {
      final source = GoogleDriveFolderSource(api());

      final created = await source.create(driveRootFolderId, 'Vaults');

      final file = drive.files[created.id]!;
      expect(file.name, 'Vaults');
      expect(file.isFolder, isTrue);
      expect(file.parents, [driveRootFolderId]);
      expect(await source.list(driveRootFolderId), contains(created));
    });
  });
}
