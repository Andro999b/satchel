import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_core/satchel_core.dart';

import '../l10n/l10n.dart';
import '../vault/unlocked_vaults.dart';
import 'biometric_store.dart';
import 'pin_unlock.dart';

/// Asks for a new PIN for the unlocked vault [vault] named [name] and saves
/// it. Reports success in a snack bar.
Future<void> setUpPin(
  BuildContext context,
  VaultRef vault, {
  required String name,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PinSetupDialog(vault: vault, name: name),
  );
  if (saved ?? false) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.pinSaved(name))));
  }
}

/// Turns off PIN unlock for [vault] named [name], reporting the outcome in a
/// snack bar. The password still opens the file, so there's no confirmation.
Future<void> removePin(
  BuildContext context,
  WidgetRef ref,
  VaultRef vault, {
  required String name,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  try {
    await ref.read(pinUnlockProvider.notifier).disable(vault);
    messenger.showSnackBar(SnackBar(content: Text(l10n.pinRemoved(name))));
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.pinRemoveError)));
  }
}

/// Turns biometric unlock on or off for the unlocked vault [vault] named
/// [name], which has a PIN, reporting the outcome in a snack bar. Turning it
/// on shows the biometric prompt; dismissing it changes nothing.
Future<void> setBiometricUnlock(
  BuildContext context,
  WidgetRef ref,
  VaultRef vault, {
  required String name,
  required bool enabled,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  final notifier = ref.read(pinUnlockProvider.notifier);
  try {
    if (enabled) {
      await notifier.enableBiometric(
        vault,
        BiometricPromptText(title: l10n.turnOnBiometric, cancel: l10n.cancel),
      );
    } else {
      await notifier.disableBiometric(vault);
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          enabled ? l10n.biometricEnabled(name) : l10n.biometricDisabled(name),
        ),
      ),
    );
  } on BiometricCancelledException {
    // The user changed their mind.
  } on PinRemovedException {
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.unlockPinPasswordChanged)),
    );
  } catch (_) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          enabled ? l10n.biometricEnableError : l10n.biometricDisableError,
        ),
      ),
    );
  }
}

/// A PIN input: digits only, masked, at most [PinKeyWrap.maxPinLength].
class PinField extends StatelessWidget {
  const PinField({
    super.key,
    required this.controller,
    required this.label,
    this.focusNode,
    this.enabled = true,
    this.autofocus = false,
    this.errorText,
    this.validator,
    this.textInputAction,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final FocusNode? focusNode;
  final bool enabled;
  final bool autofocus;
  final String? errorText;
  final FormFieldValidator<String>? validator;
  final TextInputAction? textInputAction;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    focusNode: focusNode,
    enabled: enabled,
    autofocus: autofocus,
    obscureText: true,
    autocorrect: false,
    enableSuggestions: false,
    keyboardType: TextInputType.number,
    inputFormatters: [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(PinKeyWrap.maxPinLength),
    ],
    textInputAction: textInputAction,
    decoration: InputDecoration(
      labelText: label,
      errorText: errorText,
      errorMaxLines: 3,
    ),
    validator: validator,
    onFieldSubmitted: (_) => onSubmitted?.call(),
  );
}

/// Sets the PIN of an unlocked vault file. Pops `true` once saved.
class PinSetupDialog extends ConsumerStatefulWidget {
  const PinSetupDialog({super.key, required this.vault, required this.name});

  final VaultRef vault;
  final String name;

  @override
  ConsumerState<PinSetupDialog> createState() => _PinSetupDialogState();
}

class _PinSetupDialogState extends ConsumerState<PinSetupDialog> {
  final _formKey = GlobalKey<FormState>();
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  var _busy = false;
  var _failed = false;

  @override
  void dispose() {
    for (final controller in [_pin, _confirm]) {
      controller
        ..clear()
        ..dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    var failed = false;
    try {
      await ref
          .read(pinUnlockProvider.notifier)
          .enable(widget.vault, _pin.text);
    } catch (_) {
      failed = true;
    }
    if (!mounted) return;
    if (!failed) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _busy = false;
      _failed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(l10n.pinSetupTitle(widget.name)),
        content: SizedBox(
          width: 360,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.pinSetupMessage(maxPinAttempts)),
                const SizedBox(height: 16),
                PinField(
                  key: const Key('newPin'),
                  controller: _pin,
                  label: l10n.pinLabel,
                  enabled: !_busy,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  validator: (v) =>
                      isValidPin(v ?? '') ? null : l10n.pinInvalid,
                ),
                const SizedBox(height: 8),
                PinField(
                  key: const Key('confirmPin'),
                  controller: _confirm,
                  label: l10n.confirmPinLabel,
                  enabled: !_busy,
                  validator: (v) => v == _pin.text ? null : l10n.pinMismatch,
                  onSubmitted: _submit,
                ),
                if (_failed) ...[
                  const SizedBox(height: 16),
                  Text(
                    l10n.pinSetupError,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                if (_busy) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(l10n.encrypting, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(l10n.save),
          ),
        ],
      ),
    );
  }
}
