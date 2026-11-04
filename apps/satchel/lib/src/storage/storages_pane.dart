import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../accounts/account_management_dialog.dart';
import '../accounts/google_accounts.dart';
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
      appBar: AppBar(
        title: Text(l10n.appTitle),
        actions: [
          IconButton(
            tooltip: l10n.manageAccountsTooltip,
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => const AccountManagementDialog(),
            ),
          ),
        ],
      ),
      floatingActionButton: canAdd ? const _AddStorageButton() : null,
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

/// "Add storage" button: adds the only addable kind directly, or offers a
/// menu of the kinds.
class _AddStorageButton extends ConsumerWidget {
  const _AddStorageButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final kinds = ref.watch(addableStorageKindsProvider);
    if (kinds case [final only]) {
      return FloatingActionButton.extended(
        onPressed: () => addStorage(context, ref, only),
        icon: const Icon(Icons.add),
        label: Text(l10n.addStorage),
      );
    }
    return MenuAnchor(
      menuChildren: [
        for (final kind in kinds)
          MenuItemButton(
            leadingIcon: Icon(storageIcon(kind)),
            onPressed: () => addStorage(context, ref, kind),
            child: Text(storageKindName(l10n, kind)),
          ),
      ],
      builder: (context, controller, _) => FloatingActionButton.extended(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.add),
        label: Text(l10n.addStorage),
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
    final accountEmail = config.accountId == null
        ? null
        : ref
              .watch(googleAccountsProvider)
              .value
              ?.where((account) => account.id == config.accountId)
              .firstOrNull
              ?.email;
    final location = storageLocationText(config, accountEmail: accountEmail);
    return ListTile(
      key: ValueKey(config.id),
      selected: open,
      leading: Icon(storageIcon(config.kind)),
      title: Text(storageName(context.l10n, config)),
      subtitle: location == null ? null : Text(location),
      onTap: () =>
          ref.read(currentLocationProvider.notifier).openStorage(config.id),
      trailing: config.kind.userAddable
          ? Focus(
              parentNode: FocusScope.of(context),
              child: MenuAnchor(
                menuChildren: [
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.edit_outlined),
                    onPressed: () => renameStorage(context, ref, config),
                    child: Text(context.l10n.renameStorage),
                  ),
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.delete_outline),
                    onPressed: () => removeStorage(context, ref, config),
                    child: Text(context.l10n.deleteStorage),
                  ),
                ],
                builder: (context, controller, _) => IconButton(
                  tooltip: context.l10n.storageActionsTooltip,
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                ),
              ),
            )
          : const Icon(Icons.chevron_right),
    );
  }
}
