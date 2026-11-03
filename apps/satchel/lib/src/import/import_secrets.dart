import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../l10n/l10n.dart';
import '../secrets/secret_display.dart';
import '../vault/unlocked_vaults.dart';
import 'import_providers.dart';

/// Lets the user pick a vault file or plain export, reads it (asking for
/// its password if needed), and shows what importing it into the unlocked
/// vault [vault] would do. Nothing is written until the user confirms.
Future<void> importSecrets(
  BuildContext context,
  WidgetRef ref,
  VaultRef vault,
) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  void report(String message) =>
      messenger.showSnackBar(SnackBar(content: Text(message)));

  final PickedFile? picked;
  try {
    picked = await ref
        .read(fileImporterProvider)
        .pick(
          typeLabel: l10n.importFileTypeLabel,
          extensions: [vaultFileExtension.substring(1), PlainExport.extension],
        );
  } catch (_) {
    report(l10n.importReadError);
    return;
  }
  if (picked == null || !context.mounted) return;
  final file = picked;

  final vaults = ref.read(unlockedVaultsProvider.notifier);
  VaultPayload? incoming;
  try {
    try {
      incoming = await vaults.readImport(vault, file.name, file.bytes);
    } on ImportPasswordRequiredException {
      if (!context.mounted) return;
      incoming = await showDialog<VaultPayload>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ImportPasswordDialog(vault: vault, file: file),
      );
    }
  } on UnsupportedImportException {
    report(l10n.importUnsupported);
  } on UnsupportedVaultVersionException {
    report(l10n.unlockNewerVersion);
  } on MissingKdfInputException {
    report(l10n.unlockNeedsExtraInputs);
  } on VaultException {
    report(l10n.importInvalid);
  } catch (_) {
    report(l10n.importReadError);
  } finally {
    // A plain export holds secrets in the clear.
    file.bytes.fillRange(0, file.bytes.length, 0);
  }
  if (incoming == null || !context.mounted) return;

  final MergePlan plan;
  try {
    plan = vaults.planImport(vault, incoming);
  } on StateError {
    return;
  }
  final imported = await showDialog<int>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        ImportReviewDialog(vault: vault, fileName: file.name, plan: plan),
  );
  if (imported != null) report(l10n.imported(imported));
}

/// Asks for the password of a vault file to import. Pops its content.
class ImportPasswordDialog extends ConsumerStatefulWidget {
  const ImportPasswordDialog({
    super.key,
    required this.vault,
    required this.file,
  });

  /// The vault imported into.
  final VaultRef vault;
  final PickedFile file;

  @override
  ConsumerState<ImportPasswordDialog> createState() =>
      _ImportPasswordDialogState();
}

/// Why opening a vault file to import failed, localized in `build`.
enum _OpenError { wrongPassword, needsExtraInputs, newerVersion, invalid }

class _ImportPasswordDialogState extends ConsumerState<ImportPasswordDialog> {
  final _password = TextEditingController();
  final _focus = FocusNode();
  var _busy = false;
  _OpenError? _error;

  @override
  void dispose() {
    _password
      ..clear()
      ..dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    if (_busy || _password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    _OpenError error;
    try {
      final payload = await ref
          .read(unlockedVaultsProvider.notifier)
          .readImport(
            widget.vault,
            widget.file.name,
            widget.file.bytes,
            password: _password.text,
          );
      if (mounted) Navigator.pop(context, payload);
      return;
    } on VaultAuthenticationException {
      error = _OpenError.wrongPassword;
    } on MissingKdfInputException {
      error = _OpenError.needsExtraInputs;
    } on UnsupportedVaultVersionException {
      error = _OpenError.newerVersion;
    } catch (_) {
      error = _OpenError.invalid;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    if (error == _OpenError.wrongPassword) {
      // Select the password for retyping once the field is enabled again.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focus.requestFocus();
        _password.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _password.text.length,
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
        title: Text(l10n.importPasswordTitle(widget.file.name)),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.importPasswordMessage),
              const SizedBox(height: 16),
              TextField(
                key: const Key('importPassword'),
                controller: _password,
                focusNode: _focus,
                enabled: !_busy,
                autofocus: true,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: l10n.passwordLabel,
                  errorText: switch (_error) {
                    null => null,
                    _OpenError.wrongPassword => l10n.unlockWrongPassword,
                    _OpenError.needsExtraInputs => l10n.unlockNeedsExtraInputs,
                    _OpenError.newerVersion => l10n.unlockNewerVersion,
                    _OpenError.invalid => l10n.importInvalid,
                  },
                  errorMaxLines: 3,
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _open(),
              ),
              if (_busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(l10n.unlocking, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: _busy || _password.text.isEmpty ? null : _open,
            child: Text(l10n.importOpen),
          ),
        ],
      ),
    );
  }
}

enum _SaveError { conflict, failed }

/// Where the incoming secrets of a merge review come from.
enum MergeReviewKind { import, copy }

/// Shows what importing would add, skip and replace, lets the user choose
/// the version of each conflicting secret, and saves on confirmation. Pops
/// the number of secrets added or replaced.
class ImportReviewDialog extends ConsumerStatefulWidget {
  const ImportReviewDialog({
    super.key,
    required this.vault,
    required this.fileName,
    required this.plan,
    this.kind = MergeReviewKind.import,
  });

  final VaultRef vault;

  /// The imported file, or for a copy the file copied into.
  final String fileName;
  final MergePlan plan;
  final MergeReviewKind kind;

  @override
  ConsumerState<ImportReviewDialog> createState() => _ImportReviewDialogState();
}

class _ImportReviewDialogState extends ConsumerState<ImportReviewDialog> {
  /// The newer version is suggested; the user confirms every choice.
  late final _resolutions = {
    for (final conflict in widget.plan.conflicts)
      conflict.id: conflict.incomingIsNewer
          ? ConflictResolution.useIncoming
          : ConflictResolution.keepExisting,
  };
  var _busy = false;
  _SaveError? _error;

  void _resolveAll(ConflictResolution resolution) => setState(() {
    for (final id in _resolutions.keys) {
      _resolutions[id] = resolution;
    }
  });

  Future<void> _import() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    _SaveError? error;
    try {
      await ref
          .read(unlockedVaultsProvider.notifier)
          .applyImport(widget.vault, widget.plan, _resolutions);
    } on StorageConflictException {
      error = _SaveError.conflict;
    } catch (_) {
      error = _SaveError.failed;
    }
    if (!mounted) return;
    if (error == null) {
      final replaced = _resolutions.values.where(
        (r) => r == ConflictResolution.useIncoming,
      );
      Navigator.pop(context, widget.plan.added.length + replaced.length);
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final plan = widget.plan;
    final copy = widget.kind == MergeReviewKind.copy;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(
          copy
              ? l10n.copySecretsReviewTitle(widget.fileName)
              : l10n.importTitle(widget.fileName),
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (plan.isEmpty)
                  Text(copy ? l10n.copySecretsNothing : l10n.importNothing)
                else ...[
                  Text(l10n.importNew(plan.added.length)),
                  if (plan.identical.isNotEmpty)
                    Text(l10n.importIdentical(plan.identical.length)),
                ],
                if (plan.conflicts.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    l10n.importConflicts(plan.conflicts.length),
                    style: theme.textTheme.titleSmall,
                  ),
                  if (plan.conflicts.length > 1)
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _resolveAll(
                                  ConflictResolution.keepExisting,
                                ),
                          child: Text(l10n.importKeepAllCurrent),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () =>
                                    _resolveAll(ConflictResolution.useIncoming),
                          child: Text(
                            copy
                                ? l10n.copySecretsUseAllCopied
                                : l10n.importUseAllImported,
                          ),
                        ),
                      ],
                    ),
                  for (final conflict in plan.conflicts)
                    _ConflictTile(
                      key: ValueKey(conflict.id),
                      conflict: conflict,
                      incomingLabel: copy
                          ? l10n.copySecretsUseCopied
                          : l10n.importUseImported,
                      resolution: _resolutions[conflict.id]!,
                      onChanged: _busy
                          ? null
                          : (resolution) => setState(
                              () => _resolutions[conflict.id] = resolution,
                            ),
                    ),
                ],
                if (_error case final error?) ...[
                  const SizedBox(height: 16),
                  Text(switch (error) {
                    _SaveError.conflict => l10n.saveConflict,
                    _SaveError.failed => l10n.saveError,
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
            child: Text(plan.isEmpty ? l10n.importClose : l10n.cancel),
          ),
          if (!plan.isEmpty)
            FilledButton(
              onPressed: _busy ? null : _import,
              child: Text(copy ? l10n.copySecretsConfirm : l10n.importConfirm),
            ),
        ],
      ),
    );
  }
}

/// One conflicting secret: its current and imported version to choose from.
class _ConflictTile extends StatelessWidget {
  const _ConflictTile({
    super.key,
    required this.conflict,
    required this.incomingLabel,
    required this.resolution,
    required this.onChanged,
  });

  final SecretConflict conflict;
  final String incomingLabel;
  final ConflictResolution resolution;
  final ValueChanged<ConflictResolution>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    String date(Secret secret) =>
        DateFormat.yMMMd(locale).add_Hm().format(secret.updatedAt.toLocal());
    final existingNewer = conflict.existing.updatedAt.isAfter(
      conflict.incoming.updatedAt,
    );

    ButtonSegment<ConflictResolution> segment(
      ConflictResolution value,
      String label,
      Secret secret, {
      required bool newer,
    }) => ButtonSegment(
      value: value,
      // Marks the newer version; the tooltip says so in words.
      icon: newer ? const Icon(Icons.update) : null,
      tooltip: newer
          ? l10n.importVersionNewer(secret.title, date(secret))
          : l10n.importVersion(secret.title, date(secret)),
      label: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          Text(date(secret), style: theme.textTheme.labelSmall),
        ],
      ),
    );

    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(secretIcon(conflict.existing), size: 20),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            conflict.existing.title,
            style: theme.textTheme.titleSmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    final choice = SegmentedButton<ConflictResolution>(
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      segments: [
        segment(
          ConflictResolution.keepExisting,
          l10n.importKeepCurrent,
          conflict.existing,
          newer: existingNewer,
        ),
        segment(
          ConflictResolution.useIncoming,
          incomingLabel,
          conflict.incoming,
          newer: conflict.incomingIsNewer,
        ),
      ],
      selected: {resolution},
      onSelectionChanged: onChanged == null
          ? null
          : (selection) => onChanged!(selection.single),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      // One line when both fit, else the choice goes below the title.
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [title, choice],
      ),
    );
  }
}
