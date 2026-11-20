// Renders the glow over time for a visual check against the original:
//   flutter test test/fx/voice_glow/voice_beam_preview_test.dart --dart-define=FX_PREVIEW_OUT=<dir>
// Writes <dir>/<scene>/fNNNN.png; skipped without the define.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dsh_app/ui/fx/voice_glow/voice_beam.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _out = String.fromEnvironment('FX_PREVIEW_OUT');

/// The libraries.dev demo voice (`demoLevel` in voice-mocks.tsx): phrases of
/// syllables, 6.6 s of speech in every 9.
double demoLevel(double t) {
  final phrase = t % 9;
  if (phrase > 6.6) return 0;
  final syllable = 0.5 + 0.5 * math.sin(t * math.pi * 2 * 3.1);
  final word = 0.5 + 0.5 * math.sin(t * math.pi * 2 * 0.55 + 1);
  final rough = 0.86 + 0.14 * math.sin(t * 23.7);
  return math.min(1, math.pow(syllable, 1.6) * (0.5 + 0.5 * word) * rough * 1.05);
}

enum _Phase { voice, speaking, idle }

class _Scene {
  const _Scene(
    this.name, {
    required this.type,
    required this.brightness,
    required this.size,
    required this.radius,
    this.variant,
    this.seed = const Color(0xFF4A6CF7),
    this.timeline = const [(_Phase.voice, 4.5), (_Phase.idle, 2.0)],
    this.pixelRatio = 2,
    this.everyFrames = 5,
    this.hold,
  });

  /// A constant level instead of the demo voice (the side-by-side shots
  /// against the web original).
  final double? hold;
  final String name;
  final VoiceBeamType type;
  final Brightness brightness;
  final Size size;
  final double radius;
  final VoiceBeamColorVariant? variant;
  final Color seed;
  final List<(_Phase, double)> timeline;
  final double pixelRatio;
  final int everyFrames;
}

const _chat = Size(371, 104);
const _phone = Size(402, 874);
const _call = [(_Phase.voice, 4.5), (_Phase.idle, 1.5), (_Phase.speaking, 4.0), (_Phase.idle, 1.0)];

/// One frame after 2.5 s at a held level, for each state the web harness
/// (headless Edge running the original stylesheet and driver) also shoots.
List<_Scene> _compare() => [
  for (final (type, size, radius, ratio) in [
    (VoiceBeamType.standard, _chat, 20.0, 2.0),
    (VoiceBeamType.mobile, _phone, 66.0, 0.75),
    (VoiceBeamType.pill, const Size(150, 44), 22.0, 3.0),
  ])
    for (final brightness in Brightness.values)
      for (final hold in [0.0, 0.5, 0.9])
        _Scene(
          'cmp_${type.name}_${brightness.name}_l${(hold * 10).round()}',
          type: type,
          brightness: brightness,
          size: size,
          radius: radius,
          variant: VoiceBeamColorVariant.colorful,
          hold: hold,
          timeline: const [(_Phase.voice, 2.5)],
          pixelRatio: ratio,
          everyFrames: 100000,
        ),
];

const _only = String.fromEnvironment('FX_PREVIEW_ONLY');

final _scenes = [
  ..._compare(),
  const _Scene(
    'chat_dark_colorful',
    type: VoiceBeamType.standard,
    brightness: Brightness.dark,
    size: _chat,
    radius: 20,
    variant: VoiceBeamColorVariant.colorful,
  ),
  const _Scene(
    'chat_light_colorful',
    type: VoiceBeamType.standard,
    brightness: Brightness.light,
    size: _chat,
    radius: 20,
    variant: VoiceBeamColorVariant.colorful,
  ),
  const _Scene('chat_dark_theme', type: VoiceBeamType.standard, brightness: Brightness.dark, size: _chat, radius: 20),
  const _Scene('chat_light_theme', type: VoiceBeamType.standard, brightness: Brightness.light, size: _chat, radius: 20),
  const _Scene(
    'chat_dark_theme_green',
    type: VoiceBeamType.standard,
    brightness: Brightness.dark,
    size: _chat,
    radius: 20,
    seed: Color(0xFF2E7D5B),
  ),
  const _Scene(
    'pill_dark_colorful',
    type: VoiceBeamType.pill,
    brightness: Brightness.dark,
    size: Size(150, 44),
    radius: 22,
    variant: VoiceBeamColorVariant.colorful,
    pixelRatio: 3,
  ),
  const _Scene(
    'mobile_dark_colorful',
    type: VoiceBeamType.mobile,
    brightness: Brightness.dark,
    size: _phone,
    radius: 66,
    variant: VoiceBeamColorVariant.colorful,
    timeline: _call,
    pixelRatio: 0.75,
  ),
  const _Scene(
    'mobile_dark_theme',
    type: VoiceBeamType.mobile,
    brightness: Brightness.dark,
    size: _phone,
    radius: 66,
    timeline: _call,
    pixelRatio: 0.75,
  ),
  const _Scene(
    'mobile_light_theme',
    type: VoiceBeamType.mobile,
    brightness: Brightness.light,
    size: _phone,
    radius: 66,
    timeline: _call,
    pixelRatio: 0.75,
  ),
  for (final variant in VoiceBeamColorVariant.values)
    for (final brightness in Brightness.values)
      _Scene(
        'palette_${variant.name}_${brightness.name}',
        type: VoiceBeamType.standard,
        brightness: brightness,
        size: _chat,
        radius: 20,
        variant: variant,
        timeline: const [(_Phase.voice, 1.3)],
        everyFrames: 1000,
      ),
];

void main() {
  testWidgets('voice glow preview frames', (tester) async {
    for (final scene in _scenes.where((s) => s.name.startsWith(_only))) {
      final dir = Directory('$_out/${scene.name}')..createSync(recursive: true);
      final level = ValueNotifier<double>(0);
      var scale = VoiceLevelScale.linear;
      late StateSetter set;
      final boundary = GlobalKey();
      final dark = scene.brightness == Brightness.dark;
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(scene.name),
          debugShowCheckedModeBanner: false,
          theme: ThemeData(brightness: scene.brightness, colorSchemeSeed: scene.seed),
          home: Scaffold(
            backgroundColor: dark ? const Color(0xFF0B0B0C) : const Color(0xFFF2F2F3),
            body: Center(
              child: RepaintBoundary(
                key: boundary,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    set = setState;
                    return VoiceBeam(
                      type: scene.type,
                      level: level,
                      levelScale: scale,
                      colorVariant: scene.variant,
                      borderRadius: scene.radius,
                      child: Container(
                        width: scene.size.width,
                        height: scene.size.height,
                        decoration: BoxDecoration(
                          color: dark ? const Color(0xFF1B1B1D) : Colors.white,
                          borderRadius: BorderRadius.circular(scene.radius),
                          border: Border.all(color: dark ? const Color(0x852C2F36) : const Color(0x14000000)),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      var t = 0.0, frame = 0, shot = 0;
      for (final (index, (phase, seconds)) in scene.timeline.indexed) {
        set(() => scale = phase == _Phase.speaking ? VoiceLevelScale.playback : VoiceLevelScale.linear);
        final end = t + seconds;
        while (t < end - 1e-9) {
          level.value = switch (phase) {
            _Phase.voice => scene.hold ?? demoLevel(t + 0.4),
            // A TTS voice on −50…−10 dBFS: around −24 dBFS while speaking.
            _Phase.speaking => demoLevel(t + 4.9) * 0.7,
            _ => 0,
          };
          await tester.pump(const Duration(milliseconds: 16));
          t += 0.016;
          frame++;
          final last = t >= end - 1e-9 && index == scene.timeline.length - 1;
          if (frame % scene.everyFrames == 0 || last) {
            final object = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await object.toImage(pixelRatio: scene.pixelRatio);
              final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
              image.dispose();
              File('${dir.path}/f${(shot++).toString().padLeft(4, '0')}.png')
                  .writeAsBytesSync(bytes!.buffer.asUint8List());
            });
          }
        }
      }
    }
  }, skip: _out.isEmpty);
}
