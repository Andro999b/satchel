import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// Confirmation for an action that can't be undone, e.g. deleting. Cancel
/// has the focus; the confirm button uses the error color. Pops `true` to
/// go ahead.
class DestructiveDialog extends StatelessWidget {
  const DestructiveDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.icon = Icons.delete_forever_outlined,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(icon, color: colors.error),
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: colors.error,
            foregroundColor: colors.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
