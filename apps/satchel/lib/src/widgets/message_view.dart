import 'package:flutter/material.dart';

/// Centered icon and text for empty, placeholder and error states.
///
/// Set [scrollable] inside a `RefreshIndicator` so pull-to-refresh works.
class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.icon,
    required this.text,
    this.detail,
    this.action,
    this.scrollable = false,
  });

  final IconData icon;
  final String text;
  final String? detail;
  final Widget? action;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text(text, textAlign: TextAlign.center),
          if (detail case final detail?) ...[
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (action case final action?) ...[
            const SizedBox(height: 16),
            action,
          ],
        ],
      ),
    );
    if (!scrollable) return Center(child: content);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(child: content),
        ),
      ),
    );
  }
}
