// The 文件 page's symmetry, measured: path capsules with equal insets and
// one height, chevrons centred between them, the search field, capsules and
// list card on the same 16 margins, the search field's two end slots
// mirrored and its height unchanged by typing, glyphs centred in their slot.

import 'package:dsh_app/ui/common/breadcrumb_row.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/files/file_glyph.dart';
import 'package:dsh_app/ui/files/files_page.dart';
import 'package:dsh_app/ui/files/workspace_browser.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/files_harness.dart';

DateTime _now() => DateTime(2026, 10, 24, 15, 0);

Future<void> _pump(WidgetTester tester, {String path = 'lib', double textScale = 1, Size? size}) async {
  usePhoneView(tester);
  if (size != null) tester.view.physicalSize = size * 2;
  await tester.pumpWidget(
    filesApp(
      MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: WorkspaceFilesPage(sessionId: 's1', initialPath: path, now: _now),
      ),
      sampleWorkspace(),
    ),
  );
  await pumpFrames(tester, 12);
}

Rect _rect(WidgetTester tester, Finder finder) => tester.getRect(finder);

void _near(double actual, double expected, String what) =>
    expect(actual, moreOrLessEquals(expected, epsilon: 0.5), reason: what);

void main() {
  setUpAll(loadTestFonts);

  for (final scale in [1.0, 1.3]) {
    testWidgets('path capsules: equal insets, one height (×$scale)', (tester) async {
      await _pump(tester, textScale: scale);
      final capsules = find.byType(BreadcrumbCapsule);
      expect(capsules, findsNWidgets(2));
      final heights = <double>{};
      for (final element in capsules.evaluate()) {
        final capsule = find.byElementPredicate((e) => e == element);
        final box = _rect(tester, find.descendant(of: capsule, matching: find.byType(Container)));
        final text = _rect(tester, find.descendant(of: capsule, matching: find.byType(Text)));
        heights.add(box.height);
        _near(text.left - box.left, box.right - text.right, 'side insets');
        _near(text.left - box.left, BreadcrumbCapsule.inset, 'inset');
        _near(text.center.dy, box.center.dy, 'label centred');
      }
      expect(heights, {BreadcrumbRow.height});
      // The chevron sits midway between its capsules, on their centre line.
      final chevron = _rect(tester, find.byIcon(AppIcons.disclosure).first);
      final first = _rect(tester, find.descendant(of: capsules.at(0), matching: find.byType(Container)).first);
      final second = _rect(tester, find.descendant(of: capsules.at(1), matching: find.byType(Container)).first);
      _near(chevron.left - first.right, second.left - chevron.right, 'gaps');
      _near(chevron.center.dy, first.center.dy, 'chevron centred');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('search, capsules and card share the 16 margins', (tester) async {
    await _pump(tester);
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final search = _rect(tester, find.byType(WorkspaceSearchField));
    final firstCapsule = _rect(
      tester,
      find.descendant(of: find.byType(BreadcrumbCapsule).first, matching: find.byType(Container)).first,
    );
    // The card: the first row spans it edge to edge.
    final row = _rect(tester, find.byType(ListPageRow).first);
    _near(search.left, 16, 'search left');
    _near(width - search.right, 16, 'search right');
    _near(firstCapsule.left, 16, 'capsules left');
    _near(row.left, 16, 'card left');
    _near(width - row.right, 16, 'card right');
    // 12 between the search field and the capsules, and the capsules and
    // the card (whose first row starts 4 in).
    _near(firstCapsule.top - search.bottom, BreadcrumbRow.gap, 'gap above');
    _near(row.top - 4 - firstCapsule.bottom, BreadcrumbRow.gap, 'gap below');
  });

  testWidgets('search field: mirrored end slots, same height typed or not', (tester) async {
    await _pump(tester);
    final empty = _rect(tester, find.byType(WorkspaceSearchField));
    expect(empty.height, WorkspaceSearchField.height);
    await tester.enterText(find.byType(TextField), 'main');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpFrames(tester, 4);
    final typed = _rect(tester, find.byType(WorkspaceSearchField));
    expect(typed, empty);
    final search = _rect(tester, find.byIcon(AppIcons.search));
    final clear = _rect(tester, find.byIcon(AppIcons.clear));
    _near(search.center.dx - typed.left, typed.right - clear.center.dx, 'ends');
    _near(search.center.dy, typed.center.dy, 'search icon centred');
    _near(clear.center.dy, typed.center.dy, 'clear icon centred');
  });

  testWidgets('glyphs centred in the 32 slot; rows 52 and 64 high', (tester) async {
    await _pump(tester, path: '');
    final folderRow = _rect(tester, find.ancestor(of: find.text('lib'), matching: find.byType(ListPageRow)));
    final fileRow = _rect(tester, find.ancestor(of: find.text('README.md'), matching: find.byType(ListPageRow)));
    expect(folderRow.height, 52);
    expect(fileRow.height, 64);
    for (final rowFinder in [
      find.ancestor(of: find.text('lib'), matching: find.byType(ListPageRow)),
      find.ancestor(of: find.text('README.md'), matching: find.byType(ListPageRow)),
    ]) {
      final row = _rect(tester, rowFinder);
      final glyph = _rect(tester, find.descendant(of: rowFinder, matching: find.byType(FileGlyph)));
      expect(glyph.size, const Size.square(32));
      _near(glyph.left - row.left, ListPageRow.horizontal, 'glyph left');
      _near(glyph.center.dy, row.center.dy, 'glyph centred');
    }
  });

  testWidgets('narrow screen at 1.3× text: nothing overflows', (tester) async {
    await _pump(tester, path: 'lib', textScale: 1.3, size: const Size(360, 780));
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField), 'login');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpFrames(tester, 4);
    expect(tester.takeException(), isNull);
  });
}
