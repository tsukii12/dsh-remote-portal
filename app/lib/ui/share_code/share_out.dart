// Where a share code goes — the clipboard, the Android share sheet, a `.dshgo`
// file in Download/DSH-Go. A seam: tests record instead.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../share_code/share_codec.dart';
import '../../state/artifacts.dart' show FilesChannel, filesChannelProvider;

class ShareOut {
  ShareOut({
    required this.files,
    Future<Directory> Function()? cacheRoot,
    Future<void> Function(ShareParams params)? share,
    Future<void> Function(String text)? copy,
    DateTime Function()? clock,
  }) : _cacheRoot = cacheRoot ?? getTemporaryDirectory,
       _share = share ?? _systemShare,
       _copy = copy ?? _clipboard,
       _clock = clock ?? DateTime.now;

  final FilesChannel files;
  final Future<Directory> Function() _cacheRoot;
  final Future<void> Function(ShareParams params) _share;
  final Future<void> Function(String text) _copy;
  final DateTime Function() _clock;

  static Future<void> _systemShare(ShareParams params) async {
    await SharePlus.instance.share(params);
  }

  static Future<void> _clipboard(String text) => Clipboard.setData(ClipboardData(text: text));

  Future<void> copy(String text) => _copy(text);

  Future<void> shareText(String text) => _share(ShareParams(text: text));

  /// `dsh-go-profile-20261024.dshgo` / `dsh-go-plugin-notes.dshgo`.
  String fileName({required bool profile, String? name}) {
    final t = _clock();
    String two(int n) => n.toString().padLeft(2, '0');
    if (profile) return 'dsh-go-profile-${t.year}${two(t.month)}${two(t.day)}.$shareFileExtension';
    final slug = (name ?? 'plugin').split('/').last.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
    return 'dsh-go-plugin-${slug.isEmpty ? 'plugin' : slug}.$shareFileExtension';
  }

  /// Writes [content] into the cache's `share_code/` (keeping the last few).
  Future<File> write(String name, String content) async {
    final dir = Directory('${(await _cacheRoot()).path}/share_code');
    await dir.create(recursive: true);
    final old = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    for (final file in old.skip(4)) {
      try {
        file.deleteSync();
      } catch (_) {}
    }
    final file = File('${dir.path}/$name');
    await file.writeAsString(content, flush: true);
    return file;
  }

  /// The Android share sheet with the file (and [text] for apps that take both).
  Future<void> shareFile(File file, {String? text}) => _share(
    ShareParams(
      files: [XFile(file.path, mimeType: shareFileMime, name: file.uri.pathSegments.last)],
      text: text,
    ),
  );

  /// Into `Download/DSH-Go`; returns where it landed.
  Future<String> save(String name, String content) async {
    final dir = await Directory('${(await _cacheRoot()).path}/share_code').create(recursive: true);
    // A dismissed sheet may reopen while the native worker still reads its source.
    final operation = await dir.createTemp('save-');
    try {
      final file = File('${operation.path}/$name');
      await file.writeAsString(content, flush: true);
      return await files.saveToDownloads(file.path, name: name, mime: shareFileMime);
    } finally {
      try {
        await operation.delete(recursive: true);
      } catch (_) {
        // Cache cleanup must not change the native save result or original error.
      }
    }
  }
}

final shareOutProvider = Provider<ShareOut>((ref) => ShareOut(files: ref.watch(filesChannelProvider)));
