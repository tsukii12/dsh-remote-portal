import 'package:dsh_app/state/features_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/slash_palette.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  setUpAll(loadTestFonts);

  final field = find.descendant(of: find.byType(Composer), matching: find.byType(TextField));
  Finder row(String name) => find
      .ancestor(
        of: find.descendant(of: find.byType(SlashPalette), matching: find.textContaining('/$name')),
        matching: find.byType(InkWell),
      )
      .first;

  Future<ChatHarness> mount(WidgetTester tester) async {
    final harness = ChatHarness(
      session: 's1',
      extra: [
        skillsProvider.overrideWith(
          (ref, id) async => const [SkillInfo(name: 'code-review', description: 'Review a change')],
        ),
      ],
    );
    usePhoneView(tester);
    mockClipboard(tester);
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester, 8);
    return harness;
  }

  TextEditingController input(WidgetTester tester) => tester.widget<TextField>(field).controller!;

  Future<void> enter(WidgetTester tester, String text, {int? caret}) async {
    await tester.enterText(field, text);
    if (caret != null) input(tester).selection = TextSelection.collapsed(offset: caret);
    await pumpFrames(tester, 3);
  }

  void expectIntent(String name, String intent) {
    expect(find.descendant(of: row(name), matching: find.textContaining(intent)), findsOneWidget);
  }

  testWidgets('a no-input command describes and performs immediate execution', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final harness = await mount(tester);
      await enter(tester, '/comp');
      expectIntent('compact', '命令 · 执行');
      final node = tester.getSemantics(find.bySemanticsLabel('压缩，/compact'));
      expect(node.getSemanticsData().hint, startsWith('命令 · 执行'));
      await tester.tap(row('compact'));
      await pumpFrames(tester, 3);
      expect(harness.controllers['s1']!.commandLines, ['/compact']);
      expect(harness.controllers['s1']!.sent, isEmpty);
      expect(input(tester).text, isEmpty);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('an input command describes insertion before explicit execution', (tester) async {
    final harness = await mount(tester);
    await enter(tester, '/per');
    expectIntent('permission', '命令 · 填入');
    await tester.tap(row('permission'));
    await pumpFrames(tester, 3);
    expect(input(tester).text, '/permission ');
    expect(harness.controllers['s1']!.commandLines, isEmpty);
    expect(find.byType(SlashPalette), findsNothing);
    await enter(tester, '/permission read-only');
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester, 3);
    expect(harness.controllers['s1']!.commandLines, ['/permission read-only']);
    expect(harness.controllers['s1']!.sent, isEmpty);
  });

  testWidgets('a skill describes insertion and is sent as a message', (tester) async {
    final harness = await mount(tester);
    await enter(tester, '/code');
    expectIntent('code-review', '技能 · 填入');
    await tester.tap(row('code-review'));
    await pumpFrames(tester, 3);
    expect(input(tester).text, '/code-review ');
    expect(harness.controllers['s1']!.commandLines, isEmpty);
    expect(harness.controllers['s1']!.sent, isEmpty);
    expect(find.byType(SlashPalette), findsNothing);
    await enter(tester, '/code-review Review this change');
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester, 3);
    expect(harness.controllers['s1']!.sent, ['/code-review Review this change']);
    expect(harness.controllers['s1']!.commandLines, isEmpty);
  });

  testWidgets('an immediate command describes insertion when a draft follows the caret', (tester) async {
    final harness = await mount(tester);
    await enter(tester, '  /已有文字', caret: 3);
    expectIntent('compact', '命令 · 填入');
    await tester.tap(row('compact'));
    await pumpFrames(tester, 3);
    expect(input(tester).text, '  /compact 已有文字');
    expect(input(tester).selection.baseOffset, '  /compact '.length);
    expect(harness.controllers['s1']!.commandLines, isEmpty);
    expect(harness.controllers['s1']!.sent, isEmpty);
  });

  testWidgets('the rest of a known name is not mistaken for a preserved draft', (tester) async {
    final harness = await mount(tester);
    await enter(tester, '/compact', caret: 4);
    expectIntent('compact', '命令 · 执行');
    await tester.tap(row('compact'));
    await pumpFrames(tester, 3);
    expect(harness.controllers['s1']!.commandLines, ['/compact']);
    expect(input(tester).text, isEmpty);
  });

  testWidgets('arguments after a known name keep the insertion intent', (tester) async {
    final harness = await mount(tester);
    await enter(tester, '/compact keep this', caret: 4);
    expectIntent('compact', '命令 · 填入');
    await tester.tap(row('compact'));
    await pumpFrames(tester, 3);
    expect(input(tester).text, '/compact keep this');
    expect(input(tester).selection.baseOffset, '/compact '.length);
    expect(harness.controllers['s1']!.commandLines, isEmpty);
    expect(harness.controllers['s1']!.sent, isEmpty);
  });
}
