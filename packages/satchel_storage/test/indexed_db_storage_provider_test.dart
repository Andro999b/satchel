@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:satchel_storage/satchel_storage.dart';
import 'package:web/web.dart' as web;

import 'storage_provider_contract.dart';

var _counter = 0;

/// A database name unique to this test run, so tests never share state.
String _uniqueDatabaseName() =>
    'satchel_test.${DateTime.now().microsecondsSinceEpoch}.${_counter++}';

Future<void> _deleteDatabase(String name) {
  final done = Completer<void>();
  final request = web.window.indexedDB.deleteDatabase(name);
  request.onsuccess = (web.Event _) {
    done.complete();
  }.toJS;
  request.onerror = (web.Event _) {
    done.completeError(StateError('Failed to delete $name'));
  }.toJS;
  return done.future;
}

IndexedDbStorageProvider _provider(String databaseName) =>
    IndexedDbStorageProvider(
      id: 'idb',
      displayName: 'Browser',
      databaseName: databaseName,
    );

Future<void> _dispose(StorageProvider storage) async {
  final idb = storage as IndexedDbStorageProvider;
  await idb.close();
  await _deleteDatabase(idb.databaseName);
}

void main() {
  storageProviderContractTests(
    () => _provider(_uniqueDatabaseName()),
    dispose: _dispose,
  );

  group('IndexedDbStorageProvider', () {
    late String databaseName;

    setUp(() => databaseName = _uniqueDatabaseName());
    tearDown(() => _deleteDatabase(databaseName));

    test('uses a database per provider id by default', () {
      final storage = IndexedDbStorageProvider(id: 'x', displayName: 'X');

      expect(
        storage.databaseName,
        IndexedDbStorageProvider.databaseNameFor('x'),
      );
      expect(
        IndexedDbStorageProvider.databaseNameFor('y'),
        isNot(storage.databaseName),
      );
    });

    test('persists blobs across connections', () async {
      final first = _provider(databaseName);
      final entry = await first.write(
        'a',
        Uint8List.fromList([7]),
        expectedRevision: null,
      );
      await first.close();

      final second = _provider(databaseName);
      final blob = await second.read('a');
      expect(blob.entry, entry);
      expect(blob.bytes, [7]);
      await second.close();
    });

    test('detects concurrent writes from another connection', () async {
      final tabA = _provider(databaseName);
      final tabB = _provider(databaseName);
      final base = await tabA.write('a', Uint8List(1), expectedRevision: null);
      final fromB = await tabB.write(
        'a',
        Uint8List.fromList([2]),
        expectedRevision: base.revision,
      );

      await expectLater(
        tabA.write('a', Uint8List(3), expectedRevision: base.revision),
        throwsA(
          isA<StorageConflictException>().having(
            (e) => e.actualRevision,
            'actualRevision',
            fromB.revision,
          ),
        ),
      );
      expect((await tabA.read('a')).bytes, [2]);
      await tabA.close();
      await tabB.close();
    });

    test('only one of two racing creates succeeds', () async {
      final storage = _provider(databaseName);
      final results = await Future.wait([
        for (var i = 0; i < 2; i++)
          storage
              .write('a', Uint8List.fromList([i]), expectedRevision: null)
              .then<Object>((entry) => entry, onError: (Object e) => e),
      ]);

      expect(results.whereType<StorageEntry>(), hasLength(1));
      expect(results.whereType<StorageConflictException>(), hasLength(1));
      await storage.close();
    });

    test('reconnects after the database is deleted elsewhere', () async {
      final storage = _provider(databaseName);
      await storage.write('a', Uint8List(1), expectedRevision: null);

      await _deleteDatabase(databaseName);

      expect(await storage.list(), isEmpty);
      await storage.close();
    });
  });
}
