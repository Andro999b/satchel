import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:satchel_storage/satchel_storage.dart';

/// Behavior every [StorageProvider] must have. Each implementation's test file
/// runs this suite against a fresh, empty provider per test.
void storageProviderContractTests(
  FutureOr<StorageProvider> Function() create, {
  FutureOr<void> Function(StorageProvider storage)? dispose,
}) {
  late StorageProvider storage;
  Uint8List bytes() => Uint8List.fromList([1, 2, 3]);

  setUp(() async {
    storage = await create();
  });

  tearDown(() async {
    await dispose?.call(storage);
  });

  test('starts empty', () async {
    expect(await storage.list(), isEmpty);
  });

  test('creates, lists and reads a blob', () async {
    final entry = await storage.write(
      'a.satchel',
      bytes(),
      expectedRevision: null,
    );

    expect(entry.path, 'a.satchel');
    expect(await storage.list(), [entry]);
    final blob = await storage.read('a.satchel');
    expect(blob.entry, entry);
    expect(blob.bytes, [1, 2, 3]);
  });

  test('lists every blob', () async {
    final a = await storage.write('a.satchel', bytes(), expectedRevision: null);
    final b = await storage.write('b.satchel', bytes(), expectedRevision: null);

    expect(await storage.list(), unorderedEquals([a, b]));
  });

  test('read of a missing blob throws StorageNotFoundException', () {
    expect(
      storage.read('missing.satchel'),
      throwsA(isA<StorageNotFoundException>()),
    );
  });

  test('create fails if the blob already exists', () async {
    await storage.write('a.satchel', bytes(), expectedRevision: null);

    await expectLater(
      storage.write('a.satchel', Uint8List(1), expectedRevision: null),
      throwsA(isA<StorageConflictException>()),
    );
    expect((await storage.read('a.satchel')).bytes, [1, 2, 3]);
  });

  test('update with the current revision replaces the blob', () async {
    final first = await storage.write(
      'a.satchel',
      bytes(),
      expectedRevision: null,
    );
    final second = await storage.write(
      'a.satchel',
      Uint8List.fromList([9]),
      expectedRevision: first.revision,
    );

    expect(second.revision, isNot(first.revision));
    final blob = await storage.read('a.satchel');
    expect(blob.entry, second);
    expect(blob.bytes, [9]);
  });

  test('update of a missing blob throws StorageConflictException', () {
    expect(
      storage.write('a.satchel', bytes(), expectedRevision: 'whatever'),
      throwsA(
        isA<StorageConflictException>().having(
          (e) => e.actualRevision,
          'actualRevision',
          isNull,
        ),
      ),
    );
  });

  test('update with a stale revision throws and keeps the data', () async {
    final first = await storage.write(
      'a.satchel',
      bytes(),
      expectedRevision: null,
    );
    final second = await storage.write(
      'a.satchel',
      Uint8List.fromList([9]),
      expectedRevision: first.revision,
    );

    await expectLater(
      storage.write('a.satchel', bytes(), expectedRevision: first.revision),
      throwsA(
        isA<StorageConflictException>().having(
          (e) => e.actualRevision,
          'actualRevision',
          second.revision,
        ),
      ),
    );
    expect((await storage.read('a.satchel')).bytes, [9]);
  });

  test('delete requires the current revision', () async {
    final entry = await storage.write(
      'a.satchel',
      bytes(),
      expectedRevision: null,
    );

    await expectLater(
      storage.delete('a.satchel', expectedRevision: 'stale'),
      throwsA(isA<StorageConflictException>()),
    );
    expect(await storage.list(), [entry]);
    await storage.delete('a.satchel', expectedRevision: entry.revision);
    expect(await storage.list(), isEmpty);
    await expectLater(
      storage.read('a.satchel'),
      throwsA(isA<StorageNotFoundException>()),
    );
  });

  test('delete of a missing blob throws StorageNotFoundException', () {
    expect(
      storage.delete('missing.satchel', expectedRevision: '1'),
      throwsA(isA<StorageNotFoundException>()),
    );
  });

  test('a stale revision never matches recreated content', () async {
    final old = await storage.write(
      'a.satchel',
      bytes(),
      expectedRevision: null,
    );
    await storage.delete('a.satchel', expectedRevision: old.revision);
    final recreated = await storage.write(
      'a.satchel',
      Uint8List.fromList([4, 5, 6]),
      expectedRevision: null,
    );

    expect(recreated.revision, isNot(old.revision));
    await expectLater(
      storage.delete('a.satchel', expectedRevision: old.revision),
      throwsA(isA<StorageConflictException>()),
    );
  });

  test('returned bytes are a defensive copy', () async {
    await storage.write('a.satchel', bytes(), expectedRevision: null);
    (await storage.read('a.satchel')).bytes[0] = 42;

    expect((await storage.read('a.satchel')).bytes, [1, 2, 3]);
  });

  test('stored bytes are a defensive copy of the input', () async {
    final input = bytes();
    final write = storage.write('a.satchel', input, expectedRevision: null);
    input[0] = 42;
    await write;

    expect((await storage.read('a.satchel')).bytes, [1, 2, 3]);
  });
}
