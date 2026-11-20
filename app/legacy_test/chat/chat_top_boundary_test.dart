import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

UserChatItem _user(int seq, String text) =>
    UserChatItem(seq: seq, time: DateTime.utc(2026), text: text, images: const [], files: const []);

AssistantChatItem _reply(int seq, String text, {bool streaming = false}) => AssistantChatItem(
  id: 'a$seq',
  seq: streaming ? null : seq,
  time: DateTime.utc(2026),
  text: text,
  reasoning: '',
  streaming: streaming,
);

ScrollPosition _position(WidgetTester tester) =>
    tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller!.position;

double _firstTop(WidgetTester tester) => tester.getTopLeft(find.byKey(const ValueKey('u1'))).dy;
double _expectedTop(WidgetTester tester) => tester.getTopLeft(find.byType(ChatList)).dy + 24 + AppSpace.sm;

Future<FakeChatController> _open(WidgetTester tester, ChatState state, {int frames = 16}) async {
  usePhoneView(tester);
  final harness = ChatHarness(session: 's1', states: {'s1': state});
  await tester.pumpWidget(
    testApp(
      const Scaffold(body: ChatList(sessionId: 's1', topInset: 24, bottomInset: 6)),
      overrides: harness.overrides,
    ),
  );
  if (frames > 0) await pumpFrames(tester, frames);
  return harness.controllers['s1']!;
}

Future<void> _dragToTop(WidgetTester tester) async {
  final p = _position(tester);
  await tester.drag(find.byType(CustomScrollView), Offset(0, p.pixels - p.minScrollExtent + p.viewportDimension * 2));
  await pumpFrames(tester, 30);
}

List<ChatItem> _history([int count = 20]) => [
  for (var i = 0; i < count; i++) ...[
    _user(i * 2 + 1, 'Prompt $i'),
    _reply(i * 2 + 2, 'Reply $i. ${'History paragraph. ' * 6}'),
  ],
];

void _expectBottom(WidgetTester tester) {
  final p = _position(tester);
  expect(p.pixels, closeTo(p.maxScrollExtent, 0.5));
  expect(tester.takeException(), isNull);
}

void _expectTop(WidgetTester tester, String scenario, {bool short = false}) {
  final p = _position(tester);
  debugPrint(
    'P1 $scenario: first=${_firstTop(tester)}, expected=${_expectedTop(tester)}, '
    'pixels=${p.pixels}, min=${p.minScrollExtent}, max=${p.maxScrollExtent}',
  );
  expect(_firstTop(tester), closeTo(_expectedTop(tester), 0.5), reason: scenario);
  expect(p.pixels, closeTo(p.minScrollExtent, 0.01));
  if (short) expect(p.maxScrollExtent - p.minScrollExtent, closeTo(0, 0.01));
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('new short chat starts at the top and cannot be pulled into a gap', (tester) async {
    final chat = await _open(tester, const ChatState(loading: false));
    chat.emit(ChatState(loading: false, items: [_user(1, 'First prompt'), _reply(2, 'Short reply')]));
    await pumpFrames(tester, 30);
    _expectTop(tester, 'new-short', short: true);
    await _dragToTop(tester);
    _expectTop(tester, 'new-short-drag', short: true);
  });

  testWidgets('two short historical turns and a long new reply stop at the first row', (tester) async {
    final history = <ChatItem>[
      _user(1, 'First prompt'),
      _reply(2, 'First reply'),
      _user(3, 'Second prompt'),
      _reply(4, 'Second reply'),
    ];
    final chat = await _open(tester, ChatState(loading: false, items: history));
    chat.emit(
      ChatState(
        loading: false,
        running: true,
        items: [
          ...history,
          _user(5, 'Third prompt'),
          _reply(6, List.filled(100, 'A long reply line.').join('\n\n'), streaming: true),
        ],
      ),
    );
    await pumpFrames(tester, 30);
    await _dragToTop(tester);
    _expectTop(tester, 'short-history-long-tail');
    final before = _firstTop(tester);
    await _dragToTop(tester);
    expect(_firstTop(tester), closeTo(before, 0.01));
    _expectTop(tester, 'short-history-repeated-drag');
  });

  testWidgets('a reopened short history is top aligned with no scroll range', (tester) async {
    await _open(
      tester,
      ChatState(loading: false, items: [_user(1, 'First prompt'), _reply(2, 'Short reply')]),
      frames: 0,
    );
    _expectTop(tester, 'reopened-first-frame', short: true);
    await pumpFrames(tester, 16);
    _expectTop(tester, 'reopened-short', short: true);
    await _dragToTop(tester);
    _expectTop(tester, 'reopened-short-drag', short: true);
  });

  testWidgets('the Android top edge clamps during the drag without a bounce', (tester) async {
    final chat = await _open(tester, const ChatState(loading: false));
    chat.emit(
      ChatState(
        loading: false,
        items: [_user(1, 'First prompt'), _reply(2, List.filled(50, 'A long reply.').join('\n\n'))],
      ),
    );
    await pumpFrames(tester, 20);
    await _dragToTop(tester);
    // Start this boundary-physics check exactly at the edge, independently
    // of the preceding fling's remaining velocity and drag touch slop.
    _position(tester).jumpTo(_position(tester).minScrollExtent);
    await pumpFrames(tester, 2);
    _expectTop(tester, 'clamped-start');
    final gesture = await tester.startGesture(tester.getCenter(find.byType(CustomScrollView)));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 16));
      _expectTop(tester, 'clamped-drag-$i');
    }
    await gesture.up();
    await pumpFrames(tester, 20);
    _expectTop(tester, 'clamped-release');
  });

  testWidgets('streaming crosses from a short top-aligned reply to bottom following', (tester) async {
    final chat = await _open(tester, const ChatState(loading: false));
    for (final lines in [1, 2, 5, 20, 40]) {
      chat.emit(
        ChatState(
          loading: false,
          running: true,
          items: [
            _user(1, 'First prompt'),
            _reply(2, List.filled(lines, 'The reply grows.').join('\n\n'), streaming: true),
          ],
        ),
      );
      await pumpFrames(tester, 20);
      _expectBottom(tester);
      if (lines <= 5) _expectTop(tester, 'stream-$lines', short: true);
    }
    final p = _position(tester);
    expect(p.maxScrollExtent - p.minScrollExtent, greaterThan(p.viewportDimension));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await pumpFrames(tester, 30);
    final held = p.pixels;
    chat.emit(
      ChatState(
        loading: false,
        running: true,
        items: [_user(1, 'First prompt'), _reply(2, List.filled(60, 'The reply grows.').join('\n\n'), streaming: true)],
      ),
    );
    await pumpFrames(tester, 10);
    expect(p.pixels, closeTo(held, 0.5));
  });

  testWidgets('sending jumps to the bottom and a consumed prompt does not pin later updates', (tester) async {
    final items = _history();
    final chat = await _open(tester, ChatState(loading: false, items: items));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 500));
    await pumpFrames(tester, 30);
    expect(_position(tester).extentAfter, greaterThan(100));
    chat.emit(
      ChatState(
        loading: false,
        running: true,
        items: items,
        pending: [PendingPrompt(requestId: 'claimed', text: '!pwd', time: DateTime.utc(2026))],
      ),
    );
    await pumpFrames(tester, 16);
    _expectBottom(tester);

    // The controller's #51 path removes the claimed prompt without an echo.
    chat.emit(ChatState(loading: false, items: items));
    await pumpFrames(tester, 16);
    expect(find.text('!pwd'), findsNothing);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 500));
    await pumpFrames(tester, 30);
    final held = _position(tester).pixels;
    chat.emit(
      ChatState(
        loading: false,
        running: true,
        items: [...items, _reply(100, 'An unrelated later reply. ' * 20, streaming: true)],
      ),
    );
    await pumpFrames(tester, 16);
    expect(_position(tester).pixels, closeTo(held, 0.5));
  });

  testWidgets('prepending history preserves the center when the positive bound crosses zero', (tester) async {
    final history = <ChatItem>[_user(1, 'First prompt'), _reply(2, 'Short history')];
    final chat = await _open(tester, ChatState(loading: false, items: history, hasMoreHistory: true));
    final live = _reply(100, List.filled(60, 'A long current reply.').join('\n\n'), streaming: true);
    chat.emit(ChatState(loading: false, running: true, items: [...history, live], hasMoreHistory: true));
    await pumpFrames(tester, 20);
    await _dragToTop(tester);
    expect(_position(tester).minScrollExtent, greaterThan(0));
    expect(chat.loadOlderCalls, greaterThan(0));
    // The row acquires inter-message padding after a prepend. Measure the
    // visible message itself, not the outer row's newly added padding.
    final before = tester.getTopLeft(find.text('First prompt')).dy;
    final pixels = _position(tester).pixels;
    chat.emit(
      ChatState(
        loading: false,
        running: true,
        items: [for (var i = -30; i < 0; i++) _user(i, 'Earlier message $i. ${'Text ' * 10}'), ...history, live],
      ),
    );
    await pumpFrames(tester, 10);
    expect(_position(tester).minScrollExtent, lessThan(0));
    expect(_position(tester).pixels, closeTo(pixels, 0.5));
    expect(tester.getTopLeft(find.text('First prompt')).dy, closeTo(before, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('history loading header occupies the top boundary before the first message', (tester) async {
    await _open(
      tester,
      ChatState(
        loading: false,
        loadingOlder: true,
        hasMoreHistory: true,
        items: [_user(1, 'First prompt'), _reply(2, 'Short reply')],
      ),
    );
    expect(_firstTop(tester), closeTo(_expectedTop(tester) + 48, 0.5));
    final spinner = tester.getRect(find.byType(CircularProgressIndicator));
    expect(spinner.center.dy, closeTo(_expectedTop(tester) + 24, 0.5));
    expect(_position(tester).maxScrollExtent, _position(tester).minScrollExtent);
  });

  testWidgets('pet headroom preserves short alignment and reserves room below long content', (tester) async {
    final chat = await _open(
      tester,
      ChatState(loading: false, items: [_user(1, 'First prompt'), _reply(2, 'Short reply')]),
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatList)));
    container.read(petHeadroomProvider.notifier).set(80);
    await pumpFrames(tester, 10);
    _expectTop(tester, 'short-pet', short: true);
    chat.emit(ChatState(loading: false, items: _history()));
    await pumpFrames(tester, 20);
    _expectBottom(tester);
    final tail = find.byKey(const ValueKey('a40'));
    double gap() => tester.getBottomLeft(find.byType(ChatList)).dy - tester.getBottomLeft(tail).dy;
    expect(gap(), closeTo(6 + AppSpace.sm + 80, 0.5));
    container.read(petHeadroomProvider.notifier).set(0);
    await pumpFrames(tester, 10);
    _expectBottom(tester);
    expect(gap(), closeTo(6 + AppSpace.sm, 0.5));
  });

  testWidgets('keyboard viewport changes keep short content at the top and long content pinned', (tester) async {
    final chat = await _open(
      tester,
      ChatState(loading: false, items: [_user(1, 'First prompt'), _reply(2, 'Short reply')]),
    );
    for (final bottom in [600.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: bottom);
      await pumpFrames(tester, 10);
      _expectTop(tester, 'short-keyboard-$bottom', short: true);
    }
    chat.emit(ChatState(loading: false, items: _history()));
    await pumpFrames(tester, 20);
    for (final bottom in [600.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: bottom);
      await pumpFrames(tester, 10);
      _expectBottom(tester);
      final end = tester.getBottomLeft(find.byKey(const ValueKey('a40'))).dy;
      expect(tester.getBottomLeft(find.byType(ChatList)).dy - end, closeTo(6 + AppSpace.sm, 0.5));
    }
  });
}
