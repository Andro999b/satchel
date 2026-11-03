import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../l10n/l10n.dart';
import '../vault/unlocked_vaults.dart';
import '../vault/vault_providers.dart';

/// Shows the editor and saves the result to the unlocked vault [vault]:
/// a new secret of [type], or changes to [initial]. Returns the saved secret
/// (or [initial] if nothing changed), or `null` if cancelled.
///
/// Full screen on compact windows, a dialog otherwise.
Future<Secret?> showSecretEditor(
  BuildContext context, {
  required VaultRef vault,
  SecretType? type,
  Secret? initial,
}) => showDialog<Secret>(
  context: context,
  barrierDismissible: false,
  builder: (context) {
    final size = MediaQuery.sizeOf(context);
    if (size.width < 600) {
      return Dialog.fullscreen(
        child: SecretEditor(
          vault: vault,
          type: type,
          initial: initial,
          fullscreen: true,
        ),
      );
    }
    final editor = SecretEditor(vault: vault, type: type, initial: initial);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: min(760, size.height * 0.9),
        ),
        child: editor,
      ),
    );
  },
);

/// Form for a new secret of [type], or for editing [initial]. Pops the
/// saved [Secret].
class SecretEditor extends ConsumerStatefulWidget {
  SecretEditor({
    super.key,
    required this.vault,
    SecretType? type,
    this.initial,
    this.fullscreen = false,
  }) : type = initial?.type ?? type!;

  final VaultRef vault;
  final SecretType type;

  /// The secret being edited, or `null` to create one.
  final Secret? initial;

  /// Whether the editor fills the screen (and so pads for the status bar)
  /// rather than sizing to its content inside a dialog.
  final bool fullscreen;

  @override
  ConsumerState<SecretEditor> createState() => _SecretEditorState();
}

enum _SaveError { conflict, failed }

/// Controllers of one custom field row.
final class _FieldRow {
  final key = UniqueKey();
  final label = TextEditingController();
  final value = TextEditingController();
  var concealed = true;

  void dispose() {
    for (final controller in [label, value]) {
      controller
        ..clear()
        ..dispose();
    }
  }
}

class _SecretEditorState extends ConsumerState<SecretEditor> {
  /// Longest validity accepted, about a century.
  static const maxValidDays = 36500;

  /// Validity presets offered as chips, in days.
  static const validityPresets = [30, 60, 90, 180, 365];

  static const _gap = SizedBox(height: 12);

  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _url = TextEditingController();
  final _totp = TextEditingController();
  final _pem = TextEditingController();
  final _codes = TextEditingController();
  final _noteText = TextEditingController();
  final _tags = TextEditingController();
  final _notes = TextEditingController();
  final _validDays = TextEditingController();
  final _fields = <_FieldRow>[];
  var _showMore = false;

  /// Whether the user changed the validity. Until then an edited secret
  /// keeps its exact expiry.
  var _expiryEdited = false;
  var _obscurePassword = true;
  var _busy = false;
  _SaveError? _error;

  List<TextEditingController> get _controllers => [
    _title,
    _username,
    _password,
    _url,
    _totp,
    _pem,
    _codes,
    _noteText,
    _tags,
    _notes,
    _validDays,
  ];

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial == null) return;
    _title.text = initial.title;
    _tags.text = initial.tags.join(', ');
    _notes.text = initial.notes;
    for (final field in initial.customFields) {
      _fields.add(
        _FieldRow()
          ..label.text = field.label
          ..value.text = field.value
          ..concealed = field.concealed,
      );
    }
    if (initial.expiresAt case final expiresAt?) {
      final left = expiresAt.difference(ref.read(appClockProvider).now());
      final days = (left.inHours / 24).ceil();
      if (days >= 1) _validDays.text = '${min(days, maxValidDays)}';
    }
    switch (initial) {
      case PasswordSecret(:final password):
        _password.text = password;
      case LoginSecret(
        :final username,
        :final password,
        :final url,
        :final totp,
      ):
        _username.text = username;
        _password.text = password;
        _url.text = url;
        _totp.text = totp;
      case PemSecret(:final pem):
        _pem.text = pem;
      case RecoveryCodesSecret(:final codes):
        _codes.text = [for (final code in codes) code.code].join('\n');
      case NoteSecret(:final text):
        _noteText.text = text;
    }
    _showMore =
        initial.tags.isNotEmpty ||
        initial.notes.isNotEmpty ||
        initial.expiresAt != null ||
        initial.customFields.isNotEmpty;
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller
        ..clear()
        ..dispose();
    }
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }

  static List<String> _lines(String text) => [
    for (final line in text.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  /// Days entered in the validity field, or `null` if empty or invalid.
  int? get _days {
    final days = int.tryParse(_validDays.text);
    return days != null && days >= 1 && days <= maxValidDays ? days : null;
  }

  String? _validateDays(String? value) {
    if ((value ?? '').isEmpty) return null;
    return _days == null ? context.l10n.validForInvalid(maxValidDays) : null;
  }

  /// Whether a field in the collapsed section would fail validation.
  bool get _moreOptionsInvalid =>
      _validateDays(_validDays.text) != null ||
      _fields.any((field) => field.label.text.trim().isEmpty);

  /// The expiry to store: the original one until the user changes the
  /// validity, then now plus the entered days.
  DateTime? _expiresAt(DateTime now) {
    final initial = widget.initial;
    if (initial != null && !_expiryEdited) return initial.expiresAt;
    final days = _days;
    return days == null ? null : now.add(Duration(days: days));
  }

  /// Recovery codes from the text, keeping the used state of codes that
  /// were already there.
  List<RecoveryCode> _recoveryCodes() {
    final used = <String, int>{};
    if (widget.initial case RecoveryCodesSecret(:final codes)) {
      for (final code in codes) {
        if (code.used) used[code.code] = (used[code.code] ?? 0) + 1;
      }
    }
    final codes = <RecoveryCode>[];
    for (final code in _lines(_codes.text)) {
      final usedLeft = used[code] ?? 0;
      if (usedLeft > 0) used[code] = usedLeft - 1;
      codes.add(RecoveryCode(code, used: usedLeft > 0));
    }
    return codes;
  }

  Secret _buildSecret() {
    final clock = ref.read(appClockProvider);
    final initial = widget.initial;
    final title = _title.text.trim();
    final tags = _tags.text.split(',');
    final expiresAt = _expiresAt(clock.now());
    final notes = _notes.text.trim();
    final customFields = [
      for (final field in _fields)
        CustomField(
          label: field.label.text.trim(),
          value: field.value.text,
          concealed: field.concealed,
        ),
    ];
    final info = initial == null
        ? SecretInfo.create(
            title: title,
            tags: tags,
            expiresAt: expiresAt,
            notes: notes,
            customFields: customFields,
            clock: clock,
          )
        : initial.info.copyWith(
            title: title,
            tags: tags,
            expiresAt: () => expiresAt,
            notes: notes,
            customFields: customFields,
          );
    final Secret secret = switch (widget.type) {
      SecretType.password => PasswordSecret(
        info: info,
        password: _password.text,
      ),
      SecretType.login => LoginSecret(
        info: info,
        username: _username.text.trim(),
        password: _password.text,
        url: _url.text.trim(),
        totp: _totp.text.trim(),
      ),
      SecretType.pem => PemSecret(info: info, pem: _pem.text.trim()),
      SecretType.recoveryCodes => RecoveryCodesSecret(
        info: info,
        codes: _recoveryCodes(),
      ),
      SecretType.note => NoteSecret(info: info, text: _noteText.text),
    };
    return initial == null
        ? secret
        : Secret.applyEdit(initial, secret, clock: clock);
  }

  Future<void> _save() async {
    if (_busy) return;
    if (!_form.currentState!.validate()) {
      // Show errors hidden in the collapsed section.
      if (!_showMore && _moreOptionsInvalid) setState(() => _showMore = true);
      return;
    }
    final secret = _buildSecret();
    if (identical(secret, widget.initial)) {
      Navigator.pop(context, secret);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    _SaveError? error;
    try {
      await ref
          .read(unlockedVaultsProvider.notifier)
          .putSecret(widget.vault, secret);
    } on StorageConflictException {
      error = _SaveError.conflict;
    } catch (_) {
      error = _SaveError.failed;
    }
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, secret);
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  String? _required(String? value, String message) =>
      (value ?? '').trim().isEmpty ? message : null;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_busy,
      child: Theme(
        data: theme.copyWith(
          visualDensity: VisualDensity.compact,
          inputDecorationTheme: theme.inputDecorationTheme.copyWith(
            isDense: true,
          ),
        ),
        // A min-sized column rather than a Scaffold, so a dialog fits its
        // content and only scrolls when that is too tall.
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sized(
              AppBar(
                primary: widget.fullscreen,
                // Show the dialog's own surface color.
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                scrolledUnderElevation: 0,
                leading: CloseButton(
                  onPressed: _busy ? null : () => Navigator.pop(context),
                ),
                title: Text(
                  widget.initial == null
                      ? l10n.newSecretTitle(widget.type.name)
                      : l10n.editSecretTitle(widget.type.name),
                ),
                actions: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: FilledButton(
                      onPressed: _busy ? null : _save,
                      child: Text(l10n.save),
                    ),
                  ),
                ],
                bottom: _busy
                    ? const PreferredSize(
                        preferredSize: Size.fromHeight(4),
                        child: LinearProgressIndicator(),
                      )
                    : null,
              ),
            ),
            // Not a lazy list: every field must exist for the form to validate.
            Flexible(
              child: Form(
                key: _form,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_error case final error?) ...[
                        Text(switch (error) {
                          _SaveError.conflict => l10n.saveConflict,
                          _SaveError.failed => l10n.saveError,
                        }, style: TextStyle(color: theme.colorScheme.error)),
                        _gap,
                      ],
                      TextFormField(
                        key: const Key('title'),
                        controller: _title,
                        enabled: !_busy,
                        autofocus: true,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(labelText: l10n.titleLabel),
                        validator: (v) => _required(v, l10n.titleRequired),
                      ),
                      _gap,
                      ..._typeFields(l10n, theme),
                      const SizedBox(height: 4),
                      _moreOptionsHeader(l10n, theme),
                      // Kept built while collapsed so its fields still validate.
                      Visibility(
                        visible: _showMore,
                        maintainState: true,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: _moreOptions(l10n, theme),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// [appBar] at its own height: outside a Scaffold nothing else bounds it.
  Widget _sized(AppBar appBar) => SizedBox(
    height:
        appBar.preferredSize.height +
        (widget.fullscreen ? MediaQuery.paddingOf(context).top : 0),
    child: appBar,
  );

  List<Widget> _typeFields(AppLocalizations l10n, ThemeData theme) {
    final mono = theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace');
    return switch (widget.type) {
      SecretType.password => [_passwordField(l10n, required: true)],
      SecretType.login => [
        TextFormField(
          key: const Key('username'),
          controller: _username,
          enabled: !_busy,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(labelText: l10n.usernameLabel),
        ),
        _gap,
        _passwordField(l10n, required: false),
        _gap,
        TextFormField(
          key: const Key('url'),
          controller: _url,
          enabled: !_busy,
          autocorrect: false,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(labelText: l10n.urlLabel),
        ),
        _gap,
        TextFormField(
          key: const Key('totp'),
          controller: _totp,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: l10n.totpLabel,
            hintText: l10n.totpHint,
          ),
        ),
      ],
      SecretType.pem => [
        TextFormField(
          key: const Key('pem'),
          controller: _pem,
          enabled: !_busy,
          minLines: 4,
          maxLines: 10,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.multiline,
          style: mono,
          decoration: InputDecoration(
            labelText: l10n.pemLabel,
            hintText: l10n.pemHint,
            hintMaxLines: 2,
            alignLabelWithHint: true,
          ),
          validator: (v) =>
              (v ?? '').contains('-----BEGIN ') ? null : l10n.pemInvalid,
        ),
      ],
      SecretType.recoveryCodes => [
        TextFormField(
          key: const Key('codes'),
          controller: _codes,
          enabled: !_busy,
          minLines: 3,
          maxLines: 10,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.multiline,
          style: mono,
          decoration: InputDecoration(
            labelText: l10n.recoveryCodesLabel,
            hintText: l10n.recoveryCodesHint,
            alignLabelWithHint: true,
          ),
          validator: (v) =>
              _lines(v ?? '').isEmpty ? l10n.recoveryCodesRequired : null,
        ),
      ],
      SecretType.note => [
        TextFormField(
          key: const Key('noteText'),
          controller: _noteText,
          enabled: !_busy,
          minLines: 3,
          maxLines: 10,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration(
            labelText: l10n.noteTextLabel,
            alignLabelWithHint: true,
          ),
          validator: (v) => _required(v, l10n.noteTextRequired),
        ),
      ],
    };
  }

  Widget _passwordField(AppLocalizations l10n, {required bool required}) {
    return TextFormField(
      key: const Key('password'),
      controller: _password,
      enabled: !_busy,
      obscureText: _obscurePassword,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.visiblePassword,
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(
        labelText: l10n.passwordLabel,
        // Keep Tab moving between fields; the buttons stay clickable.
        suffixIcon: ExcludeFocus(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: l10n.generatePassword,
                icon: const Icon(Icons.casino_outlined),
                onPressed: _busy
                    ? null
                    : () => _password.text = generatePassword(),
              ),
              IconButton(
                tooltip: _obscurePassword
                    ? l10n.showPassword
                    : l10n.hidePassword,
                icon: Icon(
                  _obscurePassword ? Icons.visibility : Icons.visibility_off,
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
            ],
          ),
        ),
      ),
      // Passwords are kept exactly as entered, spaces included.
      validator: required
          ? (v) => (v ?? '').isEmpty ? l10n.passwordRequired : null
          : null,
    );
  }

  Widget _moreOptionsHeader(AppLocalizations l10n, ThemeData theme) {
    return ListTile(
      key: const Key('moreOptions'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(l10n.moreOptions, style: theme.textTheme.titleSmall),
      subtitle: _showMore ? null : Text(l10n.moreOptionsHint),
      trailing: Icon(_showMore ? Icons.expand_less : Icons.expand_more),
      onTap: () => setState(() => _showMore = !_showMore),
    );
  }

  List<Widget> _moreOptions(AppLocalizations l10n, ThemeData theme) => [
    TextFormField(
      key: const Key('tags'),
      controller: _tags,
      enabled: !_busy,
      decoration: InputDecoration(
        labelText: l10n.tagsLabel,
        hintText: l10n.tagsHint,
      ),
    ),
    _gap,
    TextFormField(
      key: const Key('notes'),
      controller: _notes,
      enabled: !_busy,
      minLines: 1,
      maxLines: 6,
      keyboardType: TextInputType.multiline,
      decoration: InputDecoration(labelText: l10n.notesLabel),
    ),
    _gap,
    ..._validity(l10n),
    _gap,
    ..._customFields(l10n, theme),
  ];

  List<Widget> _validity(AppLocalizations l10n) {
    final now = ref.read(appClockProvider).now();
    final expiresAt = _expiresAt(now);
    final date = expiresAt == null
        ? null
        : MaterialLocalizations.of(context)
              .formatMediumDate(expiresAt.toLocal());
    return [
      TextFormField(
        key: const Key('validDays'),
        controller: _validDays,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          labelText: l10n.validForLabel,
          hintText: l10n.validForHint,
          suffixText: l10n.validForSuffix,
          helperText: date == null
              ? null
              : expiresAt!.isAfter(now)
              ? l10n.expiresOn(date)
              : l10n.expiredOn(date),
        ),
        // Rebuild for the expiry date shown below the field.
        onChanged: (_) => setState(() => _expiryEdited = true),
        validator: _validateDays,
      ),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        children: [
          for (final preset in validityPresets)
            ActionChip(
              label: Text(l10n.validForPreset(preset)),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _validDays.text = '$preset';
                      _expiryEdited = true;
                    }),
            ),
        ],
      ),
    ];
  }

  List<Widget> _customFields(AppLocalizations l10n, ThemeData theme) => [
    Text(l10n.customFieldsTitle, style: theme.textTheme.titleSmall),
    for (final (index, field) in _fields.indexed)
      Padding(
        key: field.key,
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: TextFormField(
                key: Key('fieldLabel$index'),
                controller: field.label,
                enabled: !_busy,
                decoration: InputDecoration(labelText: l10n.customFieldLabel),
                validator: (v) => _required(v, l10n.customFieldLabelRequired),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: TextFormField(
                key: Key('fieldValue$index'),
                controller: field.value,
                enabled: !_busy,
                obscureText: field.concealed,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(labelText: l10n.customFieldValue),
              ),
            ),
            IconButton(
              tooltip: field.concealed
                  ? l10n.customFieldConcealed
                  : l10n.customFieldVisible,
              icon: Icon(
                field.concealed
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
              onPressed: _busy
                  ? null
                  : () => setState(() => field.concealed = !field.concealed),
            ),
            IconButton(
              tooltip: l10n.removeCustomField,
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: _busy
                  ? null
                  : () {
                      setState(() => _fields.remove(field));
                      // Its text fields unmount in this frame.
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => field.dispose(),
                      );
                    },
            ),
          ],
        ),
      ),
    Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton.icon(
        onPressed: _busy
            ? null
            : () => setState(() => _fields.add(_FieldRow())),
        icon: const Icon(Icons.add),
        label: Text(l10n.addCustomField),
      ),
    ),
  ];
}
