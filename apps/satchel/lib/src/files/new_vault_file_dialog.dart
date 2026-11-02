import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'vault_file.dart';
import 'vault_file_fields.dart';
import 'vault_files_providers.dart';
import '../l10n/l10n.dart';

/// Asks for a name and password and creates an empty vault in the storage
/// [storageId]. Pops the created [VaultFile], or `null` if cancelled.
class NewVaultFileDialog extends ConsumerStatefulWidget {
  const NewVaultFileDialog({super.key, required this.storageId});

  final String storageId;

  @override
  ConsumerState<NewVaultFileDialog> createState() => _NewVaultFileDialogState();
}

class _NewVaultFileDialogState extends ConsumerState<NewVaultFileDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  var _busy = false;
  String? _nameTaken;
  var _failed = false;

  @override
  void dispose() {
    for (final controller in [_name, _password, _confirm]) {
      controller
        ..clear()
        ..dispose();
    }
    super.dispose();
  }

  String? _validateName(String? value) {
    final l10n = context.l10n;
    final name = value?.trim() ?? '';
    if (_nameTaken != null && _nameTaken == name) return l10n.vaultNameTaken;
    return vaultNameErrorText(l10n, name);
  }

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    final name = _name.text.trim();
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final file = await ref
          .read(vaultFilesProvider(widget.storageId).notifier)
          .create(name: name, password: _password.text);
      if (mounted) Navigator.pop(context, file);
    } on VaultFileExistsException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _nameTaken = name;
      });
      _formKey.currentState!.validate();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(l10n.newVaultFileTitle),
        content: SizedBox(
          width: 360,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const Key('name'),
                  controller: _name,
                  enabled: !_busy,
                  autofocus: true,
                  decoration: InputDecoration(labelText: l10n.nameLabel),
                  textInputAction: TextInputAction.next,
                  validator: _validateName,
                ),
                const SizedBox(height: 8),
                NewPasswordFields(
                  password: _password,
                  confirm: _confirm,
                  label: l10n.passwordLabel,
                  enabled: !_busy,
                  onSubmitted: _submit,
                ),
                if (_failed) ...[
                  const SizedBox(height: 16),
                  Text(
                    l10n.createVaultFileError,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
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
            child: Text(l10n.createVaultFile),
          ),
        ],
      ),
    );
  }
}
