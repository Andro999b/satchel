import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../accounts/account_management_dialog.dart';
import '../accounts/google_accounts.dart';
import '../export/export_secrets.dart';
import '../import/import_secrets.dart';
import '../navigation/app_location.dart';
import '../widgets/message_view.dart';
import 'change_vault_password.dart';
import 'copy_vault_file.dart';
import 'delete_vault_file.dart';
import 'new_vault_file_dialog.dart';
import 'rename_vault_file.dart';
import 'vault_file.dart';
import 'vault_files_providers.dart';
import '../l10n/l10n.dart';
import '../storage/storage_display.dart';
import '../storage/storage_providers.dart';
import '../vault/unlocked_vaults.dart';

/// Vault files in one storage.
class FilesPane extends ConsumerWidget {
  const FilesPane({super.key, required this.storageId, this.onBack});

  final String storageId;

  /// Shows a back button when set, for layouts where the storages pane is
  /// hidden.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = vaultFilesProvider(storageId);
    final l10n = context.l10n;
    final config = ref
        .watch(storageConfigsProvider)
        .value
        ?.where((config) => config.id == storageId)
        .firstOrNull;
    final files = ref.watch(provider);
    final openPath = ref.watch(
      currentLocationProvider.select(
        (l) => l.storageId == storageId ? l.filePath : null,
      ),
    );

    return Scaffold(
      floatingActionButton: files.hasValue
          ? FloatingActionButton.extended(
              onPressed: () => _newFile(context, ref),
              icon: const Icon(Icons.add),
              label: Text(l10n.newFile),
            )
          : null,
      appBar: AppBar(
        leading: onBack == null ? null : BackButton(onPressed: onBack),
        automaticallyImplyLeading: false,
        title: Text(config == null ? '' : storageName(l10n, config)),
        actions: [
          IconButton(
            tooltip: l10n.refreshTooltip,
            icon: const Icon(Icons.refresh),
            onPressed: files.isLoading ? null : () => ref.invalidate(provider),
          ),
        ],
      ),
      body: files.when(
        data: (files) => RefreshIndicator(
          onRefresh: () => ref.refresh(provider.future),
          child: files.isEmpty
              ? MessageView(
                  icon: Icons.inventory_2_outlined,
                  text: l10n.noVaultFiles,
                  scrollable: true,
                )
              : ListView(
                  children: [
                    for (final file in files)
                      _VaultFileTile(
                        file: file,
                        open: file.path == openPath,
                        storageName: config == null
                            ? null
                            : storageName(l10n, config),
                      ),
                  ],
                ),
        ),
        error: (error, _) {
          // A Drive storage whose Google account isn't linked anymore.
          final accountMissing =
              error is StorageAuthRequiredException &&
              !(ref
                      .watch(googleAccountsProvider)
                      .value
                      ?.any((account) => account.id == config?.accountId) ??
                  false);
          return MessageView(
            icon: error is StorageAuthRequiredException
                ? Icons.account_circle_outlined
                : Icons.error_outline,
            text: switch (error) {
              UnknownStorageException() => l10n.storageGone,
              StorageAuthRequiredException() when accountMissing =>
                l10n.driveAccountMissing,
              StorageAuthRequiredException() => l10n.driveSignInRequired,
              _ => l10n.storageReadError,
            },
            detail: switch (error) {
              StorageBackendException(:final message) => message,
              _ => null,
            },
            action: switch (error) {
              UnknownStorageException() => null,
              StorageAuthRequiredException() when accountMissing =>
                FilledButton.tonal(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const AccountManagementDialog(),
                  ),
                  child: Text(l10n.openAccounts),
                ),
              // Listing again signs in, from this button press.
              StorageAuthRequiredException() => FilledButton.tonal(
                onPressed: () => ref.invalidate(provider),
                child: Text(l10n.driveSignIn),
              ),
              _ => FilledButton.tonal(
                onPressed: () => ref.invalidate(provider),
                child: Text(l10n.retry),
              ),
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }

  Future<void> _newFile(BuildContext context, WidgetRef ref) async {
    final file = await showDialog<VaultFile>(
      context: context,
      barrierDismissible: false,
      builder: (_) => NewVaultFileDialog(storageId: storageId),
    );
    if (file != null) {
      ref.read(currentLocationProvider.notifier).openFile(storageId, file.path);
    }
  }
}

class _VaultFileTile extends ConsumerWidget {
  const _VaultFileTile({
    required this.file,
    required this.open,
    required this.storageName,
  });

  final VaultFile file;
  final bool open;

  /// Shown when confirming a delete; `null` while the storage is unknown.
  final String? storageName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final sessionRevision = ref.watch(
      unlockedVaultsProvider.select(
        (vaults) => vaults[VaultRef(file.storageId, file.path)]?.revision,
      ),
    );
    final unlocked = sessionRevision != null;
    // Act on exactly the version the user unlocked, or else the listed one.
    final current = unlocked
        ? VaultFile(
            storageId: file.storageId,
            path: file.path,
            revision: sessionRevision,
          )
        : file;
    final storageName = this.storageName;
    final status = unlocked ? l10n.fileUnlocked : l10n.fileLocked;
    return ListTile(
      key: ValueKey(file.path),
      selected: open,
      leading: Tooltip(
        message: status,
        child: Icon(
          unlocked ? Icons.lock_open : Icons.lock_outline,
          semanticLabel: status,
        ),
      ),
      title: Text(file.name),
      trailing: Focus(
        parentNode: FocusScope.of(context),
        child: MenuAnchor(
          menuChildren: [
            MenuItemButton(
              leadingIcon: const Icon(Icons.edit_outlined),
              // The name is also stored inside the encrypted file.
              onPressed: unlocked
                  ? () => renameVaultFile(context, ref, current)
                  : null,
              child: Text(l10n.renameFile),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.password),
              onPressed: () => changeVaultPassword(context, current),
              child: Text(l10n.changePassword),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.file_copy_outlined),
              onPressed: () => copyVaultFile(context, ref, current),
              child: Text(l10n.copyFile),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.file_upload_outlined),
              onPressed: unlocked
                  ? () => importSecrets(
                      context,
                      ref,
                      VaultRef(file.storageId, file.path),
                    )
                  : null,
              child: Text(l10n.importFile),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.file_download_outlined),
              onPressed: unlocked ? () => _exportAll(context, ref) : null,
              child: Text(l10n.exportFile),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.delete_outline),
              onPressed: storageName == null
                  ? null
                  : () => deleteVaultFile(
                      context,
                      ref,
                      current,
                      storageName: storageName,
                    ),
              child: Text(l10n.deleteFile),
            ),
          ],
          builder: (context, controller, _) => IconButton(
            tooltip: l10n.fileActionsTooltip,
            icon: const Icon(Icons.more_vert),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
        ),
      ),
      onTap: () => ref
          .read(currentLocationProvider.notifier)
          .openFile(file.storageId, file.path),
    );
  }

  Future<void> _exportAll(BuildContext context, WidgetRef ref) async {
    final vault = VaultRef(file.storageId, file.path);
    final payload = ref.read(unlockedVaultsProvider)[vault]?.payload;
    if (payload == null) return;
    await exportSecrets(context, vault, count: payload.secrets.length);
  }
}
