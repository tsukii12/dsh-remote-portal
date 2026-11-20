// Portions derived from Libraries.dev Voice ring (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// The edge lens (refract.ts): a post-process over the ring already painted,
// as a fragment shader (shaders/fx/voice_ring_refract.frag). The frame is
// recorded, rasterised with toImageSync and drawn back through the shader;
// outside the lens zone the shader passes the pixels through. Where the
// program cannot load (flutter test cannot run shaders) the ring is left as
// painted, as the original does without WebGL.

import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'frame.dart';

class EdgeLens {
  static ui.FragmentProgram? _program;
  static bool _loading = false;

  /// Starts loading the program once; [program] stays null until it is in.
  static void load() {
    if (_loading) return;
    _loading = true;
    ui.FragmentProgram.fromAsset('shaders/fx/voice_ring_refract.frag').then(
      (p) => _program = p,
      // flutter test cannot load programs: the lens is skipped there
      onError: (Object _) {},
    );
  }

  static ui.FragmentProgram? get program => _program;

  ui.FragmentShader? _shader;
  final Paint _paint = Paint();

  /// Draws [box] (the ring's canvas, logical px) refracted through [lens]
  /// where [contact] meets the edge. [paintMarks] paints the ring into a
  /// canvas in the same coordinates as [canvas].
  void paint(
    Canvas canvas,
    Rect box,
    double dpr,
    OrbContact contact,
    OrbLens lens,
    ui.FragmentProgram program,
    void Function(Canvas canvas) paintMarks,
  ) {
    final recorder = ui.PictureRecorder();
    final offscreen = Canvas(recorder)
      ..scale(dpr)
      ..translate(-box.left, -box.top);
    paintMarks(offscreen);
    final picture = recorder.endRecording();
    final image = picture.toImageSync((box.width * dpr).ceil(), (box.height * dpr).ceil());
    picture.dispose();
    final shader = _shader ??= program.fragmentShader();
    shader
      ..setFloat(0, image.width / dpr)
      ..setFloat(1, image.height / dpr)
      ..setFloat(2, contact.x - box.left)
      ..setFloat(3, contact.side)
      ..setFloat(4, lens.zone)
      ..setFloat(5, lens.gap)
      ..setFloat(6, lens.flare)
      ..setFloat(7, lens.split)
      ..setFloat(8, lens.blur)
      ..setFloat(9, lens.cy - box.top)
      ..setImageSampler(0, image, filterQuality: FilterQuality.low);
    canvas
      ..save()
      ..translate(box.left, box.top)
      ..drawRect(Offset.zero & box.size, _paint..shader = shader)
      ..restore();
    image.dispose();
  }

  void dispose() => _shader?.dispose();
}
