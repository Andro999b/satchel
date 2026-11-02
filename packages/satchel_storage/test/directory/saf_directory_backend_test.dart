@TestOn('vm')
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saf_stream/saf_stream_platform_interface.dart';
import 'package:saf_util/saf_util_platform_interface.dart';
import 'package:satchel_storage/satchel_storage.dart';
import 'package:satchel_storage/src/directory/saf_directory_backend.dart';

import '../storage_provider_contract.dart';

const _treeUri = 'content://test/tree/vaults';

/// In-memory SAF folder mimicking the provider behaviors the backend relies
/// on: name clashes get a " (1)" suffix instead of overwriting.
final class _FakeSafFolder {
  final documents = <String, ({String uri, Uint8List bytes})>{};
  var _nextId = 0;
  bool failRename = false;
  bool failDelete = false;
  PickedDirectory? pickResult;
  final released = <String>[];

  String _freeName(String name) =>
      documents.containsKey(name) ? '$name (1)' : name;

  String _nameOf(String uri) =>
      documents.entries.firstWhere((e) => e.value.uri == uri).key;

  SafDocumentFile _file(String name) => SafDocumentFile(
    uri: documents[name]!.uri,
    name: name,
    isDir: false,
    length: documents[name]!.bytes.length,
    lastModified: 0,
  );

  void _checkTree(String uri) {
    if (uri != _treeUri) throw PlatformException(code: 'PluginError');
  }
}

final class _FakeSafUtil extends SafUtilPlatform {
  _FakeSafUtil(this.folder);

  final _FakeSafFolder folder;

  @override
  Future<List<SafDocumentFile>> list(String uri) async {
    folder._checkTree(uri);
    return [for (final name in folder.documents.keys) folder._file(name)];
  }

  @override
  Future<SafDocumentFile?> child(String uri, List<String> names) async {
    folder._checkTree(uri);
    final name = names.single;
    return folder.documents.containsKey(name) ? folder._file(name) : null;
  }

  @override
  Future<void> delete(String uri, bool isDir) async {
    if (folder.failDelete) throw PlatformException(code: 'PluginError');
    folder.documents.remove(folder._nameOf(uri));
  }

  @override
  Future<SafDocumentFile> rename(String uri, bool isDir, String newName) async {
    if (folder.failRename) throw PlatformException(code: 'PluginError');
    final document = folder.documents.remove(folder._nameOf(uri))!;
    final name = folder._freeName(newName);
    folder.documents[name] = document;
    return folder._file(name);
  }

  @override
  Future<SafDocumentFile?> pickDirectory({
    String? initialUri,
    bool? writePermission,
    bool? persistablePermission,
  }) async {
    expect(writePermission, isTrue);
    expect(persistablePermission, isTrue);
    final picked = folder.pickResult;
    if (picked == null) return null;
    return SafDocumentFile(
      uri: picked.location,
      name: picked.name,
      isDir: true,
      length: 0,
      lastModified: 0,
    );
  }

  @override
  Future<void> releasePersistedPermission(
    String uri, {
    bool read = true,
    bool write = false,
  }) async {
    expect(read && write, isTrue);
    folder.released.add(uri);
  }
}

final class _FakeSafStream extends SafStreamPlatform {
  _FakeSafStream(this.folder);

  final _FakeSafFolder folder;

  @override
  Future<Uint8List> readFileBytes(String uri, {int? start, int? count}) async =>
      Uint8List.fromList(folder.documents[folder._nameOf(uri)]!.bytes);

  @override
  Future<SafNewFile> writeFileBytes(
    String treeUri,
    String fileName,
    String mime,
    Uint8List data, {
    bool? overwrite,
    bool? append,
  }) async {
    folder._checkTree(treeUri);
    expect(overwrite, isFalse);
    final name = folder._freeName(fileName);
    final uri = 'content://test/document/${folder._nextId++}';
    folder.documents[name] = (uri: uri, bytes: Uint8List.fromList(data));
    return SafNewFile(Uri.parse(uri), name);
  }
}

_FakeSafFolder _installFakeSaf() {
  final folder = _FakeSafFolder();
  SafUtilPlatform.instance = _FakeSafUtil(folder);
  SafStreamPlatform.instance = _FakeSafStream(folder);
  return folder;
}

DirectoryStorageProvider _provider() => DirectoryStorageProvider(
  id: 'saf',
  displayName: 'Folder',
  backend: SafDirectoryBackend(_treeUri),
);

void main() {
  group('contract', () {
    storageProviderContractTests(() {
      _installFakeSaf();
      return _provider();
    });
  });

  late _FakeSafFolder folder;
  setUp(() => folder = _installFakeSaf());

  test('replacing a file leaves only the file', () async {
    final storage = _provider();
    final first = await storage.write(
      'a.satchel',
      Uint8List(1),
      expectedRevision: null,
    );
    await storage.write(
      'a.satchel',
      Uint8List.fromList([5]),
      expectedRevision: first.revision,
    );

    expect(folder.documents.keys, ['a.satchel']);
    expect(folder.documents['a.satchel']!.bytes, [5]);
  });

  test('if the final rename fails, the new contents survive', () async {
    final storage = _provider();
    final first = await storage.write(
      'a.satchel',
      Uint8List(1),
      expectedRevision: null,
    );
    folder.failRename = true;

    await expectLater(
      storage.write(
        'a.satchel',
        Uint8List.fromList([5]),
        expectedRevision: first.revision,
      ),
      throwsA(isA<StorageBackendException>()),
    );
    final temp = folder.documents.entries.single;
    expect(temp.key, matches(r'^\.a\.satchel\.[0-9a-f]+\.tmp$'));
    expect(temp.value.bytes, [5]);
  });

  test('if deleting the old file fails, it is kept unchanged', () async {
    final storage = _provider();
    final first = await storage.write(
      'a.satchel',
      Uint8List(1),
      expectedRevision: null,
    );
    folder.failDelete = true;

    await expectLater(
      storage.write(
        'a.satchel',
        Uint8List.fromList([5]),
        expectedRevision: first.revision,
      ),
      throwsA(isA<StorageBackendException>()),
    );
    expect(folder.documents['a.satchel']!.bytes, [0]);
  });

  test('a write that lands under another name fails loudly', () async {
    folder.documents['a.satchel'] = (
      uri: 'content://test/document/old',
      bytes: Uint8List.fromList([9]),
    );
    // Another app re-creates the file between our delete and rename.
    SafUtilPlatform.instance = _RecreatingSafUtil(folder);

    await expectLater(
      SafDirectoryBackend(_treeUri).write('a.satchel', Uint8List.fromList([5])),
      throwsStateError,
    );
    expect(folder.documents['a.satchel (1)']!.bytes, [5]);
  });

  test('picker asks for persistable write access and releases it', () async {
    final picker = SafDirectoryPicker();

    expect(await picker.pick(), isNull);

    folder.pickResult = const PickedDirectory(
      location: _treeUri,
      name: 'vaults',
    );
    final picked = await picker.pick();
    expect(picked?.location, _treeUri);
    expect(picked?.name, 'vaults');

    await picker.release(_treeUri);
    expect(folder.released, [_treeUri]);
  });
}

/// Re-creates the deleted file immediately, as a concurrent app would.
final class _RecreatingSafUtil extends _FakeSafUtil {
  _RecreatingSafUtil(super.folder);

  @override
  Future<void> delete(String uri, bool isDir) async {
    final name = folder._nameOf(uri);
    await super.delete(uri, isDir);
    folder.documents[name] = (
      uri: 'content://test/document/racer',
      bytes: Uint8List(0),
    );
  }
}
