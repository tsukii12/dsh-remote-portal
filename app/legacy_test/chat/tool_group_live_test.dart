import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

void main() {
  setUpAll(loadTestFonts);
  testWidgets('completed live rows stay until replaced by the next batch', (tester) async {
    usePhoneView(tester);
    final base = [
      tool('r1', 'bash', {'command': 'one'}),
      tool('r2', 'bash', {'command': 'two'}),
    ];
    Widget group(List<ToolChatItem> tools, {bool live = true}) => testApp(
      Scaffold(
        body: ToolGroup(tools: tools, live: live, onRespond: (_, _) async {}),
      ),
    );
    await tester.pumpWidget(
      group([
        ...base,
        tool('r3', 'bash', {'command': 'three'}, status: ToolStatus.running),
      ]),
    );
    final height = tester.getSize(find.byType(ToolGroup)).height;
    await tester.pumpWidget(
      group([
        ...base,
        tool('r3', 'bash', {'command': 'three'}),
      ]),
    );
    expect(tester.getSize(find.byType(ToolGroup)).height, height);
    expect(find.text('three'), findsOneWidget);
    await tester.pumpWidget(
      group([
        ...base,
        tool('r3', 'bash', {'command': 'three'}),
        tool('r4', 'bash', {'command': 'four'}, status: ToolStatus.running),
      ]),
    );
    await pumpFrames(tester, 5);
    expect(tester.getSize(find.byType(ToolGroup)).height, height);
    expect(find.text('three'), findsNothing);
    expect(find.text('four'), findsOneWidget);
    await tester.pumpWidget(
      group([
        ...base,
        tool('r3', 'bash', {'command': 'three'}),
        tool('r4', 'bash', {'command': 'four'}),
      ], live: false),
    );
    await tester.pump(const Duration(milliseconds: 140));
    final midway = tester.getSize(find.byType(ToolGroup)).height;
    expect(midway, greaterThan(32));
    expect(midway, lessThan(height));
    await pumpFrames(tester, 4);
    expect(tester.getSize(find.byType(ToolGroup)).height, 32);
  });
  testWidgets('one parallel call finishing does not shrink the live batch', (tester) async {
    Widget group(bool done) => testApp(
      Scaffold(
        body: ToolGroup(
          live: true,
          onRespond: (_, _) async {},
          tools: [
            tool('a', 'bash', {'command': 'a'}, status: done ? ToolStatus.succeeded : ToolStatus.running),
            tool('b', 'bash', {'command': 'b'}, status: ToolStatus.running),
            tool('c', 'bash', {'command': 'c'}),
          ],
        ),
      ),
    );
    await tester.pumpWidget(group(false));
    final height = tester.getSize(find.byType(ToolGroup)).height;
    await tester.pumpWidget(group(true));
    expect(tester.getSize(find.byType(ToolGroup)).height, height);
    expect(find.text('a'), findsOneWidget);
  });
}
