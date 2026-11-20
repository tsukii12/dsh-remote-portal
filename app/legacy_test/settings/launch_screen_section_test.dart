// 设置 › 主题 › 启动画面: the two phones are measured (a symmetric pair on the page's picker
// grid), choosing and switching work through the stored state, a refused file says why, and
// the card is drawn light and dark with and without a picture. Goldens:
//
//   flutter test --update-goldens test/settings/launch_screen_section_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/launch/custom_launch.dart';
import 'package:dsh_app/launch/launch_import.dart';
import 'package:dsh_app/state/app_icon_state.dart';
import 'package:dsh_app/state/launch_screen_state.dart';
import 'package:dsh_app/launch/launch_media.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/launch/launch_editor_page.dart';
import 'package:dsh_app/ui/launch/launch_overlay.dart';
import 'package:dsh_app/ui/settings/appearance/appearance_page.dart';
import 'package:dsh_app/ui/settings/appearance/launch_screen_section.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';

class _Import extends LaunchImport {
  _Import(this.next) : super(directory: () async => Directory.systemTemp);

  (CustomLaunch?, LaunchImportProblem?) next;
  int picks = 0;

  @override
  Future<(CustomLaunch?, LaunchImportProblem?)> pick({CustomLaunch? previous}) async {
    picks++;
    return next;
  }
}

class _Launcher extends LauncherIconChannel {
  const _Launcher();

  @override
  Future<AppIconState?> state() async => const AppIconState(current: AppIcon.mist);
}

/// A photo-like picture: sky to sea, a sun.
Future<String> _photo(Directory dir) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const w = 540.0, h = 960.0;
  canvas
    ..drawRect(
      const Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          const Offset(0, h),
          const [Color(0xFFF6C8A8), Color(0xFF8DB3E2), Color(0xFF2E5C8A)],
          const [0, 0.55, 1],
        ),
    )
    ..drawCircle(const Offset(w / 2, h * 0.42), 90, Paint()..color = const Color(0xFFFFF1D6));
  final image = await recorder.endRecording().toImage(w.toInt(), h.toInt());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('${dir.path}/photo.png')..writeAsBytesSync(png!.buffer.asUint8List());
  return file.path;
}

Widget _page() => Scaffold(
  body: SafeArea(
    child: ListView(
      children: [
        Builder(
          builder: (context) => SettingsSection(
            title: '启动画面',
            footer: const Text('图片、动图 8 MB 以内，视频 30 MB 以内。冷启动时完整播放一遍，轻点可跳过'),
            children: const [LaunchScreenSection()],
          ),
        ),
      ],
    ),
  ),
);

void main() {
  late Directory dir;
  late _Import import;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('launch-section');
    import = _Import((null, LaunchImportProblem.cancelled));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> pump(WidgetTester tester, {CustomLaunch? stored, Brightness brightness = Brightness.light}) async {
    SharedPreferences.setMockInitialValues({
      if (stored != null)
        CustomLaunch.prefsKey:
            '{"kind":"${stored.kind.name}","path":"${stored.path}",'
            '"width":${stored.width},"height":${stored.height},"fit":"${stored.fit.name}",'
            '"backdrop":"${stored.backdrop.name}","on":${stored.on}${stored.edge == null ? '' : ',"edge":${stored.edge}'}}',
    });
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: _page(),
        brightness: brightness,
        overrides: [
          launchImportProvider.overrideWithValue(import),
          launcherIconChannelProvider.overrideWithValue(const _Launcher()),
        ],
      ),
    );
    // Prefs and the thumbnail are real I/O: let them land, a frame at a time.
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  Rect screenOf(WidgetTester tester, String which) => tester.getRect(
    find.descendant(of: find.byKey(ValueKey('launch-$which')), matching: find.byType(ClipRSuperellipse)),
  );

  bool selected(WidgetTester tester, String label) =>
      tester.getSemantics(find.bySemanticsLabel(label)).getSemanticsData().flagsCollection.isSelected ==
      ui.Tristate.isTrue;

  group('geometry', () {
    testWidgets('two phones, a symmetric pair a third of the card wide, 12 apart', (tester) async {
      await pump(tester);
      final card = tester.getRect(find.byType(SheetGroup));
      final a = screenOf(tester, 'default');
      final b = screenOf(tester, 'custom');
      expect(a.left - card.left, moreOrLessEquals(card.right - b.right, epsilon: 0.01));
      expect(b.left - a.right, moreOrLessEquals(PickerGrid.gap, epsilon: 0.01));
      final third = (card.width - 2 * PickerGrid.inset - 2 * PickerGrid.gap) / 3;
      expect(a.width, moreOrLessEquals(third, epsilon: 0.01));
      expect(b.width, moreOrLessEquals(a.width, epsilon: 0.01));
      expect(b.height, moreOrLessEquals(a.height, epsilon: 0.01));
      expect(a.top, b.top);
      // 16 under the card's own top, like every picker on the page (+4 for the card's inset).
      expect(a.top - card.top, moreOrLessEquals(PickerGrid.inset + 4, epsilon: 0.6));
      // The phone is the screen's own shape.
      expect(a.width / a.height, moreOrLessEquals(390 / 844, epsilon: 0.002));
      // Names centred under their phones.
      expect(tester.getCenter(find.text('默认')).dx, moreOrLessEquals(a.center.dx, epsilon: 0.01));
      expect(tester.getCenter(find.text('自定义')).dx, moreOrLessEquals(b.center.dx, epsilon: 0.01));
    });
  });

  group('choosing', () {
    testWidgets('no picture yet: 默认 in use, the custom phone picks one', (tester) async {
      final handle = tester.ensureSemantics();
      final path = (await tester.runAsync(() => _photo(dir)))!;
      import.next = (CustomLaunch(kind: LaunchMediaKind.image, path: path, width: 540, height: 960), null);
      await pump(tester);
      expect(selected(tester, '默认'), isTrue);
      expect(find.text('适配方式'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('launch-custom')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      expect(import.picks, 1);
      expect(selected(tester, '自定义'), isTrue);
      expect(find.text('启动画面已更换'), findsOneWidget);
      expect(find.text('适配方式'), findsOneWidget);
      expect(find.text('调整位置'), findsOneWidget);
      expect(find.text('背景色'), findsOneWidget);
      expect(find.text('更换图片或视频'), findsOneWidget);
      // Stored, in use.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(CustomLaunch.prefsKey), contains('"on":true'));
      handle.dispose();
    });

    testWidgets('默认 restores the default and keeps the picture to switch back to', (tester) async {
      final handle = tester.ensureSemantics();
      final path = (await tester.runAsync(() => _photo(dir)))!;
      await pump(
        tester,
        stored: CustomLaunch(kind: LaunchMediaKind.image, path: path, width: 540, height: 960),
      );
      expect(selected(tester, '自定义'), isTrue);
      await tester.tap(find.byKey(const ValueKey('launch-default')));
      await tester.pumpAndSettle();
      expect(selected(tester, '默认'), isTrue);
      expect(find.text('适配方式'), findsNothing);
      expect(File(path).existsSync(), isTrue);
      await tester.tap(find.byKey(const ValueKey('launch-custom')));
      await tester.pumpAndSettle();
      expect(selected(tester, '自定义'), isTrue);
      expect(import.picks, 0);
      handle.dispose();
    });

    testWidgets('fit and background are stored as they are picked', (tester) async {
      final handle = tester.ensureSemantics();
      final path = (await tester.runAsync(() => _photo(dir)))!;
      await pump(
        tester,
        stored: CustomLaunch(kind: LaunchMediaKind.image, path: path, width: 540, height: 960, edge: 0xFF2E5C8A),
      );
      expect(find.byKey(const ValueKey('launch-frame')), findsOneWidget);
      await tester.tap(find.text('居中'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('launch-frame')), findsNothing);
      await tester.tap(find.bySemanticsLabel('取自图片'));
      await tester.pumpAndSettle();
      final raw = (await SharedPreferences.getInstance()).getString(CustomLaunch.prefsKey)!;
      expect(raw, contains('"fit":"center"'));
      expect(raw, contains('"backdrop":"edge"'));
      expect(selected(tester, '取自图片'), isTrue);
      handle.dispose();
    });

    testWidgets('调整位置: drag and 完成 stores framing; 复原 centres it again', (tester) async {
      final path = (await tester.runAsync(() => _photo(dir)))!;
      await pump(
        tester,
        stored: CustomLaunch(kind: LaunchMediaKind.image, path: path, width: 540, height: 960),
      );
      await tester.tap(find.byKey(const ValueKey('launch-frame')));
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.byType(LaunchEditorPage), findsOneWidget);
      await tester.drag(find.byKey(const ValueKey('launch-editor-view')), const Offset(-40, 0));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('launch-editor-done')));
      await tester.pumpAndSettle();
      expect(find.byType(LaunchEditorPage), findsNothing);
      final stored = (await CustomLaunch.load())!;
      expect(stored.alignX, greaterThan(0.3));

      // Tapping the active custom phone in fill mode also opens the editor; 复原 resets framing.
      await tester.tap(find.byKey(const ValueKey('launch-custom')));
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.byType(LaunchEditorPage), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('launch-editor-reset')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('launch-editor-done')));
      await tester.pumpAndSettle();
      final reset = (await CustomLaunch.load())!;
      expect((reset.zoom, reset.alignX, reset.alignY), (1.0, 0.0, 0.0));
    });

    testWidgets('CustomLaunchView applies zoom and alignment in fill mode', (tester) async {
      usePhoneSurface(tester);
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 540, 960), Paint()..color = const Color(0xFF2E5C8A));
      final image = (await tester.runAsync(() => recorder.endRecording().toImage(540, 960)))!;
      addTearDown(image.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: CustomLaunchView(
            custom: const CustomLaunch(
              kind: LaunchMediaKind.image,
              path: '/x',
              width: 540,
              height: 960,
              zoom: 2,
              alignX: -1,
              alignY: 1,
            ),
            media: StillLaunchMedia(image, owned: false),
            dark: false,
          ),
        ),
      );
      final rect = tester.getRect(find.byType(RawImage));
      // 390 × 844 screen, 540 × 960 image: cover is 474.75 × 844; at 2× zoom it is 949.5 × 1688,
      // aligned to the left (-1 -> left == 0) and bottom (1 -> bottom == 844).
      expect(rect.width, moreOrLessEquals(949.5, epsilon: 0.05));
      expect(rect.height, moreOrLessEquals(1688, epsilon: 0.05));
      expect(rect.left, moreOrLessEquals(0, epsilon: 0.05));
      expect(rect.bottom, moreOrLessEquals(844, epsilon: 0.05));
    });

    testWidgets('without an edge colour there is no 取自图片', (tester) async {
      final path = (await tester.runAsync(() => _photo(dir)))!;
      await pump(
        tester,
        stored: CustomLaunch(kind: LaunchMediaKind.image, path: path, width: 540, height: 960),
      );
      expect(find.bySemanticsLabel('取自图片'), findsNothing);
      expect(find.bySemanticsLabel('自动'), findsOneWidget);
    });

    for (final (problem, text) in [
      (LaunchImportProblem.overLimit, '文件超过 30 MB'),
      (LaunchImportProblem.tooLarge, '图片超过 8 MB'),
      (LaunchImportProblem.unsupported, '支持 PNG、JPEG、WebP、GIF 和 MP4'),
      (LaunchImportProblem.unreadable, '无法读取这个文件'),
    ]) {
      testWidgets('refused: $text', (tester) async {
        import.next = (null, problem);
        await pump(tester);
        await tester.tap(find.byKey(const ValueKey('launch-custom')));
        await tester.pumpAndSettle();
        expect(find.text(text), findsOneWidget);
        expect(find.text('适配方式'), findsNothing);
      });
    }

    testWidgets('cancelled: nothing said', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('launch-custom')));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  // ── Goldens ─────────────────────────────────────────────────────────────

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';

    testWidgets('golden: default ($mode)', (tester) async {
      await tester.runAsync(loadGoldenFonts);
      await pump(tester, brightness: brightness);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/launch_section_default_$mode.png'));
    });

    for (final fit in LaunchFit.values) {
      testWidgets('golden: custom ${fit.name} ($mode)', (tester) async {
        await tester.runAsync(loadGoldenFonts);
        final path = (await tester.runAsync(() => _photo(dir)))!;
        await pump(
          tester,
          brightness: brightness,
          stored: CustomLaunch(
            kind: LaunchMediaKind.image,
            path: path,
            width: 540,
            height: 960,
            fit: fit,
            backdrop: fit == LaunchFit.center ? LaunchBackdrop.edge : LaunchBackdrop.auto,
            edge: 0xFF2E5C8A,
          ),
        );
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/launch_section_${fit.name}_$mode.png'));
      });
    }
  }
}
