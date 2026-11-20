// Task lists in replies render as read-only boxes without a Material ancestor
// (the package's default Checkbox threw "No Material widget found").

import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  testWidgets('task list items render without a Material ancestor', (tester) async {
    await tester.pumpWidget(
      testApp(
        const Align(
          alignment: Alignment.topLeft,
          child: MarkdownBody(text: '待办\n\n- [ ] 张三:整理数据\n- [x] 李四:修复上线'),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byIcon(AppIcons.checkboxOff), findsOneWidget);
    expect(find.byIcon(AppIcons.checkboxOn), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });

  test('reply links open only on the web or as email', () {
    expect(MarkdownBody.linkToOpen('https://pub.dev/x'), isNotNull);
    expect(MarkdownBody.linkToOpen('HTTP://example.com'), isNotNull);
    expect(MarkdownBody.linkToOpen('mailto:a@b.c'), isNotNull);
    for (final blocked in [
      'tel:10086',
      'sms:10086?body=hi',
      'intent://pay#Intent;scheme=alipays;end',
      'alipays://platformapi/startapp',
      'weixin://dl/scan',
      'javascript:alert(1)',
      'file:///sdcard/a',
      'https:///nohost',
      '/root/workspace/a.md',
    ]) {
      expect(MarkdownBody.linkToOpen(blocked), isNull, reason: blocked);
    }
  });
}
