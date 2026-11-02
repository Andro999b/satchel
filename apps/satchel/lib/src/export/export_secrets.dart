import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_core/satchel_core.dart';

import '../files/vault_file_fields.dart';
import '../l10n/l10n.dart';
import '../vault/unlocked_vaults.dart';
import 'export_providers.dart';

/// Asks how to export the unlocked vault [vault] (only [secretIds] if given;
/// [count] secrets either way), saves the file where the user chooses, and
/// reports it in a snack bar. Returns whether a file was saved.
Future<bool> exportSecrets(
  BuildContext context,
  VaultRef vault, {
  Set<String>? secretIds,
  required int count,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  final saved = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        ExportSecretsDialog(vault: vault, secretIds: secretIds, count: count),
  );
  if (saved == null) return false;
  messenger.showSnackBar(SnackBar(content: Text(l10n.exported(saved))));
  return true;
}

enum ExportFormat { encrypted, plain }

/// Chooses an encrypted or a plain export and saves it. Pops the saved file
/// name, or `null` if cancelled.
class ExportSecretsDialog extends ConsumerStatefulWidget {
  const ExportSecretsDialog({
    super.key,
    required this.vault,
    required this.secretIds,
    required this.count,
  });

  final VaultRef vault;
  final Set<String>? secretIds;
  final int count;

  @override
  ConsumerState<ExportSecretsDialog> createState() =>
      _ExportSecretsDialogState();
}

class _ExportSecretsDialogState extends ConsumerState<ExportSecretsDialog> {
  static const _vaultMimeType = 'application/octet-stream';

  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  var _format = ExportFormat.encrypted;
  var _newPassword = false;
  var _plainAcknowledged = false;
  var _busy = false;
  var _failed = false;

  String get _name => vaultNameFromPath(widget.vault.path);

  @override
  void dispose() {
    for (final controller in [_password, _confirm]) {
      controller
        ..clear()
        ..dispose();
    }
    super.dispose();
  }

  bool get _canExport =>
      !_busy && (_format == ExportFormat.encrypted || _plainAcknowledged);

  Future<void> _export() async {
    if (!_canExport || !_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    final vaults = ref.read(unlockedVaultsProvider.notifier);
    final plain = _format == ExportFormat.plain;
    String? saved;
    try {
      final Uint8List bytes;
      if (plain) {
        bytes = vaults.exportPlain(widget.vault, secretIds: widget.secretIds);
      } else {
        bytes = await vaults.exportEncrypted(
          widget.vault,
          secretIds: widget.secretIds,
          newPassword: _newPassword ? _password.text : null,
        );
      }
      try {
        saved = await ref
            .read(fileExporterProvider)
            .save(
              plain
                  ? '$_name.${PlainExport.extension}'
                  : vaultPathForName(_name),
              bytes,
              mimeType: plain ? PlainExport.mimeType : _vaultMimeType,
            );
      } finally {
        if (plain) bytes.fillRange(0, bytes.length, 0);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failed = true;
      });
      return;
    }
    if (!mounted) return;
    if (saved == null) {
      // The user closed the save dialog: let them choose again.
      setState(() => _busy = false);
      return;
    }
    Navigator.pop(context, saved);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(l10n.exportTitle(widget.count)),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedButton<ExportFormat>(
                    segments: [
                      ButtonSegment(
                        value: ExportFormat.encrypted,
                        icon: const Icon(Icons.lock_outline),
                        label: Text(l10n.exportEncrypted),
                      ),
                      ButtonSegment(
                        value: ExportFormat.plain,
                        icon: const Icon(Icons.data_object),
                        label: Text(l10n.exportPlain),
                      ),
                    ],
                    selected: {_format},
                    onSelectionChanged: _busy
                        ? null
                        : (selection) =>
                              setState(() => _format = selection.single),
                  ),
                  const SizedBox(height: 16),
                  if (_format == ExportFormat.encrypted) ...[
                    Text(
                      _newPassword
                          ? l10n.exportEncryptedNewPasswordHint
                          : l10n.exportEncryptedHint(_name),
                    ),
                    CheckboxListTile(
                      key: const Key('exportNewPassword'),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(l10n.exportUseNewPassword),
                      value: _newPassword,
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => _newPassword = value!),
                    ),
                    if (_newPassword)
                      NewPasswordFields(
                        password: _password,
                        confirm: _confirm,
                        label: l10n.newPasswordLabel,
                        enabled: !_busy,
                        onSubmitted: _export,
                      ),
                  ] else ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colors.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            color: colors.onErrorContainer,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              l10n.exportPlainWarning,
                              style: TextStyle(color: colors.onErrorContainer),
                            ),
                          ),
                        ],
                      ),
                    ),
                    CheckboxListTile(
                      key: const Key('exportPlainAcknowledged'),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(l10n.exportPlainConfirm),
                      value: _plainAcknowledged,
                      onChanged: _busy
                          ? null
                          : (value) =>
                                setState(() => _plainAcknowledged = value!),
                    ),
                  ],
                  if (_failed) ...[
                    const SizedBox(height: 16),
                    Text(
                      l10n.exportError,
                      style: TextStyle(color: colors.error),
                    ),
                  ],
                  if (_busy) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: _canExport ? _export : null,
            child: Text(l10n.exportConfirm),
          ),
        ],
      ),
    );
  }
}
