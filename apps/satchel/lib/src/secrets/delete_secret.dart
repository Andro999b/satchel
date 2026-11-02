import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../l10n/l10n.dart';
import '../vault/unlocked_vaults.dart';
import '../vault/vault_providers.dart';
import '../widgets/destructive_dialog.dart';

/// Asks for confirmation, then removes [secret] from the unlocked vault
/// [vault] and saves the file. Reports the outcome in a snack bar.
Future<void> deleteSecret(
  BuildContext context,
  WidgetRef ref,
  VaultRef vault,
  Secret secret,
) async {
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => DestructiveDialog(
      title: l10n.deleteSecretTitle(secret.title),
      message: l10n.deleteSecretMessage(vaultNameFromPath(vault.path)),
      confirmLabel: l10n.deleteFileConfirm,
    ),
  );
  if (!(confirmed ?? false) || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  final clock = ref.read(appClockProvider);
  String message;
  try {
    await ref
        .read(unlockedVaultsProvider.notifier)
        .save(
          vault,
          (payload) => payload.withoutSecret(secret.id, clock: clock),
        );
    message = l10n.secretDeleted(secret.title);
  } on StorageConflictException {
    message = l10n.saveConflict;
  } catch (_) {
    message = l10n.saveError;
  }
  messenger.showSnackBar(SnackBar(content: Text(message)));
}
