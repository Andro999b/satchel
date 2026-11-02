import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../navigation/app_location.dart';
import 'storage_actions.dart';
import 'storage_display.dart';
import 'storage_providers.dart';
import '../l10n/l10n.dart';

/// Configured storages. The top level of the app.
class StoragesPane extends ConsumerWidget {
  const StoragesPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configs = ref.watch(storageConfigsProvider);
    final canAdd = ref.watch(addableStorageKindsProvider).isNotEmpty;
    final l10n = context.l10n;
    final openId = ref.watch(
      currentLocationProvider.select((l) => l.storageId),
    );

    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle)),
      floatingActionButton: canAdd
          ? FloatingActionButton.extended(
              onPressed: () => addStorage(context, ref),
              icon: const Icon(Icons.add),
              label: Text(l10n.addStorage),
            )
          : null,
      body: configs.when(
        data: (configs) => configs.isEmpty
            ? Center(child: Text(l10n.noStorages))
            : ListView(
                children: [
                  for (final config in configs)
                    _StorageTile(config: config, open: config.id == openId),
                ],
              ),
        error: (_, _) => Center(child: Text(l10n.storagesLoadError)),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _StorageTile extends ConsumerWidget {
  const _StorageTile({required this.config, required this.open});

  final StorageConfig config;
  final bool open;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = config.location;
    return ListTile(
      key: ValueKey(config.id),
      selected: open,
      leading: Icon(storageIcon(config.kind)),
      title: Text(storageName(context.l10n, config)),
      subtitle: location == null ? null : Text(describeLocation(location)),
      onTap: () =>
          ref.read(currentLocationProvider.notifier).openStorage(config.id),
      trailing: config.kind.userAddable
          ? IconButton(
              tooltip: context.l10n.removeStorageTooltip,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => removeStorage(context, ref, config),
            )
          : const Icon(Icons.chevron_right),
    );
  }
}
