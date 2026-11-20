import 'package:dsh_app/ui/chat/render/code_block.dart';
import 'package:dsh_app/ui/chat/render/diff_view.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/common/edge_fade.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  setUpAll(loadTestFonts);
  final examples = <String, Widget>{
    'table': const MarkdownBody(
      text:
          '| first wide column | second wide column | third wide column |\n'
          '|---|---|---|\n'
          '| 1111111111111 | 222222222222 | 33333333333 |',
    ),
    'code': CodeBlock(code: 'final long = "${'x' * 200}";'),
    'diff': DiffView(diffText: '+${'x' * 200}'),
    'formula': MarkdownBody(text: '\$\$${List.generate(40, (i) => 'a_{$i}').join(' + ')}\$\$'),
  };
  for (final MapEntry(key: name, value: example) in examples.entries) {
    testWidgets('$name fades the edge that still has content', (tester) async {
      var notifications = 0;
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                child: NotificationListener<ScrollNotification>(
                  onNotification: (_) {
                    notifications++;
                    return false;
                  },
                  child: example,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final fade = find.byType(HorizontalEdgeFade);
      expect(fade, findsOneWidget);
      final render = tester.renderObject<RenderHorizontalEdgeFade>(fade);
      expect((render.start, render.end > 0), (0, true));
      final position = tester
          .state<ScrollableState>(
            find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.right),
          )
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      expect((render.start > 0, render.end), (true, 0));
      expect(notifications, greaterThan(0));
    });
  }
  testWidgets('content that fits draws without a mask layer', (tester) async {
    await tester.pumpWidget(
      testApp(
        const Scaffold(
          body: SizedBox(width: 300, child: MarkdownBody(text: '| a | b |\n|---|---|\n| 1 | 2 |')),
        ),
      ),
    );
    await tester.pump();
    final render = tester.renderObject<RenderHorizontalEdgeFade>(find.byType(HorizontalEdgeFade));
    expect((render.start, render.end), (0, 0));
    expect(render.alwaysNeedsCompositing, isFalse);
  });
  testWidgets('wrapped code has nothing to fade', (tester) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: SizedBox(width: 300, child: CodeBlock(code: 'x' * 200, replyActions: true)),
        ),
      ),
    );
    expect(find.byType(HorizontalEdgeFade), findsOneWidget);
    await tester.tap(find.byTooltip('自动换行'));
    await tester.pump();
    expect(find.byType(HorizontalEdgeFade), findsNothing);
  });
}
