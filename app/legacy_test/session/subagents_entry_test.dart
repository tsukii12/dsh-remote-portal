import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/session_detail_state.dart';
import 'package:dsh_app/ui/session/session_detail_page.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

class _Panels extends SessionPanelsController {
  _Panels(super.sessionId);

  @override
  SessionPanels build() => SessionPanels.empty;
}

void main() {
  Future<void> pumpPage(WidgetTester tester, {required bool fromSubagents}) async {
    usePhoneView(tester);
    final harness = ChatHarness(session: 's1', connected: false);
    await tester.pumpWidget(
      testApp(
        fromSubagents
            ? const SessionDetailPage(sessionId: 's1', initialTab: SessionTab.subagents)
            : const SessionDetailPage(sessionId: 's1'),
        overrides: [
          ...harness.overrides,
          subagentLineageProvider.overrideWith((ref, sessionId) => const []),
          sessionPanelsProvider.overrideWith2(_Panels.new),
        ],
      ),
    );
    await pumpFrames(tester, 6);
  }

  testWidgets('子代理入口在没有派活记录时选中子代理并显示空状态', (tester) async {
    await pumpPage(tester, fromSubagents: true);
    final tabs = tester.widget<GlassSegments>(find.byType(GlassSegments));
    expect(tabs.labels, contains('子代理'));
    expect(tabs.labels[tabs.controller.index], '子代理');
    expect(find.byType(SubagentsTab), findsOneWidget);
    expect(find.text('没有派出子代理'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通详情入口没有派活记录时仍默认轨迹且不增加子代理页签', (tester) async {
    await pumpPage(tester, fromSubagents: false);
    final tabs = tester.widget<GlassSegments>(find.byType(GlassSegments));
    expect(tabs.labels, isNot(contains('子代理')));
    expect(tabs.labels[tabs.controller.index], '轨迹');
    expect(find.byType(TrajectoryTab), findsOneWidget);
    expect(find.text('没有派出子代理'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
