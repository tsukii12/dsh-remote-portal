import 'package:dsh_app/ui/fx/orbs/thinking_orb.dart';
import 'package:dsh_app/ui/chat/render/code_block.dart';
import 'package:dsh_app/ui/chat/widgets/stream_row.dart';
import 'package:dsh_app/ui/chat/widgets/thinking_pill.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

void main() {
  setUpAll(loadTestFonts);
  testWidgets('thinking and tool previews share a centered 15px separator', (tester) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Column(
            children: [
              const ThinkingPill(reasoning: '预览'),
              ToolRow(item: tool('a', 'bash', {'command': 'echo'}), onRespond: (_, _) async {}),
            ],
          ),
        ),
      ),
    );
    final thought = tester.getRect(find.text('思考'));
    final verb = tester.getRect(find.text('运行'));
    expect(tester.getTopLeft(find.text('预览')).dx - thought.right, closeTo(15, 0.5));
    expect(tester.getTopLeft(find.text('echo')).dx - verb.right, closeTo(15, 0.5));
    final dots = find.byType(StreamDot);
    expect(tester.getCenter(dots.at(0)).dy, closeTo(thought.center.dy, 0.5));
    expect(tester.getCenter(dots.at(1)).dy, closeTo(verb.center.dy, 0.5));
  });
  testWidgets('streaming to running keeps one orb and the same State', (tester) async {
    Widget row(ToolStatus status) => testApp(
      Scaffold(
        body: ToolRow(
          item: tool('a', 'bash', {'command': 'echo'}, status: status),
          onRespond: (_, _) async {},
        ),
      ),
    );
    await tester.pumpWidget(row(ToolStatus.streaming));
    final state = tester.state(find.byType(ThinkingOrb));
    await tester.pumpWidget(row(ToolStatus.running));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(ThinkingOrb), findsOneWidget);
    expect(tester.state(find.byType(ThinkingOrb)), same(state));
    // A command is solving.
    expect(tester.widget<ThinkingOrb>(find.byType(ThinkingOrb)).state, OrbState.solving);
  });
  testWidgets('streaming thinking is a calm three-line window that folds away when done', (tester) async {
    Widget pill(bool active) => testApp(
      Scaffold(
        body: ThinkingPill(reasoning: '第一段\n第二段\n第三段\n正在写的这一段更长一些', active: active),
      ),
    );
    await tester.pumpWidget(pill(true));
    await pumpFrames(tester, 4);
    final ticker = find.byType(ThinkingTicker);
    expect(ticker, findsOneWidget);
    // 超过三行:窗口钉在三行高(13 号 × 1.3 行高 × 3),不跟着内容长。
    expect(tester.getSize(ticker).height, closeTo(13 * 1.3 * 3, 0.5));
    // 一整块连续的文字,最新的字还在;不再拆行、也没有省略号。
    expect(find.descendant(of: ticker, matching: find.textContaining('正在写的这一段更长一些')), findsOneWidget);
    expect(find.textContaining('…'), findsNothing, reason: 'no ellipsis on the ticker');
    // 点开:实时窗口让位给全文,两块不会同时在树上。
    await tester.tap(find.text('思考中'));
    await pumpFrames(tester, 6);
    expect(find.byType(ThinkingTicker), findsNothing);
    expect(find.textContaining('正在写的这一段更长一些'), findsOneWidget);
    // 再点:回到三行窗口。
    await tester.tap(find.text('思考中'));
    await pumpFrames(tester, 6);
    expect(find.byType(ThinkingTicker), findsOneWidget);
    // 恒高三行:内容只有一行时窗口也不缩,流式期间列表不跟着跳。
    await tester.pumpWidget(testApp(const Scaffold(body: ThinkingPill(reasoning: '短', active: true))));
    await pumpFrames(tester, 4);
    expect(tester.getSize(find.byType(ThinkingTicker)).height, closeTo(13 * 1.3 * 3, 0.5));
    // 思考结束:窗口收回,行内预览出现。
    await tester.pumpWidget(pill(false));
    await pumpFrames(tester, 6);
    expect(find.byType(ThinkingTicker), findsNothing);
    expect(find.text('第一段'), findsOneWidget);
  });
  testWidgets('streaming thinking resizes in one frame so nothing fights the glide', (tester) async {
    Widget pill(String reasoning) =>
        testApp(Scaffold(body: ThinkingPill(reasoning: reasoning, active: true, streaming: true)));
    await tester.pumpWidget(pill('第一行'));
    // 流式期间块高按行瞬长:高度动画会和文字上滑、列表追底叠在一起,看起来在抖。
    expect(find.byType(AnimatedSize), findsNothing);
    await tester.pumpWidget(pill('第一行\n第二行'));
    expect(find.byType(AnimatedSize), findsNothing);
    expect(tester.getSize(find.byType(ThinkingTicker)).height, greaterThan(13 * 1.3));
    // 点开全文时高度动画回来(单槽切换才需要过渡)。
    await tester.tap(find.text('思考中'));
    await tester.pump();
    expect(find.byType(AnimatedSize), findsOneWidget);
  });

  testWidgets('the live window keeps no text painter from one publish to the next', (tester) async {
    var live = 0;
    void track(ObjectEvent event) {
      if (event.object is! TextPainter) return;
      live += event is ObjectCreated ? 1 : -1;
    }

    FlutterMemoryAllocations.instance.addListener(track);
    addTearDown(() => FlutterMemoryAllocations.instance.removeListener(track));
    Widget window(String text) => testApp(Scaffold(body: ThinkingTicker(text: text)));
    await tester.pumpWidget(window('第一段'));
    final settled = live;
    for (var i = 0; i < 20; i++) {
      await tester.pumpWidget(window('第一段${'写' * i}'));
    }
    expect(live, settled);
  });

  testWidgets('the thinking orb paints in its own layer', (tester) async {
    await tester.pumpWidget(testApp(const Scaffold(body: ThinkingPill(reasoning: '嗯', active: true))));
    expect(find.descendant(of: find.byType(ThinkingOrb), matching: find.byType(RepaintBoundary)), findsWidgets);
  });

  testWidgets('dense code and ANSI output align with section titles and use 18px lines', (tester) async {
    usePhoneView(tester);
    final cases = [
      tool('bash', 'bash', {'command': 'echo hi'}, result: '\u001b[31mred\u001b[0m\nsecond'),
      tool(
        'read',
        'read',
        {'file_path': 'a.dart'},
        meta: {
          'lines': [
            for (var i = 40; i <= 44; i++) {'number': i, 'text': 'final value = $i;'},
          ],
        },
      ),
      tool('write', 'write', {'file_path': 'b.dart', 'content': 'final x = 1;\nfinal y = 2;'}),
      tool('edit', 'edit', {'file_path': 'c.dart', 'old_string': 'old', 'new_string': 'new'}),
    ];
    for (final item in cases) {
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: ToolRow(key: ValueKey(item.callId), item: item, onRespond: (_, _) async {}),
            ),
          ),
        ),
      );
      await tester.tap(
        find.text(switch (item.name) {
          'bash' => '运行',
          'read' => '读取',
          'write' => '写入',
          _ => '编辑',
        }),
      );
      await pumpFrames(tester, 5);
      final detail = find.byType(ToolDetail);
      final left = tester.getTopLeft(detail).dx + 12;
      for (final editable in find.descendant(of: detail, matching: find.byType(EditableText)).evaluate()) {
        final state = (editable as StatefulElement).state as EditableTextState;
        final render = state.renderEditable;
        final plain = state.widget.controller.text;
        if (plain.startsWith(r'$') || plain.startsWith('red') || (item.name != 'read' && plain.startsWith('final'))) {
          final point = render.localToGlobal(render.getLocalRectForCaret(const TextPosition(offset: 0)).topLeft);
          expect(point.dx, closeTo(left, 0.5));
          expect(render.preferredLineHeight, closeTo(18, 0.5));
        }
      }
      if (item.name == 'read') {
        expect(tester.getTopLeft(find.text('40\n41\n42\n43\n44')).dx, closeTo(left, 0.5));
        final path = tester.widget<SelectableText>(
          find.byWidgetPredicate(
            (w) =>
                w is SelectableText && (w.textSpan?.toPlainText().contains('第\u00a040\u2060–\u206044\u00a0行') ?? false),
          ),
        );
        expect(path.textSpan!.toPlainText(), contains('\u00a0·\u00a0第\u00a040\u2060–\u206044\u00a0行'));
        // A long path wraps; the line never starts with the 「·」 (or
        // inside 「第 40–44 行」): the range goes with the path's last
        // part.
        final range = path.textSpan!.children!.last;
        const tail = 'login_controller_test.dart';
        final span = TextSpan(
          style: path.textSpan!.style,
          children: [
            const TextSpan(text: 'lib/features/auth/$tail'),
            range,
          ],
        );
        final plain = span.toPlainText();
        final from = plain.indexOf('\u00a0·');
        final chunk = TextPainter(
          text: TextSpan(
            style: path.textSpan!.style,
            children: [
              const TextSpan(text: tail),
              range,
            ],
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        for (var width = chunk.width.ceilToDouble(); width <= 400; width += 4) {
          final painter = TextPainter(text: span, textDirection: TextDirection.ltr)..layout(maxWidth: width);
          for (final line in painter.computeLineMetrics().skip(1)) {
            final start = painter.getPositionForOffset(Offset(0, line.baseline - line.ascent + 1)).offset;
            expect(
              start <= from - tail.length || start >= plain.length,
              isTrue,
              reason: 'line ${line.lineNumber} at $width starts at $start',
            );
          }
          painter.dispose();
        }
        chunk.dispose();
      }
      if (item.name == 'edit') {
        expect(tester.getTopLeft(find.text('-old')).dx, closeTo(left, 0.5));
      }
    }
  });
  testWidgets('code header grows symmetrically with a 2x text scaler', (tester) async {
    await tester.pumpWidget(
      testApp(
        const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SizedBox(width: 390, child: CodeBlock(code: 'hello')),
          ),
        ),
      ),
    );
    final label = tester.getRect(find.text('复制'));
    final tap = tester.getRect(find.ancestor(of: find.text('复制'), matching: find.byType(InkWell)));
    expect(label.top - tap.top, closeTo(tap.bottom - label.bottom, 0.5));
    expect(tester.takeException(), isNull);
  });
}
