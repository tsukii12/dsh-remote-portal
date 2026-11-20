// The ways into 「分享」 (share_panel.dart): a reply (the key under it, the
// long-press menu, a reply in a replay), a whole conversation (the drawer), a
// delivered file; and the plugin card the plugin share sheet offers as 「图片」.

import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../share_code/conversation_redact.dart' show redactText;
import '../../state/artifact_files.dart';
import '../../state/artifacts.dart';
import '../../state/chat_state.dart';
import '../../state/sessions_state.dart';
import '../chat/render/code_block.dart' show languageForPath;
import '../replay/replay_scope.dart';
import '../session/workspace_files.dart' show formatBytes;
import 'share_content.dart';
import 'share_panel.dart';

/// 「分享」 on a reply: the panel at 「这条回复」. A reply in a replayed
/// conversation shares from the replay, not from the chat that happens to be
/// open.
Future<void> shareReply(BuildContext context, AssistantChatItem reply) async {
  if (ReplayScope.maybeOf(context) case final replay?) {
    final end = replay.frames.end;
    final state = ChatState(
      items: end.items,
      turns: end.turns,
      commands: end.commands,
      title: replay.share.title,
      loading: false,
    );
    final done = end.items.whereType<AssistantChatItem>().where((r) => r.id == reply.id).firstOrNull ?? reply;
    final source = ReplaySource(
      share: replay.share,
      state: state,
      assets: replay.assets,
      container: ProviderScope.containerOf(context, listen: false),
    );
    return showSharePanel(context, ConversationSubject(replay: source, reply: done));
  }
  final sessionId = ProviderScope.containerOf(context, listen: false).read(currentSessionProvider);
  if (sessionId == null) return;
  return showSharePanel(context, ConversationSubject(sessionId: sessionId, reply: reply));
}

/// 「分享」 on a conversation (the drawer): the panel at 「整段对话」. Works for
/// a conversation that is not open yet: the panel waits for it.
Future<void> shareConversation(BuildContext context, String sessionId) =>
    showSharePanel(context, ConversationSubject(sessionId: sessionId), scope: ShareScope.whole);

/// The title of [sessionId] from the session list, when it is loaded (no
/// live subscription; never starts loading it).
String? _sessionTitle(ProviderContainer container, String sessionId) => container.exists(sessionsProvider)
    ? container.read(sessionsProvider).value?.where((s) => s.sessionId == sessionId).firstOrNull?.projections.title
    : null;

/// 「分享」 on a delivered file: the panel with the file's card (the picture
/// for images, the first lines for Markdown and text, otherwise the file
/// tile) and the file itself. The panel opens at once with the tile; the
/// picture / lines arrive when fetched.
Future<void> shareArtifact(BuildContext context, {required String sessionId, required Artifact artifact}) {
  final container = ProviderScope.containerOf(context, listen: false);
  final title = shareTitleText(_sessionTitle(container, sessionId));
  final typeLabel = [artifact.typeLabel, if (artifact.bytes case final b?) formatBytes(b)].join(' · ');
  ShareContent content({ImageProvider? image, String? excerpt, String? language}) => ShareContent(
    title: title,
    blocks: [
      ShareFile(
        name: artifact.name,
        typeLabel: typeLabel,
        description: artifact.description == null ? null : redactText(artifact.description!),
        image: image,
        excerpt: excerpt,
        excerptLanguage: language,
      ),
    ],
  );
  return showSharePanel(
    context,
    ArtifactSubject(
      sessionId: sessionId,
      artifact: artifact,
      card: content(),
      refine: _artifactExtras(container.read(artifactFilesProvider), sessionId, artifact, content),
    ),
  );
}

Future<ShareContent?> _artifactExtras(
  ArtifactFiles files,
  String sessionId,
  Artifact artifact,
  ShareContent Function({ImageProvider? image, String? excerpt, String? language}) content,
) async {
  if (!files.canFetch) return null;
  try {
    switch (artifact.kind) {
      case ArtifactKind.image:
        final image = await files.thumbnail(sessionId, artifact.path).timeout(const Duration(seconds: 20));
        return image == null ? null : content(image: image);
      case ArtifactKind.markdown || ArtifactKind.text:
        if ((artifact.bytes ?? 0) > 2 * 1024 * 1024) return null;
        final file = await files.materialize(sessionId, artifact).timeout(const Duration(seconds: 20));
        final head = await file.openRead(0, 16 * 1024).transform(const Utf8Decoder(allowMalformed: true)).join();
        final lines = head.split('\n');
        final excerpt = lines.take(40).join('\n').trimRight();
        if (excerpt.isEmpty) return null;
        if (artifact.kind == ArtifactKind.markdown) {
          return content(excerpt: shareMarkdown(excerpt));
        }
        return content(excerpt: redactText(excerpt), language: languageForPath(artifact.path) ?? 'text');
      default:
        return null;
    }
  } catch (_) {
    return null;
  }
}
