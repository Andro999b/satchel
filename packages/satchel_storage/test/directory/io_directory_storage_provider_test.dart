@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:satchel_storage/satchel_storage.dart';
import 'package:satchel_storage/src/directory/directory_platform_io.dart';
import 'package:satchel_storage/src/directory/io_directory_backend.dart';
import 'package:satchel_storage/src/directory/saf_directory_backend.dart';

import '../storage_provider_contract.dart';

DirectoryStorageProvider _provider(String path) => DirectoryStorageProvider(
  id: 'dir',
  displayName: 'Folder',
  backend: IoDirectoryBackend(path),
);

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('satchel_dir_test');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  group('contract', () {
    storageProviderContractTests(() => _provider(directory.path));
  });

  List<String> filesOnDisk() =>
      [for (final entity in directory.listSync()) p.basename(entity.path)]
        ..sort();

  test('stores blobs as plain files in the directory', () async {
    await _provider(directory.path)
        .write('a.satchel', Uint8List.fromList([1, 2]), expectedRevision: null);

    expect(filesOnDisk(), ['a.satchel']);
    expect(File(p.join(directory.path, 'a.satchel')).readAsBytesSync(), [1, 2]);
  });

  test('replacing a blob leaves no temporary files behind', () async {
    final storage = _provider(directory.path);
    var entry = await storage.write(
      'a.satchel',
      Uint8List(1),
      expectedRevision: null,
    );
    for (var i = 0; i < 3; i++) {
      entry = await storage.write(
        'a.satchel',
        Uint8List.fromList([i]),
        expectedRevision: entry.revision,
      );
    }

    expect(filesOnDisk(), ['a.satchel']);
  });

  test('lists only .satchel files', () async {
    File(p.join(directory.path, 'notes.txt')).writeAsStringSync('x');
    File(p.join(directory.path, '.a.satchel.1f.tmp')).writeAsStringSync('x');
    Directory(p.join(directory.path, 'nested.satchel')).createSync();
    File(p.join(directory.path, 'vault.satchel')).writeAsStringSync('v');

    final entries = await _provider(directory.path).list();

    expect(entries.map((e) => e.path), ['vault.satchel']);
  });

  test('revision is the SHA-256 of the contents', () async {
    File(p.join(directory.path, 'v.satchel')).writeAsStringSync('vault');

    final blob = await _provider(directory.path).read('v.satchel');

    expect(
      blob.entry.revision,
      sha256.convert(utf8.encode('vault')).toString(),
    );
  });

  test('detects changes made by other programs', () async {
    final storage = _provider(directory.path);
    final entry = await storage.write(
      'a.satchel',
      Uint8List(1),
      expectedRevision: null,
    );
    File(p.join(directory.path, 'a.satchel')).writeAsBytesSync([7, 7]);

    await expectLater(
      storage.write(
        'a.satchel',
        Uint8List(2),
        expectedRevision: entry.revision,
      ),
      throwsA(isA<StorageConflictException>()),
    );
    expect(File(p.join(directory.path, 'a.satchel')).readAsBytesSync(), [7, 7]);
  });

  test('rejects paths that are not plain .satchel file names', () {
    final storage = _provider(directory.path);
    for (final path in [
      '',
      '.satchel',
      'a',
      'a.txt',
      '.a.satchel',
      '../a.satchel',
      'sub/a.satchel',
      r'sub\a.satchel',
      'a:b.satchel',
      'trailing..satchel',
      ' padded.satchel',
      'CON.satchel',
    ]) {
      expect(
        () => storage.write(path, Uint8List(1), expectedRevision: null),
        throwsArgumentError,
        reason: path,
      );
      expect(() => storage.read(path), throwsArgumentError, reason: path);
    }
    expect(filesOnDisk(), isEmpty);
  });

  test(
    'providers on the same directory serialize conditional writes',
    () async {
      final a = _provider(directory.path);
      final b = _provider(p.join(directory.path, '.'));

      final results = await Future.wait([
        for (final (i, storage) in [a, b].indexed)
          storage
              .write(
                'x.satchel',
                Uint8List.fromList([i]),
                expectedRevision: null,
              )
              .then<Object>((entry) => entry, onError: (Object e) => e),
      ]);

      expect(results.whereType<StorageEntry>(), hasLength(1));
      expect(results.whereType<StorageConflictException>(), hasLength(1));
    },
  );

  test('a missing directory surfaces as StorageBackendException', () async {
    final storage = _provider(p.join(directory.path, 'gone'));

    await expectLater(storage.list(), throwsA(isA<StorageBackendException>()));
    await expectLater(
      storage.write('a.satchel', Uint8List(1), expectedRevision: null),
      throwsA(isA<StorageBackendException>()),
    );
  });

  test('kind.create builds a directory provider for the location', () async {
    final storage = StorageProviderKind.directory.create(
      StorageConfig(
        id: 'dir',
        kind: StorageProviderKind.directory,
        displayName: 'Docs',
        location: directory.path,
      ),
    );
    await storage.write('a.satchel', Uint8List(1), expectedRevision: null);

    expect(storage.displayName, 'Docs');
    expect(filesOnDisk(), ['a.satchel']);
  });

  test('picks the backend from the location', () {
    expect(directoryBackendFor('/home/me/Sync'), isA<IoDirectoryBackend>());
    expect(
      directoryBackendFor('content://com.android.externalstorage/tree/x'),
      isA<SafDirectoryBackend>(),
    );
  });
}
