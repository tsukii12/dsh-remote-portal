import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'custom_wallpaper.dart';

enum WallpaperImportProblem { cancelled, unavailable, tooLarge, overLimit, unsupported, unreadable }

class WallpaperImport {
  WallpaperImport({
    Future<XFile?> Function()? picker,
    Future<Directory> Function()? directory,
    DateTime Function()? now,
  }) : _picker = picker ?? (() => ImagePicker().pickImage(source: ImageSource.gallery)),
       directory = directory ?? wallpaperDirectory,
       _now = now ?? DateTime.now;
  final Future<XFile?> Function() _picker;
  final Future<Directory> Function() directory;
  final DateTime Function() _now;

  static Future<Directory> wallpaperDirectory() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/wallpaper').create(recursive: true);

  Future<(CustomWallpaper?, WallpaperImportProblem?)> pick({CustomWallpaper? previous}) async {
    try {
      final file = await _picker();
      if (file == null) return (null, WallpaperImportProblem.cancelled);
      if (await file.length() > CustomWallpaper.maxBytes) return (null, WallpaperImportProblem.tooLarge);
      return await keep(file.openRead(), previous: previous);
    } catch (_) {
      return (null, WallpaperImportProblem.unavailable);
    }
  }

  Future<(CustomWallpaper?, WallpaperImportProblem?)> keep(
    Stream<List<int>> stream, {
    CustomWallpaper? previous,
  }) async {
    File? saved;
    try {
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        if (bytes.length + chunk.length > CustomWallpaper.maxBytes) return (null, WallpaperImportProblem.tooLarge);
        bytes.add(chunk);
      }
      if (bytes.isEmpty) return (null, WallpaperImportProblem.unreadable);
      final data = bytes.takeBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(data);
      ui.ImageDescriptor? descriptor;
      ui.Codec? codec;
      late final int width, height;
      try {
        descriptor = await ui.ImageDescriptor.encoded(buffer);
        width = descriptor.width;
        height = descriptor.height;
        if (width <= 0 || height <= 0 || width * height > 64 * 1024 * 1024) {
          return (null, WallpaperImportProblem.overLimit);
        }
        codec = await descriptor.instantiateCodec(targetWidth: 64, targetHeight: 64);
        (await codec.getNextFrame()).image.dispose();
        saved = File('${(await directory()).path}/${_now().microsecondsSinceEpoch}.image');
        await saved.writeAsBytes(data, flush: true);
      } finally {
        codec?.dispose();
        descriptor?.dispose();
        buffer.dispose();
      }
      final path = saved.path;
      return (
        previous?.replacedBy(path: path, width: width, height: height) ??
            CustomWallpaper(path: path, width: width, height: height),
        null,
      );
    } catch (_) {
      if (saved != null) {
        try {
          await saved.delete();
        } catch (_) {}
      }
      return (null, WallpaperImportProblem.unreadable);
    }
  }

  static Future<void> removeFile(String path) async {
    try {
      final root = await (await wallpaperDirectory()).resolveSymbolicLinks();
      final file = File(path);
      if ((await file.resolveSymbolicLinks()).startsWith('$root/')) await file.delete();
    } catch (_) {}
  }
}
