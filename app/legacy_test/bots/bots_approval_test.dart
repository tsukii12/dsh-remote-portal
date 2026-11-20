import 'dart:async';

import 'package:dsh_app/ui/bots/bots_page.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/bots/room_details_page.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show usePhoneView, loadTestFonts;
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(WidgetTester tester, Widget page, FakeDsBotTransport transport) async {
    usePhoneView(tester);
    await tester.pumpWidget(goldenApp(home: page, brightness: Brightness.light, overrides: dsBotOverrides(transport)));
    await _frames(tester);
    transport.calls.clear();
  }

  for (final details in [false, true]) {
    Widget page() => details ? const RoomDetailsPage(roomId: 'r1') : const RoomChatPage(roomId: 'r1');
    for (final allow in [true, false]) {
      testWidgets('group approval ${details ? 'details' : 'chat'} answers $allow then refreshes', (tester) async {
        final fake = approvalTransport();
        await pump(tester, page(), fake);
        expect(find.byType(GroupApprovalCard), findsOneWidget);
        expect(find.text('Writer 想运行命令'), findsOneWidget);
        if (!details) expect(find.text('有成员等你批准'), findsOneWidget);
        await tester.tap(find.text(allow ? '允许本次' : '拒绝'));
        await _frames(tester);
        expect(fake.endpoints, ['approval-answer', 'state']);
        expect(fake.calls.first.$2, {'id': 'a1', 'choice': allow ? 'allow' : 'reject'});
      });
    }

    testWidgets('group approval $details stays disabled while pending and recovers after an error', (tester) async {
      final fake = approvalTransport();
      final gate = Completer<Object?>();
      fake.handlers['approval-answer'] = (_) => gate.future;
      await pump(tester, page(), fake);
      await tester.tap(find.text('允许本次'));
      await tester.tap(find.text('允许本次'));
      await tester.pump();
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '允许本次')).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '拒绝')).onPressed, isNull);
      expect(fake.endpoints, ['approval-answer']);
      gate.completeError(const DshRemoteException('bot/failed', 'raw-secret'));
      await _frames(tester);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('raw-secret'), findsNothing);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '允许本次')).onPressed, isNotNull);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '拒绝')).onPressed, isNotNull);
    });

    testWidgets('group approval $details is disabled on a read-only team', (tester) async {
      await pump(tester, page(), approvalTransport(readOnly: true));
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '允许本次')).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '拒绝')).onPressed, isNull);
    });
  }

  testWidgets('home reports the room waiting for approval', (tester) async {
    await pump(tester, const BotsPage(), approvalTransport());
    final row = tester.widget<ListPageRow>(find.widgetWithText(ListPageRow, '发布会'));
    expect(row.subtitle, '有成员等你批准');
  });
}
