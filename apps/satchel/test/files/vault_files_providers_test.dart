import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/files/vault_file.dart';
import 'package:satchel/src/files/vault_files_providers.dart';
import 'package:satchel/src/storage/storage_providers.dart';
import 'package:satchel/src/vault/unlocked_vaults.dart';
import 'package:satchel/src/vault/vault_providers.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';
import 'package:clock/clock.dart';

import '../fakes.dart';

final _now = DateTime.utc(2026, 11, 2, 12);

void main() {
  late FakeStorageProvider storage;
  late ProviderContainer container;

  setUp(() {
    storage = FakeStorageProvider(id: 's');
    container = ProviderContainer(
      overrides: [
        storageProvidersProvider.overrideWith((ref) async => [storage]),
        appClockProvider.overrideWithValue(Clock.fixed(_now)),
        vaultCryptoProvider.overrideWithValue(const VaultCrypto(memoryKiB: 64)),
      ],
    );
    addTearDown(container.dispose);
  });

  /// Reads an auto-dispose future provider, keeping it alive until it
  /// completes.
  Future<T> read<T>(ProviderListenable<Future<T>> provider) {
    container.listen(provider, (_, _) {});
    return container.read(provider);
  }

  test('finds a storage by id', () async {
    expect(await read(storageByIdProvider('s').future), storage);
    await expectLater(
      read(storageByIdProvider('gone').future),
      throwsA(isA<UnknownStorageException>()),
    );
  });

  test('lists vault files sorted by name, ignoring other blobs', () async {
    storage.paths = [
      'work.satchel',
      'notes.txt',
      'Banking.satchel',
      '.satchel',
      'archive.satchel',
    ];

    final files = await read(vaultFilesProvider('s').future);

    expect(files.map((f) => f.name), ['archive', 'Banking', 'work']);
    expect(
      files.first,
      const VaultFile(
        storageId: 's',
        path: 'archive.satchel',
        revision: 'r-archive.satchel',
      ),
    );
  });

  test('fails for an unknown storage', () async {
    await expectLater(
      read(vaultFilesProvider('gone').future),
      throwsA(isA<UnknownStorageException>()),
    );
  });

  group('create', () {
    VaultFiles notifier() => container.read(vaultFilesProvider('s').notifier);

    setUp(() async {
      storage.paths = ['Existing.satchel'];
      await read(vaultFilesProvider('s').future);
    });

    test('writes an encrypted, empty vault and lists it', () async {
      final file = await notifier().create(
        name: 'Personal',
        password: 'hunter22',
      );

      expect(file.storageId, 's');
      expect(file.path, 'Personal.satchel');
      final opened = await VaultCodec.decrypt(
        storage.blobs['Personal.satchel']!.bytes,
        password: 'hunter22',
      );
      expect(opened.payload.name, 'Personal');
      expect(opened.payload.createdAt, _now);
      expect(opened.payload.updatedAt, _now);
      expect(opened.payload.secrets, isEmpty);
      expect(opened.key.params.memoryKiB, 64);
      final unlocked = container.read(
        unlockedVaultsProvider,
      )[const VaultRef('s', 'Personal.satchel')]!;
      expect(unlocked.payload.fileId, opened.payload.fileId);
      expect(unlocked.revision, storage.blobs['Personal.satchel']!.revision);
      expect(unlocked.key.isDestroyed, isFalse);
      expect((await read(vaultFilesProvider('s').future)).map((f) => f.name), [
        'Existing',
        'Personal',
      ]);
    });

    test('refuses a name that exists, ignoring case', () async {
      await expectLater(
        notifier().create(name: 'existing', password: 'hunter22'),
        throwsA(isA<VaultFileExistsException>()),
      );
      expect(storage.paths, ['Existing.satchel']);
    });

    test('maps a create conflict to VaultFileExistsException', () async {
      storage.writeError = const StorageConflictException(
        'Personal.satchel',
        expectedRevision: null,
        actualRevision: 'x',
      );

      await expectLater(
        notifier().create(name: 'Personal', password: 'hunter22'),
        throwsA(isA<VaultFileExistsException>()),
      );
    });

    test('removes a file that does not verify after writing', () async {
      storage.corruptWrites = true;

      await expectLater(
        notifier().create(name: 'Personal', password: 'hunter22'),
        throwsA(isA<VaultAuthenticationException>()),
      );
      expect(storage.paths, ['Existing.satchel']);
      expect(container.read(unlockedVaultsProvider), isEmpty);
    });

    test('rejects invalid names before touching the storage', () async {
      await expectLater(
        notifier().create(name: 'a/b', password: 'hunter22'),
        throwsArgumentError,
      );
      expect(storage.paths, ['Existing.satchel']);
    });
  });

  group('delete', () {
    VaultFiles notifier() => container.read(vaultFilesProvider('s').notifier);
    const ref = VaultRef('s', 'personal.satchel');

    setUp(() async {
      storage.paths = [];
      await putVault(storage, ref.path, 'hunter22');
      await putVault(storage, 'work.satchel', 'hunter22');
    });

    Future<VaultFile> listed(String path) async =>
        (await read(vaultFilesProvider('s').future))
            .singleWhere((file) => file.path == path);

    test('deletes the file, locks it and refreshes the list', () async {
      await container
          .read(unlockedVaultsProvider.notifier)
          .unlock(ref, 'hunter22');
      final key = container.read(unlockedVaultsProvider)[ref]!.key;

      await notifier().delete(await listed(ref.path));

      expect(storage.paths, ['work.satchel']);
      expect(container.read(unlockedVaultsProvider), isEmpty);
      expect(key.isDestroyed, isTrue);
      expect((await read(vaultFilesProvider('s').future)).map((f) => f.path), [
        'work.satchel',
      ]);
    });

    test('refuses a file changed since it was listed', () async {
      final stale = await listed(ref.path);
      final current = storage.blobs[ref.path]!;
      storage.blobs[ref.path] = (bytes: current.bytes, revision: 'changed');

      await expectLater(
        notifier().delete(stale),
        throwsA(isA<StorageConflictException>()),
      );
      expect(storage.paths, contains(ref.path));
      expect((await listed(ref.path)).revision, 'changed');
    });

    test('a file that is already gone counts as deleted', () async {
      final file = await listed(ref.path);
      storage.blobs.remove(ref.path);

      await notifier().delete(file);

      expect((await read(vaultFilesProvider('s').future)).map((f) => f.path), [
        'work.satchel',
      ]);
    });

    test('storage failures keep the file unlocked', () async {
      await container
          .read(unlockedVaultsProvider.notifier)
          .unlock(ref, 'hunter22');
      storage.deleteError = const StorageBackendException('', 'read-only');

      await expectLater(
        notifier().delete(await listed(ref.path)),
        throwsA(isA<StorageBackendException>()),
      );
      expect(storage.paths, contains(ref.path));
      expect(container.read(unlockedVaultsProvider), contains(ref));
    });
  });
}
