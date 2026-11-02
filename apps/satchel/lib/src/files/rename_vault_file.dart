import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../l10n/l10n.dart';
import '../navigation/app_location.dart';
import '../vault/unlocked_vaults.dart';
import 'vault_file.dart';
import 'vault_file_fields.dart';
import 'vault_files_providers.dart';

/// Asks for a new name for the unlocked vault [file] and renames it. Keeps
/// the file open under its new path if it was open.
Future<void> renameVaultFile(
  BuildContext context,
  WidgetRef ref,
  VaultFile file,
) async {
  final location = ref.read(currentLocationProvider.notifier);
  final newPath = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RenameVaultFileDialog(file: file),
  );
  if (newPath != null) location.renameFile(file.storageId, file.path, newPath);
}

/// Renames an unlocked vault file. Pops its new path, or `null` if
/// cancelled or unchanged.
class RenameVaultFileDialog extends ConsumerStatefulWidget {
  const RenameVaultFileDialog({super.key, required this.file});

  final VaultFile file;

  @override
  ConsumerState<RenameVaultFileDialog> createState() =>
      _RenameVaultFileDialogState();
}

enum _RenameError { conflict, failed }

class _RenameVaultFileDialogState extends ConsumerState<RenameVaultFileDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.file.name)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.file.name.length,
    );
  var _busy = false;
  String? _nameTaken;
  _RenameError? _error;

  @override
  void dispose() {
    _name.dispose();
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
    if (name == widget.file.name) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    _RenameError? error;
    try {
      final path = await ref
          .read(unlockedVaultsProvider.notifier)
          .rename(VaultRef(widget.file.storageId, widget.file.path), name);
      if (mounted) Navigator.pop(context, path);
      return;
    } on VaultFileExistsException {
      _nameTaken = name;
    } on StorageConflictException {
      error = _RenameError.conflict;
    } catch (_) {
      error = _RenameError.failed;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    _formKey.currentState!.validate();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(l10n.renameFileTitle(widget.file.name)),
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
                  validator: _validateName,
                  onFieldSubmitted: (_) => _submit(),
                ),
                if (_error case final error?) ...[
                  const SizedBox(height: 16),
                  Text(switch (error) {
                    _RenameError.conflict => l10n.renameFileConflict,
                    _RenameError.failed => l10n.renameFileError,
                  }, style: TextStyle(color: theme.colorScheme.error)),
                ],
                if (_busy) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
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
            child: Text(l10n.renameFileConfirm),
          ),
        ],
      ),
    );
  }
}
