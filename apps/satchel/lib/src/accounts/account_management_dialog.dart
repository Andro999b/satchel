import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../l10n/l10n.dart';
import '../storage/storage_providers.dart';
import '../widgets/destructive_dialog.dart';
import 'google_account_avatar.dart';
import 'google_accounts.dart';

/// Outcome of the last add or remove, shown below the list.
enum _Notice { added, reconnected, driveDenied, signInFailed, removeFailed }

/// Lists the linked Google accounts and lets the user add and remove them.
class AccountManagementDialog extends ConsumerStatefulWidget {
  const AccountManagementDialog({super.key});

  @override
  ConsumerState<AccountManagementDialog> createState() =>
      _AccountManagementDialogState();
}

class _AccountManagementDialogState
    extends ConsumerState<AccountManagementDialog> {
  GoogleAccounts? _signingIn;
  String? _removingId;
  _Notice? _notice;
  String _noticeEmail = '';

  bool get _busy => _signingIn != null || _removingId != null;

  @override
  void dispose() {
    // Stop waiting for the browser once the dialog is gone.
    _signingIn?.cancelAdd();
    super.dispose();
  }

  Future<void> _add() async {
    final accounts = ref.read(googleAccountsProvider.notifier);
    setState(() {
      _signingIn = accounts;
      _notice = null;
    });
    _Notice? notice;
    var email = '';
    try {
      final linked = await accounts.add();
      if (linked != null) {
        email = linked.account.email;
        notice = linked.reconnected ? _Notice.reconnected : _Notice.added;
      }
    } on GoogleDriveAccessDeniedException {
      notice = _Notice.driveDenied;
    } catch (_) {
      notice = _Notice.signInFailed;
    }
    if (!mounted) return;
    setState(() {
      _signingIn = null;
      _notice = notice;
      _noticeEmail = email;
    });
  }

  Future<void> _remove(GoogleAccount account) async {
    final l10n = context.l10n;
    List<StorageConfig> configs;
    try {
      configs = await ref.read(storageConfigsProvider.future);
    } catch (_) {
      configs = const [];
    }
    if (!mounted) return;
    final storages = configs
        .where((config) => config.accountId == account.id)
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => DestructiveDialog(
        title: l10n.removeGoogleAccountTitle(account.email),
        message: [
          l10n.removeGoogleAccountMessage,
          if (storages > 0) l10n.removeGoogleAccountStorages(storages),
        ].join('\n\n'),
        confirmLabel: l10n.removeGoogleAccountConfirm,
        icon: Icons.person_remove_outlined,
      ),
    );
    if (!(confirmed ?? false) || !mounted) return;
    setState(() {
      _removingId = account.id;
      _notice = null;
    });
    _Notice? notice;
    try {
      await ref.read(googleAccountsProvider.notifier).remove(account.id);
    } catch (_) {
      notice = _Notice.removeFailed;
    }
    if (!mounted) return;
    setState(() {
      _removingId = null;
      _notice = notice;
      _noticeEmail = account.email;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final configured = ref.watch(googleAuthProvider) != null;
    final accounts = ref.watch(googleAccountsProvider);
    final inBrowser = switch (ref.watch(storagePlatformProvider)) {
      StoragePlatform.linux || StoragePlatform.windows => true,
      _ => false,
    };
    final notice = _notice;

    return AlertDialog(
      title: Text(l10n.googleAccountsTitle),
      scrollable: true,
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            accounts.when(
              data: (accounts) => accounts.isEmpty
                  ? const _NoAccounts()
                  : Column(
                      children: [
                        for (final account in accounts)
                          _AccountTile(
                            account: account,
                            removing: _removingId == account.id,
                            onRemove: _busy ? null : () => _remove(account),
                          ),
                      ],
                    ),
              error: (_, _) => Text(l10n.googleAccountsLoadError),
              loading: () => const Center(child: CircularProgressIndicator()),
            ),
            if (!configured) ...[
              const SizedBox(height: 16),
              Text(
                l10n.googleSignInNotConfigured,
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
            if (_signingIn != null) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(
                inBrowser ? l10n.googleSignInInBrowser : l10n.googleSigningIn,
              ),
            ],
            if (notice != null) ...[
              const SizedBox(height: 16),
              Text(
                switch (notice) {
                  _Notice.added => l10n.googleAccountAdded(_noticeEmail),
                  _Notice.reconnected => l10n.googleAccountReconnected(
                    _noticeEmail,
                  ),
                  _Notice.driveDenied => l10n.googleDriveAccessDenied,
                  _Notice.signInFailed => l10n.googleSignInFailed,
                  _Notice.removeFailed => l10n.removeGoogleAccountError,
                },
                style: switch (notice) {
                  _Notice.added || _Notice.reconnected => null,
                  _ => TextStyle(color: theme.colorScheme.error),
                },
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_signingIn != null && inBrowser)
          TextButton(
            onPressed: () => _signingIn?.cancelAdd(),
            child: Text(l10n.cancel),
          )
        else
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.close),
          ),
        FilledButton.icon(
          onPressed: configured && !_busy ? _add : null,
          icon: const Icon(Icons.person_add_alt_1_outlined),
          label: Text(l10n.addGoogleAccount),
        ),
      ],
    );
  }
}

class _NoAccounts extends StatelessWidget {
  const _NoAccounts();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Icon(
          Icons.account_circle_outlined,
          size: 48,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          context.l10n.noGoogleAccounts,
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(context.l10n.googleAccountsHint, textAlign: TextAlign.center),
      ],
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.removing,
    required this.onRemove,
  });

  final GoogleAccount account;
  final bool removing;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final GoogleAccount(:displayName, :email) = account;
    final name = displayName.isEmpty ? email : displayName;
    return ListTile(
      key: ValueKey(account.id),
      contentPadding: EdgeInsets.zero,
      leading: GoogleAccountAvatar(account: account),
      title: Text(name),
      subtitle: displayName.isEmpty ? null : Text(email),
      trailing: removing
          ? const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              tooltip: context.l10n.removeGoogleAccountTooltip,
              icon: const Icon(Icons.person_remove_outlined),
              onPressed: onRemove,
            ),
    );
  }
}
