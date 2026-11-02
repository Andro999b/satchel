import 'package:flutter/material.dart';
import 'package:satchel_core/satchel_core.dart';

import '../l10n/l10n.dart';

/// Calendar days from [now] until [expiresAt] in local time: 0 means today,
/// negative means the date has passed.
int daysUntil(DateTime expiresAt, DateTime now) {
  DateTime day(DateTime time) {
    final local = time.toLocal();
    return DateTime.utc(local.year, local.month, local.day);
  }

  return day(expiresAt).difference(day(now)).inDays;
}

/// How to highlight a secret whose expiry needs attention.
final class ExpiryHighlight {
  const ExpiryHighlight._({
    required this.status,
    required this.text,
    required this.icon,
    required this.foreground,
    required this.container,
    required this.onContainer,
  });

  /// The highlight for [secret] at [now], or `null` if it doesn't expire or
  /// isn't about to.
  static ExpiryHighlight? of(
    BuildContext context,
    Secret secret,
    DateTime now,
  ) {
    final expiresAt = secret.expiresAt;
    final status = secret.expiryStatus(now);
    if (expiresAt == null) return null;
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final days = daysUntil(expiresAt, now);
    return switch (status) {
      ExpiryStatus.none || ExpiryStatus.valid => null,
      ExpiryStatus.expired => ExpiryHighlight._(
        status: status,
        text: l10n.expiredDaysAgo(days < 0 ? -days : 0),
        icon: Icons.event_busy,
        foreground: colors.error,
        container: colors.errorContainer,
        onContainer: colors.onErrorContainer,
      ),
      ExpiryStatus.expiringSoon => ExpiryHighlight._(
        status: status,
        text: l10n.expiresInDays(days < 0 ? 0 : days),
        icon: Icons.schedule,
        foreground: colors.tertiary,
        container: colors.tertiaryContainer,
        onContainer: colors.onTertiaryContainer,
      ),
    };
  }

  final ExpiryStatus status;

  /// Relative description, e.g. "Expires in 5 days".
  final String text;
  final IconData icon;

  /// Color of icons and text on the normal surface.
  final Color foreground;

  /// Background tint and the color of content on it.
  final Color container;
  final Color onContainer;
}
