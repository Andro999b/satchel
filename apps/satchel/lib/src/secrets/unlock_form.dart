import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../l10n/l10n.dart';
import '../pin/biometric_store.dart';
import '../pin/pin_setup.dart';
import '../pin/pin_unlock.dart';
import '../vault/unlocked_vaults.dart';

/// Why unlocking failed, localized in `build`.
enum _UnlockError {
  wrongPassword,
  wrongPin,
  pinTooManyAttempts,
  pinPasswordChanged,
  pinUnavailable,
  biometricRemoved,
  biometricFailed,
  newerVersion,
  invalidFile,
  readFailed,
  signInRequired,
}

/// Unlocks the locked vault [vaultRef] with its password, or its PIN or
/// biometrics where set up.
class UnlockForm extends ConsumerStatefulWidget {
  const UnlockForm({super.key, required this.vaultRef});

  final VaultRef vaultRef;

  @override
  ConsumerState<UnlockForm> createState() => _UnlockFormState();
}

class _UnlockFormState extends ConsumerState<UnlockForm> {
  final _password = TextEditingController();
  final _focus = FocusNode();
  final _pin = TextEditingController();
  final _pinFocus = FocusNode();
  var _obscure = true;
  var _busy = false;
  var _usePassword = false;
  _UnlockError? _error;
  var _attemptsLeft = 0;

  @override
  void dispose() {
    for (final controller in [_password, _pin]) {
      controller
        ..clear()
        ..dispose();
    }
    _focus.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  bool get _pinMode =>
      !_usePassword && ref.read(quickUnlockProvider(widget.vaultRef)).hasPin;

  void _switchMode() {
    setState(() {
      _usePassword = !_usePassword;
      _error = null;
    });
    final focus = _usePassword ? _focus : _pinFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) focus.requestFocus();
    });
  }

  Future<void> _unlock() async {
    final pinMode = _pinMode;
    if (_busy || (pinMode ? !isValidPin(_pin.text) : _password.text.isEmpty)) {
      return;
    }
    await _attempt(
      pinMode: pinMode,
      () => pinMode
          ? ref
                .read(pinUnlockProvider.notifier)
                .unlock(widget.vaultRef, _pin.text)
          : ref
                .read(unlockedVaultsProvider.notifier)
                .unlock(widget.vaultRef, _password.text),
    );
  }

  Future<void> _unlockWithBiometric() async {
    if (_busy) return;
    final l10n = context.l10n;
    final prompt = BiometricPromptText(
      title: l10n.biometricPromptUnlock(
        vaultNameFromPath(widget.vaultRef.path),
      ),
      cancel: l10n.biometricPromptUsePin,
    );
    await _attempt(
      pinMode: true,
      () => ref
          .read(pinUnlockProvider.notifier)
          .unlockWithBiometric(widget.vaultRef, prompt),
    );
  }

  Future<void> _attempt(
    Future<void> Function() unlock, {
    required bool pinMode,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    _UnlockError? error;
    try {
      await unlock();
    } on BiometricCancelledException {
      // Back to the PIN field.
    } on BiometricFailedException {
      error = _UnlockError.biometricFailed;
    } on BiometricRemovedException {
      error = _UnlockError.biometricRemoved;
    } on WrongPinException catch (e) {
      error = _UnlockError.wrongPin;
      _attemptsLeft = e.attemptsLeft;
    } on PinRemovedException catch (e) {
      error = switch (e.reason) {
        PinRemovedReason.tooManyAttempts => _UnlockError.pinTooManyAttempts,
        PinRemovedReason.passwordChanged => _UnlockError.pinPasswordChanged,
        PinRemovedReason.unavailable => _UnlockError.pinUnavailable,
      };
    } on VaultAuthenticationException {
      // The PIN was right, so the file itself doesn't decrypt.
      error = pinMode ? _UnlockError.invalidFile : _UnlockError.wrongPassword;
    } on UnsupportedVaultVersionException {
      error = _UnlockError.newerVersion;
    } on VaultFormatException {
      error = _UnlockError.invalidFile;
    } on StorageAuthRequiredException {
      error = _UnlockError.signInRequired;
    } on StorageException {
      error = _UnlockError.readFailed;
    } catch (_) {
      error = _UnlockError.readFailed;
    }
    // On success this form is replaced by the secret list.
    if (!mounted) return;
    if (pinMode) _pin.clear();
    setState(() {
      _busy = false;
      _error = error;
    });
    switch (error) {
      case _UnlockError.wrongPassword:
        // Select the password for retyping once the field is enabled again.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _focus.requestFocus();
          _password.selection = TextSelection(
            baseOffset: 0,
            extentOffset: _password.text.length,
          );
        });
      case _UnlockError.wrongPin ||
          _UnlockError.biometricFailed ||
          _UnlockError.biometricRemoved:
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _pinFocus.requestFocus();
        });
      case _UnlockError.pinTooManyAttempts ||
          _UnlockError.pinPasswordChanged ||
          _UnlockError.pinUnavailable:
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focus.requestFocus();
        });
      default:
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final quickUnlock = ref.watch(quickUnlockProvider(widget.vaultRef));
    final hasPin = quickUnlock.hasPin;
    final pinMode = hasPin && !_usePassword;
    final error = switch (_error) {
      null => null,
      _UnlockError.wrongPassword => l10n.unlockWrongPassword,
      _UnlockError.wrongPin => l10n.unlockWrongPin(_attemptsLeft),
      _UnlockError.pinTooManyAttempts => l10n.unlockPinTooManyAttempts,
      _UnlockError.pinPasswordChanged => l10n.unlockPinPasswordChanged,
      _UnlockError.pinUnavailable => l10n.unlockPinUnavailable,
      _UnlockError.biometricRemoved => l10n.unlockBiometricRemoved,
      _UnlockError.biometricFailed => l10n.unlockBiometricFailed,
      _UnlockError.newerVersion => l10n.unlockNewerVersion,
      _UnlockError.invalidFile => l10n.unlockInvalidFile,
      _UnlockError.readFailed => l10n.unlockReadError,
      _UnlockError.signInRequired => l10n.unlockSignInRequired,
    };
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.lock_outline,
                size: 48,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Text(
                pinMode ? l10n.lockedFilePinMessage : l10n.lockedFileMessage,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              if (pinMode)
                PinField(
                  key: const Key('unlockPin'),
                  controller: _pin,
                  focusNode: _pinFocus,
                  label: l10n.pinLabel,
                  enabled: !_busy,
                  autofocus: true,
                  errorText: error,
                  onSubmitted: _unlock,
                )
              else
                TextField(
                  key: const Key('unlockPassword'),
                  controller: _password,
                  focusNode: _focus,
                  enabled: !_busy,
                  autofocus: true,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.visiblePassword,
                  decoration: InputDecoration(
                    labelText: l10n.passwordLabel,
                    errorText: error,
                    errorMaxLines: 3,
                    // Keep Tab moving to Unlock; the button stays clickable.
                    suffixIcon: ExcludeFocus(
                      child: IconButton(
                        tooltip: _obscure
                            ? l10n.showPassword
                            : l10n.hidePassword,
                        icon: Icon(
                          _obscure ? Icons.visibility : Icons.visibility_off,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  onSubmitted: (_) => _unlock(),
                ),
              const SizedBox(height: 16),
              if (_busy) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(
                  l10n.unlocking,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ] else ...[
                ListenableBuilder(
                  listenable: Listenable.merge([_password, _pin]),
                  builder: (context, _) => FilledButton.icon(
                    onPressed:
                        (pinMode
                            ? isValidPin(_pin.text)
                            : _password.text.isNotEmpty)
                        ? _unlock
                        : null,
                    icon: const Icon(Icons.lock_open),
                    label: Text(l10n.unlock),
                  ),
                ),
                if (pinMode && quickUnlock == QuickUnlock.pinAndBiometric) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _unlockWithBiometric,
                    icon: const Icon(Icons.fingerprint),
                    label: Text(l10n.unlockWithBiometric),
                  ),
                ],
                if (hasPin) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _switchMode,
                    child: Text(pinMode ? l10n.usePassword : l10n.usePin),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
