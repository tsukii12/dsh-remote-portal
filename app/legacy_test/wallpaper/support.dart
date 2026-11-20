// Shared bits of the wallpaper tests: the fixtures, a phone frame, and reading a bake's pixels.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/theme/accent.dart';
import 'package:dsh_app/wallpaper/custom_wallpaper.dart';
import 'package:dsh_app/wallpaper/wallpaper_look.dart';
import 'package:dsh_app/wallpaper/wallpaper_render.dart';
import 'package:flutter/material.dart';

/// A pale seaside noon (JPEG, 720 × 1280): sky, sun, sea, sand and two dark rocks.
const brightFixture = 'test/wallpaper/fixtures/bright.jpg';

/// A city at night (WebP, 720 × 1280): a moon, a skyline, lit windows, a neon sign.
const darkFixture = 'test/wallpaper/fixtures/dark.webp';

/// Two frames: a pale one, then black.
const gifFixture = 'test/wallpaper/fixtures/two_frames.gif';

/// A small PNG (300 × 200).
const pngFixture = 'test/wallpaper/fixtures/landscape.png';

/// A PNG header and nothing that decodes.
const brokenFixture = 'test/wallpaper/fixtures/broken.png';

/// The golden harness's phone: 390 × 844 at 2×, a 32 status bar, a 24 navigation bar; the
/// header and composer bars as [WallpaperBackdrop.frameOf] measures them there.
WallpaperFrame phoneFrame(Brightness brightness, {AppAccent accent = AppAccent.mist, bool lightweight = false}) =>
    WallpaperFrame(
      size: const Size(390, 844),
      pixelRatio: 2,
      look: WallpaperLook.forAccent(accent, brightness),
      top: 32 + 56 + 8,
      bottom: 24 + 96,
      lightweight: lightweight,
    );

/// A fixture as the stored wallpaper; [tone] sets both 提亮 and 压暗 (else their defaults).
CustomWallpaper fixtureWallpaper(String path, {double blur = CustomWallpaper.defaultBlur, double? tone}) =>
    CustomWallpaper(
      path: path,
      width: 720,
      height: 1280,
      blur: blur,
      lighten: tone ?? CustomWallpaper.defaultLighten,
      dim: tone ?? CustomWallpaper.defaultDim,
    );

/// [w] as stored in shared preferences.
String jsonOf(CustomWallpaper w) => jsonEncode(w.toJson());

/// A bake's pixels.
class Pixels {
  Pixels(this.width, this.height, this.rgba);

  final int width;
  final int height;
  final Uint8List rgba;

  static Future<Pixels> of(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return Pixels(image.width, image.height, data!.buffer.asUint8List());
  }

  Color at(int x, int y) {
    final i = (y * width + x) * 4;
    return Color.fromARGB(255, rgba[i], rgba[i + 1], rgba[i + 2]);
  }

  /// Per channel the least (or, [most], the largest) value in [rect] (pixels): a colour no pixel
  /// there is darker (lighter) than.
  Color extreme(Rect rect, {required bool most}) {
    final x0 = math.max(0, rect.left.floor()), x1 = math.min(width, rect.right.ceil());
    final y0 = math.max(0, rect.top.floor()), y1 = math.min(height, rect.bottom.ceil());
    var r = most ? 0 : 255, g = r, b = r;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final i = (y * width + x) * 4;
        if (most) {
          r = math.max(r, rgba[i]);
          g = math.max(g, rgba[i + 1]);
          b = math.max(b, rgba[i + 2]);
        } else {
          r = math.min(r, rgba[i]);
          g = math.min(g, rgba[i + 1]);
          b = math.min(b, rgba[i + 2]);
        }
      }
    }
    return Color.fromARGB(255, r, g, b);
  }

  /// The lowest contrast [text] has against any pixel in [rect] (pixels), each under [lift] of
  /// white (a dark card's fill).
  double worstContrast(Color text, Rect rect, {double lift = 0}) {
    final t = text.computeLuminance();
    final x0 = math.max(0, rect.left.floor()), x1 = math.min(width, rect.right.ceil());
    final y0 = math.max(0, rect.top.floor()), y1 = math.min(height, rect.bottom.ceil());
    final lum = List<double>.generate(256, (v) {
      final c = v / 255;
      return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    });
    var worst = double.infinity;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final i = (y * width + x) * 4;
        int up(int c) => lift == 0 ? c : (c + (255 - c) * lift).round().clamp(0, 255);
        final l = 0.2126 * lum[up(rgba[i])] + 0.7152 * lum[up(rgba[i + 1])] + 0.0722 * lum[up(rgba[i + 2])];
        worst = math.min(worst, contrastOf(t, l));
      }
    }
    return worst;
  }

  /// The least and most relative luminance in [rect] (pixels), each pixel under [lift] of white.
  (double, double) luminanceRange(Rect rect, {double lift = 0}) {
    final x0 = math.max(0, rect.left.floor()), x1 = math.min(width, rect.right.ceil());
    final y0 = math.max(0, rect.top.floor()), y1 = math.min(height, rect.bottom.ceil());
    var lo = double.infinity, hi = double.negativeInfinity;
    double lin(int v) {
      final c = (v + (255 - v) * lift) / 255;
      return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    }

    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final i = (y * width + x) * 4;
        final l = 0.2126 * lin(rgba[i]) + 0.7152 * lin(rgba[i + 1]) + 0.0722 * lin(rgba[i + 2]);
        lo = math.min(lo, l);
        hi = math.max(hi, l);
      }
    }
    return (lo, hi);
  }

  /// The mean colour of [rect] (pixels).
  Color mean(Rect rect) {
    final x0 = math.max(0, rect.left.floor()), x1 = math.min(width, rect.right.ceil());
    final y0 = math.max(0, rect.top.floor()), y1 = math.min(height, rect.bottom.ceil());
    var r = 0, g = 0, b = 0, n = 0;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final i = (y * width + x) * 4;
        r += rgba[i];
        g += rgba[i + 1];
        b += rgba[i + 2];
        n++;
      }
    }
    return Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
  }
}

/// Writes [image] as a PNG to `$WALLPAPER_DUMP/<name>.png` when that's set (for looking at bakes).
Future<void> dump(ui.Image image, String name) async {
  final dir = Platform.environment['WALLPAPER_DUMP'];
  if (dir == null) return;
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File('$dir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
}
