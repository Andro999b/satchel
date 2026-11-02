import 'package:flutter/material.dart';
import 'package:satchel_core/satchel_core.dart';

import '../l10n/l10n.dart';

IconData secretTypeIcon(SecretType type) => switch (type) {
  SecretType.password => Icons.password,
  SecretType.login => Icons.account_circle_outlined,
  SecretType.pem => Icons.verified_user_outlined,
  SecretType.recoveryCodes => Icons.pin_outlined,
  SecretType.note => Icons.sticky_note_2_outlined,
};

IconData secretIcon(Secret secret) => secretTypeIcon(secret.type);

/// Localized name of a kind of secret.
String secretTypeName(AppLocalizations l10n, SecretType type) => switch (type) {
  SecretType.password => l10n.secretTypePassword,
  SecretType.login => l10n.secretTypeLogin,
  SecretType.pem => l10n.secretTypePem,
  SecretType.recoveryCodes => l10n.secretTypeRecoveryCodes,
  SecretType.note => l10n.secretTypeNote,
};
