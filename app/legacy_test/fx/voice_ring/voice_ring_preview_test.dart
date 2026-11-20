// Preview frames for review, only when asked:
//   flutter test test/fx/voice_ring/voice_ring_preview_test.dart --dart-define=FX_PREVIEW_OUT=<dir>
// Writes anim/*.png (a 2×2 timeline: ring and mono, dark and light), stills_*.png
// (every state and emotion across palettes) and lens_* (a leaned frame and the
// edge lens's uniforms, for a numpy run of the shader, which flutter test cannot load).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dsh_app/ui/fx/voice_ring/aura.dart';
import 'package:dsh_app/ui/fx/voice_ring/frame.dart';
import 'package:dsh_app/ui/fx/voice_ring/lean.dart';
import 'package:dsh_app/ui/fx/voice_ring/light.dart';
import 'package:dsh_app/ui/fx/voice_ring/voice.dart';
import 'package:dsh_app/ui/fx/voice_ring/voice_ring.dart';
import 'package:dsh_app/ui/theme/accent.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const out = String.fromEnvironment('FX_PREVIEW_OUT');

double _now = 0;

/// A voice as the call's meters report it: dBFS every 40 ms.
double _speechDb(double t, {double seed = 0, double gain = 0}) {
  final tq = (t / 0.04).floorToDouble() * 0.04;
  final ph = (tq + seed) % 2.9;
  if (ph > 2.4) return -55 + 3 * math.sin(tq * 13);
  final syl = 0.5 + 0.5 * math.sin(2 * math.pi * (4.2 * tq + 0.3 * math.sin(2 * math.pi * 0.6 * tq)));
  final stress = 0.6 + 0.4 * math.sin(2 * math.pi * 0.45 * tq + seed);
  return -42 + gain + 26 * math.pow(syl, 1.4) * stress;
}

double _mic() => VoiceRingLevel.mic(((_speechDb(_now) + 60) / 50).clamp(0, 1));
double _tts() => VoiceRingLevel.playback(((_speechDb(_now, seed: 1.1, gain: 4) + 50) / 40).clamp(0, 1));

Color _field(ThemeData theme) {
  final hue = HSLColor.fromColor(theme.colorScheme.primary).hue;
  return theme.brightness == Brightness.dark
      ? HSLColor.fromAHSL(1, hue, 0.3, 0.05).toColor()
      : HSLColor.fromAHSL(1, hue, 0.28, 0.965).toColor();
}

Widget _cell(ThemeData theme, double box, Widget ring) => Theme(
  data: theme,
  child: Container(width: box, height: box, color: _field(theme), alignment: Alignment.center, child: ring),
);

Future<void> _save(WidgetTester tester, GlobalKey key, String path) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _advance(WidgetTester tester, double seconds) async {
  final n = (seconds / 0.017).round();
  for (var i = 0; i < n; i++) {
    _now += 0.017;
    await tester.pump(const Duration(milliseconds: 17));
  }
}

void main() {
  testWidgets('timeline', (tester) async {
    tester.view
      ..physicalSize = const Size(600, 600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    _now = 0;
    final key = GlobalKey();
    final phase = ValueNotifier<(VoiceRingState, VoiceRingEmotion?)>((VoiceRingState.idle, null));
    final dark = buildDarkTheme();
    final light = buildLightTheme();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: ValueListenableBuilder(
            valueListenable: phase,
            builder: (context, p, _) {
              final (state, emotion) = p;
              double level() => state == VoiceRingState.listening ? _mic() : _tts();
              Widget ring(VoiceRingType type) =>
                  VoiceRing(type: type, state: state, size: 280, level: level, emotion: emotion);
              return Wrap(
                children: [
                  for (final type in VoiceRingType.values)
                    for (final theme in [dark, light]) _cell(theme, 300, ring(type)),
                ],
              );
            },
          ),
        ),
      ),
    );
    const script = [
      (2.0, VoiceRingState.idle, null),
      (3.2, VoiceRingState.listening, null),
      (2.4, VoiceRingState.processing, null),
      (3.2, VoiceRingState.speaking, null),
      (2.8, VoiceRingState.speaking, VoiceRingEmotion.positive),
      (2.0, VoiceRingState.idle, null),
    ];
    var frame = 0;
    for (final (seconds, state, emotion) in script) {
      phase.value = (state, emotion);
      for (var t = 0.0; t < seconds; t += 0.085) {
        await _advance(tester, 0.085);
        await _save(tester, key, '$out/anim/${(frame++).toString().padLeft(4, '0')}.png');
      }
    }
  }, skip: out.isEmpty);

  testWidgets('stills', (tester) async {
    const box = 200.0;
    const columns = [
      (VoiceRingState.idle, null),
      (VoiceRingState.listening, null),
      (VoiceRingState.speaking, null),
      (VoiceRingState.processing, null),
      (VoiceRingState.speaking, VoiceRingEmotion.positive),
      (VoiceRingState.listening, VoiceRingEmotion.negative),
      (VoiceRingState.speaking, VoiceRingEmotion.calm),
    ];
    final rows = [
      (VoiceRingType.ring, buildDarkTheme(), null),
      (VoiceRingType.ring, buildLightTheme(), null),
      (VoiceRingType.mono, buildDarkTheme(), null),
      (VoiceRingType.mono, buildLightTheme(), null),
      (VoiceRingType.ring, buildDarkTheme(), VoiceRingPalette.original),
      (VoiceRingType.ring, buildLightTheme(), VoiceRingPalette.original),
      (VoiceRingType.ring, buildDarkTheme(accent: AppAccent.amber), null),
      (VoiceRingType.ring, buildLightTheme(accent: AppAccent.turquoise), null),
      (VoiceRingType.ring, buildDarkTheme(accent: AppAccent.graphite), null),
    ];
    tester.view
      ..physicalSize = Size(box * columns.length, box * rows.length)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    _now = 0;
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: Wrap(
            children: [
              for (final (type, theme, palette) in rows)
                for (final (state, emotion) in columns)
                  _cell(
                    theme,
                    box,
                    VoiceRing(
                      type: type,
                      state: state,
                      size: 180,
                      palette: palette,
                      emotion: emotion,
                      level: state == VoiceRingState.listening ? _mic : _tts,
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
    await _advance(tester, 2.2);
    await _save(tester, key, '$out/stills_a.png');
    await _advance(tester, 0.45);
    await _save(tester, key, '$out/stills_b.png');
  }, skip: out.isEmpty);

  testWidgets('lens', (tester) async {
    // A 300 px ring centred on a 390 px phone, leaning hard right: the room
    // to either edge is 13 px past the 32 px margin.
    const size = 300.0;
    const dpr = 2.0;
    final segs = (140 * math.sqrt(1.4)).round();
    final builder = AuraFrameBuilder(segs: segs);
    final follower = VoiceFollower();
    final bounce = EdgeBounce();
    var press = 0.0;
    OrbFrame? last;
    for (var i = 0; i < 240; i++) {
      _now = i / 60;
      follower.readLevel(_tts(), 0.85);
      final v = follower.step(
        1 / 60,
        threshold: 0.04,
        attack: 0.06,
        release: 0.32,
        idle: 0.1,
        driveGain: 1.8,
        calm: 0.4,
        rate: 1.6,
        processing: false,
        direction: 1,
        still: false,
      );
      final f = builder.build(size, follower.t, v);
      leanFrame(f, v.pan, size, ringLean, roomLeft: 13, roomRight: 13, bounce: bounce.step(press, 1 / 60));
      press = f.contact?.press ?? 0;
      last = f;
    }
    final frame = last!;
    const box = Rect.fromLTRB(-45, 0, size + 45, size);
    final painter = LightPainter();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(dpr)
      ..translate(-box.left, 0)
      ..saveLayer(box, Paint());
    painter.paint(canvas, frame, dark: true, bounds: box);
    canvas.restore();
    final picture = recorder.endRecording();
    await tester.runAsync(() async {
      final image = await picture.toImage((box.width * dpr).ceil(), (box.height * dpr).ceil());
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(out).createSync(recursive: true);
      File('$out/lens_frame.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
    final c = frame.contact!;
    final l = c.lens!;
    File('$out/lens_uniforms.json').writeAsStringSync(
      jsonEncode({
        'dpr': dpr,
        'width': box.width,
        'height': box.height,
        'wall': c.x - box.left,
        'side': c.side,
        'zone': l.zone,
        'gap': l.gap,
        'flare': l.flare,
        'split': l.split,
        'blur': l.blur,
        'cy': l.cy,
        'press': c.press,
      }),
    );
  }, skip: out.isEmpty);
}
