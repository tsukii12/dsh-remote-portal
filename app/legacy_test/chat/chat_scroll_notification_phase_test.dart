import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

void main() {
  testWidgets('a ballistic collapse to short content publishes scroll state after layout', (tester) async {
    usePhoneView(tester);
    ChatState content(String reply) => ChatState(loading: false, items: [user(1, 'First prompt'), assistant(2, reply)]);
    final harness = ChatHarness(
      session: 's1',
      states: {'s1': content(List.filled(80, 'A long paragraph.').join('\n\n'))},
    );
    final under = ValueNotifier<double>(0);
    addTearDown(under.dispose);
    final publishedPhases = <SchedulerPhase>[];
    under.addListener(() => publishedPhases.add(SchedulerBinding.instance.schedulerPhase));
    var layoutEnds = 0;
    var afterFling = false;
    var inertialUpdates = 0;
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Column(
            children: [
              ValueListenableBuilder<double>(
                valueListenable: under,
                builder: (_, value, _) => SizedBox(height: 24, child: Text('Under: $value')),
              ),
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.depth == 0 &&
                        n is ScrollEndNotification &&
                        SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
                      layoutEnds++;
                    }
                    if (afterFling && n is ScrollUpdateNotification && n.dragDetails == null) inertialUpdates++;
                    return false;
                  },
                  child: ChatList(sessionId: 's1', topInset: 0, bottomInset: 0, scrolledUnder: under),
                ),
              ),
            ],
          ),
        ),
        overrides: harness.overrides,
      ),
    );
    await pumpFrames(tester, 10);
    final position = tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller!.position;
    await tester.fling(find.byType(CustomScrollView), const Offset(0, 160), 1800);
    afterFling = true;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(position.isScrollingNotifier.value, isTrue);
    expect(inertialUpdates, greaterThan(0));
    expect(position.maxScrollExtent, greaterThan(position.minScrollExtent));
    harness.controllers['s1']!.emit(content('Short reply'));
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull, reason: 'frame $frame');
      expect(position.pixels, closeTo(position.minScrollExtent, .01));
      expect(position.minScrollExtent, closeTo(position.maxScrollExtent, .01));
    }
    expect(layoutEnds, greaterThan(0), reason: 'The test must exercise the layout-phase ScrollEnd path.');
    expect(publishedPhases, isNot(contains(SchedulerPhase.persistentCallbacks)));
    expect(position.minScrollExtent, closeTo(position.maxScrollExtent, .01));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('u1'))).dy,
      closeTo(tester.getTopLeft(find.byType(ChatList)).dy + AppSpace.sm, .5),
    );
    expect(under.value, 0);
  });
}
