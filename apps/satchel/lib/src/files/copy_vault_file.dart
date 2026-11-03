import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../accounts/google_accounts.dart';
import '../l10n/l10n.dart';
import '../storage/storage_display.dart';
import '../storage/storage_providers.dart';
import '../vault/unlocked_vaults.dart';
import '../widgets/destructive_dialog.dart';
import 'vault_file.dart';
import 'vault_files_providers.dart';

/// Asks for a storage to copy [file] to and copies it there. If that storage
/// has a file with the same name, asks before replacing it. Reports the
/// outcome in a snack bar.
Future<void> copyVaultFile(
  BuildContext context,
  WidgetRef ref,
  VaultFile file,
) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final vaults = ref.read(unlockedVaultsProvider.notifier);
  String? message;
  VaultFile? existing;
  var targetName = '';

  /// Copies [file] and returns the outcome, or `null` if a file is in the
  /// way (then [existing]).
  Future<String?> copy(String storageId, {VaultFile? replacing}) async {
    try {
      await vaults.copyFile(file, storageId, replacing: replacing);
    } on VaultFileExistsException catch (e) {
      if (replacing != null) return l10n.copyFileConflict(file.name);
      existing = e.existing;
      return null;
    } on StorageConflictException {
      return l10n.copyFileConflict(file.name);
    } catch (_) {
      return l10n.copyFileError(file.name, targetName);
    }
    return l10n.fileCopied(file.name, targetName);
  }

  await showDialog<void>(
    context: context,
    builder: (_) => CopyVaultFileDialog(
      file: file,
      onCopy: (target) async {
        targetName = storageName(l10n, target);
        message = await copy(target.id);
      },
    ),
  );

  if (existing case final existing? when context.mounted) {
    await showDialog<bool>(
      context: context,
      builder: (_) => DestructiveDialog(
        icon: Icons.file_copy_outlined,
        title: l10n.replaceFileTitle(existing.name),
        message: l10n.replaceFileMessage(targetName),
        confirmLabel: l10n.replaceFileConfirm,
        onConfirm: () async =>
            message = await copy(existing.storageId, replacing: existing),
      ),
    );
  }
  if (message case final message?) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Lists the other storages to copy [file] to. Tapping one runs [onCopy]
/// while showing progress, then closes the dialog.
class CopyVaultFileDialog extends ConsumerStatefulWidget {
  const CopyVaultFileDialog({
    super.key,
    required this.file,
    required this.onCopy,
  });

  final VaultFile file;
  final Future<void> Function(StorageConfig target) onCopy;

  @override
  ConsumerState<CopyVaultFileDialog> createState() =>
      _CopyVaultFileDialogState();
}

class _CopyVaultFileDialogState extends ConsumerState<CopyVaultFileDialog> {
  String? _busyId;

  Future<void> _copy(StorageConfig target) async {
    if (_busyId != null) return;
    setState(() => _busyId = target.id);
    try {
      await widget.onCopy(target);
    } finally {
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final busy = _busyId != null;
    final targets = [
      for (final config
          in ref.watch(storageConfigsProvider).value ?? const <StorageConfig>[])
        if (config.id != widget.file.storageId) config,
    ];
    final accounts = ref.watch(googleAccountsProvider).value;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: Text(l10n.copyFileTitle(widget.file.name)),
        contentPadding: const EdgeInsets.symmetric(vertical: 16),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (targets.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(l10n.copyFileNoStorages),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final config in targets)
                        _target(context, config, accounts, busy),
                    ],
                  ),
                ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 16, 24, 0),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
        ],
      ),
    );
  }

  Widget _target(
    BuildContext context,
    StorageConfig config,
    List<GoogleAccount>? accounts,
    bool busy,
  ) {
    final location = storageLocationText(
      config,
      accountEmail: accounts
          ?.where((account) => account.id == config.accountId)
          .firstOrNull
          ?.email,
    );
    return ListTile(
      key: ValueKey(config.id),
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      enabled: !busy,
      selected: _busyId == config.id,
      leading: Icon(storageIcon(config.kind)),
      title: Text(storageName(context.l10n, config)),
      subtitle: location == null ? null : Text(location),
      onTap: () => _copy(config),
    );
  }
}
