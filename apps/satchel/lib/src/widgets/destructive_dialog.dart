import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// Confirmation for an action that can't be undone, e.g. deleting. Cancel
/// has the focus; the confirm button uses the error color. Pops `true` to
/// go ahead.
///
/// With [onConfirm], the action runs inside the dialog: it shows progress,
/// disables its buttons and can't be dismissed until [onConfirm] completes,
/// then pops `true`. [onConfirm] should handle its own errors.
class DestructiveDialog extends StatefulWidget {
  const DestructiveDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.icon = Icons.delete_forever_outlined,
    this.onConfirm,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final IconData icon;
  final Future<void> Function()? onConfirm;

  @override
  State<DestructiveDialog> createState() => _DestructiveDialogState();
}

class _DestructiveDialogState extends State<DestructiveDialog> {
  var _busy = false;

  Future<void> _confirm() async {
    final onConfirm = widget.onConfirm;
    if (onConfirm == null) {
      Navigator.pop(context, true);
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await onConfirm();
    } finally {
      if (mounted) Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        icon: Icon(widget.icon, color: colors.error),
        title: Text(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.message),
            if (_busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
          ],
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: _busy ? null : () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.error,
              foregroundColor: colors.onError,
            ),
            onPressed: _busy ? null : _confirm,
            child: Text(widget.confirmLabel),
          ),
        ],
      ),
    );
  }
}
