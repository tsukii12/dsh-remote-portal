// Measured symmetry of 对话详情: the capsule tabs (thumb concentric with the
// track, equal segments) and the bar (back key and its mirror, title centred).

import 'package:dsh_app/state/session_detail_state.dart';
import 'package:dsh_app/ui/common/segmented_pill.dart';
import 'package:dsh_app/ui/session/session_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../chat/support/run_info_fixture.dart';

class _Panels extends SessionPanelsController {
  _Panels(super.sessionId);

  @override
  SessionPanels build() => SessionPanels.empty;
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('tabs: thumb inset equally on every side, equal segments', (tester) async {
    usePhoneView(tester);
    final controller = TabController(length: 5, vsync: const TestVSync());
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: GlassSegments(
                key: const ValueKey('tabs'),
                controller: controller,
                labels: const ['轨迹', '改动', '文件', '进度', '上下文'],
              ),
            ),
          ),
        ),
      ),
    );
    final track = tester.getRect(find.byKey(const ValueKey('tabs')));
    Rect thumb() => tester.getRect(
      find.descendant(of: find.byKey(const ValueKey('tabs')), matching: find.byType(Positioned)).first,
    );
    const inset = SegmentedPill.inset;
    expect(thumb().left - track.left, inset);
    expect(thumb().top - track.top, inset);
    expect(track.bottom - thumb().bottom, inset);
    expect(thumb().width, (track.width - 2 * inset) / 5);

    controller.index = 4;
    await tester.pump();
    expect(track.right - thumb().right, moreOrLessEquals(inset));
    // Every label sits in the middle of its own segment.
    for (final (i, label) in ['轨迹', '改动', '文件', '进度', '上下文'].indexed) {
      final center = track.left + inset + (i + 0.5) * thumb().width;
      expect(tester.getCenter(find.text(label)).dx, moreOrLessEquals(center, epsilon: 0.01));
    }
  });

  testWidgets('bar: back key mirrored, title centred once collapsed', (tester) async {
    usePhoneView(tester);
    final harness = ChatHarness(session: 's1', states: {'s1': runInfoState(finished: true)});
    await tester.pumpWidget(
      testApp(
        const SessionDetailPage(sessionId: 's1'),
        overrides: [...harness.overrides, sessionPanelsProvider.overrideWith2(_Panels.new)],
      ),
    );
    await pumpFrames(tester, 6);
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final back = tester.getRect(find.byTooltip('返回'));
    expect(back.left, 12);
    expect(back.width, 44);
    // The bar title (faded in once the hero scrolls away) is centred on the
    // screen: the back key's 44 is mirrored on the right.
    final barTitle = find.text('修复登录重复提交').first;
    expect(tester.getCenter(barTitle).dx, moreOrLessEquals(width / 2, epsilon: 0.5));
    // The tabs strip keeps 16 on both sides.
    final tabs = tester.getRect(find.byType(GlassSegments));
    expect(tabs.left, 16);
    expect(width - tabs.right, 16);
  });
}
