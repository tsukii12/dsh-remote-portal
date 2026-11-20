import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';
import 'turn_settle_test.dart' show state;

enum _Head { prompt, tool, assistant, mergedTools, toolOnlyPage }

ToolChatItem _oldTool(int seq) =>
    ToolChatItem(callId: 'previous-$seq', name: 'bash', arguments: '{}', status: ToolStatus.succeeded, seq: seq);

ChatState _snapshot({
  int older = 0,
  _Head head = _Head.tool,
  bool trace = true,
  bool running = true,
  List<CommandNotice> commands = const [],
}) {
  final current = state(running: running);
  return ChatState(
    loading: false,
    running: running,
    hasMoreHistory: true,
    turns: trace ? current.turns : const [],
    commands: commands,
    items: [
      for (var i = -older; i < 0; i++)
        if (head == _Head.toolOnlyPage || (head == _Head.mergedTools && i >= -2))
          _oldTool(i)
        else
          user(i, 'Earlier $i ${'text ' * 10}'),
      if (head == _Head.tool || head == _Head.mergedTools) _oldTool(0),
      if (head == _Head.assistant) assistant(2, 'Opening text'),
      ...head == _Head.assistant ? current.items.skip(1) : current.items,
    ],
  );
}

ScrollPosition _position(WidgetTester tester) =>
    tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller!.position;

Finder _reading(_Head head) => find.text(head == _Head.assistant ? 'Opening text' : '问题', findRichText: true);

Future<FakeChatController> _open(
  WidgetTester tester, {
  _Head head = _Head.tool,
  bool trace = true,
  bool fluid = false,
}) async {
  usePhoneView(tester);
  final harness = ChatHarness(
    session: 's1',
    states: {'s1': _snapshot(head: head, trace: trace)},
  );
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: AppMotionScope(
          fluid: fluid,
          child: const ChatList(sessionId: 's1', topInset: 24, bottomInset: 6),
        ),
      ),
      overrides: harness.overrides,
    ),
  );
  final reply = find.byWidgetPredicate((w) => w is AssistantMessage && w.item.text == '最终回答');
  expect(tester.getBottomRight(reply).dy, closeTo(tester.getRect(find.byType(ChatList)).bottom - 14, .5));
  await pumpFrames(tester, 20);
  final p = _position(tester);
  await tester.drag(find.byType(CustomScrollView), Offset(0, p.pixels - p.minScrollExtent + p.viewportDimension * 2));
  await pumpFrames(tester, 30);
  expect(p.extentAfter, greaterThan(100));
  expect(harness.controllers['s1']!.loadOlderCalls, greaterThan(0));
  return harness.controllers['s1']!;
}

double _readingTop(WidgetTester tester, [_Head head = _Head.tool]) => _visibleTop(tester, _reading(head));

double _visibleTop(WidgetTester tester, Finder reading) {
  expect(reading, findsOneWidget);
  final rect = tester.getRect(reading);
  final viewport = tester.getRect(find.byType(ChatList));
  expect(rect.top, greaterThanOrEqualTo(viewport.top + 24));
  expect(rect.bottom, lessThan(viewport.bottom - 14));
  return rect.top;
}

Future<void> _expectHeld(WidgetTester tester, double before, {_Head head = _Head.tool, Finder? reading}) async {
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    expect(_visibleTop(tester, reading ?? _reading(head)), closeTo(before, .5), reason: 'frame $frame');
    expect(tester.takeException(), isNull);
  }
}

SessionLogEvent _event(int seq, String type, Map<String, Object?> data) =>
    SessionLogEvent.fromJson({'seq': seq, 'time': 1000 + seq, 'type': type, 'data': data});

ChatTranscript _partialTranscript({bool stablePrefix = false}) {
  final transcript = ChatTranscript()..hasMoreHistory = true;
  if (stablePrefix) {
    transcript.apply(
      _event(95, 'user/message', {
        'id': 'old-human',
        'role': 'user',
        'source': {'kind': 'user'},
        'content': [
          {'type': 'text', 'text': 'Earlier prompt'},
        ],
      }),
    );
  }
  return transcript
    ..apply(_event(100, 'tool/call', {'turn': 1, 'step': 1, 'callId': 'old-tool', 'name': 'bash', 'arguments': '{}'}))
    ..apply(
      _event(101, 'tool/result', {
        'turn': 1,
        'step': 1,
        'message': {
          'id': 'old-result',
          'role': 'tool',
          'toolCallId': 'old-tool',
          'content': [
            {'type': 'text', 'text': 'done'},
          ],
        },
      }),
    )
    ..apply(
      _event(102, 'turn/end', {
        'turn': 1,
        'reason': {'kind': 'completed'},
      }),
    )
    ..apply(_event(200, 'turn/start', {'turn': 2}));
}

ChatState _transcriptSnapshot(ChatTranscript transcript, {bool reasoningHead = false}) => ChatState(
  loading: false,
  running: true,
  hasMoreHistory: transcript.hasMoreHistory,
  turns: transcript.turns,
  items: [
    ...transcript.items,
    if (reasoningHead) assistant(201, '', reasoning: 'Current process reasoning') else user(201, '问题'),
    for (var i = 0; i < 15; i++) ...[
      ToolChatItem(callId: 'current-$i', name: 'bash', arguments: '{}', status: ToolStatus.succeeded, seq: 202 + i * 3),
      assistant(203 + i * 3, '', reasoning: 'Thinking $i'),
    ],
    assistant(300, 'Final reply'),
  ],
);

void main() {
  setUpAll(loadTestFonts);
  for (final fluid in [false, true]) {
    for (final head in _Head.values) {
      testWidgets('partial history prepends keep visible text (fluid=$fluid, head=${head.name})', (tester) async {
        final chat = await _open(tester, head: head, fluid: fluid);
        final before = _readingTop(tester, head);
        for (final count in [3, 6, 31]) {
          chat.emit(_snapshot(older: count, head: head));
          await _expectHeld(tester, before, head: head);
        }
      });
    }
    testWidgets('prepending still preserves the old no-trace fallback (fluid=$fluid)', (tester) async {
      final chat = await _open(tester, trace: false, fluid: fluid);
      final before = _readingTop(tester);
      chat.emit(_snapshot(older: 3, trace: false));
      await _expectHeld(tester, before);
    });

    for (final stablePrefix in [false, true]) {
      for (final reasoningHead in [false, true]) {
        testWidgets(
          'metadata-only history preserves visible text (fluid=$fluid, stablePrefix=$stablePrefix, reasoningHead=$reasoningHead)',
          (tester) async {
            usePhoneView(tester);
            final transcript = _partialTranscript(stablePrefix: stablePrefix);
            final initial = _transcriptSnapshot(transcript, reasoningHead: reasoningHead);
            expect(transcript.turns.map((turn) => turn.startSeq), [200]);
            expect(transcript.items, hasLength(stablePrefix ? 2 : 1));
            expect((transcript.items.last as ToolChatItem).seq, 100);
            final itemKeys = transcript.items.map((item) => item.key).toList();
            final initialRows = deriveRows(items: initial.items, turns: initial.turns, running: true, foldTurns: true);
            expect(initialRows.first, stablePrefix ? isA<UserRow>() : isA<ToolCallRow>());
            expect(initialRows[stablePrefix ? 1 : 0], isA<ToolCallRow>());
            final harness = ChatHarness(session: 's1', states: {'s1': initial});
            await tester.pumpWidget(
              testApp(
                Scaffold(
                  body: AppMotionScope(
                    fluid: fluid,
                    child: const ChatList(sessionId: 's1', topInset: 24, bottomInset: 6),
                  ),
                ),
                overrides: harness.overrides,
              ),
            );
            await pumpFrames(tester, 20);
            final p = _position(tester);
            await tester.drag(
              find.byType(CustomScrollView),
              Offset(0, p.pixels - p.minScrollExtent + p.viewportDimension * 2),
            );
            await pumpFrames(tester, 30);
            expect(p.extentAfter, greaterThan(100));
            expect(harness.controllers['s1']!.loadOlderCalls, greaterThan(0));
            final reading = reasoningHead
                ? find.textContaining('Current process reasoning', findRichText: true)
                : find.text('问题', findRichText: true);
            final before = _visibleTop(tester, reading);

            transcript.prependHistory(
              HistoryPage([
                _event(90, 'turn/start', {'turn': 1}),
              ], true),
            );
            expect(transcript.oldestSeq, 90);
            expect(
              transcript.items.map((item) => item.key),
              itemKeys,
              reason: 'The page adds no message/tool/command.',
            );
            expect((transcript.items.last as ToolChatItem).seq, 100);
            expect(transcript.turns.map((turn) => turn.startSeq), [90, 200]);
            final next = _transcriptSnapshot(transcript, reasoningHead: reasoningHead);
            expect(next.commands, isEmpty);
            final nextRows = deriveRows(items: next.items, turns: next.turns, running: true, foldTurns: true);
            expect(nextRows.first, stablePrefix ? isA<UserRow>() : isA<TurnProcessRow>());
            expect(nextRows.whereType<TurnProcessRow>(), hasLength(1));
            expect(nextRows.whereType<TurnFootnoteRow>(), hasLength(1));
            harness.controllers['s1']!.emit(next);
            await _expectHeld(tester, before, reading: reading);
          },
        );
      }
    }
  }

  testWidgets('the same drag continues after a partial-window prepend', (tester) async {
    final chat = await _open(tester, fluid: true);
    final gesture = await tester.startGesture(const Offset(200, 400));
    await gesture.moveBy(const Offset(0, -50));
    await tester.pump();
    final before = _readingTop(tester);
    chat.emit(_snapshot(older: 3));
    await _expectHeld(tester, before);
    final p = _position(tester);
    final pixels = p.pixels;
    await gesture.moveBy(const Offset(0, 50));
    await tester.pump();
    expect(p.pixels, lessThan(pixels - 40), reason: 'Prepending must not end the active drag with jumpTo.');
    expect(_readingTop(tester), closeTo(before + 50, 1));
    await gesture.up();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a history page containing only a command preserves the current prompt', (tester) async {
    final chat = await _open(tester);
    final before = _readingTop(tester);
    chat.emit(
      _snapshot(
        commands: const [CommandNotice(id: 'old', name: 'help', text: 'Earlier help', done: true, seq: -1)],
      ),
    );
    await _expectHeld(tester, before);
  });

  testWidgets('a partial-window prepend leaves the fling in control', (tester) async {
    final chat = await _open(tester, fluid: true);
    await tester.fling(find.byType(CustomScrollView), const Offset(0, -180), 900);
    await tester.pump(const Duration(milliseconds: 16));
    final p = _position(tester);
    expect(p.isScrollingNotifier.value, isTrue);
    chat.emit(_snapshot(older: 3));
    await tester.pump(const Duration(milliseconds: 16));
    expect(p.isScrollingNotifier.value, isTrue);
    final pixels = p.pixels;
    await tester.pump(const Duration(milliseconds: 16));
    expect(p.pixels, greaterThan(pixels));
    expect(tester.takeException(), isNull);
  });

  testWidgets('completion keeps newly loaded history above the running turn anchored', (tester) async {
    final chat = await _open(tester);
    final before = _readingTop(tester);
    chat.emit(_snapshot(older: 31));
    await _expectHeld(tester, before);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 1000));
    await pumpFrames(tester, 30);
    final viewport = tester.getRect(find.byType(ChatList));
    final visible = find.byWidgetPredicate((w) => w is Text && (w.data?.startsWith('Earlier ') ?? false));
    final reading = visible.evaluate().map((e) => e.widget as Text).firstWhere((w) {
      final rect = tester.getRect(find.byWidget(w));
      return rect.top > viewport.top + 100 && rect.bottom < viewport.bottom - 100;
    });
    final text = find.text(reading.data!);
    final readingTop = tester.getTopLeft(text).dy;
    chat.emit(_snapshot(older: 31, running: false));
    for (var frame = 0; frame < 25; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getTopLeft(text).dy, closeTo(readingTop, .5), reason: 'frame $frame');
      expect(tester.takeException(), isNull);
    }
  });
}
