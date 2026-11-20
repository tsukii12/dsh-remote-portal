// The column plan of the home screen (AdaptiveLayout.resolve): window
// classes, when the list is a rail or a sidebar, how wide the detail panel
// is, and where 对话详情 opens. Pure numbers.
//
//   flutter test test/shell/adaptive/adaptive_layout_test.dart

import 'package:dsh_app/ui/shell/adaptive/adaptive_layout.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

AdaptiveLayout _resolve(
  double width, {
  double height = 800,
  EdgeInsets padding = EdgeInsets.zero,
  bool session = true,
  bool sidebarOpen = true,
  bool panelOpen = true,
}) => AdaptiveLayout.resolve(
  window: Size(width, height),
  padding: padding,
  hasSession: session,
  sidebarOpen: sidebarOpen,
  panelOpen: panelOpen,
);

void main() {
  group('window classes', () {
    test('Material 3 breakpoints', () {
      expect(WindowClass.of(390), WindowClass.compact);
      expect(WindowClass.of(599.9), WindowClass.compact);
      expect(WindowClass.of(600), WindowClass.medium);
      expect(WindowClass.of(839.9), WindowClass.medium);
      expect(WindowClass.of(840), WindowClass.expanded);
      expect(WindowClass.of(1280), WindowClass.expanded);
    });

    test('below 840 every column is hidden and the chat is the window', () {
      for (final width in [360.0, 599.0, 600.0, 720.0, 839.0]) {
        final layout = _resolve(width, height: 900);
        expect(layout.left, LeftPane.none, reason: '$width');
        expect(layout.panelShown, isFalse);
        expect(layout.panelAvailable, isFalse);
        expect(layout.chatRect, Rect.fromLTWH(0, 0, width, 900));
        expect(layout.menuAction, MenuAction.overlay);
      }
    });

    test('the detail is a page on phones, a sheet in between', () {
      expect(_resolve(390).detail, DetailPresentation.page);
      expect(_resolve(720).detail, DetailPresentation.sheet);
      expect(_resolve(1280).detail, DetailPresentation.panel);
      // Wide but nothing open: no panel to show.
      expect(_resolve(1280, session: false).detail, DetailPresentation.sheet);
    });
  });

  group('short windows: a phone on its side', () {
    test('under 480 tall is compact whatever the width', () {
      expect(WindowClass.of(915, 412), WindowClass.compact);
      expect(WindowClass.of(1280, 479.9), WindowClass.compact);
      expect(WindowClass.of(720, 412), WindowClass.compact);
      expect(WindowClass.of(840, 480), WindowClass.expanded);
      expect(WindowClass.of(600, 480), WindowClass.medium);
      expect(WindowClass.ofSize(const Size(915, 412)), WindowClass.compact);
    });

    test('915 × 412: one column, the drawer, 对话详情 as a page', () {
      const cutout = EdgeInsets.fromLTRB(36, 24, 0, 16);
      final layout = _resolve(915, height: 412, padding: cutout);
      expect(layout.windowClass, WindowClass.compact);
      expect(layout.left, LeftPane.none);
      expect(layout.panelAvailable, isFalse);
      expect(layout.menuAction, MenuAction.overlay);
      expect(layout.detail, DetailPresentation.page);
    });

    test('a tablet split top / bottom is short too', () {
      expect(_resolve(1280, height: 400).detail, DetailPresentation.page);
      expect(_resolve(1280, height: 400).left, LeftPane.none);
    });
  });

  group('1280 × 800 (tablet landscape)', () {
    test('panel shown: about 30% wide, the list folds into the rail', () {
      final layout = _resolve(1280);
      expect(layout.panelShown, isTrue);
      expect(layout.panelWidth, 384);
      expect(layout.left, LeftPane.rail);
      expect(layout.leftExtent, AdaptiveMetrics.railWidth);
      // The chat keeps more than its reading width (720 + 2 × 12).
      expect(layout.chatRect.width, 1280 - 68 - 384);
      expect(layout.chatRect.width, greaterThan(744));
      // The rail unfolds into the overlay drawer: no room for the sidebar.
      expect(layout.sidebarFits, isFalse);
      expect(layout.menuAction, MenuAction.overlay);
    });

    test('panel folded: the sidebar fits and the chat takes the rest', () {
      final layout = _resolve(1280, panelOpen: false);
      expect(layout.panelShown, isFalse);
      expect(layout.panelAvailable, isTrue);
      expect(layout.left, LeftPane.sidebar);
      expect(layout.chatRect, const Rect.fromLTRB(320, 0, 1280, 800));
      expect(layout.menuAction, MenuAction.collapse);
    });

    test('sidebar folded by hand: the rail, which unfolds it again', () {
      final layout = _resolve(1280, panelOpen: false, sidebarOpen: false);
      expect(layout.left, LeftPane.rail);
      expect(layout.menuAction, MenuAction.expand);
    });

    test('no conversation: no panel, the sidebar', () {
      final layout = _resolve(1280, session: false);
      expect(layout.panelAvailable, isFalse);
      expect(layout.panelExtent, 0);
      expect(layout.left, LeftPane.sidebar);
    });
  });

  group('panel width', () {
    test('30% of the window on the 4dp grid, 360–420', () {
      expect(AdaptiveMetrics.panelIdeal(840), 360);
      expect(AdaptiveMetrics.panelIdeal(1024), 360);
      expect(AdaptiveMetrics.panelIdeal(1280), 384);
      expect(AdaptiveMetrics.panelIdeal(1366), 408);
      expect(AdaptiveMetrics.panelIdeal(1600), 420);
      for (var w = 840.0; w <= 2000; w += 7) {
        expect(AdaptiveMetrics.panelIdeal(w) % 4, 0, reason: '$w');
      }
    });

    test('840 wide (a foldable in landscape): rail + phone-wide chat', () {
      final layout = _resolve(840);
      expect(layout.panelWidth, 360);
      expect(layout.chatRect.width, 840 - 68 - 360);
      expect(layout.chatRect.width, greaterThanOrEqualTo(AdaptiveMetrics.chatMin));
    });

    test('gives way to keep the chat 400 wide, then does not show', () {
      // A 48dp navigation bar on the right of a landscape window.
      const nav = EdgeInsets.only(right: 48);
      final narrow = _resolve(840, padding: nav);
      expect(narrow.panelWidth, 840 - 48 - 68 - 400);
      expect(narrow.chatRect.width, 400);
      // Too little left for the panel's minimum: the sheet instead.
      final cramped = _resolve(840, padding: const EdgeInsets.only(right: 96));
      expect(cramped.panelAvailable, isFalse);
      expect(cramped.detail, DetailPresentation.sheet);
    });

    test('the inset beside the panel belongs to it', () {
      const nav = EdgeInsets.only(right: 48);
      final layout = _resolve(1280, padding: nav);
      expect(layout.panelExtent, layout.panelWidth + 48);
      expect(layout.chatRect.right, 1280 - layout.panelExtent);
    });

    test('a cutout on the left widens the left column, not the chat', () {
      const cutout = EdgeInsets.only(left: 32);
      final layout = _resolve(1280, padding: cutout, panelOpen: false);
      expect(layout.left, LeftPane.sidebar);
      expect(layout.leftExtent, 320 + 32);
      expect(layout.chatRect.left, 352);
    });
  });

  group('sidebar', () {
    test('unfolds only while the chat keeps 600', () {
      // No conversation: 320 + 600 = 920 is the threshold.
      expect(_resolve(919, session: false).left, LeftPane.rail);
      expect(_resolve(920, session: false).left, LeftPane.sidebar);
      // With the panel, 1440 fits all three (320 + 600 + 420 = 1340).
      final wide = _resolve(1440);
      expect(wide.left, LeftPane.sidebar);
      expect(wide.panelShown, isTrue);
      expect(wide.chatRect.width, greaterThanOrEqualTo(600));
    });

    test('opening the panel folds it, closing unfolds it again', () {
      expect(_resolve(1280, panelOpen: false).left, LeftPane.sidebar);
      expect(_resolve(1280).left, LeftPane.rail);
    });

    test('a panel grid step does not fold a sidebar that already fits', () {
      for (final width in [1312.0, 1313.0, 1314.0, 1315.0, 1316.0]) {
        final layout = _resolve(width);
        expect(layout.left, LeftPane.sidebar, reason: '$width');
        expect(layout.chatRect.width, greaterThanOrEqualTo(600), reason: '$width');
      }
      expect(_resolve(1314).panelWidth, 392);
      expect(_resolve(1316).panelWidth, 396);
    });

    test('a folded sidebar can still be expanded at the panel grid step', () {
      final folded = _resolve(1314, sidebarOpen: false);
      expect(folded.left, LeftPane.rail);
      expect(folded.sidebarFits, isTrue);
      expect(folded.menuAction, MenuAction.expand);
      final unfolded = _resolve(1314);
      expect(unfolded.menuAction, MenuAction.collapse);
      expect(unfolded.chatRect.width, greaterThanOrEqualTo(600));
      expect(unfolded.panelWidth, folded.panelWidth);
    });

    for (final padding in [
      EdgeInsets.zero,
      const EdgeInsets.only(right: 16),
      const EdgeInsets.only(left: 32),
      const EdgeInsets.symmetric(horizontal: 48),
      const EdgeInsets.fromLTRB(17, 24, 41, 16),
    ]) {
      test('sidebar availability is monotonic with $padding', () {
        var fitted = false;
        for (var width = 840.0; width <= 1600; width += 0.25) {
          final layout = _resolve(width, padding: padding);
          final reason = '$width, $padding';
          if (fitted) expect(layout.sidebarFits, isTrue, reason: reason);
          fitted = layout.sidebarFits;
          if (layout.left == LeftPane.sidebar) {
            expect(layout.chatRect.width, greaterThanOrEqualTo(600), reason: reason);
            expect(layout.panelWidth, inInclusiveRange(360, 420), reason: reason);
            expect(layout.panelWidth % 4, 0, reason: reason);
          }
        }
        expect(fitted, isTrue);
      });
    }
  });

  test('equal inputs, equal layouts', () {
    expect(_resolve(1280), _resolve(1280));
    expect(_resolve(1280).hashCode, _resolve(1280).hashCode);
    expect(_resolve(1280), isNot(_resolve(1280, panelOpen: false)));
  });
}
