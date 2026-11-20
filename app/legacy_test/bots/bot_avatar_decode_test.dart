import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/ui/fx/bot_avatar/bot_avatar.dart' as fx;
import 'package:dsh_app/ui/bots/bot_avatar.dart';
import 'package:dsh_app/ui/common/status_dot.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

const _bot = DsBot(id: 'photo-bot', name: 'Photo', imageRef: 'synthetic-photo');

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = Colors.blue);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void _view(WidgetTester tester, double dpr) {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = Size(320 * dpr, 640 * dpr);
  addTearDown(tester.view.reset);
}

Future<void> _mount(WidgetTester tester, Uint8List? photo, {double size = 40, bool working = false}) async {
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: Center(
          child: BotAvatar(bot: _bot, size: size, working: working),
        ),
      ),
      overrides: [dsBotPhotoProvider((botId: _bot.id, ref: _bot.imageRef!)).overrideWith((ref) async => photo)],
    ),
  );
  await pumpFrames(tester, 2);
}

Future<Size> _decodedSize(WidgetTester tester) async {
  final image = tester.widget<Image>(find.byType(Image));
  final context = tester.element(find.byType(Image));
  await tester.runAsync(() => precacheImage(image.image, context));
  await tester.pump();
  final decoded = tester.widget<RawImage>(find.byType(RawImage)).image!;
  return Size(decoded.width.toDouble(), decoded.height.toDouble());
}

void main() {
  setUpAll(loadTestFonts);

  for (final (width, height, size, dpr, expected) in <(int, int, double, double, Size)>[
    (2400, 1600, 24, 1, const Size(36, 24)),
    (2400, 1600, 40, 3, const Size(180, 120)),
    (1600, 2400, 40, 3, const Size(120, 180)),
    (2400, 1600, 19.2, 2.625, const Size(77, 51)),
    (2400, 1600, 96, 2, const Size(288, 192)),
  ]) {
    testWidgets('a $width x $height photo decodes enough to cover $size dp at $dpr', (tester) async {
      _view(tester, dpr);
      final photo = (await tester.runAsync(() => _png(width, height)))!;
      await _mount(tester, photo, size: size);
      expect(await _decodedSize(tester), expected);
      expect(tester.getSize(find.byType(BotAvatar)), Size.square(size));
      expect(find.byType(ClipOval), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('an extremely wide photo keeps its native short axis', (tester) async {
    _view(tester, 1);
    final photo = (await tester.runAsync(() => _png(2400, 16)))!;
    await _mount(tester, photo, size: 24);
    expect(await _decodedSize(tester), const Size(2400, 16));
    expect(find.byType(BotMonogram), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a changed device scale refreshes the decoded avatar', (tester) async {
    _view(tester, 1);
    final photo = (await tester.runAsync(() => _png(2400, 1600)))!;
    await _mount(tester, photo);
    expect(await _decodedSize(tester), const Size(60, 40));
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(960, 1920);
    await pumpFrames(tester, 2);
    expect(await _decodedSize(tester), const Size(180, 120));
    expect(tester.getSize(find.byType(BotAvatar)), const Size.square(40));
    expect(tester.takeException(), isNull);
  });

  testWidgets('small originals are not upscaled during decoding', (tester) async {
    _view(tester, 3);
    final photo = (await tester.runAsync(() => _png(16, 12)))!;
    await _mount(tester, photo, size: 96);
    expect(await _decodedSize(tester), const Size(16, 12));
    expect(tester.getSize(find.byType(BotAvatar)), const Size.square(96));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an absent photo shows its own little bot', (tester) async {
    _view(tester, 2);
    await _mount(tester, null);
    expect(find.byType(Image), findsNothing);
    expect(find.byType(fx.BotAvatar), findsOneWidget);
    expect(find.byType(BotMonogram), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an invalid photo falls back to the little bot and the working indicator', (tester) async {
    _view(tester, 2);
    await _mount(tester, Uint8List.fromList([1, 2, 3]), working: true);
    final image = tester.widget<Image>(find.byType(Image));
    final context = tester.element(find.byType(Image));
    await tester.runAsync(() => precacheImage(image.image, context, onError: (_, _) {}));
    await pumpFrames(tester, 2);
    expect(find.byType(fx.BotAvatar), findsOneWidget);
    expect(find.byType(StatusDot), findsOneWidget);
    expect(tester.getSize(find.byType(BotAvatar)), const Size.square(40));
    expect(tester.takeException(), isNull);
  });
}
