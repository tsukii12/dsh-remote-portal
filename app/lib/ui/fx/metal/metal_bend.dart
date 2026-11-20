// Portions derived from Libraries.dev Metal (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;
import 'dart:ui';

import 'metal_geometry.dart';

/// The liquid bend's constants (the web's `useMetalBend` defaults, as in the
/// author's SwiftUI port; tuned for a 40-px button).
abstract final class MetalBendConfig {
  /// Global multiplier on the whole dent.
  static const strength = 0.74;

  /// σ of the directional dent, px.
  static const blob = 13.0;

  /// σ of the liquid push, px.
  static const liquidBlob = 10.0;

  /// Displacement cap, px.
  static const maxDisp = 9.0;

  /// Radial stretch under the contact, px.
  static const liquid = 7.5;
  static const stiffness = 260.0;
  static const damping = 13.0;
  static const mass = 1.0;
  static const liquidStiffness = 53.0;
  static const liquidDamping = 9.0;

  /// Contact-point lag behind the pointer, per 60 Hz frame (0..1).
  static const follow = 0.32;

  /// Low-pass on the targets, ms.
  static const smoothMs = 140.0;
  static const fadeInMs = 200.0;
  static const fadeOutMs = 350.0;

  /// How far beyond the edge the pointer is still felt, px.
  static const reach = 36.0;

  /// Displacement per 100 px/s of pointer speed — a transient kick.
  static const gain = 0.6;

  /// Dent per px the pointer sits inside the edge.
  static const pressGain = 0.55;

  /// Bulge per px the pointer sits outside the edge (within [reach]).
  static const pullGain = 0.49;

  /// Extra dent toward the centre while pressed, px.
  static const press = 5.0;

  /// Distance from the edge over which the liquid pressure fades, px.
  static const liquidReach = 8.0;
}

/// The evaluated bend for one frame: two gaussian blobs on the contact point —
/// a directional displacement and a divergent "liquid" push that thins the
/// band under the contact and thickens it either side.
class MetalBendField {
  const MetalBendField._(this._cx, this._cy, this._dirX, this._dirY, this._radK, this._s2b, this._s2l);

  final double _cx, _cy, _dirX, _dirY, _radK, _s2b, _s2l;

  Offset deform(Offset p) {
    final dx = p.dx - _cx, dy = p.dy - _cy;
    final q = dx * dx + dy * dy;
    final gb = math.exp(-q / _s2b);
    final gl = math.exp(-q / _s2l);
    return Offset(p.dx + _dirX * gb + dx * _radK * gl, p.dy + _dirY * gb + dy * _radK * gl);
  }
}

/// Per-instance bend simulation: the web's pointer bend (`useMetalBend` step,
/// line for line from the SwiftUI port's `stepPointer`) with a finger as the
/// pointer, pressed while it is down.
class MetalBendModel {
  double _cx = 0, _cy = 0;
  double _ax = 0, _ay = 0, _vax = 0, _vay = 0;
  double _la = 0, _vla = 0;
  double _stx = 0, _sty = 0, _stl = 0;
  double _env = 0;
  bool _active = false;
  double _lastS = 0;
  double _svx = 0, _svy = 0;
  Offset? _lastPointer;

  /// The field for the last step, or null while the ring is at rest.
  MetalBendField? field;

  /// True while the simulation still moves (a finger down or springs settling).
  bool get busy => _active || field != null;

  /// Advance to [nowS] seconds. [pointer] is box-local (null = lifted).
  MetalBendField? step(
    double nowS,
    Offset? pointer, {
    required bool pressed,
    required Size size,
    required double radius,
  }) {
    final dt = _lastS > 0 ? (nowS - _lastS).clamp(0.001, 0.032) : 1 / 60;
    _lastS = nowS;
    final w = size.width, h = size.height;
    final ecx = w / 2, ecy = h / 2;

    // Pointer velocity: ~40 ms time constant, then the web's decay.
    final lp = _lastPointer;
    if (pointer != null && lp != null) {
      final a = 1 - math.exp(-dt / 0.04);
      _svx += ((pointer.dx - lp.dx) / dt - _svx) * a;
      _svy += ((pointer.dy - lp.dy) / dt - _svy) * a;
    }
    _lastPointer = pointer;

    var tx = 0.0, ty = 0.0, pressure = 0.0;
    if (pointer != null) {
      final lx = pointer.dx, ly = pointer.dy;
      final ddx = lx - ecx, ddy = ly - ecy;
      final d = math.sqrt(ddx * ddx + ddy * ddy);
      // The edge's distance from the centre toward the pointer.
      final b = MetalGeometry.boundaryPoint(size, radius, Offset(ddx, ddy));
      final edgeR = d > 0.001 ? (b - Offset(ecx, ecy)).distance : math.min(w, h) / 2;
      final reach = math.max(w, h) / 2 + MetalBendConfig.reach;
      final wasActive = _active;
      _active = d < reach;
      final u = math.max(0.0, 1 - (d - edgeR).abs() / MetalBendConfig.liquidReach);
      pressure = u * u * (3 - 2 * u);
      if (_active) {
        if (!wasActive) {
          _cx = lx;
          _cy = ly;
        }
        final fa = 1 - math.pow(1 - MetalBendConfig.follow, dt * 60);
        _cx += (lx - _cx) * fa;
        _cy += (ly - _cy) * fa;
        final edgeFade = 1 - math.max(0.0, (d - (reach - MetalBendConfig.reach)) / MetalBendConfig.reach);
        tx = _svx * (MetalBendConfig.gain / 100) * edgeFade;
        ty = _svy * (MetalBendConfig.gain / 100) * edgeFade;
        final ux = d > 0.001 ? ddx / d : 0.0, uy = d > 0.001 ? ddy / d : 0.0;
        final pen = edgeR - d;
        if (pen > 0) {
          final m = pen * MetalBendConfig.pressGain;
          tx -= ux * m;
          ty -= uy * m;
        } else {
          final out = -pen;
          final f = math.max(0.0, 1 - out / MetalBendConfig.reach);
          final m = out * MetalBendConfig.pullGain * (f * f * (3 - 2 * f));
          tx += ux * m;
          ty += uy * m;
        }
        final tm = math.sqrt(tx * tx + ty * ty);
        if (tm > MetalBendConfig.maxDisp) {
          tx *= MetalBendConfig.maxDisp / tm;
          ty *= MetalBendConfig.maxDisp / tm;
        }
      }
    } else {
      _active = false;
    }
    _svx *= math.exp(-dt * 12);
    _svy *= math.exp(-dt * 12);

    final sa = 1 - math.exp(-(dt * 1000) / MetalBendConfig.smoothMs);
    _stx += (tx - _stx) * sa;
    _sty += (ty - _sty) * sa;

    const mass = MetalBendConfig.mass;
    _vax += (-MetalBendConfig.stiffness * (_ax - _stx) - MetalBendConfig.damping * _vax) / mass * dt;
    _vay += (-MetalBendConfig.stiffness * (_ay - _sty) - MetalBendConfig.damping * _vay) / mass * dt;
    _ax += _vax * dt;
    _ay += _vay * dt;

    final pressAmt = pressed && _active ? MetalBendConfig.press : 0.0;
    final tl = _active ? MetalBendConfig.liquid * (pressure + (pressed ? 0.5 : 0)) : 0.0;
    _stl += (tl - _stl) * sa;
    _vla += (-MetalBendConfig.liquidStiffness * (_la - _stl) - MetalBendConfig.liquidDamping * _vla) / mass * dt;
    _la += _vla * dt;

    final envTarget = _active ? 1.0 : 0.0;
    final tauMs = (envTarget > 0 ? MetalBendConfig.fadeInMs : MetalBendConfig.fadeOutMs) / 3;
    _env += (envTarget - _env) * (1 - math.exp(-(dt * 1000) / tauMs));
    if (_env < 0.002 && envTarget == 0) _env = 0;

    final amp = math.sqrt(_ax * _ax + _ay * _ay);
    final speed = math.sqrt(_vax * _vax + _vay * _vay);
    if (!_active && _env == 0 && amp < 0.05 && speed < 1 && _la.abs() < 0.05 && pressAmt == 0) {
      _ax = _ay = _vax = _vay = _la = _vla = _stx = _sty = _stl = 0;
      return field = null;
    }

    final k = MetalBendConfig.strength * _env;
    var pdx = ecx - _cx, pdy = ecy - _cy;
    final pl = math.sqrt(pdx * pdx + pdy * pdy);
    final pn = pl > 0 ? pl : 1.0;
    pdx /= pn;
    pdy /= pn;
    const sb = MetalBendConfig.blob, sl = MetalBendConfig.liquidBlob;
    return field = MetalBendField._(
      _cx,
      _cy,
      (_ax + pdx * pressAmt) * k,
      (_ay + pdy * pressAmt) * k,
      _la / sl * k,
      2 * sb * sb,
      2 * sl * sl,
    );
  }
}
