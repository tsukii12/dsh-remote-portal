// 图片快捷方式: the bitmap puts the crop in the launcher's visible middle, the sheet picks,
// asks the launcher, says what happens next, and closes when the launcher reports the shortcut
// added. Goldens:
//
//   flutter test --update-goldens test/settings/icon_shortcut_sheet_test.dart

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/app_icon_state.dart';
import 'package:dsh_app/state/icon_shortcut_state.dart';
import 'package:dsh_app/ui/settings/appearance/icon_shortcut_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

class _Channel extends IconShortcutChannel {
  _Channel(this.answer);

  PinRequest answer;
  final pins = <(String, Uint8List)>[];
  final _events = StreamController<void>.broadcast();
  int settings = 0;

  @override
  Stream<void> get pinned => _events.stream;

  void reportPinned() => _events.add(null);

  @override
  Future<PinRequest> pin(String label, Uint8List png) async {
    pins.add((label, png));
    return answer;
  }

  @override
  Future<bool> openAppSettings() async {
    settings++;
    return true;
  }
}

class _Bridge extends RuntimeBridge {
  _Bridge(this.asked, this.answer);

  final List<String> asked;
  final String? answer;

  @override
  Future<String?> openVendorSettings(String vendorSwitch) async {
    asked.add(vendorSwitch);
    return answer;
  }
}

class _Launcher extends LauncherIconChannel {
  const _Launcher();

  @override
  Future<AppIconState?> state() async => const AppIconState(current: AppIcon.mist);
}

/// Four quarters, red / green / blue / yellow: where each lands says how the crop mapped.
Future<ui.Image> _quarters(int side) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final h = side / 2;
  canvas
    ..drawRect(Rect.fromLTWH(0, 0, h, h), Paint()..color = const Color(0xFFFF0000))
    ..drawRect(Rect.fromLTWH(h, 0, h, h), Paint()..color = const Color(0xFF00FF00))
    ..drawRect(Rect.fromLTWH(0, h, h, h), Paint()..color = const Color(0xFF0000FF))
    ..drawRect(Rect.fromLTWH(h, h, h, h), Paint()..color = const Color(0xFFFFFF00));
  return recorder.endRecording().toImage(side, side);
}

Future<Uint8List> _png(ui.Image image) async =>
    (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();

Future<(int, int, int, int)> _pixel(Uint8List png, int x, int y) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
  final i = (y * image.width + x) * 4;
  return (data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2), data.getUint8(i + 3));
}

void main() {
  group('bitmap', () {
    test('the crop fills the visible middle 72 of 108; the picture carries on around it', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final picture = await _quarters(400);
      // The middle 200 px: the four quarters meet at its centre.
      final png = await shortcutBitmap(picture, const Rect.fromLTWH(100, 100, 200, 200), const Color(0xFFFFFFFF));
      expect(await _pixel(png, 0, 0), isNot((255, 255, 255, 255)), reason: 'the picture reaches the corner');
      // 432 px: the visible middle is 72..360. Its quarter points are the four colours.
      expect(await _pixel(png, 144, 144), (255, 0, 0, 255));
      expect(await _pixel(png, 288, 144), (0, 255, 0, 255));
      expect(await _pixel(png, 144, 288), (0, 0, 255, 255));
      expect(await _pixel(png, 288, 288), (255, 255, 0, 255));
    });

    test('where the picture ends, the fill colour', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final picture = await _quarters(200);
      // The whole picture as the crop: the ring around it is beyond the picture.
      final png = await shortcutBitmap(picture, const Rect.fromLTWH(0, 0, 200, 200), const Color(0xFF123456));
      expect(await _pixel(png, 10, 10), (0x12, 0x34, 0x56, 255));
      expect(await _pixel(png, 100, 100), (255, 0, 0, 255));
    });
  });

  group('where to allow it', () {
    test('the maker\'s own permission page (popup in the ACCESS table), else nothing opened', () async {
      final asked = <String>[];
      final container = ProviderContainer(
        overrides: [runtimeBridgeProvider.overrideWithValue(_Bridge(asked, 'vendor'))],
      );
      addTearDown(container.dispose);
      expect(await container.read(iconShortcutChannelProvider).openAppSettings(), isTrue);
      expect(asked, ['popup']);
      expect(await IconShortcutChannel(openPermissions: () async => null).openAppSettings(), isFalse);
    });
  });

  group('sheet', () {
    late _Channel channel;
    late Uint8List picture;

    Future<void> open(WidgetTester tester, {Brightness brightness = Brightness.light, bool pick = true}) async {
      picture = (await tester.runAsync(() async => _png(await _quarters(600))))!;
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(onPressed: () => showIconShortcutSheet(context), child: const Text('open')),
              ),
            ),
          ),
          brightness: brightness,
          overrides: [
            iconShortcutChannelProvider.overrideWithValue(channel),
            shortcutPicturePickerProvider.overrideWithValue(() async => picture),
            launcherIconChannelProvider.overrideWithValue(const _Launcher()),
          ],
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      if (!pick) return;
      await tester.tap(find.byKey(const ValueKey('shortcut-pick')));
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    setUp(() => channel = _Channel(PinRequest.asked));

    testWidgets('nothing to add before a picture', (tester) async {
      await open(tester, pick: false);
      final add = tester.widget<FilledButton>(find.byKey(const ValueKey('shortcut-add')));
      expect(add.onPressed, isNull);
      expect(find.text('选择图片'), findsOneWidget);
      // The honest note is always there.
      expect(find.textContaining('部分桌面会在它的角上加一个小标'), findsOneWidget);
    });

    testWidgets('pick, name, add: the launcher is asked; what to do if no dialog shows', (tester) async {
      await open(tester);
      expect(find.text('拖动或双指缩放'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('shortcut-name')), '我的助手');
      await tester.tap(find.byKey(const ValueKey('shortcut-add')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      expect(channel.pins.single.$1, '我的助手');
      // A 432 px PNG.
      final png = channel.pins.single.$2;
      expect(png.sublist(1, 4), 'PNG'.codeUnits);
      expect(find.text('在弹出的窗口里确认'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shortcut-settings')));
      expect(channel.settings, 1);
      // The launcher reports it added: the sheet closes and says so.
      channel.reportPinned();
      await tester.pumpAndSettle();
      expect(find.byType(IconShortcutSheet), findsNothing);
      expect(find.text('已添加到桌面'), findsOneWidget);
    });

    testWidgets('a launcher without pinned shortcuts says so', (tester) async {
      channel.answer = PinRequest.unsupported;
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('shortcut-add')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      expect(find.text('这个桌面不支持添加快捷方式'), findsOneWidget);
      expect(find.text('在弹出的窗口里确认'), findsNothing);
    });

    testWidgets('the well is centred and square', (tester) async {
      await open(tester);
      final well = tester.getRect(find.byKey(const ValueKey('shortcut-well')));
      final sheet = tester.getRect(find.byType(IconShortcutSheet));
      expect(well.width, well.height);
      expect(well.width, IconShortcutSheet.well);
      expect(well.center.dx, moreOrLessEquals(sheet.center.dx, epsilon: 0.01));
    });

    for (final brightness in Brightness.values) {
      final mode = brightness == Brightness.dark ? 'dark' : 'light';
      testWidgets('golden ($mode)', (tester) async {
        await tester.runAsync(loadGoldenFonts);
        await open(tester, brightness: brightness);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/icon_shortcut_sheet_$mode.png'));
      });
    }
  });
}
