import 'package:dsh_app/state/usage_state.dart';
import 'package:dsh_app/ui/chat/usage_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  for (final sheet in [true, false]) {
    testWidgets('context usage keeps values and labels aligned (sheet: $sheet)', (tester) async {
      Future<void> show(SessionUsage usage) async {
        await tester.pumpWidget(
          testApp(
            Scaffold(
              body: SingleChildScrollView(
                child: SessionUsageSections(usage: usage, sheet: sheet),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(
        const SessionUsage(pressureTokens: 840, projectedTokens: 400, contextWindow: 1000, messageTokens: 300),
      );
      expect(find.text('预计下次请求'), findsOneWidget);
      expect(find.text('40%'), findsOneWidget);
      expect(find.text('400 / 1K'), findsOneWidget);
      expect(find.text('累计输入'), findsOneWidget);

      await show(const SessionUsage(pressureTokens: 840, contextWindow: 1000));
      expect(find.text('上次请求'), findsOneWidget);
      expect(find.text('84%'), findsOneWidget);
      expect(find.text('840 / 1K'), findsOneWidget);

      await show(const SessionUsage(contextWindow: 1000));
      expect(find.text('0%'), findsNothing);
      expect(find.text('0 / 1K'), findsNothing);
    });
  }
}
