// 「重新回答」. DSH keeps an append-only log and has no regenerate call, and
// the official web client offers none. It is done the way 「编辑后重发」 is —
// `session/fork` just before the prompt (`forkPointBeforePrompt`) — and then
// the same prompt, text and images, is sent again in the fork. The source
// conversation stays as it was.

import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'attachments.dart';
import 'chat_state.dart';

/// The prompt 「重新回答」 sends again for [reply]; null when it is not
/// offered:
/// * [reply] is not the conversation's last word (only notices may follow
///   it), or it is still streaming;
/// * a turn is running or messages wait to be sent;
/// * the prompt carried files: DSH serves image bytes back
///   (`session/attachment`), not file contents, so only text and images can
///   be sent again.
///
/// Whether the turn ended cleanly is the caller's other check
/// (`ChatController.branchPointAfter`).
UserChatItem? regenerablePrompt(ChatState state, AssistantChatItem reply) {
  if (state.running || state.pending.isNotEmpty || reply.streaming || reply.seq == null || reply.text.trim().isEmpty) {
    return null;
  }
  final items = state.items;
  var at = items.length - 1;
  for (; at >= 0; at--) {
    final item = items[at];
    if (item is AssistantChatItem && item.id == reply.id) break;
    if (item is! NoticeChatItem) return null;
  }
  if (at < 0) return null;
  for (var i = at - 1; i >= 0; i--) {
    if (items[i] case final UserChatItem prompt) {
      if (prompt.files.isNotEmpty) return null;
      if (prompt.text.trim().isEmpty && prompt.images.isEmpty) return null;
      return prompt;
    }
  }
  return null;
}

/// The images of [prompt] as new attachments, in order, read back with
/// [bytesOf] (`session/attachment`). Throws what [bytesOf] throws.
Future<List<DraftAttachment>> resendImages(
  UserChatItem prompt,
  Future<Uint8List> Function(ImageAttachment image) bytesOf,
) async {
  final drafts = <DraftAttachment>[];
  for (final (index, image) in prompt.images.indexed) {
    final bytes = await bytesOf(image);
    final type = inlineImageType(bytes) ?? image.mediaType;
    final given = image.name?.trim() ?? '';
    drafts.add(
      DraftAttachment(
        name: given.isNotEmpty
            ? given
            : 'image-${index + 1}.${switch (type) {
                'image/jpeg' => 'jpg',
                'image/gif' => 'gif',
                'image/webp' => 'webp',
                _ => 'png',
              }}',
        bytes: bytes,
        mediaType: type,
      ),
    );
  }
  return drafts;
}

/// Bytes of [image], sent in [sessionId], through the cache the bubbles'
/// thumbnails use ([sessionImageProvider]): an image on screen is not
/// fetched again.
Future<Uint8List> sessionImageBytes(WidgetRef ref, String sessionId, ImageAttachment image) async {
  final provider = sessionImageProvider((sessionId, image));
  // Held while it loads: a plain read of an auto-dispose provider could be
  // dropped before it answers.
  final hold = ref.listenManual(provider, (_, _) {});
  try {
    return await ref.read(provider.future);
  } finally {
    hold.close();
  }
}
