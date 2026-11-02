import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../l10n/l10n.dart';
import '../navigation/app_location.dart';
import '../widgets/destructive_dialog.dart';
import 'vault_file.dart';
import 'vault_files_providers.dart';

/// Asks for confirmation, then deletes [file] from its storage
/// ([storageName] is shown in the warning) while the dialog shows progress.
/// Closes the file if it is open and reports the outcome in a snack bar.
Future<void> deleteVaultFile(
  BuildContext context,
  WidgetRef ref,
  VaultFile file, {
  required String storageName,
}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  String? message;
  await showDialog<bool>(
    context: context,
    builder: (context) => DeleteVaultFileDialog(
      name: file.name,
      storageName: storageName,
      onConfirm: () async => message = await _delete(ref, file, l10n),
    ),
  );
  if (message case final message?) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Deletes [file] and returns the message describing the outcome.
Future<String> _delete(
  WidgetRef ref,
  VaultFile file,
  AppLocalizations l10n,
) async {
  final location = ref.read(currentLocationProvider.notifier);
  try {
    await ref.read(vaultFilesProvider(file.storageId).notifier).delete(file);
  } on StorageConflictException {
    return l10n.deleteFileConflict(file.name);
  } catch (_) {
    return l10n.deleteFileError(file.name);
  }
  location.closeFile(file.storageId, file.path);
  return l10n.fileDeleted(file.name);
}

/// Confirms deleting a vault file, then runs [onConfirm] while showing
/// progress (see [DestructiveDialog]). Pops `true` once it is done.
class DeleteVaultFileDialog extends StatelessWidget {
  const DeleteVaultFileDialog({
    super.key,
    required this.name,
    required this.storageName,
    this.onConfirm,
  });

  final String name;
  final String storageName;
  final Future<void> Function()? onConfirm;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return DestructiveDialog(
      title: l10n.deleteFileTitle(name),
      message: l10n.deleteFileMessage(storageName),
      confirmLabel: l10n.deleteFileConfirm,
      onConfirm: onConfirm,
    );
  }
}
