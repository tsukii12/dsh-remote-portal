// Secondary pages on wide windows: the headline and the content keep the
// reading width, centred; the bar's keys stay on the window's edges. Phones
// are untouched.
//
//   flutter test test/shell/adaptive/page_frame_wide_test.dart

import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../chat/support/harness.dart';
import 'support.dart';

Future<void> _pump(WidgetTester tester, Size size) async {
  useWindow(tester, size);
  await tester.pumpWidget(
    testApp(
      AppPage.list(
        title: '设置',
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(key: const ValueKey('card'), height: 120),
          ),
        ],
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final width in [1280.0, 900.0]) {
    testWidgets('$width wide: one centred column, 720 wide', (tester) async {
      await _pump(tester, Size(width, 800));
      final card = tester.getRect(find.byKey(const ValueKey('card')));
      final side = (width - 720) / 2;
      expect(card.left, side + 16);
      expect(width - card.right, side + 16);
      // The headline on the column's 24.
      expect(tester.getRect(find.text('设置').first).left, side + 24);
      // The back key stays on the window's 12.
      expect(tester.getRect(find.byTooltip('返回')).left, 12);
    });
  }

  for (final width in [390.0, 720.0]) {
    testWidgets('$width wide: edge to edge as before', (tester) async {
      await _pump(tester, Size(width, 844));
      final card = tester.getRect(find.byKey(const ValueKey('card')));
      expect(card.left, 16);
      expect(width - card.right, 16);
      expect(tester.getRect(find.text('设置').first).left, 24);
    });
  }
}
