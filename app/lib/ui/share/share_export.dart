// Turning a share card into a PNG and handing it to the Android share sheet or
// the photo album.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/artifacts.dart' show FilesChannel, filesChannelProvider;
import 'share_gallery.dart' show shareImagesSettled;

/// Pixel ratio for a card [height] logical pixels tall: 3× (1170 px wide)
/// for most, 2× for very long ones so the bitmap stays within ~30 MB.
double sharePixelRatio(double height) => height <= 2000 ? 3 : 2;

/// Renders the [RepaintBoundary] behind [key] as PNG bytes at
/// [sharePixelRatio], once the card's pictures are decoded (or given up on:
/// at most [imageTimeout]), so nothing is captured as an empty box. The
/// boundary is drawn at its own layout size, not at the size a preview
/// scales it to.
Future<Uint8List> captureShareCard(GlobalKey key, {Duration imageTimeout = const Duration(seconds: 8)}) async {
  if (key.currentContext case final context?) await shareImagesSettled(context, timeout: imageTimeout);
  final boundary = key.currentContext?.findRenderObject();
  if (boundary is! RenderRepaintBoundary) throw StateError('share card is not on screen');
  // (debugNeedsPaint is debug-only.) A pending frame may still repaint it.
  if (SchedulerBinding.instance.hasScheduledFrame) await SchedulerBinding.instance.endOfFrame;
  final image = await boundary.toImage(pixelRatio: sharePixelRatio(boundary.size.height));
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('PNG encoding failed');
    return data.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// Where a finished card goes. A seam: tests record instead of sharing.
class ShareExporter {
  ShareExporter({
    required this.files,
    Future<Directory> Function()? cacheRoot,
    Future<void> Function(ShareParams params)? share,
    DateTime Function()? clock,
  }) : _cacheRoot = cacheRoot ?? getTemporaryDirectory,
       _share = share ?? _systemShare,
       _clock = clock ?? DateTime.now;

  final FilesChannel files;
  final Future<Directory> Function() _cacheRoot;
  final Future<void> Function(ShareParams params) _share;
  final DateTime Function() _clock;

  static Future<void> _systemShare(ShareParams params) async {
    await SharePlus.instance.share(params);
  }

  /// `dsh-go-20261024-153012.png`.
  String fileName() {
    final t = _clock();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'dsh-go-${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}.png';
  }

  /// Writes [png] into the cache's `share/` (keeping only the last few).
  Future<File> write(Uint8List png) async {
    final dir = Directory('${(await _cacheRoot()).path}/share');
    await dir.create(recursive: true);
    final old = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    for (final file in old.skip(4)) {
      try {
        file.deleteSync();
      } catch (_) {}
    }
    final file = File('${dir.path}/${fileName()}');
    await file.writeAsBytes(png, flush: true);
    return file;
  }

  /// The Android share sheet with the image (and [text], for apps that take both).
  Future<void> share(File image, {String? text}) => _share(
    ShareParams(
      files: [XFile(image.path, mimeType: 'image/png', name: image.uri.pathSegments.last)],
      text: text,
    ),
  );

  /// Into the shared pictures the album shows (`Download/DSH-Go`, indexed as an
  /// image by MediaStore); returns where it landed.
  Future<String> save(File image) =>
      files.saveToDownloads(image.path, name: image.uri.pathSegments.last, mime: 'image/png');
}

final shareExporterProvider = Provider<ShareExporter>((ref) => ShareExporter(files: ref.watch(filesChannelProvider)));
