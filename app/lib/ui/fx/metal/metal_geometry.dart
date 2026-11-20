// Portions derived from Libraries.dev Metal (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;
import 'dart:ui';

/// Outline kind: a rounded rect (pill) or a true circle.
enum MetalShapeKind { pill, circle }

/// A point displacement — the liquid bend.
typedef MetalDeform = Offset Function(Offset p);

/// Rounded-rect and perimeter maths shared by the ring, the glow and the bend
/// (`renderer/outline.ts`, `glow/geometry.ts`, `cursor/light.ts`).
abstract final class MetalGeometry {
  static const _arcN = 14;
  static const _edgeStep = 1.5;

  /// The rounded rect sampled clockwise from the end of the top-left corner:
  /// edges every ~1.5 px, 14 points per corner arc (more on big corners), each
  /// displaced by [deform].
  static Path deformedRoundRect(Rect rect, double radius, MetalDeform deform) {
    final x = rect.left, y = rect.top, w = rect.width, h = rect.height;
    final r = math.max(0.0, math.min(radius, math.min(w, h) / 2));
    final arcN = math.max(_arcN, (math.pi / 2 * r / 2.5).ceil());
    final path = Path();
    var first = true;
    void push(double px, double py) {
      final p = deform(Offset(px, py));
      if (first) {
        path.moveTo(p.dx, p.dy);
        first = false;
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }

    void edge(double x0, double y0, double x1, double y1) {
      final k = math.max(1, (math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)) / _edgeStep).ceil());
      for (var i = 0; i < k; i++) {
        final t = i / k;
        push(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t);
      }
    }

    void arc(double cx, double cy, double a0, double a1) {
      for (var i = 0; i <= arcN; i++) {
        final a = a0 + (a1 - a0) * (i / arcN);
        push(cx + r * math.cos(a), cy + r * math.sin(a));
      }
    }

    edge(x + r, y, x + w - r, y);
    arc(x + w - r, y + r, -math.pi / 2, 0);
    edge(x + w, y + r, x + w, y + h - r);
    arc(x + w - r, y + h - r, 0, math.pi / 2);
    edge(x + w - r, y + h, x + r, y + h);
    arc(x + r, y + h - r, math.pi / 2, math.pi);
    edge(x, y + h - r, x, y + r);
    arc(x + r, y + r, math.pi, 1.5 * math.pi);
    return path..close();
  }

  /// The rounded rect [rect] with corner [radius], displaced by [deform] when given.
  static Path roundRect(Rect rect, double radius, MetalDeform? deform) {
    if (deform != null) return deformedRoundRect(rect, radius, deform);
    final r = math.max(0.0, math.min(radius, rect.shortestSide / 2));
    return Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)));
  }

  /// The outline of [size] with corner [radius], minus the same outline inset
  /// by [inset] — the band the ring, its rim and the glow live in.
  static Path band(Size size, double radius, double inset, MetalDeform? deform) {
    final box = Offset.zero & size;
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addPath(roundRect(box, radius, deform), Offset.zero)
      ..addPath(roundRect(box.deflate(inset), math.max(0.0, radius - inset), deform), Offset.zero);
  }

  // ── Perimeter (glow hotspot placement) ───────────────────────────────────

  static double rrPerim(double w, double h, double r) {
    final rr = math.max(0.0, math.min(r, math.min(w, h) / 2));
    return 2 * math.max(0.0, w - 2 * rr) + 2 * math.max(0.0, h - 2 * rr) + 2 * math.pi * rr;
  }

  static double shapePerim(double w, double h, double r, MetalShapeKind kind) {
    if (kind == MetalShapeKind.circle) return 2 * math.pi * math.max(0.0, math.min(r, math.min(w, h) / 2));
    return rrPerim(w, h, r);
  }

  /// The point at arc length [s] along the outline (clockwise from the end of
  /// the top-left corner), [inset] in from it and pushed out by [outward].
  static Offset sampleAtArc(double s, double w, double h, double r, double inset, double outward, MetalShapeKind kind) {
    final rr = math.max(0.0, math.min(r, math.min(w, h) / 2));
    if (kind == MetalShapeKind.circle) {
      final perim = 2 * math.pi * rr;
      if (perim <= 0.0001) return Offset(w / 2, h / 2);
      final sw = ((s % perim) + perim) % perim;
      final theta = -math.pi / 2 + (sw / perim) * math.pi * 2;
      final rad = math.max(0.0, rr - inset + outward);
      return Offset(w / 2 + rad * math.cos(theta), h / 2 + rad * math.sin(theta));
    }
    final topLen = math.max(0.0, w - 2 * rr), sideLen = math.max(0.0, h - 2 * rr);
    final arcLen = math.pi * rr / 2;
    final perim = 2 * (topLen + sideLen) + 4 * arcLen;
    var d = ((s % perim) + perim) % perim;
    final rad = math.max(0.0, rr - inset + outward);
    double at(double d) => arcLen > 0 ? d / arcLen : 0;
    if (d < topLen) return Offset(rr + d, inset - outward);
    d -= topLen;
    if (d < arcLen) {
      final theta = -math.pi / 2 + at(d) * (math.pi / 2);
      return Offset(w - rr + rad * math.cos(theta), rr + rad * math.sin(theta));
    }
    d -= arcLen;
    if (d < sideLen) return Offset(w - inset + outward, rr + d);
    d -= sideLen;
    if (d < arcLen) {
      final theta = at(d) * (math.pi / 2);
      return Offset(w - rr + rad * math.cos(theta), h - rr + rad * math.sin(theta));
    }
    d -= arcLen;
    if (d < topLen) return Offset(w - rr - d, h - inset + outward);
    d -= topLen;
    if (d < arcLen) {
      final theta = math.pi / 2 + at(d) * (math.pi / 2);
      return Offset(rr + rad * math.cos(theta), h - rr + rad * math.sin(theta));
    }
    d -= arcLen;
    if (d < sideLen) return Offset(inset - outward, h - rr - d);
    d -= sideLen;
    final theta = math.pi + at(d) * (math.pi / 2);
    return Offset(rr + rad * math.cos(theta), rr + rad * math.sin(theta));
  }

  static double tangentAngleAtArc(double s, double w, double h, double r, double inset, MetalShapeKind kind) {
    const eps = 0.1;
    final a = sampleAtArc(s - eps, w, h, r, inset, 0, kind);
    final b = sampleAtArc(s + eps, w, h, r, inset, 0, kind);
    return math.atan2(b.dy - a.dy, b.dx - a.dx);
  }

  /// Inverse of [sampleAtArc] at inset 0: the arc position on the outline
  /// nearest a box-local point.
  static double arcAtPoint(Offset p, double w, double h, double r, MetalShapeKind kind) {
    final x = p.dx, y = p.dy;
    final rr = math.max(0.0, math.min(r, math.min(w, h) / 2));
    if (kind == MetalShapeKind.circle) {
      final perim = 2 * math.pi * rr;
      if (perim <= 0.0001) return 0;
      final theta = math.atan2(y - h / 2, x - w / 2);
      final s = (theta + math.pi / 2) / (2 * math.pi) * perim;
      return ((s % perim) + perim) % perim;
    }
    final topLen = math.max(0.0, w - 2 * rr), sideLen = math.max(0.0, h - 2 * rr);
    final arcLen = math.pi * rr / 2;
    const q = math.pi / 2;
    final s1 = topLen, s2 = s1 + arcLen, s3 = s2 + sideLen, s4 = s3 + arcLen;
    final s5 = s4 + topLen, s6 = s5 + arcLen, s7 = s6 + sideLen;
    final inX = x >= rr && x <= w - rr, inY = y >= rr && y <= h - rr;
    if (inX && inY) {
      final dl = x, dr = w - x, dt = y, db = h - y;
      final m = math.min(math.min(dl, dr), math.min(dt, db));
      if (m == dt) return x - rr;
      if (m == dr) return s2 + (y - rr);
      if (m == db) return s4 + (w - rr - x);
      return s6 + (h - rr - y);
    }
    if (inX) return y < h / 2 ? x - rr : s4 + (w - rr - x);
    if (inY) return x > w / 2 ? s2 + (y - rr) : s6 + (h - rr - y);
    if (x > w / 2 && y < h / 2) return s1 + (math.atan2(y - rr, x - (w - rr)) + q) / q * arcLen;
    if (x > w / 2) return s3 + math.atan2(y - (h - rr), x - (w - rr)) / q * arcLen;
    if (y > h / 2) return s5 + (math.atan2(y - (h - rr), x - rr) - q) / q * arcLen;
    return s7 + (math.atan2(y - rr, x - rr) + math.pi) / q * arcLen;
  }

  /// The outline point nearest a box-local point, and its signed distance
  /// (negative inside).
  static (Offset, double) nearestOutlinePoint(Offset p, double w, double h, double r, MetalShapeKind kind) {
    final rr = kind == MetalShapeKind.circle ? math.min(w, h) / 2 : math.max(0.0, math.min(r, math.min(w, h) / 2));
    final cx = w / 2, cy = h / 2;
    final hx = math.max(0.0, w / 2 - rr), hy = math.max(0.0, h / 2 - rr);
    final qx = (p.dx - cx).clamp(-hx, hx), qy = (p.dy - cy).clamp(-hy, hy);
    final dx = p.dx - cx - qx, dy = p.dy - cy - qy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len > 1e-6) return (Offset(cx + qx + dx / len * rr, cy + qy + dy / len * rr), len - rr);
    final dl = p.dx, dr = w - p.dx, dt = p.dy, db = h - p.dy;
    final m = math.min(math.min(dl, dr), math.min(dt, db));
    if (m == dl) return (Offset(0, p.dy), -m);
    if (m == dr) return (Offset(w, p.dy), -m);
    if (m == dt) return (Offset(p.dx, 0), -m);
    return (Offset(p.dx, h), -m);
  }

  /// Where a ray from the centre of [size] in direction [dir] leaves the rounded rect.
  static Offset boundaryPoint(Size size, double radius, Offset dir) {
    final hw = size.width / 2, hh = size.height / 2;
    final r = math.max(0.0, math.min(radius, math.min(hw, hh)));
    final len = dir.distance;
    if (len <= 1e-6) return Offset(hw, hh);
    final nx = dir.dx / len, ny = dir.dy / len;
    final tx = nx.abs() > 1e-6 ? hw / nx.abs() : double.infinity;
    final ty = ny.abs() > 1e-6 ? hh / ny.abs() : double.infinity;
    var t = math.min(tx, ty);
    final px = nx * t, py = ny * t;
    if (px.abs() > hw - r && py.abs() > hh - r && r > 0) {
      // Corner: intersect the ray with that corner's circle.
      final cx = (px < 0 ? -1 : 1) * (hw - r), cy = (py < 0 ? -1 : 1) * (hh - r);
      final b = -2 * (nx * cx + ny * cy);
      final c = cx * cx + cy * cy - r * r;
      final disc = b * b - 4 * c;
      if (disc >= 0) t = (-b + math.sqrt(disc)) / 2;
    }
    return Offset(hw + nx * t, hh + ny * t);
  }
}
