// The approval card and its notification show the same reason for one request,
// in the interface language.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/notify/chat_alerts.dart';
import 'package:dsh_app/ui/chat/widgets/approval_card.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _request = ApprovalRequest(
  eventId: 'e1',
  sessionId: 's1',
  toolName: 'run_command',
  reason: 'raw reason',
  displayReason: {'zh-CN': '需要联网', 'en': 'Network access is required'},
);

void main() {
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  for (final (locale, shown, hidden) in [
    (AppLocale.zhCN, '需要联网', 'Network access is required'),
    (AppLocale.en, 'Network access is required', '需要联网'),
  ]) {
    testWidgets('$locale: card and notification agree', (tester) async {
      AppLocale.use(locale);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: ApprovalCard(request: _request, onRespond: (_, _) async {}),
          ),
        ),
      );
      expect(find.textContaining(shown), findsOneWidget);
      expect(find.textContaining(hidden), findsNothing);
      expect(approvalText(_request), contains(shown));
      expect(approvalText(_request), isNot(contains(hidden)));
    });
  }

  testWidgets('a reason in neither language still shows the host original', (tester) async {
    AppLocale.use(AppLocale.en);
    const request = ApprovalRequest(eventId: 'e2', sessionId: 's1', toolName: 'run_command', reason: 'raw reason');
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ApprovalCard(request: request, onRespond: (_, _) async {}),
        ),
      ),
    );
    expect(find.textContaining('raw reason'), findsOneWidget);
    expect(approvalText(request), contains('raw reason'));
  });
}
