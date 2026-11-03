import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../l10n/l10n.dart';
import '../navigation/app_location.dart';
import '../vault/unlocked_vaults.dart';
import '../vault/vault_providers.dart';

/// Adds a copy of [secret] with a new id, new timestamps and a "(copy)"
/// title to the unlocked vault [vault], saves it while a modal dialog shows
/// progress, and opens it. Reports the outcome in a snack bar.
Future<void> duplicateSecret(
  BuildContext context,
  WidgetRef ref,
  VaultRef vault,
  Secret secret,
) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final location = ref.read(currentLocationProvider.notifier);
  final current = ref.read(currentLocationProvider);
  final vaults = ref.read(unlockedVaultsProvider.notifier);
  final duplicate = secret.duplicate(clock: ref.read(appClockProvider));
  final titled = duplicate.withInfo(
    duplicate.info.copyWith(title: l10n.duplicateSecretTitle(secret.title)),
  );
  var message = '';
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ProgressDialog(
      message: l10n.duplicatingSecret(secret.title),
      task: () async {
        try {
          await vaults.putSecret(vault, titled);
          message = l10n.secretDuplicated(secret.title);
          if (current.storageId == vault.storageId &&
              current.filePath == vault.path) {
            location.openSecret(titled.id);
          }
        } on StorageConflictException {
          message = l10n.saveConflict;
        } catch (_) {
          message = l10n.saveError;
        }
      },
    ),
  );
  messenger.showSnackBar(SnackBar(content: Text(message)));
}

/// Runs [task] while showing [message] and progress; closes when it ends.
class _ProgressDialog extends StatefulWidget {
  const _ProgressDialog({required this.message, required this.task});

  final String message;
  final Future<void> Function() task;

  @override
  State<_ProgressDialog> createState() => _ProgressDialogState();
}

class _ProgressDialogState extends State<_ProgressDialog> {
  @override
  void initState() {
    super.initState();
    widget.task().whenComplete(() {
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.message),
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
      ),
    ),
  );
}
