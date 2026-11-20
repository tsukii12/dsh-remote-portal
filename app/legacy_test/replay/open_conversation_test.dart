// A conversation file opened with dsh-go (「打开方式」, system share, a
// dshgo:// link) goes to its replay; anything else still to the importer.
//
//   flutter test test/replay/open_conversation_test.dart

import 'dart:io';

import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/replay/replay_page.dart';
import 'package:dsh_app/ui/share_code/share_code_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/rich_conversation.dart';

Future<void> _openFile(WidgetTester tester, String text) async {
  await tester.runAsync(loadTestFonts);
  usePhoneView(tester);
  final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('open-conversation')))!;
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = File('${dir.path}/对话.dshgo')..writeAsStringSync(text);
  await tester.pumpWidget(
    testApp(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(onPressed: () => openShareFile(context, file), child: const Text('open')),
        ),
      ),
      overrides: [settingsProvider.overrideWith(() => TestSettings())],
    ),
  );
  await tester.tap(find.text('open'));
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('a .dshgo conversation opens its replay, pictures and all', (tester) async {
    await _openFile(tester, richFileText());
    expect(find.byType(ReplayPage), findsOneWidget);
    final page = tester.widget<ReplayPage>(find.byType(ReplayPage));
    expect(page.share.title, '修复登录重复提交');
    expect(page.assets, hasLength(1));
    expect(page.preview, isFalse);
  });

  testWidgets('a damaged one says so in a toast', (tester) async {
    final text = richFileText().replaceFirst('"code":"', '"code":"x');
    await _openFile(tester, text);
    expect(find.byType(ReplayPage), findsNothing);
    expect(find.text('这个分享码不完整或已损坏'), findsOneWidget);
  });
}
