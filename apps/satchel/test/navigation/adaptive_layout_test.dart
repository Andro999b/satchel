import 'package:flutter_test/flutter_test.dart';
import 'package:satchel/src/navigation/adaptive_layout.dart';
import 'package:satchel/src/navigation/app_location.dart';

void main() {
  test('pane count follows the Material 3 window size classes', () {
    expect(paneCountForWidth(360), 1);
    expect(paneCountForWidth(599), 1);
    expect(paneCountForWidth(600), 2);
    expect(paneCountForWidth(839), 2);
    expect(paneCountForWidth(840), 3);
    expect(paneCountForWidth(1199), 3);
    expect(paneCountForWidth(1200), 4);
    expect(paneCountForWidth(2560), 4);
  });

  test('a single pane shows the current level only', () {
    for (final level in AppLevel.values) {
      expect(visibleLevels(level, 1), [level]);
    }
  });

  test('wider layouts add the next level, then parent levels', () {
    const s = AppLevel.storages, f = AppLevel.files;
    const l = AppLevel.secrets, d = AppLevel.secret;
    final expected = {
      (s, 2): [s, f],
      (f, 2): [f, l],
      (l, 2): [l, d],
      (d, 2): [l, d],
      (s, 3): [s, f],
      (f, 3): [s, f, l],
      (l, 3): [f, l, d],
      (d, 3): [f, l, d],
      (s, 4): [s, f],
      (f, 4): [s, f, l],
      (l, 4): [s, f, l, d],
      (d, 4): [s, f, l, d],
    };
    expected.forEach((input, levels) {
      expect(visibleLevels(input.$1, input.$2), levels, reason: '$input');
    });
  });

  test('panes get an equal share of the width for the pane count', () {
    expect(paneWidthFor(500, 1), 500);
    // 701 - 1 divider.
    expect(paneWidthFor(701, 2), 350);
    // 1202 - 2 dividers.
    expect(paneWidthFor(1202, 3), 400);
    // 1923 - 3 dividers.
    expect(paneWidthFor(1923, 4), 480);
  });
}
