import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../l10n/l10n.dart';
import '../pin/pin_unlock.dart';
import '../vault/unlocked_vaults.dart';
import 'vault_file.dart';
import 'vault_file_fields.dart';

/// Asks for the current and a new password of [file] and re-encrypts it.
/// Reports success in a snack bar, which says if the file's PIN was removed.
Future<void> changeVaultPassword(BuildContext context, VaultFile file) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  final hadPin = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(quickUnlockProvider(VaultRef(file.storageId, file.path))).hasPin;
  final changed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ChangeVaultPasswordDialog(file: file),
  );
  if (changed ?? false) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          hadPin
              ? l10n.passwordChangedPinRemoved(file.name)
              : l10n.passwordChanged(file.name),
        ),
      ),
    );
  }
}

/// Changes the password of a vault file, locked or not. Pops `true` once
/// changed.
class ChangeVaultPasswordDialog extends ConsumerStatefulWidget {
  const ChangeVaultPasswordDialog({super.key, required this.file});

  final VaultFile file;

  @override
  ConsumerState<ChangeVaultPasswordDialog> createState() =>
      _ChangeVaultPasswordDialogState();
}

enum _ChangeError { wrongPassword, conflict, failed }

class _ChangeVaultPasswordDialogState
    extends ConsumerState<ChangeVaultPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _currentFocus = FocusNode();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  var _busy = false;
  _ChangeError? _error;

  @override
  void dispose() {
    for (final controller in [_current, _password, _confirm]) {
      controller
        ..clear()
        ..dispose();
    }
    _currentFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    _ChangeError? error;
    try {
      await ref
          .read(unlockedVaultsProvider.notifier)
          .changePassword(
            VaultRef(widget.file.storageId, widget.file.path),
            currentPassword: _current.text,
            newPassword: _password.text,
          );
    } on VaultAuthenticationException {
      error = _ChangeError.wrongPassword;
    } on StorageConflictException {
      error = _ChangeError.conflict;
    } catch (_) {
      error = _ChangeError.failed;
    }
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
    if (error == _ChangeError.wrongPassword) {
      // Select the password for retyping once the field is enabled again.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _currentFocus.requestFocus();
        _current.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _current.text.length,
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
        title: Text(l10n.changePasswordTitle(widget.file.name)),
        content: SizedBox(
          width: 360,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const Key('currentPassword'),
                  controller: _current,
                  focusNode: _currentFocus,
                  enabled: !_busy,
                  autofocus: true,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l10n.currentPasswordLabel,
                  ),
                  validator: (v) =>
                      (v ?? '').isEmpty ? l10n.passwordRequired : null,
                ),
                const SizedBox(height: 8),
                NewPasswordFields(
                  password: _password,
                  confirm: _confirm,
                  label: l10n.newPasswordLabel,
                  enabled: !_busy,
                  onSubmitted: _submit,
                ),
                if (_error case final error?) ...[
                  const SizedBox(height: 16),
                  Text(switch (error) {
                    _ChangeError.wrongPassword => l10n.unlockWrongPassword,
                    _ChangeError.conflict => l10n.changePasswordConflict,
                    _ChangeError.failed => l10n.changePasswordError,
                  }, style: TextStyle(color: theme.colorScheme.error)),
                ],
                if (_busy) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(l10n.encrypting, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(l10n.changePassword),
          ),
        ],
      ),
    );
  }
}
