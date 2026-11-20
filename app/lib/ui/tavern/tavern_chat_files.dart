// SillyTavern chat files (Pro's T9): bring a character's .jsonl chats over
// from ST, and hand a chat back as .jsonl (the current path first, then its
// other branches). Picking and sharing are providers so tests can swap them.

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
import '../common/app_dialog.dart';

/// Picks one or more files; an empty list when nothing was picked.
final tavernChatPickerProvider = Provider<Future<List<TavernChatFile>> Function()>(
  (ref) =>
      () async => [
        for (final file in await FilePicker.pickFiles())
          TavernChatFile(fileName: file.name, bytes: await file.readAsBytes()),
      ],
);

/// Hands chat files to the system share sheet, through the app cache.
final tavernChatSinkProvider = Provider<Future<void> Function(List<TavernChatFile> files)>(
  (ref) => (files) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/tavern_export');
    await dir.create(recursive: true);
    final shared = <XFile>[];
    for (final f in files) {
      final file = File('${dir.path}/${f.fileName}');
      await file.writeAsBytes(f.bytes, flush: true);
      shared.add(XFile(file.path, mimeType: tavernFileMime(f.fileName), name: f.fileName));
    }
    await SharePlus.instance.share(ShareParams(files: shared, fileNameOverrides: [for (final f in files) f.fileName]));
  },
);

/// Imports picked ST .jsonl chats into [characterId]; says how it went, and
/// shows what the import noticed (missing lorebooks and the like).
Future<void> importTavernChats(BuildContext context, WidgetRef ref, String characterId) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final picked = await ref.read(tavernChatPickerProvider)();
  if (picked.isEmpty) return;
  final files = [
    for (final f in picked)
      if (f.fileName.toLowerCase().endsWith('.jsonl')) f,
  ];
  if (files.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernOnlyJsonl)));
    return;
  }
  final TavernChatImportResult result;
  try {
    result = await ref.read(tavernProvider).importChats(characterId, files);
  } on Object catch (e) {
    // The engine names the file and line it stopped at; say that much.
    final line = e.toString().split('\n').first;
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernImportChatsFailed(line))));
    return;
  }
  messenger.showSnackBar(SnackBar(content: Text(l10n.tavernImportedChats(result.chatIds.length))));
  if (result.notices.isEmpty || !context.mounted) return;
  await showAppDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      key: const ValueKey('tavern-import-notices'),
      title: Text(l10n.tavernImportNoticesTitle),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final notice in result.notices)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('· $notice')),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(dialog).pop(), child: Text(l10n.commonDone))],
    ),
  );
}

/// Exports [chatId] as ST .jsonl files named after [title] and shares them.
Future<void> exportTavernChat(BuildContext context, WidgetRef ref, String chatId, {required String title}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final sink = ref.read(tavernChatSinkProvider);
  try {
    final files = await ref.read(tavernProvider).exportChat(chatId, fileName: tavernChatFileName(title));
    await sink(files);
  } on Object {
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernExportChatFailed)));
  }
}

/// What a file handed on is, from its name: chats, books, text.
String tavernFileMime(String fileName) => switch (fileName.split('.').last.toLowerCase()) {
  'epub' => 'application/epub+zip',
  'txt' => 'text/plain',
  _ => 'application/x-ndjson',
};

/// `<title>.jsonl` (or another [extension]) without path or reserved characters.
String tavernChatFileName(String title, {String extension = 'jsonl'}) {
  final safe = title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
  return '${safe.isEmpty ? 'chat' : safe}.$extension';
}
