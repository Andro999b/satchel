import 'app_location.dart';

/// Widest the secret pane's fields get, so they read close together.
const secretPaneMaxWidth = 560.0;

/// Width of the divider between two panes.
const paneDividerWidth = 1.0;

/// Number of side-by-side panes for a window of [width] logical pixels, by
/// Material 3 window size class: compact 1, medium 2, expanded 3, large 4.
int paneCountForWidth(double width) => switch (width) {
  < 600 => 1,
  < 840 => 2,
  < 1200 => 3,
  _ => 4,
};

/// The consecutive levels to show side by side with [paneCount] panes when
/// the user is at [level].
///
/// Always ends with [level], followed by the next (still empty) level when
/// there is room, so the user sees where a selection will open. When not
/// all levels fit, the top ones are hidden first.
List<AppLevel> visibleLevels(AppLevel level, int paneCount) {
  const levels = AppLevel.values;
  final last = paneCount > 1
      ? (level.index + 1).clamp(0, levels.length - 1)
      : level.index;
  final first = (last - paneCount + 1).clamp(0, last);
  return levels.sublist(first, last + 1);
}

/// Width of each pane but the last in a window of [width] logical pixels
/// that fits [paneCount] panes: an equal share, with a divider between each
/// pair. The last shown pane fills the rest.
double paneWidthFor(double width, int paneCount) =>
    (width - (paneCount - 1) * paneDividerWidth) / paneCount;
