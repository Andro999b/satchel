import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../files/files_pane.dart';
import '../secrets/secret_pane.dart';
import '../secrets/secrets_pane.dart';
import '../storage/storages_pane.dart';
import '../widgets/message_view.dart';
import 'adaptive_layout.dart';
import 'app_location.dart';
import '../l10n/l10n.dart';

/// The app's adaptive layout: one pane per level (storages → files →
/// secrets → secret), side by side as far as the window width allows.
///
/// On compact windows only the current level is shown. System back, and the
/// back button of the first pane when its parent is hidden, go one level up.
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = ref.watch(currentLocationProvider);
    final notifier = ref.read(currentLocationProvider.notifier);

    return PopScope(
      canPop: location.level == AppLevel.storages,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) notifier.up();
      },
      // Panes are nested Scaffolds, so snack bars appear once, here.
      child: Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) {
            final paneCount = paneCountForWidth(constraints.maxWidth);
            final levels = visibleLevels(location.level, paneCount);
            final width = paneWidthFor(constraints.maxWidth, paneCount);
            final onBack = levels.first == AppLevel.storages
                ? null
                : notifier.up;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, level) in levels.indexed) ...[
                  if (i > 0)
                    const VerticalDivider(
                      width: paneDividerWidth,
                      thickness: paneDividerWidth,
                    ),
                  // The last pane fills the rest, including unused slots.
                  if (i < levels.length - 1)
                    SizedBox(
                      width: width,
                      child: _pane(
                        context.l10n,
                        level,
                        location,
                        i == 0 ? onBack : null,
                      ),
                    )
                  else
                    Expanded(
                      child: _pane(
                        context.l10n,
                        level,
                        location,
                        i == 0 ? onBack : null,
                      ),
                    ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  static Widget _pane(
    AppLocalizations l10n,
    AppLevel level,
    AppLocation location,
    VoidCallback? onBack,
  ) {
    final AppLocation(:storageId, :filePath, :secretId) = location;
    return switch (level) {
      AppLevel.storages => const StoragesPane(),
      AppLevel.files when storageId != null => FilesPane(
        key: ValueKey(storageId),
        storageId: storageId,
        onBack: onBack,
      ),
      AppLevel.secrets when storageId != null && filePath != null =>
        SecretsPane(
          key: ValueKey((storageId, filePath)),
          storageId: storageId,
          path: filePath,
          onBack: onBack,
        ),
      AppLevel.secret
          when storageId != null && filePath != null && secretId != null =>
        SecretPane(
          key: ValueKey(secretId),
          storageId: storageId,
          path: filePath,
          secretId: secretId,
          onBack: onBack,
        ),
      AppLevel.files => _EmptyPane(
        icon: Icons.folder_open_outlined,
        text: l10n.selectStorage,
      ),
      AppLevel.secrets => _EmptyPane(
        icon: Icons.lock_outline,
        text: l10n.selectVaultFile,
      ),
      AppLevel.secret => _EmptyPane(
        icon: Icons.key_outlined,
        text: l10n.selectSecret,
      ),
    };
  }
}

/// Placeholder for the level that a selection in the previous pane opens.
class _EmptyPane extends StatelessWidget {
  const _EmptyPane({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: MessageView(icon: icon, text: text),
    );
  }
}
