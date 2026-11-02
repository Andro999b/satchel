import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';

export '../../l10n/app_localizations.dart';

extension AppLocalizationsContext on BuildContext {
  /// The app's strings for the current locale.
  AppLocalizations get l10n => AppLocalizations.of(this);
}
