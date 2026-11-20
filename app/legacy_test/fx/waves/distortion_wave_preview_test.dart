// Portions derived from Libraries.dev Distortion waves (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// Preview frames, only when asked:
//   flutter test --dart-define=FX_PREVIEW_OUT=<dir> test/fx/waves/distortion_wave_preview_test.dart
// The tester runs the shaders (the bundle's SkSL), so these are the real frames.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/fx/waves/distortion_wave.dart';
import 'package:dsh_app/ui/fx/waves/wave_stage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const out = String.fromEnvironment('FX_PREVIEW_OUT');
const size = Size(402, 874);

ThemeData theme(Brightness brightness) {
  final light = brightness == Brightness.light;
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF4B67B4),
      brightness: brightness,
    ).copyWith(primary: light ? const Color(0xFF4B67B4) : const Color(0xFF97B1F0)),
  );
}

/// The home: a title, a few cards, an input at the bottom.
class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    final ink = light ? const Color(0xFF1E232E) : const Color(0xFFE6E9F0);
    final card = light ? Colors.white : const Color(0xFF272C36);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: light ? const [Color(0xFFEBF1FE), Color(0xFFF6F7FC)] : const [Color(0xFF1D222C), Color(0xFF1B1C23)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 64, 20, 34),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '工作',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600, color: ink),
            ),
            const SizedBox(height: 18),
            for (final line in ['整理这周的会议纪要', '把报销单拆成三类', '给新同事写一份上手说明', '检查一下构建为什么变慢'])
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                width: double.infinity,
                decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(18)),
                child: Text(line, style: TextStyle(fontSize: 16, color: ink)),
              ),
            const Spacer(),
            Container(
              height: 58,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(29),
              ),
              alignment: Alignment.center,
              child: const Text('进入伙伴小屋', style: TextStyle(fontSize: 17, color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}

/// The companion's room: a soft field, her, a line of hers.
class _Room extends StatelessWidget {
  const _Room();

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    final ink = light ? const Color(0xFF1E232E) : const Color(0xFFE6E9F0);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: light ? const [Color(0xFFF4EEF8), Color(0xFFE5ECFA)] : const [Color(0xFF241F2E), Color(0xFF17202C)],
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 150),
          Container(
            width: 168,
            height: 168,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: light
                    ? const [Color(0xFFD9C8EE), Color(0xFFBFD0F4)]
                    : const [Color(0xFF4A3D63), Color(0xFF2F4568)],
              ),
            ),
          ),
          const SizedBox(height: 28),
          Text(
            '伙伴小屋',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: ink),
          ),
          const SizedBox(height: 12),
          Text('今天想聊点什么?', style: TextStyle(fontSize: 16, color: ink.withValues(alpha: 0.7))),
        ],
      ),
    );
  }
}

class _Variant {
  const _Variant(this.name, this.style, this.brightness, {this.source, this.focus});

  final String name;
  final DistortionWaveStyle style;
  final Brightness brightness;
  final Rect? source;
  final Offset? focus;
}

void main() {
  setUpAll(WavePrograms.load);

  final variants = [
    const _Variant('vertical-light', DistortionWaveStyle.vertical, Brightness.light, source: button),
    const _Variant('vertical-dark', DistortionWaveStyle.vertical, Brightness.dark, source: button),
    _Variant(
      'vertical-colorful',
      DistortionWaveStyle.vertical.copyWith(palette: DistortionWavePalette.colorful),
      Brightness.light,
      source: button,
      focus: const Offset(330, 811),
    ),
    const _Variant('horizontal-light', DistortionWaveStyle.horizontal, Brightness.light),
    const _Variant('center-dark', DistortionWaveStyle.center, Brightness.dark),
    _Variant(
      'center-green',
      DistortionWaveStyle.center.copyWith(palette: DistortionWavePalette.green),
      Brightness.light,
    ),
  ];

  testWidgets('preview frames', skip: out.isEmpty, (tester) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    for (final variant in variants) {
      final dir = Directory('$out/${variant.name}')..createSync(recursive: true);
      // 15 frames a second over the whole wave.
      final frames = (variant.style.duration * 15).ceil();
      for (var i = 0; i <= frames; i++) {
        final p = i / frames;
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey(variant.name),
            debugShowCheckedModeBanner: false,
            theme: theme(variant.brightness),
            themeAnimationDuration: Duration.zero,
            home: RepaintBoundary(
              key: key,
              child: Material(
                type: MaterialType.transparency,
                child: DistortionWave(
                  isRevealed: false,
                  scrub: p,
                  style: variant.style,
                  source: variant.source,
                  focus: variant.focus,
                  content: const _Home(),
                  revealed: const _Room(),
                ),
              ),
            ),
          ),
        );
        await _save(tester, key, dir, i);
      }
    }
  });

  // The route in real time: the home captured on the second frame, pushed
  // over, then popped back.
  testWidgets('preview the route', skip: out.isEmpty, (tester) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    late NavigatorState navigator;
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(Brightness.light),
          home: Builder(
            builder: (context) {
              navigator = Navigator.of(context);
              return const Material(type: MaterialType.transparency, child: _Home());
            },
          ),
        ),
      ),
    );
    final dir = Directory('$out/route-light')..createSync(recursive: true);
    navigator.push(
      DistortionWaveRoute<void>(
        source: button,
        builder: (_) => const Material(type: MaterialType.transparency, child: _Room()),
      ),
    );
    var i = 0;
    await tester.pump();
    await _save(tester, key, dir, i++);
    const frame = Duration(microseconds: 1000000 ~/ 15);
    while (i <= (DistortionWaveStyle.vertical.duration * 15).ceil() + 1) {
      await tester.pump(frame);
      await _save(tester, key, dir, i++);
    }
    navigator.pop();
    await tester.pump();
    final back = (DistortionWaveStyle.vertical.duration / DistortionWaveStyle.vertical.returnSpeed * 15).ceil() + 1;
    for (var k = 0; k <= back; k++) {
      await tester.pump(frame);
      await _save(tester, key, dir, i++);
    }
  });
}

const button = Rect.fromLTWH(20, 782, 362, 58);

Future<void> _save(WidgetTester tester, GlobalKey key, Directory dir, int i) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    File('${dir.path}/${i.toString().padLeft(3, '0')}.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
}
