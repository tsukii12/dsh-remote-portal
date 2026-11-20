/// 检视 › 缓存 (docs/design/roleplay-compat.md §3.5): DeepSeek caches a prompt
/// by its prefix, so the first part that differs from the previous turn's
/// prompt, and every part after it, misses the cache. A lorebook entry that
/// comes and goes near the top is the usual cause.
library;

import 'dart:convert';
import 'dart:math';

import 'package:dsh_tavern/dsh_tavern.dart';

/// Where [current] stops repeating [previous]: the index of the first part
/// whose message differs. Null when the whole of [previous] comes back
/// unchanged at the front (only parts added after it, as a chat growing does),
/// or [current] is itself the front of [previous].
int? tavernCacheBreak(List<PromptSegment> previous, List<PromptSegment> current) {
  final shared = min(previous.length, current.length);
  for (var i = 0; i < shared; i++) {
    if (jsonEncode(previous[i].message) != jsonEncode(current[i].message)) return i;
  }
  return null;
}

/// The tokens from part [from] on: what misses the cache past a break.
int tavernTokensFrom(List<PromptSegment> segments, int from) =>
    segments.skip(from).fold(0, (sum, segment) => sum + segment.tokens);

/// The turn before [record]: the latest reply before it on the current path
/// that has a recorded prompt, looking back over [tries] replies at most.
/// Null when there is none to compare with.
Future<TavernTurnInspection?> tavernPreviousTurn(Tavern tavern, TavernTurnInspection record, {int tries = 4}) async {
  final anchor = record.contextNodeId ?? record.nodeId;
  if (anchor == null) return null;
  final before = await tavern.path(record.chatId, limit: 20, beforeNodeId: anchor);
  var left = tries;
  for (final message in before.reversed) {
    if (message.role == TavernRole.user || message.nodeId == record.nodeId) continue;
    if (left-- == 0) break;
    final found = await tavern.inspectTurn(record.chatId, nodeId: message.nodeId);
    if (found?.prompt != null) return found;
  }
  return null;
}
