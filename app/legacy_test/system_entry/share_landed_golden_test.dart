// Golden of the new-chat composer after a share (text, two photos, a PDF),
// as the chat screen fills it. Regenerate with
// `flutter test --update-goldens test/system_entry/share_landed_golden_test.dart`.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/compose_inbox.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_state.dart' show chatClock;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';

/// A small "photo": a soft sky-to-sea gradient with a sun.
Future<Uint8List> _photo(Color top, Color bottom) async {
  const size = 240.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, size, size),
    Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(0, size), [top, bottom]),
  );
  canvas.drawCircle(const Offset(168, 78), 30, Paint()..color = const Color(0xFFFFE7B0));
  canvas.drawRect(const Rect.fromLTWH(0, 150, size, 90), Paint()..color = bottom.withValues(alpha: 0.6));
  final image = await recorder.endRecording().toImage(size.toInt(), size.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    chatClock = () => DateTime(2026, 10, 24, 15, 20);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.dark ? 'dark' : 'light';

    testWidgets('share landed in the new-chat composer ($suffix)', (tester) async {
      usePhoneView(tester);
      mockClipboard(tester);
      final harness = ChatHarness(session: 's1');
      await tester.pumpWidget(testApp(const ChatScreen(), brightness: brightness, overrides: harness.overrides));
      await pumpFrames(tester);

      final photos = await tester.runAsync(
        () async => [
          await _photo(const Color(0xFF9DB8F2), const Color(0xFF3E5FA8)),
          await _photo(const Color(0xFFF3C9A8), const Color(0xFF8C5A7A)),
        ],
      );
      final attachments = [
        DraftAttachment.sniff('IMG_2041.png', photos![0]),
        DraftAttachment.sniff('IMG_2042.png', photos[1]),
        DraftAttachment.sniff('报价单.pdf', Uint8List.fromList(utf8.encode('%PDF-1.7${' ' * 180000}'))),
      ];
      final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
      container
          .read(composeInboxProvider.notifier)
          .push(ComposeRequest(text: '帮我看看这份报价单，有没有算错的地方', attachments: attachments));
      await pumpFrames(tester);
      final context = tester.element(find.byType(ChatScreen));
      await tester.runAsync(() async {
        for (final a in attachments.where((a) => a.isImage)) {
          await precacheImage(MemoryImage(a.bytes), context);
        }
      });
      // The keyboard is up on a device; the golden shows the composer resting.
      FocusManager.instance.primaryFocus?.unfocus();
      await pumpFrames(tester);
      await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/share_landed_$suffix.png'));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    });
  }
}
