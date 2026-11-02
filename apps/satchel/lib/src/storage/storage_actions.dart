import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_storage/satchel_storage.dart';

import 'add_google_drive.dart';
import 'storage_display.dart';
import 'storage_providers.dart';
import '../l10n/l10n.dart';
import '../navigation/app_location.dart';

/// Lets the user configure and add a storage of [kind], then opens it.
Future<void> addStorage(
  BuildContext context,
  WidgetRef ref,
  StorageProviderKind kind,
) async {
  switch (kind) {
    case StorageProviderKind.directory:
      await _addDirectory(context, ref);
    case StorageProviderKind.googleDrive:
      await addGoogleDrive(context, ref);
    case StorageProviderKind.indexedDb:
      // Built in, never offered.
      break;
  }
}

Future<void> _addDirectory(BuildContext context, WidgetRef ref) async {
  final notifier = ref.read(storageConfigsProvider.notifier);
  final location = ref.read(currentLocationProvider.notifier);
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  try {
    final picked = await notifier.pickDirectory();
    if (picked == null || !context.mounted) return;
    if (await notifier.hasLocation(picked.location)) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.folderAlreadyAdded)));
      return;
    }
    if (!context.mounted) return;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => StorageNameDialog(
        initialName: picked.name.isEmpty
            ? l10n.storageKindDirectory
            : picked.name,
        location: describeLocation(picked.location),
      ),
    );
    if (name == null) return;
    final config = await notifier.add(
      kind: StorageProviderKind.directory,
      displayName: name,
      location: picked.location,
    );
    location.openStorage(config.id);
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.addFolderError)));
  }
}

/// Asks for the name of a new storage. Pops the trimmed name, or `null`.
class StorageNameDialog extends StatefulWidget {
  const StorageNameDialog({
    super.key,
    required this.initialName,
    required this.location,
  });

  final String initialName;
  final String location;

  @override
  State<StorageNameDialog> createState() => _StorageNameDialogState();
}

class _StorageNameDialogState extends State<StorageNameDialog> {
  late final _controller = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.addFolderTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.location),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(labelText: l10n.nameLabel),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => FilledButton(
            onPressed: _controller.text.trim().isEmpty ? null : _submit,
            child: Text(l10n.addFolderConfirm),
          ),
        ),
      ],
    );
  }
}

/// Asks for confirmation, then removes the storage. Its files are kept.
Future<void> removeStorage(
  BuildContext context,
  WidgetRef ref,
  StorageConfig config,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        context.l10n.removeStorageTitle(storageName(context.l10n, config)),
      ),
      content: Text(context.l10n.removeStorageMessage),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(context.l10n.removeStorageConfirm),
        ),
      ],
    ),
  );
  if (confirmed ?? false) {
    await ref.read(storageConfigsProvider.notifier).remove(config.id);
  }
}
