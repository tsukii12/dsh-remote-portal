import 'package:dsh_app/ui/chat/render/code_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// Android gestures on a code well: a sideways drag scrolls the long line,
/// a long press still selects.
void main() {
  setUpAll(loadTestFonts);

  Future<ScrollPosition> pumpCode(WidgetTester tester) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ListView(
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 300,
                  child: CodeBlock(code: 'final long = "${'x' * 200}";\nprint(long);', replyActions: true),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    return tester
        .state<ScrollableState>(
          find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.right),
        )
        .position;
  }

  /// A point on the first line of code, inside the visible well.
  Offset onCode(WidgetTester tester) =>
      tester.getTopLeft(find.textContaining('final long', findRichText: true)) + const Offset(60, 8);

  testWidgets('a sideways drag scrolls the code', (tester) async {
    final position = await pumpCode(tester);
    expect(position.pixels, 0);

    await tester.dragFrom(onCode(tester), const Offset(-160, 0));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(100));
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a long press selects and offers copy', (tester) async {
    final position = await pumpCode(tester);

    await tester.longPressAt(onCode(tester));
    await tester.pumpAndSettle();
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    expect(position.pixels, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
