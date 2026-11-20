import 'package:dsh_app/state/commands_state.dart';
import 'package:dsh_app/state/features_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/slash_palette.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _permission = SlashCommand(name: 'permission', label: '权限', description: '选择预设', hint: '<预设名>');
const _skill = SlashCommand(
  name: 'code-review',
  label: 'code-review',
  description: 'Review a change',
  hint: '',
  kind: SlashCommandKind.skill,
);
const _commands = [_permission, _skill];

void main() {
  setUpAll(loadTestFonts);

  test('a selected skill has no parameter hint to keep open', () {
    expect(_skill.takesInput, isTrue);
    expect(PaletteContent.of(_commands, '/code-review '), isNull);
  });

  test('an input descriptor without hint text still takes input without a hint card', () {
    for (final hint in ['', ' \t']) {
      final command = SlashCommand(name: 'deploy', label: 'deploy', description: 'Deploy', hint: hint);
      expect(command.takesInput, isTrue);
      expect(PaletteContent.of([command], '/deploy '), isNull);
    }
  });

  test('an empty argument on the command line retains the real hint', () {
    for (final text in ['/permission ', '/permission \t', ' \t/权限  ']) {
      final content = PaletteContent.of(_commands, text) as PaletteHint;
      expect(content.command, same(_permission));
    }
  });

  test('writing an argument closes the hint, including multiline text', () {
    for (final text in ['/permission read-only', '/permission 只读', '/permission \nread-only']) {
      expect(PaletteContent.of(_commands, text), isNull, reason: text);
    }
  });

  test('moving the caret before an existing argument does not reopen its hint', () {
    const text = '/permission read-only';
    expect(PaletteContent.of(_commands, text, caret: '/permission '.length), isNull);
  });

  test('moving to an empty later line closes the hint', () {
    for (final text in ['/permission \n', '/permission \r\n  ', '/permission \r']) {
      expect(PaletteContent.of(_commands, text), isNull, reason: text);
    }
  });

  test('the first line can still hint when only blank lines follow the caret', () {
    final content = PaletteContent.of(_commands, '/permission \n', caret: '/permission '.length) as PaletteHint;
    expect(content.command, same(_permission));
  });

  test('name completion still considers only the text before the caret', () {
    final inserted = PaletteContent.of(_commands, '/已有文字', caret: 1) as PaletteMatches;
    expect(inserted.commands, _commands);
    expect(inserted.typed, isFalse);
    final editing = PaletteContent.of(_commands, '/permission read-only', caret: 4) as PaletteMatches;
    expect(editing.commands, [_permission]);
  });

  testWidgets('picking a real skill row closes the palette and preserves normal sending', (tester) async {
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
    final field = find.byType(TextField);
    await tester.enterText(field, '/code');
    await pumpFrames(tester, 3);
    await tester.tap(find.descendant(of: find.byType(SlashPalette), matching: find.textContaining('/code-review')));
    await pumpFrames(tester, 3);
    final controller = tester.widget<TextField>(field).controller!;
    expect(controller.text, '/code-review ');
    expect(find.byType(SlashPalette), findsNothing);
    expect(harness.controllers['s1']!.commandLines, isEmpty);
    expect(harness.controllers['s1']!.sent, isEmpty);

    const body = '/code-review Review this change\nKeep the public API';
    await tester.enterText(field, body);
    await pumpFrames(tester, 3);
    expect(find.byType(SlashPalette), findsNothing);
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester, 3);
    expect(harness.controllers['s1']!.sent, [body]);
    expect(harness.controllers['s1']!.commandLines, isEmpty);
  });
}
