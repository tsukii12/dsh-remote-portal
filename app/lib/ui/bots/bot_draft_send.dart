// A failed send may restore the editor only while it still belongs to the
// same connection and conversation. Drafts are not moved between targets.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/bots_state.dart';

Future<void> sendBotDraft(
  BuildContext context,
  WidgetRef ref,
  TextEditingController input, {
  String? botId,
  String? roomId,
  required Future<bool> Function(String text) send,
}) async {
  final text = input.text.trim();
  if (text.isEmpty) return;
  final hub = ref.read(dsBotProvider.notifier);
  final api = hub.api;
  final origin = ref.read(dsBotProvider);
  final part = botId == null ? null : origin.team?.bot(botId)?.sessionId;
  bool sameTarget(DsBotStatus status) =>
      api != null &&
      ref.read(dsBotProvider.notifier).api == api &&
      status.host == origin.host &&
      status.hello?.boot == origin.hello?.boot &&
      (botId == null || (status.team?.bot(botId) != null && status.team?.bot(botId)?.sessionId == part)) &&
      (roomId == null || status.team?.room(roomId) != null);
  var retired = false;
  // Retirement is permanent even if the same part or entity reappears before
  // the pending request completes, including changes between rendered frames.
  final subscription = ref.listenManual<DsBotStatus>(dsBotProvider, (_, status) {
    if (!sameTarget(status)) retired = true;
  });
  input.clear();
  try {
    final ok = await send(text);
    if (!ok && context.mounted && !retired && sameTarget(ref.read(dsBotProvider)) && input.text.isEmpty) {
      input.text = text;
    }
  } finally {
    subscription.close();
  }
}
