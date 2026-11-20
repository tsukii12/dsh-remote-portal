import 'dart:typed_data';

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

Future<void> pumpScreen(WidgetTester tester, ChatHarness harness) async {
  usePhoneView(tester);
  mockClipboard(tester);
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester);
}

Future<void> attachFrom(WidgetTester tester, String menuLabel) async {
  await tester.tap(find.bySemanticsLabel('添加图片或文件'));
  await pumpFrames(tester);
  await tester.tap(find.text(menuLabel));
  await pumpFrames(tester);
}

DraftAttachment textFile(String name, [String body = 'hello']) =>
    DraftAttachment.sniff(name, Uint8List.fromList(body.codeUnits));

void main() {
  setUpAll(() => chatClock = () => DateTime(2026, 10, 23, 9));

  group('sniffing and limits', () {
    test('inline images are recognised by their bytes, not the name', () {
      expect(inlineImageType(tinyPng), 'image/png');
      expect(inlineImageType(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), 'image/jpeg');
      expect(inlineImageType(Uint8List.fromList('GIF89a'.codeUnits)), 'image/gif');
      expect(inlineImageType(Uint8List.fromList('RIFF\x00\x00\x00\x00WEBPVP8 '.codeUnits)), 'image/webp');
      // HEIC and friends are not inline types: they go as files.
      expect(inlineImageType(Uint8List.fromList('\x00\x00\x00\x18ftypheic'.codeUnits)), isNull);
      expect(DraftAttachment.sniff('photo.png', Uint8List.fromList('not a png'.codeUnits)).isImage, isFalse);
      expect(DraftAttachment.sniff('scan', tinyPng).isImage, isTrue);
    });

    test('sizes read like a file manager', () {
      expect(formatBytes(12), '12 B');
      expect(formatBytes(860 * 1024), '860 KB');
      expect(formatBytes((1.2 * 1024 * 1024).round()), '1.2 MB');
      expect(formatBytes(42 * 1024 * 1024), '42 MB');
    });

    test('empty and oversized attachments are refused with a reason', () {
      expect(attachmentProblem(textFile('a.txt', '')), contains('空文件'));
      expect(
        attachmentProblem(DraftAttachment(name: 'big.zip', bytes: Uint8List(maxFileBytes + 1))),
        contains('200 MB'),
      );
      expect(attachmentProblem(textFile('ok.txt')), isNull);
    });
  });

  group('composer', () {
    testWidgets('＋ offers 相册 / 拍照 / 文件, and a picked file waits in the tray', (tester) async {
      final harness = ChatHarness(session: 's1')..picker.files = [textFile('notes.md')];
      await pumpScreen(tester, harness);

      await tester.tap(find.bySemanticsLabel('添加图片或文件'));
      await pumpFrames(tester);
      expect(find.text('相册'), findsOneWidget);
      expect(find.text('拍照'), findsOneWidget);
      expect(find.text('文件'), findsOneWidget);

      await tester.tap(find.text('文件'));
      await pumpFrames(tester);
      expect(harness.picker.calls, ['files']);
      expect(find.byType(ComposerTray), findsOneWidget);
      expect(find.text('notes.md'), findsOneWidget);
      expect(find.text('MD · 5 B'), findsOneWidget);
    });

    testWidgets('an attachment alone can be sent, and the tray empties', (tester) async {
      final harness = ChatHarness(session: 's1')..picker.images = [DraftAttachment.sniff('cat.png', tinyPng)];
      await pumpScreen(tester, harness);
      await attachFrom(tester, '相册');
      expect(harness.picker.calls, ['images:$maxAttachments']);

      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);

      final controller = harness.controllers['s1']!;
      expect(controller.sent, ['']);
      expect(controller.sentAttachments.single.single.name, 'cat.png');
      expect(controller.sentAttachments.single.single.mediaType, 'image/png');
      expect(find.byType(ComposerTray), findsNothing);
    });

    testWidgets('removing from the tray drops just that one', (tester) async {
      final harness = ChatHarness(session: 's1')..picker.files = [textFile('a.txt'), textFile('b.txt')];
      await pumpScreen(tester, harness);
      await attachFrom(tester, '文件');

      await tester.tap(find.bySemanticsLabel('移除「a.txt」'));
      await pumpFrames(tester);
      expect(find.text('a.txt'), findsNothing);
      expect(find.text('b.txt'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '看看这个');
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      final controller = harness.controllers['s1']!;
      expect(controller.sent, ['看看这个']);
      expect([for (final a in controller.sentAttachments.single) a.name], ['b.txt']);
    });

    testWidgets('with attachments a "/" line is a message, not a command', (tester) async {
      final harness = ChatHarness(session: 's1')..picker.files = [textFile('log.txt')];
      await pumpScreen(tester, harness);
      await attachFrom(tester, '文件');

      await tester.enterText(find.byType(TextField), '/compact');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      final controller = harness.controllers['s1']!;
      expect(controller.commandLines, isEmpty);
      expect(controller.sent, ['/compact']);
    });

    testWidgets('oversized picks are refused with a note, the rest kept', (tester) async {
      final harness = ChatHarness(session: 's1')
        ..picker.files = [DraftAttachment(name: 'huge.bin', bytes: Uint8List(maxFileBytes + 1)), textFile('small.txt')];
      await pumpScreen(tester, harness);
      await attachFrom(tester, '文件');
      expect(find.text('small.txt'), findsOneWidget);
      expect(find.text('huge.bin'), findsNothing);
      expect(find.textContaining('超过 200 MB'), findsOneWidget);
    });

    testWidgets('a cancelled camera adds nothing', (tester) async {
      final harness = ChatHarness(session: 's1');
      await pumpScreen(tester, harness);
      await attachFrom(tester, '拍照');
      expect(harness.picker.calls, ['camera']);
      expect(find.byType(ComposerTray), findsNothing);
    });

    testWidgets('disconnected: the ＋ is disabled', (tester) async {
      final harness = ChatHarness(session: 's1', connected: false);
      await pumpScreen(tester, harness);
      await tester.tap(find.bySemanticsLabel('添加图片或文件'));
      await pumpFrames(tester);
      expect(find.text('相册'), findsNothing);
    });
  });

  group('bubble', () {
    testWidgets('an in-flight message shows its images and files above the text', (tester) async {
      final harness = ChatHarness(
        session: 's1',
        states: {
          's1': ChatState(
            loading: false,
            pending: [
              PendingPrompt(
                requestId: 'r1',
                text: '帮我看看',
                time: DateTime(2026, 10, 23, 9),
                attachments: [DraftAttachment.sniff('cat.png', tinyPng), textFile('report.pdf')],
              ),
            ],
          ),
        },
      );
      await pumpScreen(tester, harness);
      expect(find.byType(SentAttachments), findsOneWidget);
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('帮我看看'), findsOneWidget);
      // Images sit above the text, not inside the bubble.
      final image = tester.getCenter(find.bySemanticsLabel('图片').first);
      final text = tester.getCenter(find.text('帮我看看'));
      expect(image.dy, lessThan(text.dy));
    });
  });
}
