// Going to a message in a chat's story (a search hit, and whatever else
// points at one): whoever found it asks here; the chat page loads back far
// enough, scrolls it into view, and clears the ask.

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The message [chatId]'s page should go to, or null.
final tavernJumpProvider = NotifierProvider.family<TavernJump, String?, String>(TavernJump.new);

class TavernJump extends Notifier<String?> {
  TavernJump(this.chatId);

  final String chatId;

  @override
  String? build() => null;

  /// Go to [nodeId] (already on the current path: switch its branch first).
  void go(String nodeId) => state = nodeId;

  /// The page has gone there (or given up).
  void done() => state = null;
}
