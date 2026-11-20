import 'dart:convert';

import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:dsh_app/ui/common/page_hero.dart';
import 'package:dsh_app/ui/session/session_detail_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../chat/support/run_info_fixture.dart';

ChatState _snapshot(ChatTranscript transcript) =>
    ChatState(loading: false, items: transcript.items, turns: transcript.turns, running: transcript.running);

Future<ChatHarness> _pump(WidgetTester tester, Widget child, ChatState state) async {
  usePhoneView(tester);
  mockClipboard(tester);
  final harness = ChatHarness(session: 's1', states: {'s1': state});
  await tester.pumpWidget(
    testApp(
      Scaffold(body: child),
      overrides: [...harness.overrides, subagentLineageProvider.overrideWith((ref, sessionId) => const [])],
    ),
  );
  await pumpFrames(tester);
  return harness;
}

void main() {
  setUp(() => runClock = () => runInfoTestDispatched.add(const Duration(seconds: 1)));
  tearDown(() => runClock = DateTime.now);

  for (final section in const <Widget>[
    SessionHero(sessionId: 's1', title: '对话详情'),
    TrajectoryTab(sessionId: 's1'),
    ChangesTab(sessionId: 's1'),
    SubagentsTab(sessionId: 's1'),
  ]) {
    testWidgets('${section.runtimeType} ignores text-only stream publications', (tester) async {
      final transcript = runInfoTranscript();
      final harness = await _pump(tester, section, _snapshot(transcript));
      final turns = transcript.turns;
      transcript.apply(
        AssistantStreamStarted('detail-stream', 0, turn: 2, step: 99, startedAfterSeq: transcript.cursor),
      );
      var builds = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        if (identical(element.widget, section)) builds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);

      for (var index = 0; index < 10; index++) {
        transcript.apply(
          AssistantChunkEvent(
            'detail-stream',
            index + 1,
            index: index,
            time: runInfoTestDispatched,
            chunk: const TextDeltaChunk(0, 'x'),
          ),
        );
        expect(transcript.turns, same(turns));
        expect(transcript.items.whereType<AssistantChatItem>().last.text, 'x' * (index + 1));
        harness.controllers['s1']!.emit(_snapshot(transcript));
        await tester.pump(const Duration(milliseconds: 32));
      }

      debugPrint('[WORK] ${section.runtimeType}: 10 text publications, $builds section rebuilds');
      expect(builds, 0, reason: 'Only assistant prose changed; this section does not render it.');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('same-count tool replacements still update file names and hero totals', (tester) async {
    ToolChatItem write(String path, ToolStatus status) => ToolChatItem(
      callId: 'detail-write',
      name: 'write',
      arguments: jsonEncode({'file_path': path, 'content': 'one line\n'}),
      status: status,
    );
    final harness = await _pump(
      tester,
      const Column(
        children: [
          SessionHero(sessionId: 's1', title: '对话详情'),
          Expanded(child: ChangesTab(sessionId: 's1')),
        ],
      ),
      ChatState(loading: false, items: [write('old.txt', ToolStatus.running)]),
    );
    String fileCount() =>
        tester.widget<HeroStat>(find.byWidgetPredicate((widget) => widget is HeroStat && widget.label == '改动文件')).value;
    expect(fileCount(), '0');
    expect(find.text('old.txt'), findsNothing);

    harness.controllers['s1']!.emit(ChatState(loading: false, items: [write('old.txt', ToolStatus.succeeded)]));
    await pumpFrames(tester);
    expect(fileCount(), '1');
    expect(find.text('old.txt'), findsOneWidget);

    harness.controllers['s1']!.emit(ChatState(loading: false, items: [write('new.txt', ToolStatus.succeeded)]));
    await pumpFrames(tester);
    expect(fileCount(), '1');
    expect(find.text('old.txt'), findsNothing);
    expect(find.text('new.txt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-count user prompt replacements still update the trajectory', (tester) async {
    final start = runInfoTurnTwoStart;
    final turns = [TurnTrace(turn: 1, startSeq: 10, start: start, spans: const [])];
    ChatState state(String prompt) => ChatState(
      loading: false,
      turns: turns,
      items: [UserChatItem(seq: 11, time: start, text: prompt, images: const [], files: const [])],
    );
    final harness = await _pump(tester, const TrajectoryTab(sessionId: 's1'), state('原问题'));
    expect(find.text('原问题'), findsOneWidget);

    harness.controllers['s1']!.emit(state('替换后的问题'));
    await pumpFrames(tester);
    expect(find.text('原问题'), findsNothing);
    expect(find.text('替换后的问题'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
