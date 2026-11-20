import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/trajectory_sheet.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  setUpAll(loadTestFonts);
  testWidgets('trajectory close circle stays aligned while the turn finishes', (tester) async {
    usePhoneView(tester);
    final start = DateTime.now();
    ChatState state(bool running) => ChatState(
      loading: false,
      turns: [
        TurnTrace(
          turn: 1,
          startSeq: 1,
          start: start,
          spans: const [],
          endSeq: running ? null : 2,
          end: running ? null : start.add(const Duration(seconds: 1)),
          endReason: running ? null : const TurnEndReason('completed'),
        ),
      ],
    );
    final harness = ChatHarness(session: 's1', states: {'s1': state(true)});
    await tester.pumpWidget(
      testApp(
        const Scaffold(body: TrajectorySheet(sessionId: 's1', turn: 1)),
        overrides: harness.overrides,
      ),
    );
    await tester.pump();
    final close = find.byType(SheetIconButton);
    final initial = tester.getRect(close);
    final title = find.byWidgetPredicate((w) => w is Text && (w.textSpan?.toPlainText().startsWith('本轮轨迹') ?? false));
    expect(initial.center.dy, closeTo(tester.getCenter(title).dy, 0.5));
    // The 44px hit target contains a centered 32px visible circle.
    expect(initial.right - 6, closeTo(390 - 20, 0.5));
    harness.controllers['s1']!.emit(state(false));
    await pumpFrames(tester, 4);
    expect(tester.getRect(close), initial);
  });
  for (final scale in [1.0, 2.0]) {
    testWidgets('actual trajectory route has one handle and mirrored title insets at $scale', (tester) async {
      usePhoneView(tester);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final start = DateTime(2026, 10, 27);
      final harness = ChatHarness(
        session: 's1',
        states: {
          's1': ChatState(
            loading: false,
            turns: [
              TurnTrace(
                turn: 1,
                startSeq: 1,
                start: start,
                spans: const [],
                endSeq: 2,
                end: start.add(const Duration(seconds: 1)),
                endReason: const TurnEndReason('completed'),
              ),
            ],
          ),
        },
      );
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showTrajectorySheet(context, sessionId: 's1', turn: 1),
                child: const Text('打开'),
              ),
            ),
          ),
          overrides: harness.overrides,
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.byType(SheetDragHandle), findsOneWidget);
      expect(find.byTooltip('关闭'), findsNothing);
      final title = find.byWidgetPredicate((w) => w is Text && (w.textSpan?.toPlainText().startsWith('本轮轨迹') ?? false));
      final column = find.ancestor(of: title, matching: find.byType(Expanded)).first;
      final rect = tester.getRect(column);
      expect(rect.left, closeTo(20, 0.01));
      expect(390 - rect.right, closeTo(20, 0.01));
      expect(tester.takeException(), isNull);
    });
  }
}
