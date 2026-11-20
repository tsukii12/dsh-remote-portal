// Portions derived from Libraries.dev Image (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'field.dart';
import 'presets.dart';
import 'reveal.dart';

/// The two fragment programs, loaded once. Until they have loaded, or where
/// they can't, the renderer draws the same field on the CPU, cell by cell.
class FxPrograms {
  FxPrograms._(this.field, this.mosaic);

  final ui.FragmentProgram field;
  final ui.FragmentProgram mosaic;

  /// Null while loading or after a failed load; tests clear it to exercise the CPU path.
  static FxPrograms? ready;
  static Future<void>? _loading;

  static Future<void> load() => _loading ??= () async {
    try {
      ready = FxPrograms._(
        await ui.FragmentProgram.fromAsset('shaders/fx/img_fx_field.frag'),
        await ui.FragmentProgram.fromAsset('shaders/fx/img_fx_mosaic.frag'),
      );
    } on Exception {
      // No runtime effects here: the CPU path draws instead.
    }
  }();
}

/// One card's renderer.ts `Instance`: the two-pass mosaic (a gridX×gridY
/// cell field, then a per-pixel composite) and the raw-field read-back the
/// reveal mask and the churn use.
class FxRenderer {
  ui.FragmentShader? _fieldShader;
  ui.FragmentShader? _mosaicShader;
  ui.Image? _fieldImage;
  Object? _fieldKey;
  bool _sampleInFlight = false;
  Uint8List? _latestSample;
  bool _disposed = false;
  final _col = Float64List(3);

  // Cell quads for the per-cell alpha passes, per grid and size.
  Float32List _quads = Float32List(0);
  Int32List _quadColors = Int32List(0);
  Object? _quadKey;

  bool get _gpu {
    final programs = FxPrograms.ready;
    if (programs == null) return false;
    _fieldShader ??= programs.field.fragmentShader();
    _mosaicShader ??= programs.mosaic.fragmentShader();
    return true;
  }

  void _setFieldUniforms(
    ui.FragmentShader s,
    FxField f,
    FxLook look,
    Size size,
    int targetW,
    int targetH,
    int gx,
    int gy,
    bool raw,
    double time,
  ) {
    var i = 0;
    void put(double v) => s.setFloat(i++, v);
    put(size.width);
    put(size.height);
    put(targetW.toDouble());
    put(targetH.toDouble());
    put(gx.toDouble());
    put(gy.toDouble());
    put(raw ? 1 : 0);
    put(time);
    put(f.speed);
    put(f.effect.toDouble());
    put(f.intensity);
    put(f.scale);
    put(f.direction);
    put(f.distortion);
    put(f.complexity);
    put(f.shape);
    put(f.flicker);
    put(f.blur);
    put(f.sweepEase.toDouble());
    put(f.vignette);
    put(f.vigOpacity);
    for (var c = 0; c < 5; c++) {
      put(look.colors[c].r);
      put(look.colors[c].g);
      put(look.colors[c].b);
    }
  }

  ui.Image _renderField(FxField f, FxLook look, Size size, int w, int h, int gx, int gy, bool raw, double time) {
    final s = _fieldShader!;
    _setFieldUniforms(s, f, look, size, w, h, gx, gy, raw, time);
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = s);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(w, h);
    picture.dispose();
    return image;
  }

  /// Paint the mosaic over [size] at [opacity]. [frame] identifies the engine
  /// frame, so the cell field is rendered once per frame.
  void paintMosaic(
    Canvas canvas,
    Size size,
    FxField f,
    FxPresetMode mode,
    FxLook look,
    double time,
    double pixelScale,
    double opacity,
    int frame,
  ) {
    final (gx, gy) = fxGrid(effectiveCellSize(mode.pixel.cellSize, pixelScale), size);
    if (!_gpu) {
      _paintCpu(canvas, size, f, mode, look, time, gx, gy, opacity);
      return;
    }
    final key = (frame, size, gx, gy, f, look);
    if (_fieldImage == null || _fieldKey != key) {
      _fieldImage?.dispose();
      _fieldImage = _renderField(f, look, size, gx, gy, gx, gy, false, time);
      _fieldKey = key;
    }
    final s = _mosaicShader!;
    final px = mode.pixel;
    var i = 0;
    void put(double v) => s.setFloat(i++, v);
    put(size.width);
    put(size.height);
    put(gx.toDouble());
    put(gy.toDouble());
    put(time);
    put(f.speed);
    put(f.scale);
    put(f.highlight);
    put(f.hlScale);
    put(px.gap);
    put(px.dotOpacity);
    put(px.fillOpacity);
    put(px.edgeFade);
    put(px.fadeStr);
    put(f.vignette);
    put(f.vigOpacity);
    put(opacity * mode.shaderOpacity);
    put(look.cardBg.r);
    put(look.cardBg.g);
    put(look.cardBg.b);
    s.setImageSampler(0, _fieldImage!);
    canvas.drawRect(Offset.zero & size, Paint()..shader = s);
  }

  /// The raw field for the reveal (see [FxFrame.sample]).
  Uint8List? sample(bool fresh, FxField f, FxPresetMode mode, FxLook look, Size size, double time, double pixelScale) {
    final (gx, gy) = fxGrid(effectiveCellSize(mode.pixel.cellSize, pixelScale), size);
    if (!_gpu) {
      if (fresh || _latestSample == null) _latestSample = f.rawSample(fxMaskSize, size, time, gx, gy);
      return _latestSample;
    }
    if (fresh && !_sampleInFlight) {
      _sampleInFlight = true;
      final image = _renderField(f, look, size, fxMaskSize, fxMaskSize, gx, gy, true, time);
      image
          .toByteData()
          .then(
            (data) {
              if (!_disposed && data != null) _latestSample = data.buffer.asUint8List();
            },
            // A failed read-back (the GPU went away) keeps the last sample; the
            // next frame asks again.
            onError: (Object _) {},
          )
          .whenComplete(() {
            image.dispose();
            _sampleInFlight = false;
          });
    }
    return _latestSample;
  }

  static double _smoothstep(double e0, double e1, double x) {
    final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  /// The composite pass evaluated once per cell: the cell's colour and alpha,
  /// its gap ring at the fill opacity.
  void _paintCpu(
    Canvas canvas,
    Size size,
    FxField f,
    FxPresetMode mode,
    FxLook look,
    double time,
    int gx,
    int gy,
    double opacity,
  ) {
    final px = mode.pixel;
    final aspect = size.width / size.height;
    final t = time * f.speed;
    final bgLum = fxLuma(look.cardBg);
    final cw = size.width / gx, ch = size.height / gy;
    final rect = Offset.zero & size;
    canvas.saveLayer(rect, Paint()..color = Color.fromRGBO(0, 0, 0, (opacity * mode.shaderOpacity).clamp(0.0, 1.0)));
    final paint = Paint()..isAntiAlias = false;
    final inner = Paint()
      ..isAntiAlias = false
      ..blendMode = BlendMode.src;
    for (var cy = 0; cy < gy; cy++) {
      final v = (cy + 0.5) / gy;
      final top = (gy - 1 - cy) * ch;
      for (var cx = 0; cx < gx; cx++) {
        final u = (cx + 0.5) / gx;
        f.effectColor(u, v, aspect, t, gx, gy, _col);
        final colLum = 0.299 * _col[0] + 0.587 * _col[1] + 0.114 * _col[2];
        final hl = f.cellHighlight(u, v, aspect, t);
        final edgeDist = FxField.edgeDistance(u, v, size);
        final vig = f.vignetteAt(edgeDist);
        final h = f.highlight > 0.01 ? hl * f.highlight : 0.0;
        final rgb = [for (final c in _col) ((c * vig) * (1 + h * 2.5) + h * h * 0.3).clamp(0.0, 1.0)];
        final scaleBoost = 1 + _smoothstep(0.2, 0.8, hl) * px.hlScale * 1.2;
        final gapW = px.gap * 0.35 / scaleBoost;
        var ef = 1.0;
        if (px.edgeFade > 0.5 && px.fadeStr > 0.005) ef = 1 + (_smoothstep(0, px.edgeFade, edgeDist) - 1) * px.fadeStr;
        final contrast = _smoothstep(0, 0.33, (colLum - bgLum).abs());
        final cell = Rect.fromLTWH(cx * cw, top, cw, ch);
        final color = Color.from(alpha: 1, red: rgb[0], green: rgb[1], blue: rgb[2]);
        paint.color = color.withValues(alpha: px.fillOpacity * contrast);
        canvas.drawRect(cell, paint);
        inner.color = color.withValues(alpha: (px.fillOpacity + (px.dotOpacity - px.fillOpacity) * ef) * contrast);
        canvas.drawRect(
          gapW > 0.003
              ? Rect.fromLTRB(
                  cell.left + gapW * cw,
                  cell.top + gapW * ch,
                  cell.right - gapW * cw,
                  cell.bottom - gapW * ch,
                )
              : cell,
          inner,
        );
      }
    }
    canvas.restore();
  }

  /// Paint the reveal overlay (the reveal canvas) at [opacity].
  void paintOverlay(Canvas canvas, Size size, FxOverlay? overlay, double opacity) {
    if (overlay == null || opacity <= 0) return;
    final rect = Offset.zero & size;
    final faded = opacity < 1;
    if (faded) canvas.saveLayer(rect, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
    switch (overlay) {
      case FxOverlayImage(:final image):
        _drawCover(canvas, image, size, 1);
      case FxOverlayPixels(:final image, :final gx, :final gy, :final drop, :final mask):
        canvas.saveLayer(rect, Paint());
        _drawCover(canvas, image, size, 1);
        canvas.saveLayer(rect, Paint());
        _drawCells(canvas, image, size, gx, gy, 1);
        _cellAlpha(canvas, size, gx, gy, drop);
        canvas.restore();
        _cellAlpha(canvas, size, gx, gy, mask);
        canvas.restore();
      case FxOverlayBoil(:final from, :final to, :final blendT, :final base, :final baseAlpha):
        if (base != null) _drawCover(canvas, base, size, baseAlpha);
        canvas.saveLayer(rect, Paint());
        if (from != null) _drawCells(canvas, from, size, overlay.gx, overlay.gy, 1);
        if (to != null) _drawCells(canvas, to, size, overlay.gx, overlay.gy, blendT);
        _cellAlpha(canvas, size, overlay.gx, overlay.gy, overlay.drop);
        canvas.restore();
    }
    if (faded) canvas.restore();
  }

  static void _drawCover(Canvas canvas, RevealImage image, Size size, double alpha) {
    canvas.drawImageRect(
      image.image,
      image.cover(size),
      Offset.zero & size,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Color.fromRGBO(0, 0, 0, alpha),
    );
  }

  /// The downsampled image upscaled nearest-neighbour: chunky cells.
  static void _drawCells(Canvas canvas, RevealImage image, Size size, int gx, int gy, double alpha) {
    canvas.drawImageRect(
      image.cells(gx, gy, size),
      Rect.fromLTWH(0, 0, gx.toDouble(), gy.toDouble()),
      Offset.zero & size,
      Paint()
        ..filterQuality = FilterQuality.none
        ..color = Color.fromRGBO(0, 0, 0, alpha),
    );
  }

  /// `destination-in` with a [gx]×[gy] alpha grid upscaled nearest-neighbour.
  void _cellAlpha(Canvas canvas, Size size, int gx, int gy, Uint8List alpha) {
    final key = (gx, gy, size);
    if (_quadKey != key) {
      _quadKey = key;
      _quads = Float32List(gx * gy * 12);
      _quadColors = Int32List(gx * gy * 6);
      final cw = size.width / gx, ch = size.height / gy;
      var k = 0;
      for (var cy = 0; cy < gy; cy++) {
        for (var cx = 0; cx < gx; cx++) {
          final x0 = cx * cw, x1 = (cx + 1) * cw, y0 = cy * ch, y1 = (cy + 1) * ch;
          for (final v in [x0, y0, x1, y0, x1, y1, x0, y0, x1, y1, x0, y1]) {
            _quads[k++] = v;
          }
        }
      }
    }
    for (var i = 0; i < gx * gy; i++) {
      final c = alpha[i] << 24 | 0xFFFFFF;
      for (var j = 0; j < 6; j++) {
        _quadColors[i * 6 + j] = c;
      }
    }
    final vertices = ui.Vertices.raw(ui.VertexMode.triangles, _quads, colors: _quadColors);
    canvas.drawVertices(vertices, BlendMode.dst, Paint()..blendMode = BlendMode.dstIn);
    vertices.dispose();
  }

  void dispose() {
    _disposed = true;
    _fieldImage?.dispose();
    _fieldShader?.dispose();
    _mosaicShader?.dispose();
  }
}
