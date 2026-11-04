import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../accounts/account_management_dialog.dart';
import '../l10n/l10n.dart';
import 'auto_lock_settings.dart';

/// The app settings: Google accounts and the auto-lock delay.
class SettingsButton extends ConsumerWidget {
  const SettingsButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final delay = ref.watch(autoLockSettingProvider).value;
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.account_circle_outlined),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (context) => const AccountManagementDialog(),
          ),
          child: Text(l10n.googleAccountsMenu),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.lock_clock_outlined),
          onPressed: () => showAutoLockPicker(context),
          child: Text(
            delay == null
                ? l10n.autoLockMenu
                : l10n.autoLockMenuValue(autoLockDelayShortName(l10n, delay)),
          ),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: l10n.settingsTooltip,
        icon: const Icon(Icons.settings_outlined),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// Lets the user choose the [AutoLockDelay]: a bottom sheet on compact
/// screens, a dialog otherwise. Choosing one saves it and closes.
Future<void> showAutoLockPicker(BuildContext context) {
  if (MediaQuery.sizeOf(context).width < 600) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Fits all choices instead of the default 9/16 of the screen height.
      isScrollControlled: true,
      builder: (context) => const SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: _AutoLockPicker(sheet: true),
        ),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.l10n.autoLockMenu),
      contentPadding: const EdgeInsets.only(top: 16, bottom: 8),
      content: const SizedBox(width: 360, child: _AutoLockPicker()),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
        ),
      ],
    ),
  );
}

class _AutoLockPicker extends ConsumerWidget {
  const _AutoLockPicker({this.sheet = false});

  /// Adds the title, which a dialog shows itself.
  final bool sheet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final delay = ref.watch(autoLockSettingProvider).value;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (sheet)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(l10n.autoLockMenu, style: theme.textTheme.titleLarge),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(l10n.autoLockDescription),
          ),
          const SizedBox(height: 8),
          RadioGroup<AutoLockDelay>(
            groupValue: delay,
            onChanged: (choice) {
              if (choice == null) return;
              ref.read(autoLockSettingProvider.notifier).set(choice);
              Navigator.pop(context);
            },
            child: Column(
              children: [
                for (final choice in AutoLockDelay.values)
                  RadioListTile<AutoLockDelay>(
                    value: choice,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    title: Text(autoLockDelayName(l10n, choice)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String autoLockDelayName(AppLocalizations l10n, AutoLockDelay delay) =>
    switch (delay) {
      AutoLockDelay.oneMinute => l10n.autoLockMinutes(1),
      AutoLockDelay.fiveMinutes => l10n.autoLockMinutes(5),
      AutoLockDelay.fifteenMinutes => l10n.autoLockMinutes(15),
      AutoLockDelay.thirtyMinutes => l10n.autoLockMinutes(30),
      AutoLockDelay.oneHour => l10n.autoLockOneHour,
      AutoLockDelay.never => l10n.autoLockNever,
    };

/// For the settings menu, where space is short.
String autoLockDelayShortName(AppLocalizations l10n, AutoLockDelay delay) =>
    switch (delay) {
      AutoLockDelay.oneMinute => l10n.autoLockMinutesShort(1),
      AutoLockDelay.fiveMinutes => l10n.autoLockMinutesShort(5),
      AutoLockDelay.fifteenMinutes => l10n.autoLockMinutesShort(15),
      AutoLockDelay.thirtyMinutes => l10n.autoLockMinutesShort(30),
      AutoLockDelay.oneHour => l10n.autoLockOneHourShort,
      AutoLockDelay.never => l10n.autoLockNever,
    };
