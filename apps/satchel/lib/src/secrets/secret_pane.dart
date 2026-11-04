import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import '../export/export_providers.dart';
import '../l10n/l10n.dart';
import '../navigation/adaptive_layout.dart';
import '../vault/unlocked_vaults.dart';
import '../vault/vault_providers.dart';
import '../widgets/destructive_dialog.dart';
import '../widgets/message_view.dart';
import 'delete_secret.dart';
import 'expiry_display.dart';
import 'secret_clipboard.dart';
import 'secret_display.dart';
import 'secret_editor.dart';

/// Shown instead of masked values. Fixed length, so it doesn't reveal the
/// length of the value.
const maskedValue = '••••••••';

/// Recovery codes left at or below which the user is warned.
const lowRecoveryCodes = 2;

/// Details of one secret of an unlocked vault file, with Edit and Delete.
class SecretPane extends ConsumerWidget {
  const SecretPane({
    super.key,
    required this.storageId,
    required this.path,
    required this.secretId,
    this.onBack,
  });

  final String storageId;
  final String path;
  final String secretId;

  /// Shows a back button when set, for layouts where the secrets pane is
  /// hidden.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final vaultRef = VaultRef(storageId, path);
    final secret = ref.watch(
      unlockedVaultsProvider.select(
        (vaults) => vaults[vaultRef]?.payload.secretById(secretId),
      ),
    );
    final leading = onBack == null ? null : BackButton(onPressed: onBack);
    if (secret == null) {
      return Scaffold(
        appBar: AppBar(leading: leading, automaticallyImplyLeading: false),
        body: MessageView(
          icon: Icons.key_off_outlined,
          text: l10n.secretNotFound,
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        leading: leading,
        automaticallyImplyLeading: false,
        title: Text(secret.title),
        actions: [
          IconButton(
            tooltip: l10n.editTooltip,
            icon: const Icon(Icons.edit_outlined),
            onPressed: () =>
                showSecretEditor(context, vault: vaultRef, initial: secret),
          ),
          IconButton(
            tooltip: l10n.deleteSecretTooltip,
            icon: const Icon(Icons.delete_outline),
            onPressed: () => deleteSecret(context, ref, vaultRef, secret),
          ),
        ],
      ),
      // Reveal and expand states reset when another secret is shown.
      body: Align(
        alignment: AlignmentDirectional.topStart,
        child: ConstrainedBox(
          // Keeps copy and reveal buttons close to their values.
          constraints: const BoxConstraints(maxWidth: secretPaneMaxWidth),
          child: _SecretDetails(
            key: ValueKey(secret.id),
            vault: vaultRef,
            secret: secret,
          ),
        ),
      ),
    );
  }
}

class _SecretDetails extends ConsumerWidget {
  const _SecretDetails({super.key, required this.vault, required this.secret});

  final VaultRef vault;
  final Secret secret;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final now = ref.watch(appClockProvider).now();
    final secret = this.secret;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _Header(secret: secret, now: now),
        ...switch (secret) {
          PasswordSecret(:final password) => [
            _ValueTile(
              key: const Key('password'),
              label: l10n.passwordLabel,
              value: password,
              masked: true,
            ),
          ],
          LoginSecret(
            :final username,
            :final password,
            :final url,
            :final totp,
          ) =>
            [
              if (username.isNotEmpty)
                _ValueTile(
                  key: const Key('username'),
                  label: l10n.usernameLabel,
                  value: username,
                ),
              if (password.isNotEmpty)
                _ValueTile(
                  key: const Key('password'),
                  label: l10n.passwordLabel,
                  value: password,
                  masked: true,
                ),
              if (url.isNotEmpty)
                _ValueTile(
                  key: const Key('url'),
                  label: l10n.urlLabel,
                  value: url,
                  action: _OpenUrlButton.forUrl(url),
                ),
              if (totp.isNotEmpty)
                _ValueTile(
                  key: const Key('totp'),
                  label: l10n.totpLabel,
                  value: totp,
                  masked: true,
                  monospace: true,
                ),
            ],
          PemSecret() => [_PemTile(secret: secret)],
          RecoveryCodesSecret() => [
            _RecoveryCodes(vault: vault, secret: secret),
          ],
          NoteSecret(:final text) => [
            _ValueTile(
              key: const Key('noteText'),
              label: l10n.noteTextLabel,
              value: text,
              masked: true,
              multiline: true,
            ),
          ],
        },
        if (secret.notes.isNotEmpty)
          _ValueTile(
            key: const Key('notes'),
            label: l10n.notesLabel,
            value: secret.notes,
            multiline: true,
          ),
        for (final (index, field) in secret.customFields.indexed)
          _ValueTile(
            key: Key('customField$index'),
            label: field.label,
            value: field.value,
            masked: field.concealed,
          ),
        if (secret.tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final tag in secret.tags)
                  Chip(
                    avatar: const Icon(Icons.sell_outlined, size: 16),
                    label: Text(tag),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
        _Timestamps(secret: secret, now: now),
      ],
    );
  }
}

/// Opens an http(s) URL in the browser.
class _OpenUrlButton extends StatelessWidget {
  const _OpenUrlButton(this.uri);

  /// The button for [url], or `null` if it isn't a web address.
  static Widget? forUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
      return null;
    }
    return _OpenUrlButton(uri);
  }

  final Uri uri;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: context.l10n.openUrlTooltip,
      icon: const Icon(Icons.open_in_new),
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        final error = context.l10n.openUrlError;
        var opened = false;
        try {
          opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {
          opened = false;
        }
        if (!opened) messenger.showSnackBar(SnackBar(content: Text(error)));
      },
    );
  }
}

/// Type and expiry status of the secret.
class _Header extends StatelessWidget {
  const _Header({required this.secret, required this.now});

  final Secret secret;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final highlight = ExpiryHighlight.of(context, secret, now);
    return ListTile(
      leading: Icon(secretIcon(secret)),
      title: Text(secretTypeName(context.l10n, secret.type)),
      trailing: highlight == null ? null : _Badge(highlight: highlight),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.highlight});

  final ExpiryHighlight highlight;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: const Key('expiryBadge'),
      decoration: BoxDecoration(
        color: highlight.container,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(highlight.icon, size: 16, color: highlight.onContainer),
            const SizedBox(width: 4),
            Text(
              highlight.text,
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: highlight.onContainer),
            ),
          ],
        ),
      ),
    );
  }
}

/// Copies [value] with auto-clear and says so in a snack bar.
Future<void> copyValue(
  BuildContext context,
  WidgetRef ref,
  String label,
  String value,
) async {
  final clipboard = ref.read(secretClipboardProvider);
  final messenger = ScaffoldMessenger.of(context);
  final message = context.l10n.copied(label, clipboard.clearAfter.inSeconds);
  await clipboard.copy(value);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// A labelled value with copy, and reveal when [masked].
class _ValueTile extends ConsumerStatefulWidget {
  const _ValueTile({
    super.key,
    required this.label,
    required this.value,
    this.masked = false,
    this.multiline = false,
    this.monospace = false,
    this.action,
  });

  final String label;
  final String value;
  final bool masked;
  final bool multiline;
  final bool monospace;

  /// Extra button before Copy, e.g. "open in browser".
  final Widget? action;

  @override
  ConsumerState<_ValueTile> createState() => _ValueTileState();
}

class _ValueTileState extends ConsumerState<_ValueTile> {
  var _revealed = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final hidden = widget.masked && !_revealed;
    return ListTile(
      title: Text(widget.label, style: theme.textTheme.labelMedium),
      subtitle: Text(
        hidden ? maskedValue : widget.value,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontFamily: widget.monospace && !hidden ? 'monospace' : null,
        ),
        maxLines: widget.multiline && !hidden ? null : 1,
        overflow: widget.multiline && !hidden ? null : TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.masked)
            IconButton(
              tooltip: _revealed ? l10n.hideTooltip : l10n.revealTooltip,
              icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _revealed = !_revealed),
            ),
          ?widget.action,
          IconButton(
            tooltip: l10n.copyTooltip,
            icon: const Icon(Icons.copy),
            onPressed: () =>
                copyValue(context, ref, widget.label, widget.value),
          ),
        ],
      ),
    );
  }
}

/// A PEM document: monospace and collapsed, masked if it holds a private
/// key.
class _PemTile extends ConsumerStatefulWidget {
  const _PemTile({required this.secret});

  final PemSecret secret;

  static const collapsedLines = 4;

  @override
  ConsumerState<_PemTile> createState() => _PemTileState();
}

class _PemTileState extends ConsumerState<_PemTile> {
  var _revealed = false;
  var _expanded = false;
  var _saving = false;

  Future<void> _download() async {
    if (_saving) return;
    final secret = widget.secret;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final exporter = ref.read(fileExporterProvider);
    setState(() => _saving = true);
    try {
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => DestructiveDialog(
          title: l10n.downloadPem,
          message: secret.containsPrivateKey
              ? l10n.downloadPrivateKeyWarning
              : l10n.downloadPemWarning,
          confirmLabel: l10n.downloadPem,
          icon: Icons.warning_amber_rounded,
          onConfirm: () async {
            final bytes = utf8.encode(secret.pem);
            try {
              final name = secret.title.replaceAll(
                RegExp(r'[<>:"/\\|?*\x00-\x1f]'),
                '_',
              );
              final saved = await exporter.save(
                '$name.pem',
                bytes,
                mimeType: 'application/x-pem-file',
              );
              if (saved != null) {
                messenger.showSnackBar(
                  SnackBar(content: Text(l10n.exported(saved))),
                );
              }
            } catch (_) {
              messenger.showSnackBar(SnackBar(content: Text(l10n.exportError)));
            } finally {
              bytes.fillRange(0, bytes.length, 0);
            }
          },
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final pem = widget.secret.pem;
    final masked = widget.secret.containsPrivateKey;
    final hidden = masked && !_revealed;
    final long = '\n'.allMatches(pem).length >= _PemTile.collapsedLines;
    return Padding(
      key: const Key('pem'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(l10n.pemLabel, style: theme.textTheme.labelMedium),
              ),
              IconButton(
                tooltip: l10n.downloadPem,
                icon: const Icon(Icons.file_download_outlined),
                onPressed: _saving ? null : _download,
              ),
              if (masked)
                IconButton(
                  tooltip: _revealed ? l10n.hideTooltip : l10n.revealTooltip,
                  icon: Icon(
                    _revealed ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () => setState(() => _revealed = !_revealed),
                ),
              IconButton(
                tooltip: l10n.copyTooltip,
                icon: const Icon(Icons.copy),
                onPressed: () => copyValue(context, ref, l10n.pemLabel, pem),
              ),
            ],
          ),
          SizedBox(
            width: double.infinity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: hidden
                    ? Row(
                        children: [
                          Icon(
                            Icons.key,
                            size: 18,
                            color: theme.colorScheme.error,
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(l10n.privateKeyHidden)),
                        ],
                      )
                    : Text(
                        pem,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                        maxLines: _expanded ? null : _PemTile.collapsedLines,
                        overflow: _expanded ? null : TextOverflow.fade,
                      ),
              ),
            ),
          ),
          if (long && !hidden)
            TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? l10n.showLess : l10n.showAll),
            ),
        ],
      ),
    );
  }
}

/// Checklist of recovery codes: ticking one marks it used and saves.
class _RecoveryCodes extends ConsumerStatefulWidget {
  const _RecoveryCodes({required this.vault, required this.secret});

  final VaultRef vault;
  final RecoveryCodesSecret secret;

  @override
  ConsumerState<_RecoveryCodes> createState() => _RecoveryCodesState();
}

class _RecoveryCodesState extends ConsumerState<_RecoveryCodes> {
  var _revealed = false;
  var _saving = false;

  Future<void> _setUsed(int index, bool used) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final original = widget.secret;
    final edited = Secret.applyEdit(
      original,
      original.withCodeUsed(index, used: used),
      clock: ref.read(appClockProvider),
    );
    setState(() => _saving = true);
    String? error;
    try {
      await ref
          .read(unlockedVaultsProvider.notifier)
          .putSecret(widget.vault, edited);
    } on StorageConflictException {
      error = l10n.saveConflict;
    } catch (_) {
      error = l10n.saveError;
    }
    if (mounted) setState(() => _saving = false);
    if (error != null) messenger.showSnackBar(SnackBar(content: Text(error)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final remaining = widget.secret.remaining;
    final low = remaining <= lowRecoveryCodes;
    final warning = theme.colorScheme.error;
    return Column(
      key: const Key('recoveryCodes'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text(
            l10n.recoveryCodesLeft(remaining),
            style: theme.textTheme.titleSmall?.copyWith(
              color: low ? warning : null,
            ),
          ),
          subtitle: low
              ? Text(l10n.recoveryCodesLow, style: TextStyle(color: warning))
              : null,
          trailing: IconButton(
            tooltip: _revealed ? l10n.hideTooltip : l10n.revealTooltip,
            icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _revealed = !_revealed),
          ),
        ),
        for (final (index, code) in widget.secret.codes.indexed)
          CheckboxListTile(
            key: Key('code$index'),
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            value: code.used,
            onChanged: _saving
                ? null
                : (used) => _setUsed(index, used ?? false),
            title: Text(
              _revealed ? code.code : maskedValue,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontFamily: _revealed ? 'monospace' : null,
                decoration: code.used ? TextDecoration.lineThrough : null,
                color: code.used ? theme.disabledColor : null,
              ),
            ),
            secondary: IconButton(
              tooltip: l10n.copyTooltip,
              icon: const Icon(Icons.copy),
              onPressed: () =>
                  copyValue(context, ref, l10n.recoveryCodesLabel, code.code),
            ),
          ),
      ],
    );
  }
}

/// Expiry and created/updated times.
class _Timestamps extends StatelessWidget {
  const _Timestamps({required this.secret, required this.now});

  final Secret secret;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    String dateTime(DateTime time) =>
        DateFormat.yMMMd(locale).add_Hm().format(time.toLocal());
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final expiresAt = secret.expiresAt;
    final status = secret.expiryStatus(now);
    final days = expiresAt == null ? 0 : daysUntil(expiresAt, now);
    final relativeExpiry = status == ExpiryStatus.expired
        ? l10n.expiredDaysAgo(days < 0 ? -days : 0)
        : l10n.expiresInDays(days < 0 ? 0 : days);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (expiresAt != null)
            Text(
              key: const Key('expiry'),
              status == ExpiryStatus.expired
                  ? '${l10n.expiredOn(dateTime(expiresAt))} ($relativeExpiry)'
                  : '${l10n.expiresOn(dateTime(expiresAt))} ($relativeExpiry)',
              style: style?.copyWith(
                color: ExpiryHighlight.of(context, secret, now)?.foreground,
              ),
            ),
          Text(l10n.createdOn(dateTime(secret.createdAt)), style: style),
          Text(l10n.updatedOn(dateTime(secret.updatedAt)), style: style),
        ],
      ),
    );
  }
}
