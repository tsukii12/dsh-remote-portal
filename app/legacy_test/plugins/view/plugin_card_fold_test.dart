// A finished turn folds its process into one line; a plugin tool's native
// card stays in the stream (between the folded line and the answer), the
// way the artifact card stays outside the fold. The whole chat screen, so
// the list's spacing and keys are the real ones.

import 'dart:convert';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_state.dart' show chatClock;
import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_app/ui/chat/widgets/turn_process.dart';
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../chat/support/harness.dart';
import '../../chat/support/sample_chat.dart' show assistant, user;

final _t0 = DateTime(2026, 10, 23, 14, 30);

TurnTrace _turn(int startSeq, int endSeq, int seconds) => TurnTrace(
  turn: startSeq,
  startSeq: startSeq,
  start: _t0,
  spans: const [],
  endSeq: endSeq,
  end: _t0.add(Duration(seconds: seconds)),
  endReason: const TurnEndReason('completed'),
);

ToolChatItem _call(int seq, String id, String name, Map<String, Object?> args, {String result = '', Object? meta}) =>
    ToolChatItem(
      callId: id,
      name: name,
      arguments: jsonEncode(args),
      status: ToolStatus.succeeded,
      seq: seq,
      resultParts: [TextPart(result)],
      meta: meta,
    );

const _forecast = {
  'type': 'stack',
  'title': '东京 · 周末',
  'children': [
    {
      'type': 'row',
      'children': [
        {'type': 'metric', 'label': '周六', 'value': '21° / 15°', 'caption': '晴 · 降水 10%'},
        {'type': 'metric', 'label': '周日', 'value': '18° / 13°', 'caption': '小雨 · 降水 70%', 'tone': 'warn'},
      ],
    },
    {'type': 'text', 'text': '数据：Open-Meteo', 'tone': 'muted'},
  ],
};

ChatState _state() => ChatState(
  items: [
    user(1, '周末想出去走走，附近有什么推荐？'),
    assistant(2, '', reasoning: '搜一下东京周边适合周末的地方。'),
    _call(2, 'search', 'web_search', {'query': '东京周边 周末 一日游'}, result: '镰仓、箱根、日光……'),
    assistant(4, '镰仓和箱根都很合适：镰仓近，看海和寺院；箱根远一点，泡温泉。'),
    user(6, '那这周末天气怎么样？'),
    assistant(7, '', reasoning: '查一下东京周末的天气。'),
    _call(
      7,
      'weather',
      'weather_forecast',
      {'city': '东京', 'days': 2},
      result: 'Sat: clear 21/15, Sun: light rain 18/13',
      meta: {'dsh-go/view': _forecast},
    ),
    assistant(9, '**周六**更适合出门，去镰仓正好；周日有雨，可以留给箱根的温泉。'),
  ],
  turns: [_turn(0, 5, 18), _turn(5, 10, 9)],
  running: false,
  title: '周末去哪儿',
  loading: false,
  model: const ModelSelection(provider: 'deepseek-official', model: 'deepseek-v4-pro', reasoningEffort: 'high'),
);

Future<void> _pump(WidgetTester tester, Brightness brightness) async {
  usePhoneView(tester);
  final harness = ChatHarness(session: 's1', states: {'s1': _state()});
  await tester.pumpWidget(testApp(const ChatScreen(), brightness: brightness, overrides: harness.overrides));
  await pumpFrames(tester, 10);
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    chatClock = () => DateTime(2026, 10, 23, 15, 20);
    runClock = () => DateTime(2026, 10, 23, 15, 20);
  });

  testWidgets('folded: the card stays, its tool row is inside', (tester) async {
    await _pump(tester, Brightness.light);
    // Both turns folded.
    expect(find.byType(TurnProcess), findsNWidgets(2));
    // The card is in the stream, alone: no tool line above it.
    expect(find.byType(PluginToolCard), findsOneWidget);
    expect(find.text('东京 · 周末'), findsOneWidget);
    expect(find.text('21° / 15°'), findsOneWidget);
    final card = tester.getRect(find.byType(PluginToolCard));
    // The list builds bottom-up: the second turn's fold is the lower one.
    Finder secondFold() {
      final all = find.byType(TurnProcess).evaluate().toList()
        ..sort(
          (a, b) => (a.renderObject! as RenderBox)
              .localToGlobal(Offset.zero)
              .dy
              .compareTo((b.renderObject! as RenderBox).localToGlobal(Offset.zero).dy),
        );
      final target = all.last;
      return find.byElementPredicate((e) => identical(e, target));
    }

    final folds = secondFold();
    final answer = tester.getRect(find.textContaining('更适合出门'));
    expect(card.top, greaterThan(tester.getRect(folds).bottom));
    expect(card.bottom, lessThan(answer.top));
    // The first turn had no card: nothing of it is outside its fold.
    expect(find.text('镰仓、箱根、日光……'), findsNothing);
    // Opening the fold shows the tool row (titled), not a second card.
    await tester.tap(folds);
    await pumpFrames(tester, 16);
    final opened = secondFold();
    expect(find.byType(PluginToolCard), findsOneWidget);
    expect(find.descendant(of: opened, matching: find.byType(ToolRow)), findsOneWidget);
    expect(find.descendant(of: opened, matching: find.text('东京 · 周末')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('folded turns with a plugin card ($suffix)', (tester) async {
      await _pump(tester, brightness);
      await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/plugin_card_folded_$suffix.png'));
    });
  }
}
