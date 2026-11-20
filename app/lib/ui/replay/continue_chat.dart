// 「接着聊」 on a replayed conversation. DSH has no way to import a conversation, so
// a new one starts with this one attached as Markdown and a first line in the
// composer; the person edits it and sends.

import 'dart:convert';

import '../../l10n/l10n.dart';
import '../../share_code/conversation_share.dart';
import '../../state/attachments.dart';
import '../../state/compose_inbox.dart';
import 'conversation_out.dart' show fileStem;

/// What the composer says above the attachment.
String get continueChatPrompt => appL10n.viewContinuePrompt;

/// The new-chat fill for [share].
ComposeRequest continueChatRequest(ConversationShare share) {
  final bytes = utf8.encode(conversationMarkdown(share));
  return ComposeRequest(
    text: continueChatPrompt,
    attachments: [DraftAttachment(name: '${fileStem(share.title)}.md', bytes: bytes)],
  );
}

/// [share] as Markdown a model reads well: who said what, the work in one
/// line per call, no thinking, no tool output.
String conversationMarkdown(ConversationShare share) {
  final out = StringBuffer('# ${_oneLine(share.title)}\n\n');
  final start = share.start.toLocal();
  final meta = [
    '${start.year}-${_two(start.month)}-${_two(start.day)}',
    ?share.model,
    if (share.range case final r?) appL10n.viewContinueRange(r.from, r.to, r.of),
  ];
  out.write(appL10n.viewContinueHeader(meta.join(' · ')));
  String? last;
  for (final entry in share.entries) {
    switch (entry) {
      case UserEntry(:final text, :final images, :final files):
        out.write(appL10n.viewContinueUser);
        if (text.trim().isNotEmpty) out.write('${text.trim()}\n');
        final attached = [if (images.isNotEmpty) appL10n.viewImageCount(images.length), for (final f in files) f.name];
        if (attached.isNotEmpty) {
          out.write(appL10n.viewContinueAttachments(attached.join(appL10n.viewAttachmentSeparator)));
        }
        last = 'user';
      case ReplyEntry(:final text, :final plain, :final interrupted):
        final body = (plain ?? text).trim();
        if (body.isEmpty) continue;
        if (last != 'reply') out.write(appL10n.viewContinueAssistant);
        out.write('$body\n');
        if (interrupted) out.write(appL10n.viewContinueInterrupted);
        last = 'reply';
      case ToolEntry(:final verb, :final name, :final summary, :final status):
        if (last != 'reply' && last != 'tool') out.write(appL10n.viewContinueAssistant);
        final state = switch (status) {
          ToolOutcome.ok => '',
          ToolOutcome.failed => appL10n.viewContinueFailed,
          ToolOutcome.denied => appL10n.viewContinueDeclined,
          ToolOutcome.cancelled => appL10n.viewContinueCancelled,
        };
        final what = summary.trim().isEmpty ? '' : ' `${_oneLine(summary).replaceAll('`', "'")}`';
        out.write('\n- ${verb ?? name}$what$state\n');
        last = 'tool';
      case NoticeEntry(:final kind, :final text) when kind == 'error' || kind == 'aborted':
        if (text.trim().isNotEmpty) out.write(appL10n.viewContinueNotice(_oneLine(text)));
      case CommandEntry(:final line):
        out.write('\n`${_oneLine(line)}`\n');
      default:
        break;
    }
  }
  return out.toString();
}

String _two(int n) => n.toString().padLeft(2, '0');

String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
