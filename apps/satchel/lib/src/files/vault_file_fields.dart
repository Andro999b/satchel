import 'package:flutter/material.dart';
import 'package:satchel_core/satchel_core.dart';

import '../l10n/l10n.dart';

/// Characters [checkVaultName] rejects, as shown to the user.
const _invalidCharacters = r'< > : " / \ | ? *';

/// Why [name] can't be a vault name, or `null` if it can.
String? vaultNameErrorText(AppLocalizations l10n, String name) =>
    switch (checkVaultName(name)) {
      null => null,
      VaultNameError.empty => l10n.vaultNameEmpty,
      VaultNameError.tooLong => l10n.vaultNameTooLong(maxVaultNameLength),
      VaultNameError.surroundingWhitespace =>
        l10n.vaultNameSurroundingWhitespace,
      VaultNameError.leadingDot => l10n.vaultNameLeadingDot,
      VaultNameError.trailingDot => l10n.vaultNameTrailingDot,
      VaultNameError.invalidCharacter => l10n.vaultNameInvalidCharacter(
        _invalidCharacters,
      ),
      VaultNameError.reservedName => l10n.vaultNameReserved,
    };

/// A new vault password and its confirmation, with generate and reveal
/// buttons. Must be inside a [Form].
class NewPasswordFields extends StatefulWidget {
  const NewPasswordFields({
    super.key,
    required this.password,
    required this.confirm,
    required this.label,
    this.enabled = true,
    this.onSubmitted,
  });

  /// Minimum password length. Longer passphrases are encouraged.
  static const minLength = 8;

  final TextEditingController password;
  final TextEditingController confirm;
  final String label;
  final bool enabled;
  final VoidCallback? onSubmitted;

  @override
  State<NewPasswordFields> createState() => _NewPasswordFieldsState();
}

class _NewPasswordFieldsState extends State<NewPasswordFields> {
  var _obscure = true;

  /// Fills both fields and reveals them, so the user can write it down.
  void _generate() {
    final password = generatePassword();
    setState(() {
      widget.password.text = password;
      widget.confirm.text = password;
      _obscure = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: const Key('password'),
          controller: widget.password,
          enabled: widget.enabled,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: widget.label,
            helperText: l10n.passwordHelper(NewPasswordFields.minLength),
            helperMaxLines: 2,
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: l10n.generatePassword,
                  icon: const Icon(Icons.casino_outlined),
                  onPressed: widget.enabled ? _generate : null,
                ),
                IconButton(
                  tooltip: _obscure ? l10n.showPassword : l10n.hidePassword,
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ],
            ),
          ),
          validator: (value) =>
              (value ?? '').length < NewPasswordFields.minLength
              ? l10n.passwordTooShort(NewPasswordFields.minLength)
              : null,
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: const Key('confirm'),
          controller: widget.confirm,
          enabled: widget.enabled,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          decoration: InputDecoration(labelText: l10n.confirmPasswordLabel),
          validator: (value) =>
              value == widget.password.text ? null : l10n.passwordsDontMatch,
          onFieldSubmitted: (_) => widget.onSubmitted?.call(),
        ),
      ],
    );
  }
}
