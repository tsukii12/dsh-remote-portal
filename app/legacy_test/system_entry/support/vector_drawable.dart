// Reads the launcher-shortcut and tile icons straight from the Android
// resources (android/app/src/main/res), so the geometry test and the preview
// golden check the files that ship, not a copy. Only what those files use:
// one group (translate + scale), `M L H V C Z` absolute path commands and
// `@color/…` fills from values[-night]/entry_colors.xml.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

const resDir = 'android/app/src/main/res';

String readRes(String relative) => File('$resDir/$relative').readAsStringSync();

/// One `<vector>` with a single path, optionally under one transform group.
class VectorGlyph {
  VectorGlyph({
    required this.viewport,
    required this.translate,
    required this.scale,
    required this.pathData,
    required this.fill,
  });

  /// `drawable/<name>.xml`.
  factory VectorGlyph.load(String name) {
    final xml = readRes('drawable/$name.xml');
    double attr(String name, {double or = 0}) {
      final m = RegExp('android:$name="([-0-9.]+)"').firstMatch(xml);
      return m == null ? or : double.parse(m.group(1)!);
    }

    final path = RegExp(r'android:pathData="([^"]+)"').firstMatch(xml)!.group(1)!;
    final fill = RegExp(r'android:fillColor="([^"]+)"').firstMatch(xml)!.group(1)!;
    return VectorGlyph(
      viewport: Size(attr('viewportWidth'), attr('viewportHeight')),
      translate: Offset(attr('translateX'), attr('translateY')),
      scale: attr('scaleX', or: 1),
      pathData: path,
      fill: fill,
    );
  }

  final Size viewport;
  final Offset translate;
  final double scale;
  final String pathData;

  /// `#AARRGGBB` or `@color/name`.
  final String fill;

  /// Every point of the outline (end and control points) in viewport units.
  List<Offset> get points => [for (final p in parseSvgPoints(pathData)) p * scale + translate];

  /// The outline's box in viewport units (control points included: a
  /// slight over-estimate, never an under-estimate).
  Rect get bounds {
    final ps = points;
    var r = Rect.fromPoints(ps.first, ps.first);
    for (final p in ps) {
      r = r.expandToInclude(Rect.fromPoints(p, p));
    }
    return r;
  }

  /// The 24-unit Material box after the group transform.
  Rect get iconBox => translate & Size(24 * scale, 24 * scale);

  Path toPath() {
    final path = parseSvgPath(pathData);
    return path.transform((Matrix4Ish.scaleThenTranslate(scale, translate)).storage);
  }

  Color fillColor({required bool dark}) => resolveColor(fill, dark: dark);
}

/// `@color/name` from values[-night]/entry_colors.xml, or a literal.
Color resolveColor(String value, {required bool dark}) {
  if (value.startsWith('#')) return _hex(value);
  final name = value.replaceFirst('@color/', '');
  String? find(String file) {
    final f = File('$resDir/$file');
    if (!f.existsSync()) return null;
    return RegExp('<color name="$name">(#[0-9A-Fa-f]+)</color>').firstMatch(f.readAsStringSync())?.group(1);
  }

  final hex = (dark ? find('values-night/entry_colors.xml') : null) ?? find('values/entry_colors.xml')!;
  return _hex(hex);
}

Color _hex(String hex) {
  var h = hex.substring(1);
  if (h.length == 6) h = 'FF$h';
  return Color(int.parse(h, radix: 16));
}

final _token = RegExp(r'[MLHVCZmlhvcz]|-?[0-9]*\.?[0-9]+(?:e-?[0-9]+)?');

Iterable<(String, List<double>)> _commands(String d) sync* {
  String? cmd;
  var args = <double>[];
  for (final m in _token.allMatches(d)) {
    final t = m.group(0)!;
    if (RegExp(r'^[A-Za-z]$').hasMatch(t)) {
      if (cmd != null) yield (cmd, args);
      cmd = t;
      args = [];
    } else {
      args.add(double.parse(t));
    }
  }
  if (cmd != null) yield (cmd, args);
}

/// The outline's points: absolute commands only (what the resources use).
List<Offset> parseSvgPoints(String d) {
  final out = <Offset>[];
  var cur = Offset.zero;
  for (final (cmd, a) in _commands(d)) {
    switch (cmd) {
      case 'M' || 'L':
        for (var i = 0; i + 1 < a.length; i += 2) {
          cur = Offset(a[i], a[i + 1]);
          out.add(cur);
        }
      case 'H':
        for (final x in a) {
          cur = Offset(x, cur.dy);
          out.add(cur);
        }
      case 'V':
        for (final y in a) {
          cur = Offset(cur.dx, y);
          out.add(cur);
        }
      case 'C':
        for (var i = 0; i + 5 < a.length; i += 6) {
          out
            ..add(Offset(a[i], a[i + 1]))
            ..add(Offset(a[i + 2], a[i + 3]));
          cur = Offset(a[i + 4], a[i + 5]);
          out.add(cur);
        }
      case 'Z' || 'z':
        break;
      default:
        throw UnsupportedError('path command $cmd');
    }
  }
  return out;
}

Path parseSvgPath(String d) {
  final path = Path()..fillType = PathFillType.nonZero;
  var cur = Offset.zero;
  var start = Offset.zero;
  for (final (cmd, a) in _commands(d)) {
    switch (cmd) {
      case 'M':
        for (var i = 0; i + 1 < a.length; i += 2) {
          cur = Offset(a[i], a[i + 1]);
          if (i == 0) {
            path.moveTo(cur.dx, cur.dy);
            start = cur;
          } else {
            path.lineTo(cur.dx, cur.dy);
          }
        }
      case 'L':
        for (var i = 0; i + 1 < a.length; i += 2) {
          cur = Offset(a[i], a[i + 1]);
          path.lineTo(cur.dx, cur.dy);
        }
      case 'H':
        for (final x in a) {
          cur = Offset(x, cur.dy);
          path.lineTo(cur.dx, cur.dy);
        }
      case 'V':
        for (final y in a) {
          cur = Offset(cur.dx, y);
          path.lineTo(cur.dx, cur.dy);
        }
      case 'C':
        for (var i = 0; i + 5 < a.length; i += 6) {
          path.cubicTo(a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5]);
          cur = Offset(a[i + 4], a[i + 5]);
        }
      case 'Z' || 'z':
        path.close();
        cur = start;
      default:
        throw UnsupportedError('path command $cmd');
    }
  }
  return path;
}

/// A column-major 4×4 for `Path.transform`: scale about the origin, then
/// translate (VectorDrawable's group order with pivot 0).
class Matrix4Ish {
  Matrix4Ish.scaleThenTranslate(double s, Offset t)
    : storage = Float64List.fromList([
        s, 0, 0, 0, //
        0, s, 0, 0, //
        0, 0, 1, 0, //
        t.dx, t.dy, 0, 1,
      ]);

  final Float64List storage;
}
