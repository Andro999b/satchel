import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/files/vault_file.dart';
import 'package:satchel/src/files/vault_files_providers.dart';
import 'package:satchel/src/pin/pin_unlock.dart';
import 'package:satchel/src/storage/storage_providers.dart';
import 'package:satchel/src/vault/unlocked_vaults.dart';
import 'package:satchel/src/vault/vault_providers.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../fakes.dart';

void main() {
  late FakeStorageProvider storage;
  late FakeStorageProvider other;
  late MemoryPinStore pins;
  late ProviderContainer container;
  const a = VaultRef('s', 'a.satchel');
  const b = VaultRef('s', 'b.satchel');

  ProviderContainer create({MemoryPinStore? pinStore}) {
    final container = ProviderContainer(
      overrides: [
        ...storageOverrides(
          platform: StoragePlatform.android,
          store: MemoryStorageConfigStore([
            directoryConfig('s', '/s'),
            directoryConfig('t', '/t'),
          ]),
          pins: pinStore,
        ),
        storageProvidersProvider.overrideWith((ref) async => [storage, other]),
        appClockProvider.overrideWithValue(Clock.fixed(DateTime.utc(2026))),
        vaultCryptoProvider.overrideWithValue(
          const VaultCrypto(memoryKiB: 64, pinMemoryKiB: 64, pinIterations: 1),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() async {
    storage = FakeStorageProvider(id: 's');
    other = FakeStorageProvider(id: 't');
    await putVault(storage, a.path, 'password-a');
    await putVault(storage, b.path, 'password-b');
    pins = MemoryPinStore();
    container = create(pinStore: pins);
  });

  UnlockedVaults vaults() => container.read(unlockedVaultsProvider.notifier);
  PinUnlock pinUnlock() => container.read(pinUnlockProvider.notifier);
  Future<Set<VaultRef>> enabled() => container.read(pinUnlockProvider.future);

  Future<void> enable(VaultRef vault, String pin) async {
    await vaults().unlock(vault, 'password-${vault.path[0]}');
    await pinUnlock().enable(vault, pin);
  }

  test('is not offered without a PIN store', () async {
    container = create();

    expect(await enabled(), isEmpty);
    await vaults().unlock(a, 'password-a');
    expect(pinUnlock().enable(a, '123456'), throwsUnsupportedError);
  });

  test('enable stores a wrapped key, never the PIN', () async {
    await enable(a, '123456');

    expect(await enabled(), {a});
    final record = pins.records[a]!;
    expect(record.failedAttempts, 0);
    expect(record.wrappedKey, isNot(contains('123456')));
    expect(record.wrappedKey, isNot(contains('password-a')));
  });

  test('enable needs an unlocked file and a valid PIN', () async {
    expect(pinUnlock().enable(a, '123456'), throwsStateError);
    await vaults().unlock(a, 'password-a');
    expect(pinUnlock().enable(a, '1234'), throwsArgumentError);
    expect(pins.records, isEmpty);
  });

  test('unlock with the PIN opens the locked file', () async {
    await enable(a, '123456');
    final payload = container.read(unlockedVaultsProvider)[a]!.payload;
    vaults().lock(a);

    await pinUnlock().unlock(a, '123456');

    final unlocked = container.read(unlockedVaultsProvider)[a]!;
    expect(unlocked.payload.toJson(), payload.toJson());
    expect(unlocked.revision, storage.blobs[a.path]!.revision);
    // The unwrapped key saves like a password-derived one.
    await vaults().save(a, (p) => p.withName('Renamed', clock: clock));
    vaults().lock(a);
    await vaults().unlock(a, 'password-a');
  });

  test('a wrong PIN is counted, and a right one resets the count', () async {
    await enable(a, '123456');
    vaults().lock(a);

    await expectLater(
      pinUnlock().unlock(a, '654321'),
      throwsA(isA<WrongPinException>().having((e) => e.attemptsLeft, '', 4)),
    );
    expect(pins.records[a]!.failedAttempts, 1);
    expect(container.read(unlockedVaultsProvider), isEmpty);

    await pinUnlock().unlock(a, '123456');
    expect(pins.records[a]!.failedAttempts, 0);
  });

  test('the PIN is removed after $maxPinAttempts wrong attempts', () async {
    await enable(a, '123456');
    vaults().lock(a);

    for (var left = maxPinAttempts - 1; left > 0; left--) {
      await expectLater(
        pinUnlock().unlock(a, '000000'),
        throwsA(
          isA<WrongPinException>().having((e) => e.attemptsLeft, '', left),
        ),
      );
    }
    await expectLater(
      pinUnlock().unlock(a, '000000'),
      throwsA(
        isA<PinRemovedException>().having(
          (e) => e.reason,
          '',
          PinRemovedReason.tooManyAttempts,
        ),
      ),
    );

    expect(pins.records, isEmpty);
    expect(await enabled(), isEmpty);
    expect(
      pinUnlock().unlock(a, '123456'),
      throwsA(isA<PinRemovedException>()),
    );
  });

  test('an attempt is counted before the PIN is checked', () async {
    await enable(a, '123456');
    vaults().lock(a);
    pins.writeError = Exception('disk full');

    await expectLater(pinUnlock().unlock(a, '123456'), throwsException);

    expect(container.read(unlockedVaultsProvider), isEmpty);
  });

  test('a password changed elsewhere removes the PIN', () async {
    await enable(a, '123456');
    vaults().lock(a);
    storage.blobs.remove(a.path);
    await putVault(storage, a.path, 'new-password');

    await expectLater(
      pinUnlock().unlock(a, '123456'),
      throwsA(
        isA<PinRemovedException>().having(
          (e) => e.reason,
          '',
          PinRemovedReason.passwordChanged,
        ),
      ),
    );
    expect(pins.records, isEmpty);
  });

  test('disable removes the PIN', () async {
    await enable(a, '123456');

    await pinUnlock().disable(a);

    expect(pins.records, isEmpty);
    expect(await enabled(), isEmpty);
  });

  test('changing the password removes the PIN', () async {
    await enable(a, '123456');

    await vaults().changePassword(
      a,
      currentPassword: 'password-a',
      newPassword: 'password-new',
    );

    expect(pins.records, isEmpty);
    expect(await enabled(), isEmpty);
  });

  test('renaming keeps the PIN', () async {
    await enable(a, '123456');

    await vaults().rename(a, 'Renamed');

    const renamed = VaultRef('s', 'Renamed.satchel');
    expect(pins.records.keys, [renamed]);
    expect(await enabled(), {renamed});
    vaults().lock(renamed);
    await pinUnlock().unlock(renamed, '123456');
  });

  test('deleting the file removes its PIN', () async {
    await enable(a, '123456');
    await enable(b, '654321');
    final files = container.read(vaultFilesProvider('s').notifier);
    container.listen(vaultFilesProvider('s'), (_, _) {});
    await container.read(vaultFilesProvider('s').future);

    await files.delete(
      VaultFile(
        storageId: 's',
        path: a.path,
        revision: storage.blobs[a.path]!.revision,
      ),
    );

    expect(pins.records.keys, [b]);
    expect(await enabled(), {b});
  });

  test('replacing a file by a copy removes its PIN', () async {
    await putVault(other, a.path, 'other');
    const target = VaultRef('t', 'a.satchel');
    await vaults().unlock(target, 'other');
    await pinUnlock().enable(target, '123456');

    await vaults().copyFile(
      VaultFile(
        storageId: 's',
        path: a.path,
        revision: storage.blobs[a.path]!.revision,
      ),
      't',
      replacing: VaultFile(
        storageId: 't',
        path: a.path,
        revision: other.blobs[a.path]!.revision,
      ),
    );

    expect(pins.records, isEmpty);
  });

  test('removing a storage removes the PINs of its files', () async {
    await enable(a, '123456');
    pins.records[const VaultRef('t', 'x.satchel')] = pins.records[a]!;

    await container.read(storageConfigsProvider.notifier).remove('s');

    expect(await enabled(), {const VaultRef('t', 'x.satchel')});
    expect(pins.records.keys, [const VaultRef('t', 'x.satchel')]);
  });
}
