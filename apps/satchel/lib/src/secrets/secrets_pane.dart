import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_core/satchel_core.dart';

import '../l10n/l10n.dart';
import '../export/export_secrets.dart';
import '../files/rename_vault_file.dart';
import '../files/vault_file.dart';
import '../import/import_secrets.dart';
import '../navigation/app_location.dart';
import '../pin/pin_setup.dart';
import '../pin/pin_unlock.dart';
import '../vault/unlocked_vaults.dart';
import '../vault/vault_providers.dart';
import '../widgets/fab_padding.dart';
import '../widgets/message_view.dart';
import 'copy_secrets.dart';
import 'delete_secret.dart';
import 'duplicate_secret.dart';
import 'expiry_display.dart';
import 'secret_display.dart';
import 'secret_editor.dart';
import 'unlock_form.dart';

/// One vault file: an unlock form while it is locked, its secrets once
/// unlocked. Secrets can be selected, e.g. to export them.
class SecretsPane extends ConsumerStatefulWidget {
  const SecretsPane({
    super.key,
    required this.storageId,
    required this.path,
    this.onBack,
  });

  final String storageId;
  final String path;

  /// Shows a back button when set, for layouts where the files pane is
  /// hidden.
  final VoidCallback? onBack;

  @override
  ConsumerState<SecretsPane> createState() => _SecretsPaneState();
}

class _SecretsPaneState extends ConsumerState<SecretsPane> {
  /// Ids of the selected secrets.
  final _selected = <String>{};

  VaultRef get _vaultRef => VaultRef(widget.storageId, widget.path);

  @override
  void didUpdateWidget(SecretsPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storageId != widget.storageId ||
        oldWidget.path != widget.path) {
      _selected.clear();
    }
  }

  void _toggle(String id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  Future<void> _export(Set<String> ids) async {
    final exported = await exportSecrets(
      context,
      _vaultRef,
      secretIds: ids,
      count: ids.length,
    );
    if (exported && mounted) setState(_selected.clear);
  }

  Future<void> _copy(Set<String> ids) async {
    final copied = await copySecrets(context, ref, _vaultRef, ids);
    if (copied && mounted) setState(_selected.clear);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final vaultRef = _vaultRef;
    final vault = ref.watch(unlockedVaultsProvider.select((v) => v[vaultRef]));
    ref.listen(unlockedVaultsProvider.select((v) => v.containsKey(vaultRef)), (
      _,
      unlocked,
    ) {
      if (!unlocked) setState(_selected.clear);
    });
    // Drop secrets that were deleted meanwhile.
    final ids = {...?vault?.payload.secrets.map((secret) => secret.id)};
    final selected = _selected.intersection(ids);

    return switch (vault) {
      null => Scaffold(
        appBar: _fileAppBar(),
        body: UnlockForm(key: ValueKey(vaultRef), vaultRef: vaultRef),
      ),
      final vault when selected.isNotEmpty => Scaffold(
        appBar: _selectionAppBar(selected, ids),
        body: _SecretList(vault: vault, selected: selected, onToggle: _toggle),
      ),
      final vault => Scaffold(
        floatingActionButton: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            FloatingActionButton.small(
              heroTag: null,
              tooltip: l10n.lockTooltip,
              onPressed: () =>
                  ref.read(unlockedVaultsProvider.notifier).lock(vaultRef),
              child: const Icon(Icons.lock_outline),
            ),
            const SizedBox(height: 16),
            _NewSecretButton(vaultRef: vaultRef),
          ],
        ),
        appBar: _fileAppBar(actions: [_FileMenu(vault: vault)]),
        body: _SecretList(vault: vault, selected: selected, onToggle: _toggle),
      ),
    };
  }

  /// The file's name, with [actions] while it is unlocked.
  AppBar _fileAppBar({List<Widget>? actions}) => AppBar(
    leading: widget.onBack == null
        ? null
        : BackButton(onPressed: widget.onBack),
    automaticallyImplyLeading: false,
    title: Text(vaultNameFromPath(widget.path)),
    actions: actions,
  );

  /// Replaces the file's app bar while secrets are selected.
  AppBar _selectionAppBar(Set<String> selected, Set<String> ids) {
    final l10n = context.l10n;
    return AppBar(
      leading: IconButton(
        tooltip: l10n.clearSelection,
        icon: const Icon(Icons.close),
        onPressed: () => setState(_selected.clear),
      ),
      automaticallyImplyLeading: false,
      title: Text(l10n.selectedCount(selected.length)),
      actions: [
        IconButton(
          tooltip: l10n.selectAll,
          icon: const Icon(Icons.select_all),
          onPressed: selected.length == ids.length
              ? null
              : () => setState(() => _selected.addAll(ids)),
        ),
        IconButton(
          tooltip: l10n.copySecrets,
          icon: const Icon(Icons.content_copy),
          onPressed: () => _copy(selected),
        ),
        IconButton(
          tooltip: l10n.exportSelected,
          icon: const Icon(Icons.file_download_outlined),
          onPressed: () => _export(selected),
        ),
      ],
    );
  }
}

/// Actions on the unlocked file as a whole: rename, its PIN (Android),
/// import and export.
class _FileMenu extends ConsumerWidget {
  const _FileMenu({required this.vault});

  final UnlockedVault vault;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final vaultRef = vault.ref;
    final name = vaultNameFromPath(vaultRef.path);
    final pinSupported = ref.watch(pinStoreProvider) != null;
    final quickUnlock = ref.watch(quickUnlockProvider(vaultRef));
    final hasPin = quickUnlock.hasPin;
    final biometricAvailable =
        ref.watch(biometricAvailableProvider).value ?? false;
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.edit_outlined),
          onPressed: () => renameVaultFile(
            context,
            ref,
            VaultFile(
              storageId: vaultRef.storageId,
              path: vaultRef.path,
              revision: vault.revision,
            ),
          ),
          child: Text(l10n.renameFile),
        ),
        const Divider(),
        if (pinSupported) ...[
          MenuItemButton(
            leadingIcon: const Icon(Icons.pin_outlined),
            onPressed: () => setUpPin(context, vaultRef, name: name),
            child: Text(hasPin ? l10n.changePin : l10n.setUpPin),
          ),
          if (hasPin)
            MenuItemButton(
              leadingIcon: const Icon(Icons.backspace_outlined),
              onPressed: () => removePin(context, ref, vaultRef, name: name),
              child: Text(l10n.removePin),
            ),
          if (quickUnlock == QuickUnlock.pinAndBiometric)
            MenuItemButton(
              leadingIcon: const Icon(Icons.fingerprint),
              onPressed: () => setBiometricUnlock(
                context,
                ref,
                vaultRef,
                name: name,
                enabled: false,
              ),
              child: Text(l10n.turnOffBiometric),
            )
          else if (hasPin && biometricAvailable)
            MenuItemButton(
              leadingIcon: const Icon(Icons.fingerprint),
              onPressed: () => setBiometricUnlock(
                context,
                ref,
                vaultRef,
                name: name,
                enabled: true,
              ),
              child: Text(l10n.turnOnBiometric),
            ),
          const Divider(),
        ],
        MenuItemButton(
          leadingIcon: const Icon(Icons.file_upload_outlined),
          onPressed: () => importSecrets(context, ref, vaultRef),
          child: Text(l10n.importFile),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.file_download_outlined),
          onPressed: () => exportSecrets(
            context,
            vaultRef,
            count: vault.payload.secrets.length,
          ),
          child: Text(l10n.exportFile),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: l10n.fileActionsTooltip,
        icon: const Icon(Icons.more_vert),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// "New secret" button with a menu of secret types.
class _NewSecretButton extends ConsumerWidget {
  const _NewSecretButton({required this.vaultRef});

  final VaultRef vaultRef;

  Future<void> _create(
    BuildContext context,
    WidgetRef ref,
    SecretType type,
  ) async {
    final secret = await showSecretEditor(context, vault: vaultRef, type: type);
    if (secret == null) return;
    final location = ref.read(currentLocationProvider);
    if (location.storageId == vaultRef.storageId &&
        location.filePath == vaultRef.path) {
      ref.read(currentLocationProvider.notifier).openSecret(secret.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return MenuAnchor(
      menuChildren: [
        for (final type in SecretType.values)
          MenuItemButton(
            leadingIcon: Icon(secretTypeIcon(type)),
            onPressed: () => _create(context, ref, type),
            child: Text(secretTypeName(l10n, type)),
          ),
      ],
      builder: (context, controller, _) => FloatingActionButton.extended(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.add),
        label: Text(l10n.newSecret),
      ),
    );
  }
}

class _SecretList extends ConsumerWidget {
  const _SecretList({
    required this.vault,
    required this.selected,
    required this.onToggle,
  });

  final UnlockedVault vault;
  final Set<String> selected;
  final void Function(String id) onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final secrets = vault.payload.secrets;
    if (secrets.isEmpty) {
      return MessageView(
        icon: Icons.inventory_2_outlined,
        text: context.l10n.noSecrets,
      );
    }
    final openId = ref.watch(currentLocationProvider.select((l) => l.secretId));
    final now = ref.watch(appClockProvider).now();
    return ListView(
      padding: twoFabListPadding,
      children: [
        for (final secret in secrets)
          _SecretTile(
            key: ValueKey(secret.id),
            vault: vault.ref,
            secret: secret,
            open: secret.id == openId,
            selecting: selected.isNotEmpty,
            checked: selected.contains(secret.id),
            onToggle: () => onToggle(secret.id),
            now: now,
          ),
      ],
    );
  }
}

/// A secret in the list. Secrets that are expired or about to expire are
/// tinted and say when, so they stand out while scrolling.
///
/// While [selecting], it shows a checkbox and taps toggle it.
class _SecretTile extends ConsumerWidget {
  const _SecretTile({
    super.key,
    required this.vault,
    required this.secret,
    required this.open,
    required this.selecting,
    required this.checked,
    required this.onToggle,
    required this.now,
  });

  final VaultRef vault;
  final Secret secret;
  final bool open;
  final bool selecting;
  final bool checked;
  final VoidCallback onToggle;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final highlight = ExpiryHighlight.of(context, secret, now);
    return ListTile(
      selected: open,
      tileColor: highlight?.container,
      selectedTileColor: highlight?.container,
      iconColor: highlight?.onContainer,
      textColor: highlight?.onContainer,
      leading: selecting
          ? Checkbox(value: checked, onChanged: (_) => onToggle())
          : Icon(secretIcon(secret)),
      title: Text(secret.title),
      subtitle: highlight == null
          ? null
          : Row(
              key: const Key('expiryHighlight'),
              children: [
                Icon(highlight.icon, size: 16),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(highlight.text, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
      trailing: selecting
          ? null
          : Focus(
              parentNode: FocusScope.of(context),
              child: MenuAnchor(
                menuChildren: [
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.check_box_outlined),
                    onPressed: onToggle,
                    child: Text(l10n.selectForExport),
                  ),
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.edit_outlined),
                    onPressed: () => showSecretEditor(
                      context,
                      vault: vault,
                      initial: secret,
                    ),
                    child: Text(l10n.editSecret),
                  ),
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.control_point_duplicate),
                    onPressed: () =>
                        duplicateSecret(context, ref, vault, secret),
                    child: Text(l10n.duplicateSecret),
                  ),
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.content_copy),
                    onPressed: () =>
                        copySecrets(context, ref, vault, {secret.id}),
                    child: Text(l10n.copySecret),
                  ),
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.delete_outline),
                    onPressed: () => deleteSecret(context, ref, vault, secret),
                    child: Text(l10n.deleteSecret),
                  ),
                ],
                builder: (context, controller, _) => IconButton(
                  tooltip: l10n.secretActionsTooltip,
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                ),
              ),
            ),
      onTap: selecting
          ? onToggle
          : () => ref
                .read(currentLocationProvider.notifier)
                .openSecret(secret.id),
      onLongPress: onToggle,
    );
  }
}
