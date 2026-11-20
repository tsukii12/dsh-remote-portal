// 酒馆设置 › 数据 (docs/design/roleplay-roadmap.md P0, engine T24): the whole
// tavern backed up to one ZIP and handed to the share sheet; a ZIP restored
// over it after asking. Files go by path, not through memory: a backup holds
// every card, chat and Live2D model.

import 'dart:async';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../common/brief_notice.dart';
import 'tavern_widgets.dart';

/// Where a backup is written before it is handed on. Tests swap it.
final tavernBackupDirProvider = Provider<Future<Directory> Function()>((ref) => getTemporaryDirectory);

/// Hands the backup at a path to the share sheet (save to Files, send to
/// oneself). Tests swap it.
final tavernBackupShareProvider = Provider<Future<void> Function(String path, String name)>(
  (ref) => (path, name) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, mimeType: 'application/zip', name: name)],
        fileNameOverrides: [name],
      ),
    );
  },
);

/// The path of a backup ZIP to restore, or null if none was picked. Tests
/// swap it.
final tavernBackupPickerProvider = Provider<Future<String?> Function()>(
  (ref) =>
      () async => (await FilePicker.pickFiles()).firstOrNull?.path,
);

/// Restores the ZIP at a path over the tavern: the engine closed first, and
/// opened again after whether or not it worked (a bad archive leaves the old
/// data as it was). Tests swap it.
final tavernRestoreProvider = Provider<Future<TavernBackupInfo> Function(String archivePath)>(
  (ref) => (archivePath) async {
    await ref.read(tavernProvider).close();
    try {
      final support = await getApplicationSupportDirectory();
      return await restoreTavernDirectory(archivePath, '${support.path}/tavern');
    } finally {
      ref.invalidate(tavernProvider);
    }
  },
);

/// [bytes] as people read a size: KB below a megabyte, else MB.
String tavernSize(int bytes) =>
    bytes < 1024 * 1024 ? '${(bytes / 1024).ceil()} KB' : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// A backup's file name, by when it was made.
String tavernBackupName(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'dshgo-tavern-${at.year}${two(at.month)}${two(at.day)}-${two(at.hour)}${two(at.minute)}.zip';
}

/// Backs the tavern up and hands the ZIP on; says how it went.
Future<void> backupTavern(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final tavern = ref.read(tavernProvider);
  final share = ref.read(tavernBackupShareProvider);
  final name = tavernBackupName(DateTime.now());
  final dir = await ref.read(tavernBackupDirProvider)();
  final path = '${dir.path}/$name';
  messenger?.showBriefNotice(l10n.tavernBackingUp);
  final TavernBackupInfo info;
  try {
    info = await tavern.backup(path);
  } on Object catch (e) {
    messenger?.showBriefNotice(l10n.tavernBackupFailed('$e'));
    return;
  }
  messenger?.showBriefNotice(l10n.tavernBackedUp(info.fileCount, tavernSize(info.totalBytes)));
  try {
    await share(path, name);
  } on Object catch (e) {
    messenger?.showBriefNotice(l10n.tavernBackupFailed('$e'));
  }
}

/// Picks a backup, asks, and restores it over the tavern; says how it went.
Future<void> restoreTavern(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final restore = ref.read(tavernRestoreProvider);
  final path = await ref.read(tavernBackupPickerProvider)();
  if (path == null || !context.mounted) return;
  final ok = await confirmTavernDelete(
    context,
    title: l10n.tavernRestoreTitle,
    message: l10n.tavernRestoreMessage,
    action: l10n.tavernRestoreAction,
  );
  if (!ok) return;
  messenger?.showBriefNotice(l10n.tavernRestoring);
  try {
    final info = await restore(path);
    messenger?.showBriefNotice(l10n.tavernRestored(info.fileCount));
  } on Object catch (e) {
    messenger?.showBriefNotice(l10n.tavernRestoreFailed('$e'));
  }
}
