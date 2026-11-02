import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/navigation/app_location.dart';
import 'package:satchel/src/storage/storage_providers.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../fakes.dart';

void main() {
  late MemoryStorageConfigStore store;
  late ProviderContainer container;

  setUp(() {
    store = MemoryStorageConfigStore([
      directoryConfig('a', '/a'),
      directoryConfig('b', '/b'),
    ]);
    container = ProviderContainer(
      overrides: storageOverrides(
        platform: StoragePlatform.linux,
        store: store,
      ),
    );
    addTearDown(container.dispose);
  });

  CurrentLocation notifier() =>
      container.read(currentLocationProvider.notifier);
  AppLocation location() => container.read(currentLocationProvider);

  test('starts at the storages level', () {
    expect(location(), const AppLocation());
    expect(location().level, AppLevel.storages);
  });

  test('opening goes down the hierarchy and up goes back', () {
    notifier().openStorage('a');
    expect(location().level, AppLevel.files);

    notifier().openFile('a', 'v.satchel');
    expect(location().level, AppLevel.secrets);

    notifier().openSecret('s1');
    expect(
      location(),
      const AppLocation(storageId: 'a', filePath: 'v.satchel', secretId: 's1'),
    );
    expect(location().level, AppLevel.secret);

    notifier().up();
    expect(
      location(),
      const AppLocation(storageId: 'a', filePath: 'v.satchel'),
    );
    notifier().up();
    expect(location(), const AppLocation(storageId: 'a'));
    notifier().up();
    expect(location(), const AppLocation());
    notifier().up();
    expect(location(), const AppLocation());
  });

  test('opening another storage closes the open file', () {
    notifier()
      ..openFile('a', 'v.satchel')
      ..openStorage('b');

    expect(location(), const AppLocation(storageId: 'b'));
  });

  test('re-opening the open storage keeps the open file', () {
    notifier()
      ..openFile('a', 'v.satchel')
      ..openStorage('a');

    expect(location().filePath, 'v.satchel');
  });

  test('closeFile closes only the open file', () {
    notifier().openFile('a', 'v.satchel');

    notifier().closeFile('a', 'other.satchel');
    expect(location().filePath, 'v.satchel');
    notifier().closeFile('b', 'v.satchel');
    expect(location().filePath, 'v.satchel');

    notifier().closeFile('a', 'v.satchel');
    expect(location(), const AppLocation(storageId: 'a'));
  });

  test('a secret can only be opened inside a file', () {
    notifier().openStorage('a');

    expect(() => notifier().openSecret('s'), throwsStateError);
  });

  test('removing the open storage closes it', () async {
    await container.read(storageConfigsProvider.future);
    notifier().openFile('a', 'v.satchel');

    await container.read(storageConfigsProvider.notifier).remove('b');
    expect(location().storageId, 'a');

    await container.read(storageConfigsProvider.notifier).remove('a');
    expect(location(), const AppLocation());
  });
}
