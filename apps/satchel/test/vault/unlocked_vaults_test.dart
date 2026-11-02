import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/files/vault_files_providers.dart';
import 'package:satchel/src/storage/storage_providers.dart';
import 'package:satchel/src/vault/unlocked_vaults.dart';
import 'package:satchel/src/vault/vault_providers.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../fakes.dart';

final _now = DateTime.utc(2026, 11, 2, 12);

void main() {
  late FakeStorageProvider storage;
  late MemoryStorageConfigStore store;
  late ProviderContainer container;
  const a = VaultRef('s', 'a.satchel');
  const b = VaultRef('s', 'b.satchel');

  final secret = NoteSecret(
    info: SecretInfo(
      id: 'n1',
      title: 'Safe',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    ),
    text: '12-34-56',
  );

  setUp(() async {
    storage = FakeStorageProvider(id: 's');
    await putVault(storage, a.path, 'password-a', secrets: [secret]);
    await putVault(storage, b.path, 'password-b');
    store = MemoryStorageConfigStore([directoryConfig('s', '/s')]);
    container = ProviderContainer(
      overrides: [
        ...storageOverrides(platform: StoragePlatform.linux, store: store),
        storageProvidersProvider.overrideWith((ref) async => [storage]),
        appClockProvider.overrideWithValue(Clock.fixed(_now)),
        vaultCryptoProvider.overrideWithValue(const VaultCrypto(memoryKiB: 64)),
      ],
    );
    addTearDown(container.dispose);
  });

  UnlockedVaults notifier() => container.read(unlockedVaultsProvider.notifier);
  Map<VaultRef, UnlockedVault> vaults() =>
      container.read(unlockedVaultsProvider);

  test('starts with nothing unlocked', () {
    expect(vaults(), isEmpty);
  });

  test('unlock decrypts the file and keeps its revision', () async {
    await notifier().unlock(a, 'password-a');

    final vault = vaults()[a]!;
    expect(vault.ref, a);
    expect(vault.payload.secrets, [secret]);
    expect(vault.revision, storage.blobs[a.path]!.revision);
    expect(vault.key.isDestroyed, isFalse);
    expect(vaults().keys, [a]);
  });

  test('several files can be unlocked at once', () async {
    await notifier().unlock(a, 'password-a');
    await notifier().unlock(b, 'password-b');

    expect(vaults().keys, unorderedEquals([a, b]));
  });

  test('a wrong password leaves the file locked', () async {
    await expectLater(
      notifier().unlock(a, 'password-b'),
      throwsA(isA<VaultAuthenticationException>()),
    );
    expect(vaults(), isEmpty);
  });

  test('reports files that are not vaults or missing', () async {
    storage.blobs['junk.satchel'] = (
      bytes: Uint8List.fromList(utf8.encode('not a vault at all, honestly')),
      revision: 'j',
    );

    await expectLater(
      notifier().unlock(const VaultRef('s', 'junk.satchel'), 'x'),
      throwsA(isA<VaultFormatException>()),
    );
    await expectLater(
      notifier().unlock(const VaultRef('s', 'gone.satchel'), 'x'),
      throwsA(isA<StorageNotFoundException>()),
    );
    expect(vaults(), isEmpty);
  });

  test('unlocking an unlocked file keeps the session as is', () async {
    await notifier().unlock(a, 'password-a');
    final first = vaults()[a];

    await notifier().unlock(a, 'wrong password is not even checked');

    expect(identical(vaults()[a], first), isTrue);
  });

  test('lock zeroes the key and drops the content', () async {
    await notifier().unlock(a, 'password-a');
    await notifier().unlock(b, 'password-b');
    final key = vaults()[a]!.key;

    notifier().lock(a);

    expect(vaults().keys, [b]);
    expect(key.isDestroyed, isTrue);
  });

  test('lockAll locks every file', () async {
    await notifier().unlock(a, 'password-a');
    await notifier().unlock(b, 'password-b');
    final keys = [for (final v in vaults().values) v.key];

    notifier().lockAll();

    expect(vaults(), isEmpty);
    expect(keys.every((k) => k.isDestroyed), isTrue);
  });

  test('removing a storage locks its files', () async {
    await container.read(storageConfigsProvider.future);
    await notifier().unlock(a, 'password-a');
    final key = vaults()[a]!.key;

    await container.read(storageConfigsProvider.notifier).remove('s');

    expect(vaults(), isEmpty);
    expect(key.isDestroyed, isTrue);
  });

  test('disposing the app zeroes every key', () async {
    await notifier().unlock(a, 'password-a');
    final key = vaults()[a]!.key;

    container.dispose();

    expect(key.isDestroyed, isTrue);
  });

  test('adopt takes over a key, and refuses duplicates', () async {
    final key = await VaultKey.create(password: 'x', memoryKiB: 64);
    final payload = VaultPayload.create(name: 'a');

    notifier().adopt(a, payload: payload, key: key, revision: 'r');
    expect(vaults()[a]!.key, same(key));

    final second = await VaultKey.create(password: 'x', memoryKiB: 64);
    notifier().adopt(a, payload: payload, key: second, revision: 'r');
    expect(vaults()[a]!.key, same(key));
    expect(second.isDestroyed, isTrue);
  });

  test('toString reveals nothing', () async {
    await notifier().unlock(a, 'password-a');

    expect(vaults()[a].toString(), isNot(contains('Safe')));
  });

  group('save', () {
    final login = LoginSecret(
      info: SecretInfo(
        id: 'l1',
        title: 'Bank',
        createdAt: DateTime.utc(2026, 5),
        updatedAt: DateTime.utc(2026, 5),
      ),
      username: 'ann',
      password: 'pw',
    );

    setUp(() => notifier().unlock(a, 'password-a'));

    Future<VaultPayload> stored() async => (await VaultCodec.decrypt(
      storage.blobs[a.path]!.bytes,
      password: 'password-a',
    )).payload;

    test('putSecret encrypts and writes the file', () async {
      final before = storage.blobs[a.path]!;

      await notifier().putSecret(a, login);

      final vault = vaults()[a]!;
      expect(vault.payload.secrets, [secret, login]);
      expect(vault.payload.updatedAt, _now);
      expect(vault.revision, storage.blobs[a.path]!.revision);
      expect(vault.revision, isNot(before.revision));
      final onDisk = await stored();
      expect(onDisk.secrets, [secret, login]);
      expect(onDisk.updatedAt, _now);
      expect(onDisk.fileId, vault.payload.fileId);
    });

    test('every save uses a fresh nonce', () async {
      String nonce() =>
          RegExp(r'"nonce":"([^"]+)"')
              .firstMatch(latin1.decode(storage.blobs[a.path]!.bytes))!
              .group(1)!;
      final nonces = {nonce()};

      await notifier().putSecret(a, login);
      nonces.add(nonce());
      await notifier().putSecret(a, login.copyWith(username: 'bob'));
      nonces.add(nonce());

      expect(nonces, hasLength(3));
    });

    test('an unchanged secret writes nothing', () async {
      await notifier().putSecret(a, secret);

      expect(storage.blobs[a.path]!.revision, vaults()[a]!.revision);
      expect(vaults()[a]!.payload.updatedAt, DateTime.utc(2026));
    });

    test('refuses to overwrite a file changed elsewhere', () async {
      final current = storage.blobs[a.path]!;
      storage.blobs[a.path] = (bytes: current.bytes, revision: 'elsewhere');

      await expectLater(
        notifier().putSecret(a, login),
        throwsA(isA<StorageConflictException>()),
      );
      expect(vaults()[a]!.payload.secrets, [secret]);
      expect(storage.blobs[a.path]!.revision, 'elsewhere');
    });

    test('a locked vault cannot be saved', () async {
      notifier().lock(a);

      await expectLater(notifier().putSecret(a, login), throwsStateError);
    });

    test('a write that does not verify can be retried', () async {
      storage.corruptWrites = true;

      await expectLater(
        notifier().putSecret(a, login),
        throwsA(isA<VaultAuthenticationException>()),
      );
      expect(vaults()[a]!.payload.secrets, [secret]);

      storage.corruptWrites = false;
      await notifier().putSecret(a, login);
      expect((await stored()).secrets, [secret, login]);
    });

    test('concurrent saves are applied in order', () async {
      final saves = [
        notifier().putSecret(a, login),
        notifier().putSecret(a, login.copyWith(username: 'bob')),
      ];
      await Future.wait(saves);

      final onDisk = await stored();
      expect((onDisk.secretById('l1')! as LoginSecret).username, 'bob');
      expect(vaults()[a]!.revision, storage.blobs[a.path]!.revision);
    });
  });

  group('rename', () {
    const renamed = VaultRef('s', 'Work.satchel');

    setUp(() => notifier().unlock(a, 'password-a'));

    test('moves the file and the session to the new name', () async {
      final key = vaults()[a]!.key;

      final path = await notifier().rename(a, 'Work');

      expect(path, renamed.path);
      expect(storage.paths, unorderedEquals([b.path, renamed.path]));
      expect(vaults().keys, [renamed]);
      final vault = vaults()[renamed]!;
      expect(vault.key, same(key));
      expect(key.isDestroyed, isFalse);
      expect(vault.payload.name, 'Work');
      expect(vault.payload.secrets, [secret]);
      expect(vault.revision, storage.blobs[renamed.path]!.revision);
      final onDisk = await VaultCodec.decrypt(
        storage.blobs[renamed.path]!.bytes,
        password: 'password-a',
      );
      expect(onDisk.payload.name, 'Work');
      expect(onDisk.payload.fileId, vault.payload.fileId);
    });

    test('refuses a name that is taken, ignoring case', () async {
      await expectLater(
        notifier().rename(a, 'B'),
        throwsA(isA<VaultFileExistsException>()),
      );
      expect(storage.paths, unorderedEquals([a.path, b.path]));
      expect(vaults().keys, [a]);
    });

    test('allows changing only the case', () async {
      await notifier().rename(a, 'A');

      expect(storage.paths, unorderedEquals(['A.satchel', b.path]));
    });

    test('keeps the original if it changed elsewhere', () async {
      final current = storage.blobs[a.path]!;
      storage.blobs[a.path] = (bytes: current.bytes, revision: 'elsewhere');

      await expectLater(
        notifier().rename(a, 'Work'),
        throwsA(isA<StorageConflictException>()),
      );
      expect(storage.paths, unorderedEquals([a.path, b.path]));
      expect(vaults().keys, [a]);
    });

    test('removes a copy that does not verify', () async {
      storage.corruptWrites = true;

      await expectLater(
        notifier().rename(a, 'Work'),
        throwsA(isA<VaultAuthenticationException>()),
      );
      expect(storage.paths, unorderedEquals([a.path, b.path]));
      expect(vaults().keys, [a]);
    });

    test('a locked vault cannot be renamed', () async {
      notifier().lock(a);

      await expectLater(notifier().rename(a, 'Work'), throwsStateError);
    });
  });

  group('export', () {
    setUp(() => notifier().unlock(a, 'password-a'));

    test('encrypted with the session key, optionally a subset', () async {
      final all = await notifier().exportEncrypted(a);
      final none = await notifier().exportEncrypted(a, secretIds: {});

      final opened = await VaultCodec.decrypt(all, password: 'password-a');
      expect(opened.payload.secrets, [secret]);
      expect(opened.payload.fileId, vaults()[a]!.payload.fileId);
      expect(
        (await VaultCodec.decrypt(
          none,
          password: 'password-a',
        )).payload.secrets,
        isEmpty,
      );
      expect(vaults()[a]!.key.isDestroyed, isFalse);
    });

    test('encrypted under a new password', () async {
      final bytes = await notifier().exportEncrypted(a, newPassword: 'other');

      final opened = await VaultCodec.decrypt(bytes, password: 'other');
      expect(opened.payload.secrets, [secret]);
    });

    test('plain JSON', () {
      final bytes = notifier().exportPlain(a, secretIds: {secret.id});

      expect(PlainExport.decode(bytes).secrets, [secret]);
    });

    test('a locked vault cannot be exported', () {
      notifier().lock(a);

      expect(() => notifier().exportPlain(a), throwsStateError);
      expect(notifier().exportEncrypted(a), throwsStateError);
    });
  });

  group('import', () {
    setUp(() => notifier().unlock(a, 'password-a'));

    test('reads plain exports and own exports by extension', () async {
      final plain = notifier().exportPlain(a);
      final own = await notifier().exportEncrypted(a);

      for (final (name, bytes) in [('x.JSON', plain), ('x.satchel', own)]) {
        final payload = await notifier().readImport(a, name, bytes);
        expect(payload.secrets, [secret], reason: name);
      }
    });

    test('needs the password of other vault files', () async {
      final other = await notifier().exportEncrypted(a, newPassword: 'other');

      await expectLater(
        notifier().readImport(a, 'x.satchel', other),
        throwsA(isA<ImportPasswordRequiredException>()),
      );
      await expectLater(
        notifier().readImport(a, 'x.satchel', other, password: 'wrong'),
        throwsA(isA<VaultAuthenticationException>()),
      );
      final payload = await notifier().readImport(
        a,
        'x.satchel',
        other,
        password: 'other',
      );
      expect(payload.secrets, [secret]);
    });

    test('rejects other extensions', () async {
      await expectLater(
        notifier().readImport(a, 'x.txt', Uint8List(0)),
        throwsA(isA<UnsupportedImportException>()),
      );
    });

    test('plans and applies the merge', () async {
      final edited = secret.copyWith(text: 'changed');
      final plan = notifier().planImport(
        a,
        VaultPayload.create(name: 'x').withSecret(edited),
      );
      expect(plan.conflicts.single.incoming, edited);

      await notifier().applyImport(a, plan, {
        secret.id: ConflictResolution.useIncoming,
      });

      expect(vaults()[a]!.payload.secrets, [edited]);
      final onDisk = await VaultCodec.decrypt(
        storage.blobs[a.path]!.bytes,
        password: 'password-a',
      );
      expect(onDisk.payload.secrets, [edited]);
    });
  });

  group('changePassword', () {
    Future<VaultPayload> openWith(String password) async =>
        (await VaultCodec.decrypt(
          storage.blobs[a.path]!.bytes,
          password: password,
        )).payload;

    test('re-encrypts a locked file and keeps it locked', () async {
      await notifier().changePassword(
        a,
        currentPassword: 'password-a',
        newPassword: 'new-password',
      );

      expect((await openWith('new-password')).secrets, [secret]);
      await expectLater(
        openWith('password-a'),
        throwsA(isA<VaultAuthenticationException>()),
      );
      expect(vaults(), isEmpty);
    });

    test('swaps the key of an unlocked file', () async {
      await notifier().unlock(a, 'password-a');
      final oldKey = vaults()[a]!.key;

      await notifier().changePassword(
        a,
        currentPassword: 'password-a',
        newPassword: 'new-password',
      );

      final vault = vaults()[a]!;
      expect(oldKey.isDestroyed, isTrue);
      expect(vault.key.isDestroyed, isFalse);
      expect(vault.key.params.salt, isNot(oldKey.params.salt));
      expect(vault.revision, storage.blobs[a.path]!.revision);

      // Later saves use the new password.
      await notifier().save(a, (p) => p.withoutSecret(secret.id));
      expect((await openWith('new-password')).secrets, isEmpty);
    });

    test('a wrong current password changes nothing', () async {
      final before = storage.blobs[a.path]!;

      await expectLater(
        notifier().changePassword(
          a,
          currentPassword: 'password-b',
          newPassword: 'new-password',
        ),
        throwsA(isA<VaultAuthenticationException>()),
      );
      expect(storage.blobs[a.path]!.revision, before.revision);
    });

    test('refuses a file changed since it was unlocked', () async {
      await notifier().unlock(a, 'password-a');
      final current = storage.blobs[a.path]!;
      storage.blobs[a.path] = (bytes: current.bytes, revision: 'elsewhere');

      await expectLater(
        notifier().changePassword(
          a,
          currentPassword: 'password-a',
          newPassword: 'new-password',
        ),
        throwsA(isA<StorageConflictException>()),
      );
      expect(storage.blobs[a.path]!.revision, 'elsewhere');
      expect((await openWith('password-a')).secrets, [secret]);
    });

    test('a write that does not verify keeps the session key', () async {
      await notifier().unlock(a, 'password-a');
      final key = vaults()[a]!.key;
      storage.corruptWrites = true;

      await expectLater(
        notifier().changePassword(
          a,
          currentPassword: 'password-a',
          newPassword: 'new-password',
        ),
        throwsA(isA<VaultAuthenticationException>()),
      );
      expect(vaults()[a]!.key, same(key));
      expect(key.isDestroyed, isFalse);
    });
  });
}
