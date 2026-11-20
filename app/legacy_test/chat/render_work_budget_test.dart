// Work-count contracts, not host wall-time or Android frame-rate claims.
import 'dart:async';
import 'dart:collection';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/chat/widgets/turn_process.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

class _StreamMux extends DshMux {
  _StreamMux(super.carrier);
  final connection = StreamController<DshConnectionState>.broadcast();
  @override
  Stream<DshConnectionState> get states => connection.stream;
}

class _StreamClient extends DshClient {
  _StreamClient() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));
  final events = StreamController<DshEvent>();
  late final _fakeMux = _StreamMux(carrier);
  @override
  _StreamMux get mux => _fakeMux;
  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) => events.stream;
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('unchanged Markdown reuses prepared text across parent frames', (tester) async {
    usePhoneView(tester);
    const text = r'**Stable** $x^2$';
    final tick = ValueNotifier(0);
    addTearDown(tick.dispose);
    var builds = 0;
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: tick,
            builder: (_, value, _) {
              builds++;
              return MarkdownBody(text: text, selectable: value.isEven);
            },
          ),
        ),
      ),
    );
    final prepared = HashSet<String>.identity();
    for (var frame = 0; frame < 40; frame++) {
      tick.value++;
      await tester.pump(const Duration(milliseconds: 16));
      prepared.add(tester.widget<GptMarkdown>(find.byType(GptMarkdown)).data);
      expect(tester.takeException(), isNull);
    }
    debugPrint('[WORK] parent builds=$builds prepared identities=${prepared.length} frames=40');
    expect(builds, 41);
    expect(prepared.length, 1, reason: 'unchanged text/streaming must not repeat Markdown preparation');
  });

  testWidgets('Markdown cache invalidates on text/streaming and refreshes visual dependencies', (tester) async {
    usePhoneView(tester);
    final value = ValueNotifier((text: r'**One** $x$', streaming: true, secondary: false, dark: false));
    addTearDown(value.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ValueListenableBuilder(
            valueListenable: value,
            builder: (context, current, _) => Theme(
              data: testTheme(current.dark ? Brightness.dark : Brightness.light),
              child: MarkdownBody(text: current.text, streaming: current.streaming, secondary: current.secondary),
            ),
          ),
        ),
      ),
    );
    GptMarkdown markdown() => tester.widget<GptMarkdown>(find.byType(GptMarkdown));
    final first = markdown().data;
    final firstColor = markdown().style!.color;
    value.value = (text: value.value.text, streaming: true, secondary: true, dark: true);
    await tester.pump();
    expect(identical(markdown().data, first), isTrue);
    expect(markdown().style!.color, isNot(firstColor));
    value.value = (text: r'**Two** $y$', streaming: true, secondary: true, dark: true);
    await tester.pump();
    expect(markdown().data, MarkdownBody.prepareSource(value.value.text, streaming: true));
    expect(identical(markdown().data, first), isFalse);
    value.value = (text: value.value.text, streaming: false, secondary: true, dark: true);
    await tester.pump();
    expect(markdown().data, MarkdownBody.prepareSource(value.value.text));
    expect(markdown().data, isNot(contains('\uE000')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('1000-row ChatList builds viewport rows for each virtual stream frame', (tester) async {
    usePhoneView(tester);
    final history = [for (var i = 0; i < 1000; i++) assistant(i, '**History $i**\n\nStable content.')];
    ChatState snapshot(int token) =>
        ChatState(loading: false, running: true, items: [...history, assistant(1001, 'Token $token', streaming: true)]);
    final harness = ChatHarness(session: 's1', states: {'s1': snapshot(0)});
    await tester.pumpWidget(
      testApp(
        const Scaffold(body: ChatList(sessionId: 's1', topInset: 0, bottomInset: 0)),
        overrides: harness.overrides,
      ),
    );
    await pumpFrames(tester, 4);
    var rowBuilds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      if (element.widget is AssistantMessage) rowBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    var maximum = 0;
    for (var token = 1; token <= 20; token++) {
      rowBuilds = 0;
      harness.controllers['s1']!.emit(snapshot(token));
      await tester.pump(const Duration(milliseconds: 32));
      if (rowBuilds > maximum) maximum = rowBuilds;
      expect(rowBuilds, lessThan(40), reason: '1000 historical rows must remain lazy at token $token');
      expect(find.byWidgetPredicate((w) => w is AssistantMessage && w.item.text == 'Token $token'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    debugPrint('[WORK] history=1000 virtual stream frames=20 max AssistantMessage builds/frame=$maximum');
    expect(maximum, greaterThan(0));
  });

  testWidgets('real ChatController coalesces 1000 deltas into ten virtual 32 ms publications', (tester) async {
    final client = _StreamClient();
    final container = ProviderContainer(
      overrides: [activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(hostId: '', client: client, isLocal: true)))],
    );
    var publications = 0;
    final subscription = container.listen(chatProvider('work'), (_, _) => publications++);
    var disposed = false;
    void disposeContainer() {
      if (disposed) return;
      disposed = true;
      subscription.close();
      container.dispose();
    }

    addTearDown(() async {
      disposeContainer();
      await client.events.close();
      await client.mux.connection.close();
      await client.close();
    });
    client.events.add(SessionSnapshotEvent.fromJson('work', {'cursor': 0, 'records': []}));
    await tester.pump();
    publications = 0;
    client.events.add(const AssistantStreamStarted('attempt', 0, turn: 1, step: 1, startedAfterSeq: 0));
    final time = DateTime(2026, 10, 28);
    for (var window = 0; window < 10; window++) {
      for (var offset = 0; offset < 100; offset++) {
        final index = window * 100 + offset;
        client.events.add(
          AssistantChunkEvent('attempt', index + 1, index: index, time: time, chunk: const TextDeltaChunk(0, 'x')),
        );
      }
      await tester.pump();
      expect(publications, window);
      await tester.pump(const Duration(milliseconds: 31));
      expect(publications, window);
      await tester.pump(const Duration(milliseconds: 1));
      expect(publications, window + 1);
      expect(subscription.read().items.whereType<AssistantChatItem>().single.text.length, (window + 1) * 100);
    }
    debugPrint('[WORK] real controller delta events=1000 publications=$publications virtual time=320ms');
    disposeContainer();
  });

  testWidgets('folded process builds no body; animation does not rebuild all 100 rows per frame', (tester) async {
    usePhoneView(tester);
    final start = DateTime(2026, 10, 28);
    final row = TurnProcessRow(
      TurnTrace(
        turn: 1,
        startSeq: 1,
        start: start,
        spans: const [],
        endSeq: 200,
        end: start.add(const Duration(seconds: 1)),
        endReason: const TurnEndReason('completed'),
      ),
      [for (var i = 0; i < 100; i++) AssistantRow(assistant(i, 'Row $i'))],
      toolCalls: 0,
      messages: 100,
    );
    var bodyBuilds = 0;
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: SingleChildScrollView(
            child: TurnProcess(
              row: row,
              buildRow: (_) {
                bodyBuilds++;
                return const SizedBox(height: 20);
              },
              gapBefore: (_, _) => 4,
            ),
          ),
        ),
      ),
    );
    expect(bodyBuilds, 0);
    await tester.tap(find.byType(TurnProcess));
    await tester.pump();
    expect(bodyBuilds, 100);
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(bodyBuilds, 100);
    debugPrint('[WORK] process rows=100 collapsed builds=0 expand builds=100 extra animation builds=0 frames=30');
    expect(tester.takeException(), isNull);
  });
}
