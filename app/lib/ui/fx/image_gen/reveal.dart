// Portions derived from Libraries.dev Image (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'presets.dart';

/// Edge of the square the live field is sampled at for the reveal mask
/// (reveal.ts `MASK_SIZE`).
const fxMaskSize = 64;

/// Fraction trimmed off every edge of a cover-fit image (`COVER_EDGE_INSET_FRAC`).
const _coverEdgeInsetFrac = 0.006;

/// Source rect of a cover-fit draw (`computeCoverSourceRect`): aspect kept,
/// the overflowing axis centre-cropped, a thin border trimmed off.
Rect fxCoverRect(double imageW, double imageH, Size target) {
  final targetAspect = target.width / math.max(1, target.height);
  final imgAspect = imageW / math.max(1, imageH);
  var sx = 0.0, sy = 0.0, sw = imageW, sh = imageH;
  if (imgAspect > targetAspect) {
    sw = imageH * targetAspect;
    sx = (imageW - sw) / 2;
  } else {
    sh = imageW / targetAspect;
    sy = (imageH - sh) / 2;
  }
  final inset = math.min(sw, sh) * _coverEdgeInsetFrac;
  if (sw - 2 * inset > 1 && sh - 2 * inset > 1) {
    sx += inset;
    sy += inset;
    sw -= 2 * inset;
    sh -= 2 * inset;
  }
  return Rect.fromLTWH(sx, sy, sw, sh);
}

/// A decoded picture the reveal draws, and what it derives from it.
class RevealImage {
  RevealImage(this.image);

  final ui.Image image;

  ui.Image? _cells;
  (int, int, Size)? _cellsKey;
  bool _tintStarted = false;
  bool _disposed = false;

  /// The [fxTintGrid]² cover-fit image the regenerate tint is sampled from,
  /// once it has been read back.
  Uint8List? tintPixels;

  Rect cover(Size target) => fxCoverRect(image.width.toDouble(), image.height.toDouble(), target);

  /// The cover-fit image averaged down to the [gx]×[gy] cell grid (the
  /// reveal's `pixCanvas` source), made once per grid.
  ui.Image cells(int gx, int gy, Size target) {
    final key = (gx, gy, target);
    if (_cells case final cells? when _cellsKey == key) return cells;
    _cells?.dispose();
    _cellsKey = key;
    return _cells = _downsample(gx, gy, target);
  }

  ui.Image _downsample(int w, int h, Size target) {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      image,
      cover(target),
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final out = picture.toImageSync(w, h);
    picture.dispose();
    return out;
  }

  /// Reads the image back at [fxTintGrid]² for the regenerate tint (palette.ts
  /// samples the overlay canvas the same way), once.
  void prepareTint(Size target) {
    if (_tintStarted) return;
    _tintStarted = true;
    final small = _downsample(fxTintGrid, fxTintGrid, target);
    small.toByteData().then((data) {
      small.dispose();
      if (!_disposed && data != null) tintPixels = data.buffer.asUint8List();
    });
  }

  void dispose() {
    _disposed = true;
    _cells?.dispose();
    image.dispose();
  }
}

/// reveal.ts `RevealInternals.phase`.
enum RevealPhase { idle, reveal, hold, hide, boil }

/// What the overlay shows this frame.
sealed class FxOverlay {
  const FxOverlay();

  /// Painting it draws [img].
  bool uses(RevealImage img);
}

/// The whole picture (hold, the reveal's last frame).
class FxOverlayImage extends FxOverlay {
  const FxOverlayImage(this.image);

  final RevealImage image;

  @override
  bool uses(RevealImage img) => identical(image, img);
}

/// `paintPixelMasked`: the smooth picture, its chunky cells on top with
/// [drop] alpha each, all cut by the cell-stepped reveal [mask]. Both are
/// [gx]×[gy] alphas, row 0 at the top.
class FxOverlayPixels extends FxOverlay {
  const FxOverlayPixels(this.image, this.gx, this.gy, this.drop, this.mask);

  final RevealImage image;
  final int gx, gy;
  final Uint8List drop, mask;

  @override
  bool uses(RevealImage img) => identical(image, img);
}

/// `paintBoilFrame`: chunky cells of [from] cross-fading to [to] by [blendT],
/// [drop] alpha each, over an optional smooth [base] at [baseAlpha].
class FxOverlayBoil extends FxOverlay {
  const FxOverlayBoil({
    required this.from,
    required this.to,
    required this.blendT,
    required this.base,
    required this.baseAlpha,
    required this.gx,
    required this.gy,
    required this.drop,
  });

  final RevealImage? from, to, base;
  final double blendT, baseAlpha;
  final int gx, gy;
  final Uint8List drop;

  @override
  bool uses(RevealImage img) => identical(from, img) || identical(to, img) || identical(base, img);
}

/// The renderer.ts `Instance` fields one reveal frame reads.
class FxFrame {
  const FxFrame({
    required this.mode,
    required this.look,
    required this.size,
    required this.pixelScale,
    required this.time,
    required this.sample,
  });

  final FxPresetMode mode;
  final FxLook look;

  /// Card size, CSS (logical) px.
  final Size size;
  final double pixelScale;

  /// The instance clock (`accumulatedTime`), seconds.
  final double time;

  /// The raw field, [fxMaskSize]² RGBA with row 0 at the top. [fresh] asks for
  /// a new sample; on the GPU that starts a read-back and returns the latest
  /// finished one, which may still be null on the very first frame.
  final Uint8List? Function(bool fresh) sample;
}

/// reveal.ts `hash` of the flicker clock.
double _hash(int i, int s) {
  final x = math.sin(i * 127.1 + s * 17.23) * 43758.5453;
  return x - x.floorToDouble();
}

double _smooth(double t) => t * t * (3 - 2 * t);

int _byte(double a) => (a * 255 + 0.5).floor();

/// Boil ("regenerating") tuning, reveal.ts.
const _boilPixInMs = 800.0;
const _boilPixOverlapMs = 300.0;
const _boilRampS = 1.0;
const _boilLevel = 0.5;
const _boilBand = 0.03;
const _boilFieldW = 0.6;
const _boilBlendMs = 800.0;
const _boilBaseMs = 400.0;
const _boilSharpenMs = 1200.0;

/// The per-card reveal pipeline (reveal.ts `createReveal`): reveal → hold →
/// hide, and the regenerate churn (boil) with its handoff to the next image.
/// It owns the [RevealImage]s handed to it and disposes them when done.
class FxReveal {
  FxReveal({required this.now, required this.random});

  /// The engine clock, ms (`performance.now()`).
  final double Function() now;
  final math.Random random;

  RevealPhase phase = RevealPhase.idle;
  bool _active = false;
  double _revealStartMs = 0;
  double _hideStartMs = 0;
  double _hideDurationMs = 300;
  double _boilStartMs = 0;
  double? _boilHandoffStartMs;
  Float64List? _boilPattern;
  Float64List? _boilField;
  RevealImage? _pending;

  /// Pictures let go while the overlay may still draw them (a hide keeps the
  /// last one); disposed once it no longer does.
  final _retired = <RevealImage>[];
  VoidCallback? _onRevealComplete;

  /// The image being revealed, held or churned.
  RevealImage? image;

  Uint8List? _sampleCache;
  int _sampleFrameCounter = 0;
  final _mask = Uint8List(fxMaskSize * fxMaskSize);
  Float64List? _gsTable;
  Float64List? _dropPattern;
  double _dropRevealStart = -1;
  Uint8List _drop = Uint8List(0);
  Uint8List _maskCells = Uint8List(0);

  /// Opacity of the mosaic under the overlay (the shader canvas's CSS opacity).
  double shaderOpacity = 1;

  /// Opacity of the overlay (the reveal canvas's CSS opacity).
  double overlayOpacity = 1;

  /// What the overlay shows; kept as is while it fades out.
  FxOverlay? overlay;

  bool get isActive => _active;

  /// `afterShaderFrame`: advance one frame.
  void frame(FxFrame f, double nowMs) {
    final shown = overlay;
    _retired.removeWhere((img) {
      if (shown != null && shown.uses(img)) return false;
      img.dispose();
      return true;
    });
    if (!_active) return;
    switch (phase) {
      case RevealPhase.reveal:
        final elapsed = (nowMs - _revealStartMs) / 1000;
        final t = math.min(elapsed / math.max(0.05, f.mode.reveal.duration), 1.0);
        shaderOpacity = 1 - easeOutCubic(t);
        _paintMaskedFrame(f, nowMs);
        if (t >= 1) {
          phase = RevealPhase.hold;
          shaderOpacity = 0;
          _onRevealComplete?.call();
        }
      case RevealPhase.hold:
        overlay = FxOverlayImage(image!);
        shaderOpacity = 0;
      case RevealPhase.boil:
        _paintBoilFrame(f, nowMs);
      case RevealPhase.hide:
        final t = math.min((nowMs - _hideStartMs) / math.max(1, _hideDurationMs), 1.0);
        overlayOpacity = 1 - t;
        shaderOpacity = t;
        if (t >= 1) {
          _active = false;
          phase = RevealPhase.idle;
          overlayOpacity = 1;
          shaderOpacity = 1;
          _release();
        }
      case RevealPhase.idle:
        break;
    }
  }

  void _paintMaskedFrame(FxFrame f, double nowMs) {
    final img = image!;
    final preset = f.mode;
    final elapsed = (nowMs - _revealStartMs) / 1000;
    final progress = math.min(elapsed / math.max(0.05, preset.reveal.duration), 1.0);
    final eased = easeOutCubic(progress);
    if (progress >= 1) {
      overlay = FxOverlayImage(img);
      return;
    }

    final maskShape = preset.reveal.mask;
    final softBand = preset.reveal.softness;
    Uint8List? sampleData;
    var tr = 0.0, tg = 0.0, tb = 0.0;
    if (!maskShape.isSweep) {
      // Re-sample every 2nd frame; the field drifts slowly enough.
      final counter = _sampleFrameCounter++;
      sampleData = _sampleCache = f.sample(_sampleCache == null || counter.isEven);
      final target = f.look.colors[maskShape.slot];
      tr = target.r;
      tg = target.g;
      tb = target.b;
    }

    final threshold = 1 - eased * (1 + softBand);
    // Per-cell flicker on the mask's transition edge, from the preset's flicker.
    final gsAmp = preset.flicker;
    final cellSize = effectiveCellSize(preset.pixel.cellSize, f.pixelScale);
    var gsGrid = 2, gsStep = 0, gsStep1 = 0;
    var gsFz = 0.0;
    Float64List? gsTable;
    if (gsAmp > 0.003) {
      gsGrid = math.max(2, (6 + cellSize * 74).floor());
      // Clamped to Sweep Gradient's cadence so slow presets still re-roll.
      final gsT = f.time * math.max(preset.speed, 2) * 1.6;
      final rawStep = gsT.floor();
      gsStep = rawStep % 1024;
      gsStep1 = (gsStep + 1) % 1024;
      gsFz = _smooth(gsT - rawStep);
      final cellCount = gsGrid * gsGrid;
      final table = gsTable = _gsTable?.length == cellCount ? _gsTable! : (_gsTable = Float64List(cellCount));
      for (var i = 0; i < cellCount; i++) {
        final rnd = _hash(i, gsStep) * (1 - gsFz) + _hash(i, gsStep1) * gsFz;
        table[i] = (rnd - 0.5) * gsAmp * 1.6;
      }
    }
    var gsW = 0.0, gsPos = 0.0;
    if (maskShape.isSweep) {
      gsW = 0.9 / math.max(preset.scale, 0.25);
      gsPos = -gsW + eased * (1 + 2 * gsW);
    }

    const n = fxMaskSize;
    for (var r = 0; r < n; r++) {
      final ny = r / (n - 1);
      for (var c = 0; c < n; c++) {
        final nx = c / (n - 1);
        double a;
        if (maskShape.isSweep) {
          a = (gsPos + gsW - (nx + ny) * 0.5) / (2 * gsW);
        } else {
          var val = 0.0;
          if (sampleData != null) {
            final i = (r * n + c) * 4;
            final dr = sampleData[i] / 255 - tr, dg = sampleData[i + 1] / 255 - tg, db = sampleData[i + 2] / 255 - tb;
            val = math.exp(-8 * (dr * dr + dg * dg + db * db));
          }
          a = (val - threshold) / softBand;
        }
        if (gsTable != null && a > -0.5 && a < 1.5) {
          // Edge-localised jitter: strongest mid-transition, none once settled.
          final at = a.clamp(0.0, 1.0);
          final edge = at * (1 - at) * 4;
          if (edge > 0.001) {
            final ci = (ny * gsGrid).floor() * gsGrid + (nx * gsGrid).floor();
            // The last row and column index one past the table; in JS that
            // reads `undefined` and the pixel comes out transparent.
            if (ci >= gsTable.length) {
              _mask[r * n + c] = 0;
              continue;
            }
            a += gsTable[ci] * edge;
          }
        }
        _mask[r * n + c] = _byte(_smooth(a.clamp(0.0, 1.0)));
      }
    }

    // Every bundled preset is a pixel preset (dotMode 1): paintPixelMasked.
    // The sweep's band already flickers; its dissolve doesn't.
    _paintPixelMasked(f, img, cellSize, elapsed, maskShape.isSweep ? 0 : gsAmp, gsStep, gsStep1, gsFz);
  }

  void _paintPixelMasked(
    FxFrame f,
    RevealImage img,
    double cellSize,
    double elapsed,
    double flickerAmp,
    int flickerStep,
    int flickerStep1,
    double flickerFz,
  ) {
    final (gx, gy) = fxGrid(cellSize, f.size);
    final cellCount = gx * gy;
    final fadeT = easeOutCubic((elapsed / math.max(0.05, f.mode.reveal.pixDuration)).clamp(0.0, 1.0));

    const softBand = 0.07;
    const invBand2 = 1 / (2 * softBand);
    if (_dropPattern?.length != cellCount || _dropRevealStart != _revealStartMs) {
      final pattern = _dropPattern = Float64List(cellCount);
      for (var i = 0; i < cellCount; i++) {
        pattern[i] = softBand + random.nextDouble() * (1 - 2 * softBand);
      }
      _dropRevealStart = _revealStartMs;
    }
    final pattern = _dropPattern!;
    if (_drop.length != cellCount) _drop = Uint8List(cellCount);
    final useFlicker = flickerAmp > 0.003;
    for (var i = 0; i < cellCount; i++) {
      final dt = pattern[i];
      var a = (0.5 + (dt - fadeT) * invBand2).clamp(0.0, 1.0);
      if (useFlicker) {
        // Cells near the dissolve position pop in and out.
        final prox = 1 - (fadeT - dt).abs() * 6.25;
        if (prox > 0) {
          final rnd = _hash(i, flickerStep) * (1 - flickerFz) + _hash(i, flickerStep1) * flickerFz;
          a = (a + (rnd - 0.5) * flickerAmp * 1.6 * prox).clamp(0.0, 1.0);
        }
      }
      _drop[i] = _byte(a);
    }

    // Step 5: the mask quantised to the same grid, so the reveal edge is
    // cell-stepped like the shader mosaic.
    if (_maskCells.length != cellCount) _maskCells = Uint8List(cellCount);
    fxAreaDownsample(_mask, fxMaskSize, _maskCells, gx, gy);
    overlay = FxOverlayPixels(img, gx, gy, _drop, _maskCells);
  }

  void _paintBoilFrame(FxFrame f, double nowMs) {
    final img = image!;
    final preset = f.mode;
    final cellSize = effectiveCellSize(preset.pixel.cellSize, f.pixelScale);
    final (gx, gy) = fxGrid(cellSize, f.size);
    final cellCount = gx * gy;

    // Handoff timeline (only ticks once a reveal is pending).
    final pending = _pending;
    final handoffStart = _boilHandoffStartMs;
    final hand = pending != null && handoffStart != null ? nowMs - handoffStart : -1.0;
    final blendT = hand < 0 ? 0.0 : _smooth(math.min(1, hand / _boilBlendMs));
    final rt = hand < 0 ? -1.0 : hand - _boilBlendMs;
    final baseT = rt <= 0 ? 0.0 : _smooth(math.min(1, rt / _boilBaseMs));
    final sharpRaw = rt <= 0 ? 0.0 : math.min(1.0, rt / _boilSharpenMs);
    final resolving = pending != null && rt > 0;

    // PIXELATE-IN, then the churn ramp overlapping its tail.
    final sinceStart = nowMs - _boilStartMs;
    final inRaw = math.min(1.0, sinceStart / _boilPixInMs);
    final inT = _smooth(inRaw);
    final pixelatingIn = inRaw < 1;
    final afterPixIn = math.max(0.0, sinceStart - (_boilPixInMs - _boilPixOverlapMs));
    final pixInBaseAlpha = 1 - _smooth(math.min(1.0, afterPixIn / _boilPixOverlapMs));
    final ramp = _smooth(math.min(1.0, afterPixIn / (_boilRampS * 1000)));
    final boilT = ramp * _boilLevel;
    shaderOpacity = ramp;

    // Persistent per-cell thresholds, seeded once per boil.
    if (_boilPattern?.length != cellCount) {
      final p = _boilPattern = Float64List(cellCount);
      for (var i = 0; i < cellCount; i++) {
        p[i] = random.nextDouble();
      }
    }
    final pattern = _boilPattern!;

    // Same flicker clock as the reveal mask, with an amplitude floor.
    final amp = math.max(preset.flicker, 0.5);
    final gsT = f.time * math.max(preset.speed, 2) * 1.6;
    final rawStep = gsT.floor();
    final step = rawStep % 1024;
    final step1 = (step + 1) % 1024;
    final fz = _smooth(gsT - rawStep);

    // The live field, re-sampled every 3rd frame, normalised to 0..1 per cell.
    final counter = _sampleFrameCounter++;
    final shouldSample = _sampleCache == null || counter % 3 == 0;
    final fieldStale = _boilField?.length != cellCount;
    final sampleData = _sampleCache = f.sample(shouldSample);
    if (shouldSample || fieldStale) {
      final field = _boilField = fieldStale ? Float64List(cellCount) : _boilField!;
      if (sampleData == null) {
        field.fillRange(0, cellCount, 0.5);
      } else {
        _normalisedField(sampleData, field, gx, gy);
      }
    }
    final field = _boilField!;

    const invBand2 = 1 / (2 * _boilBand);
    final churn = amp * 0.6 * (1 - sharpRaw);
    const patW = 1 - _boilFieldW;
    final fadeT = resolving ? easeOutCubic(sharpRaw) : 0.0;
    const invBandS = 1 / (2 * 0.07);
    final sAmp = preset.flicker;
    if (_drop.length != cellCount) _drop = Uint8List(cellCount);
    for (var i = 0; i < cellCount; i++) {
      final rnd = _hash(i, step) * (1 - fz) + _hash(i, step1) * fz;
      // Threshold = animated field (waves) + stable random grain + flicker pop.
      final dtEff = field[i] * _boilFieldW + pattern[i] * patW + (rnd - 0.5) * churn;
      var a = (0.5 + (dtEff - boilT) * invBand2).clamp(0.0, 1.0);
      final dt = pattern[i];
      if (pixelatingIn) {
        var aIn = (0.5 + (inT - dt) * invBandS).clamp(0.0, 1.0);
        final prox = 1 - (inT - dt).abs() * 6.25;
        if (prox > 0) aIn = (aIn + (rnd - 0.5) * amp * 1.6 * prox).clamp(0.0, 1.0);
        a = math.min(a, aIn);
      }
      if (resolving) {
        var a2 = (0.5 + (dt - fadeT) * invBandS).clamp(0.0, 1.0);
        if (sAmp > 0.003) {
          final prox = 1 - (fadeT - dt).abs() * 6.25;
          if (prox > 0) a2 = (a2 + (rnd - 0.5) * sAmp * 1.6 * prox).clamp(0.0, 1.0);
        }
        a = math.min(a, a2);
      }
      _drop[i] = _byte(a);
    }

    overlay = FxOverlayBoil(
      from: blendT < 1 ? img : null,
      to: pending != null && blendT > 0 ? pending : null,
      blendT: blendT,
      base: pixelatingIn && pixInBaseAlpha > 0 ? img : (resolving && baseT > 0 ? pending : null),
      baseAlpha: pixelatingIn ? pixInBaseAlpha : baseT,
      gx: gx,
      gy: gy,
      drop: _drop,
    );

    // Handoff complete: settle into hold like a finished reveal.
    if (resolving && sharpRaw >= 1 && baseT >= 1) {
      img.dispose();
      image = pending;
      _pending = null;
      _boilHandoffStartMs = null;
      phase = RevealPhase.hold;
      shaderOpacity = 0;
      _onRevealComplete?.call();
    }
  }

  /// Per-cell luminance of the sample at each cell centre, spread over 0..1
  /// across the frame's min / max.
  static void _normalisedField(Uint8List sample, Float64List field, int gx, int gy) {
    const n = fxMaskSize;
    var fMin = 1.0, fMax = 0.0;
    for (var cy = 0; cy < gy; cy++) {
      final my = math.min(n - 1, ((cy + 0.5) * n / gy).floor());
      for (var cx = 0; cx < gx; cx++) {
        final mx = math.min(n - 1, ((cx + 0.5) * n / gx).floor());
        final si = (my * n + mx) * 4;
        final lum = (sample[si] * 0.299 + sample[si + 1] * 0.587 + sample[si + 2] * 0.114) / 255;
        field[cy * gx + cx] = lum;
        if (lum < fMin) fMin = lum;
        if (lum > fMax) fMax = lum;
      }
    }
    final span = fMax - fMin > 0.001 ? 1 / (fMax - fMin) : 0.0;
    for (var i = 0; i < gx * gy; i++) {
      field[i] = span > 0 ? (field[i] - fMin) * span : 0.5;
    }
  }

  /// Begin a reveal of [img]. During a boil the image is handed to the churn
  /// instead (BLEND → RESOLVE), which settles into hold by itself.
  void startReveal(RevealImage img, VoidCallback onRevealComplete) {
    if (phase == RevealPhase.boil && _active) {
      if (!identical(_pending, img)) dropPending();
      _pending = img;
      _onRevealComplete = onRevealComplete;
      _boilHandoffStartMs ??= now();
      return;
    }
    if (!identical(image, img)) {
      image?.dispose();
      overlay = null;
    }
    _pending?.dispose();
    _pending = null;
    image = img;
    _onRevealComplete = onRevealComplete;
    _revealStartMs = now();
    phase = RevealPhase.reveal;
    _active = true;
    _boilHandoffStartMs = null;
    // The first frame of a reveal always samples fresh.
    _sampleFrameCounter = 0;
    _sampleCache = null;
    overlayOpacity = 1;
  }

  /// Fade the overlay back to the mosaic.
  void startHide([double durationMs = 300]) {
    if (!_active || phase == RevealPhase.hide) return;
    phase = RevealPhase.hide;
    _hideStartMs = now();
    _hideDurationMs = durationMs;
  }

  /// Break the revealed image into the churning cell grid until the next
  /// [startReveal] (or [startHide]). No-op unless an image is revealed or held.
  void startBoil() {
    if (!_active || image == null) return;
    if (phase != RevealPhase.hold && phase != RevealPhase.reveal) return;
    phase = RevealPhase.boil;
    _boilStartMs = now();
    _boilHandoffStartMs = null;
    _pending?.dispose();
    _pending = null;
    // A fresh cell pattern and a fresh field sample for every regeneration.
    _boilPattern = null;
    _sampleFrameCounter = 0;
    _sampleCache = null;
    overlayOpacity = 1;
  }

  /// Drop the picture handed to the churn; the churn keeps going. It is
  /// disposed once no overlay draws it.
  void dropPending() {
    if (_pending case final pending?) _retired.add(pending);
    _pending = null;
    _boilHandoffStartMs = null;
    _onRevealComplete = null;
  }

  /// Back to idle at once.
  void clear() {
    final wasActive = _active;
    _active = false;
    phase = RevealPhase.idle;
    _release();
    if (wasActive) {
      overlayOpacity = 1;
      shaderOpacity = 1;
    }
  }

  void _release() {
    image?.dispose();
    image = null;
    _pending?.dispose();
    _pending = null;
    for (final img in _retired) {
      img.dispose();
    }
    _retired.clear();
    _boilHandoffStartMs = null;
    overlay = null;
  }

  void dispose() => _release();
}

/// Area-weighted downsample of an [n]² alpha buffer to [gx]×[gy] (the
/// browser's high-quality `drawImage` downscale of the mask).
void fxAreaDownsample(Uint8List src, int n, Uint8List dst, int gx, int gy) {
  final sx = n / gx, sy = n / gy;
  for (var cy = 0; cy < gy; cy++) {
    final y0 = cy * sy, y1 = y0 + sy;
    for (var cx = 0; cx < gx; cx++) {
      final x0 = cx * sx, x1 = x0 + sx;
      var sum = 0.0;
      for (var y = y0.floor(); y < y1 && y < n; y++) {
        final wy = math.min(y + 1.0, y1) - math.max(y.toDouble(), y0);
        for (var x = x0.floor(); x < x1 && x < n; x++) {
          final wx = math.min(x + 1.0, x1) - math.max(x.toDouble(), x0);
          sum += src[y * n + x] * wx * wy;
        }
      }
      dst[cy * gx + cx] = (sum / (sx * sy) + 0.5).floor().clamp(0, 255);
    }
  }
}
