// Pictures a media card already shows: a reply naming the same file
// (`![](generated/…/cat-1.png)`, which the plugin asks the model to write for
// clients without media cards) is not drawn a second time
// (docs/design/media-generation.md §2.5, 「网页版与旧 App」).

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/chat_state.dart';
import '../tool_view.dart' show toolMedia;

/// Every file the conversation's media cards show. Media comes with a call's
/// result, a log event: recomputed when the log changes (the turns are
/// traced afresh then), not on every streamed delta.
final sessionMediaPathsProvider = Provider.autoDispose.family<Set<String>, String>((ref, sessionId) {
  ref.watch(chatProvider(sessionId).select((s) => s.turns));
  final items = ref.read(chatProvider(sessionId)).items;
  return {
    for (final item in items)
      if (item is ToolChatItem)
        if (toolMedia(item) case final media?) ...media.paths,
  };
});

/// Whether [path] (absolute, or relative to the conversation's folder when
/// the app doesn't know it) is one of [shown].
bool shownInMediaCard(Set<String> shown, String path) {
  if (shown.isEmpty || path.isEmpty) return false;
  if (shown.contains(path)) return true;
  if (path.startsWith('/')) return false;
  final relative = path.startsWith('./') ? path.substring(2) : path;
  return shown.any((p) => p.endsWith('/$relative'));
}

final _imageLine = RegExp(r'^[ \t]*!\[[^\]\n]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)[ \t]*$', multiLine: true);

/// [text] without the lines that only show a picture a media card already
/// shows (the paragraph would stay behind as a gap). Null when nothing goes.
String? withoutShownImages(String text, Set<String> shown) {
  if (shown.isEmpty || !text.contains('![')) return null;
  var changed = false;
  final out = text.replaceAllMapped(_imageLine, (m) {
    var target = m[1]!;
    try {
      target = Uri.decodeFull(target);
    } on ArgumentError {
      // Keep it as written.
    }
    if (!shownInMediaCard(shown, target)) return m[0]!;
    changed = true;
    return '';
  });
  if (!changed) return null;
  return out.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// [item] showing [text] instead.
AssistantChatItem replyWithText(AssistantChatItem item, String text) => AssistantChatItem(
  id: item.id,
  rowKey: item.rowKey,
  seq: item.seq,
  time: item.time,
  text: text,
  reasoning: item.reasoning,
  streaming: item.streaming,
  interrupted: item.interrupted,
  usage: item.usage,
  model: item.model,
  isFinalAnswer: item.isFinalAnswer,
);
