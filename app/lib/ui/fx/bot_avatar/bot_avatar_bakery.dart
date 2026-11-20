// Portions derived from Libraries.dev Bot avatars (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

/* The material caches: forms per outline × texture size × depth, piles per
   form × resolution × light × style. The author bakes them on idle time and
   shares them across every avatar of a type; here they bake on a background
   isolate (compute) and land through [BotAvatarBakery.instance], a
   ChangeNotifier the widgets listen to. The pile's alpha planes become
   images on the UI isolate, with its hairs stroked over them. */

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'bot_avatar_form.dart';
import 'bot_avatar_fur.dart';

/// A baked pile, as images.
class BotAvatarFur {
  BotAvatarFur._(this.r, this.rb, this._images);

  /// the halo's side (the body square) and the films' side (the wider square)
  final int r;
  final int rb;
  final Map<String, ui.Image> _images;

  ui.Image get dark => _images['dark']!;
  ui.Image get light => _images['light']!;
  ui.Image get glint => _images['glint']!;
  ui.Image get back => _images['back']!;
  ui.Image get backSoft => _images['backSoft']!;
  ui.Image get mask => _images['mask']!;
  ui.Image get haze => _images['haze']!;
  ui.Image get core => _images['core']!;
  ui.Image get soft => _images['soft']!;

  void _dispose() {
    for (final i in _images.values) {
      i.dispose();
    }
  }
}

class _FormJob {
  const _FormJob(this.polys, this.n, this.halfDepth);
  final List<Float64List> polys;
  final int n;
  final double halfDepth;
}

BotAvatarForm _bakeForm(_FormJob j) => buildForm(rasterizeOutline(j.polys, j.n), j.n, j.halfDepth);

int _jsRound(double v) => (v + 0.5).floor();

/// The shared bakes. Listen to it to repaint when a bake lands.
class BotAvatarBakery extends ChangeNotifier {
  BotAvatarBakery._();

  static final instance = BotAvatarBakery._();

  final _forms = <String, BotAvatarForm>{};
  final _formJobs = <String, Future<BotAvatarForm>>{};
  final _furs = <String, BotAvatarFur>{};
  final _furJobs = <String, Future<BotAvatarFur>>{};

  /// Whether any bake is still under way.
  bool get pending => _formJobs.isNotEmpty || _furJobs.isNotEmpty;

  /// The form for an outline. A form takes a few milliseconds, so it is made
  /// here: the first frame already has the body (only the fur waits).
  BotAvatarForm? form(String key, List<Float64List> polys, int n, double halfDepth) {
    final id = '$key|$n|${_jsRound(halfDepth)}';
    final hit = _forms[id];
    if (hit != null) return hit;
    final made = _bakeForm(_FormJob(polys, n, halfDepth));
    if (_forms.length >= 48) _forms.clear();
    return _forms[id] = made;
  }

  /// The form for an outline, when it lands.
  Future<BotAvatarForm> formAsync(String key, List<Float64List> polys, int n, double halfDepth) {
    final id = '$key|$n|${_jsRound(halfDepth)}';
    final hit = _forms[id];
    if (hit != null) return SynchronousFuture(hit);
    return _formJobs[id] ??= compute(_bakeForm, _FormJob(polys, n, halfDepth)).then((f) {
      _formJobs.remove(id);
      if (_forms.length >= 48) _forms.clear();
      _forms[id] = f;
      notifyListeners();
      return f;
    });
  }

  static int _lightBin(double lx, double ly) => _jsRound(math.atan2(ly, lx) / (math.pi / 12));

  /// The pile for a form, or (while it bakes) the same shape's pile at another
  /// tier or light, or null when there is none yet.
  BotAvatarFur? fur(
    BotAvatarForm form,
    String key,
    double halfDepth,
    double capPx,
    double lx,
    double ly,
    FurStyle style,
    FurLights lights,
  ) {
    final r = furTier(capPx);
    final prefix = '$key|${_jsRound(halfDepth)}|';
    final id = '$prefix$r|${_lightBin(lx, ly)}|${style.id}|${lights.id}';
    final hit = _furs[id];
    if (hit != null) return hit;
    /* a large pile takes a while: with nothing of this shape to stand in
       meanwhile, the smallest one is baked first */
    if (r > 192 && !_furJobs.containsKey(id)) {
      final any = _furs.keys.any((k) => k.startsWith(prefix)) || _furJobs.keys.any((k) => k.startsWith(prefix));
      if (!any) fur(form, key, halfDepth, 1, lx, ly, style, lights);
    }
    _furJobs[id] ??= _bakeFur(id, form, r, lx, ly, style, lights);
    for (final e in _furs.entries) {
      if (e.key.startsWith(prefix)) return e.value;
    }
    return null;
  }

  Future<BotAvatarFur> _bakeFur(
    String id,
    BotAvatarForm form,
    int r,
    double lx,
    double ly,
    FurStyle style,
    FurLights lights,
  ) async {
    final bake = await compute(
      bakeFur,
      FurJob(n: form.n, sd: form.sd, h: form.h, r: r, lx: lx, ly: ly, style: style, lights: lights),
    );
    final px = r / span, off = filmM * px;
    Future<ui.Image> plane(Uint8List a, int side, FurLayer? layer, double offset) async {
      final base = await _alphaImage(a, side);
      if (layer == null) return base;
      final strokes = bake.strokes.where((s) => s.layer == layer);
      if (strokes.isEmpty) return base;
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawImage(base, Offset.zero, Paint());
      c.translate(offset, offset);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      for (final s in strokes) {
        paint
          ..strokeWidth = s.width
          ..color = Color.fromRGBO(255, 255, 255, s.alpha)
          ..blendMode = s.erase ? BlendMode.dstOut : BlendMode.srcOver;
        c.drawPath(_strokePath(s.cmds), paint);
      }
      final pic = rec.endRecording();
      final out = await pic.toImage(side, side);
      pic.dispose();
      base.dispose();
      return out;
    }

    final images = {
      'dark': await plane(bake.dark, bake.rb, FurLayer.dark, off),
      'light': await plane(bake.light, bake.rb, FurLayer.light, off),
      'glint': await plane(bake.glint, bake.rb, FurLayer.glint, off),
      'back': await plane(bake.back, bake.rb, FurLayer.back, off),
      'backSoft': await plane(bake.backSoft, bake.rb, null, 0),
      'mask': await plane(bake.mask, bake.r, FurLayer.mask, 0),
      'haze': await plane(bake.haze, bake.r, null, 0),
      'core': await plane(bake.core, bake.r, null, 0),
      'soft': await plane(bake.soft, bake.r, null, 0),
    };
    final fur = BotAvatarFur._(bake.r, bake.rb, images);
    _furJobs.remove(id);
    if (_furs.length >= 24) _furs.remove(_furs.keys.first)?._dispose();
    _furs[id] = fur;
    notifyListeners();
    return fur;
  }
}

Path _strokePath(Float32List c) {
  final p = Path();
  var i = 0;
  while (i < c.length) {
    switch (c[i].toInt()) {
      case 0:
        p.moveTo(c[i + 1], c[i + 2]);
        i += 3;
      case 1:
        p.lineTo(c[i + 1], c[i + 2]);
        i += 3;
      default:
        p.quadraticBezierTo(c[i + 1], c[i + 2], c[i + 3], c[i + 4]);
        i += 5;
    }
  }
  return p;
}

/* an alpha plane as a white image (premultiplied-safe: every channel the alpha) */
Future<ui.Image> _alphaImage(Uint8List a, int side) {
  final px = Uint8List(side * side * 4);
  for (var i = 0; i < side * side; i++) {
    final v = a[i];
    px[4 * i] = v;
    px[4 * i + 1] = v;
    px[4 * i + 2] = v;
    px[4 * i + 3] = v;
  }
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(px, side, side, ui.PixelFormat.rgba8888, done.complete);
  return done.future;
}
