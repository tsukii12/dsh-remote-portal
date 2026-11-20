// Masked credentials in user bubbles: sent (with the eye, one value shown),
// optimistic (masked, no eye), and each mask shape (prefixed key, address
// password, private key block, JWT).

import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _sk = 'sk-4c1f0e7b9a2d4e6f8a1b3c5d7e9fa3f9';

const _keyBlock =
    '部署机的私钥:\n'
    '-----BEGIN OPENSSH PRIVATE KEY-----\n'
    'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n'
    'QyNTUxOQAAACBzZWNyZXQta2V5LWJvZHktZm9yLWdvbGRlbi10ZXN0AAAAA==\n'
    '-----END OPENSSH PRIVATE KEY-----';

const _jwt =
    'Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.'
    'dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U 过期了吗?';

Widget _sheet() {
  return Builder(
    builder: (context) => AppBackdrop(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 40, 16, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: const [
            UserBubble(text: '用这个 Key 跑一下:$_sk 谢谢'),
            SizedBox(height: 8),
            UserBubble(key: ValueKey('revealed'), text: '用这个 Key 跑一下:$_sk 谢谢'),
            SizedBox(height: 8),
            UserBubble(
              text:
                  '数据库是 postgres://admin:hunter2-Secret@db.example.com:5432/app,'
                  'password=hunter2 这种不遮',
            ),
            SizedBox(height: 8),
            UserBubble(text: _keyBlock),
            SizedBox(height: 8),
            UserBubble(text: _jwt),
            SizedBox(height: 8),
            UserBubble(text: '换成 ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8 再试', pendingLabel: '排队中 · 本轮结束后发送'),
          ],
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(loadTestFonts);

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('masked credentials ($suffix)', (tester) async {
      usePhoneView(tester);
      tester.view.physicalSize = const Size(780, 2240);
      await tester.pumpWidget(testApp(Scaffold(body: _sheet()), brightness: brightness));
      final eye = find.descendant(of: find.byKey(const ValueKey('revealed')), matching: find.bySemanticsLabel('显示密钥'));
      await tester.tap(eye);
      await pumpFrames(tester, 2);
      await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/secret_mask_$suffix.png'));
    });
  }
}
