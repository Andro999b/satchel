import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../files/vault_file.dart';
import '../files/vault_files_providers.dart';
import '../import/import_secrets.dart';
import '../l10n/l10n.dart';
import '../storage/storage_display.dart';
import '../storage/storage_providers.dart';
import '../vault/unlocked_vaults.dart';
import '../widgets/message_view.dart';

/// Copies the secrets [secretIds] of the unlocked vault [source] to a file
/// the user picks, unlocking it first if needed. Conflicts are reviewed as
/// in an import, and nothing is written until the user confirms. Returns
/// whether the copy was saved.
Future<bool> copySecrets(
  BuildContext context,
  WidgetRef ref,
  VaultRef source,
  Set<String> secretIds,
) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final vaults = ref.read(unlockedVaultsProvider.notifier);

  final target = await showDialog<VaultRef>(
    context: context,
    builder: (_) => CopySecretsDialog(source: source, count: secretIds.length),
  );
  if (target == null || !context.mounted) return false;

  if (!ref.read(unlockedVaultsProvider).containsKey(target)) {
    final unlocked = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UnlockVaultDialog(vault: target),
    );
    if (unlocked != true || !context.mounted) return false;
  }

  final MergePlan plan;
  try {
    plan = vaults.planCopy(source, target, secretIds);
  } on StateError {
    // One of the files was locked meanwhile.
    return false;
  }
  final name = vaultNameFromPath(target.path);
  final copied = await showDialog<int>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ImportReviewDialog(
      vault: target,
      fileName: name,
      plan: plan,
      kind: MergeReviewKind.copy,
    ),
  );
  if (copied == null) return false;
  messenger.showSnackBar(
    SnackBar(content: Text(l10n.secretsCopied(copied, name))),
  );
  return true;
}

/// Picks the vault file to copy [count] secrets of [source] to: first a
/// storage, then one of its files. Pops its [VaultRef].
class CopySecretsDialog extends ConsumerStatefulWidget {
  const CopySecretsDialog({
    super.key,
    required this.source,
    required this.count,
  });

  final VaultRef source;
  final int count;

  @override
  ConsumerState<CopySecretsDialog> createState() => _CopySecretsDialogState();
}

class _CopySecretsDialogState extends ConsumerState<CopySecretsDialog> {
  StorageConfig? _storage;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final storage = _storage;
    return AlertDialog(
      title: Text(l10n.copySecretsTitle(widget.count)),
      contentPadding: const EdgeInsets.symmetric(vertical: 16),
      content: SizedBox(
        width: 400,
        child: storage == null ? _storages(context) : _files(context, storage),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
      ],
    );
  }

  Widget _storages(BuildContext context) {
    final configs =
        ref.watch(storageConfigsProvider).value ?? const <StorageConfig>[];
    return ListView(
      shrinkWrap: true,
      children: [
        for (final config in configs)
          ListTile(
            key: ValueKey(config.id),
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: Icon(storageIcon(config.kind)),
            title: Text(storageName(context.l10n, config)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => setState(() => _storage = config),
          ),
      ],
    );
  }

  Widget _files(BuildContext context, StorageConfig storage) {
    final l10n = context.l10n;
    final provider = vaultFilesProvider(storage.id);
    final files = ref.watch(provider);
    final unlocked = ref.watch(unlockedVaultsProvider).keys.toSet();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: BackButton(onPressed: () => setState(() => _storage = null)),
          title: Text(storageName(l10n, storage)),
        ),
        const Divider(height: 1),
        Flexible(
          child: files.when(
            data: (files) {
              final targets = [
                for (final file in files)
                  if (VaultRef(file.storageId, file.path) != widget.source)
                    file,
              ];
              if (targets.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  child: Text(l10n.copySecretsNoFiles),
                );
              }
              return ListView(
                shrinkWrap: true,
                children: [
                  for (final file in targets)
                    _fileTile(
                      context,
                      file,
                      unlocked.contains(VaultRef(file.storageId, file.path)),
                    ),
                ],
              );
            },
            error: (_, _) => MessageView(
              icon: Icons.error_outline,
              text: l10n.storageReadError,
              action: FilledButton.tonal(
                // Listing again also signs in to Drive, from this press.
                onPressed: () => ref.invalidate(provider),
                child: Text(l10n.retry),
              ),
            ),
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
        ),
      ],
    );
  }

  Widget _fileTile(BuildContext context, VaultFile file, bool unlocked) {
    final l10n = context.l10n;
    final status = unlocked ? l10n.fileUnlocked : l10n.fileLocked;
    return ListTile(
      key: ValueKey(file.path),
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      leading: Tooltip(
        message: status,
        child: Icon(
          unlocked ? Icons.lock_open : Icons.lock_outline,
          semanticLabel: status,
        ),
      ),
      title: Text(file.name),
      onTap: () => Navigator.pop(context, VaultRef(file.storageId, file.path)),
    );
  }
}

/// Why unlocking failed, localized in `build`.
enum _UnlockError {
  wrongPassword,
  newerVersion,
  invalidFile,
  readFailed,
  signInRequired,
}

/// Asks for the password of the locked vault [vault] and unlocks it. Pops
/// `true` once it is unlocked.
class UnlockVaultDialog extends ConsumerStatefulWidget {
  const UnlockVaultDialog({super.key, required this.vault});

  final VaultRef vault;

  @override
  ConsumerState<UnlockVaultDialog> createState() => _UnlockVaultDialogState();
}

class _UnlockVaultDialogState extends ConsumerState<UnlockVaultDialog> {
  final _password = TextEditingController();
  final _focus = FocusNode();
  var _busy = false;
  _UnlockError? _error;

  @override
  void dispose() {
    _password
      ..clear()
      ..dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_busy || _password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    _UnlockError error;
    try {
      await ref
          .read(unlockedVaultsProvider.notifier)
          .unlock(widget.vault, _password.text);
      if (mounted) Navigator.pop(context, true);
      return;
    } on VaultAuthenticationException {
      error = _UnlockError.wrongPassword;
    } on UnsupportedVaultVersionException {
      error = _UnlockError.newerVersion;
    } on VaultFormatException {
      error = _UnlockError.invalidFile;
    } on StorageAuthRequiredException {
      error = _UnlockError.signInRequired;
    } catch (_) {
      error = _UnlockError.readFailed;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    if (error == _UnlockError.wrongPassword) {
      // Select the password for retyping once the field is enabled again.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focus.requestFocus();
        _password.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _password.text.length,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(l10n.unlockFileTitle(vaultNameFromPath(widget.vault.path))),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.lockedFileMessage),
              const SizedBox(height: 16),
              TextField(
                key: const Key('unlockTargetPassword'),
                controller: _password,
                focusNode: _focus,
                enabled: !_busy,
                autofocus: true,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: l10n.passwordLabel,
                  errorText: switch (_error) {
                    null => null,
                    _UnlockError.wrongPassword => l10n.unlockWrongPassword,
                    _UnlockError.newerVersion => l10n.unlockNewerVersion,
                    _UnlockError.invalidFile => l10n.unlockInvalidFile,
                    _UnlockError.readFailed => l10n.unlockReadError,
                    _UnlockError.signInRequired => l10n.unlockSignInRequired,
                  },
                  errorMaxLines: 3,
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _unlock(),
              ),
              if (_busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(l10n.unlocking, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: _busy || _password.text.isEmpty ? null : _unlock,
            child: Text(l10n.unlock),
          ),
        ],
      ),
    );
  }
}
