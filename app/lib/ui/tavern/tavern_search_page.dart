// 舞台 › 本局 › 在对话里搜索 (docs/design/roleplay-roadmap.md P1, engine T24):
// a line or a word across every branch of this chat, newest first, each hit
// with the words around it. A hit opens whole, to read or copy, or to go to
// in the story: its branch becomes the current one and the chat scrolls there.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_jump.dart';
import '../../tavern/tavern_provider.dart';
import '../bots/bot_format.dart' show shortTime;
import '../chat/render/markdown_body.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/search_capsule.dart';
import '../common/sheet_title_bar.dart';
import '../features/feature_kit.dart';
import '../shell/page_frame.dart';
import '../theme/theme.dart';

class TavernSearchPage extends ConsumerStatefulWidget {
  const TavernSearchPage({super.key, required this.chatId});

  final String chatId;

  static Route<void> route(String chatId) => MaterialPageRoute<void>(builder: (_) => TavernSearchPage(chatId: chatId));

  @override
  ConsumerState<TavernSearchPage> createState() => _TavernSearchPageState();
}

class _TavernSearchPageState extends ConsumerState<TavernSearchPage> {
  final _query = TextEditingController();
  Timer? _pause;

  /// What was asked, and what came back; null while it is being looked for.
  String _asked = '';
  List<TavernMessage>? _hits = const [];

  /// Counts searches, so an older answer arriving late is not shown.
  int _ticket = 0;

  @override
  void dispose() {
    _pause?.cancel();
    _query.dispose();
    super.dispose();
  }

  /// Searches a beat after typing stops, not on every key.
  void _changed(String text) {
    _pause?.cancel();
    _pause = Timer(const Duration(milliseconds: 250), () => unawaited(_search(text.trim())));
  }

  Future<void> _search(String query) async {
    final ticket = ++_ticket;
    if (query.isEmpty) {
      setState(() {
        _asked = '';
        _hits = const [];
      });
      return;
    }
    setState(() => _hits = null);
    List<TavernMessage> hits;
    try {
      hits = await ref.read(tavernProvider).searchChat(widget.chatId, query);
    } on Object {
      hits = const [];
    }
    if (!mounted || ticket != _ticket) return;
    setState(() {
      _asked = query;
      _hits = hits;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary, height: 1.5);
    final hits = _hits;
    return AppPage.list(
      title: l10n.tavernSearchChat,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: SearchCapsule(
            key: const ValueKey('tavern-chat-search-field'),
            controller: _query,
            hint: l10n.tavernSearchChatHint,
            autofocus: true,
            onChanged: _changed,
            onClear: () {
              _query.clear();
              _changed('');
            },
          ),
        ),
        if (hits == null)
          const QuietSpinner()
        else if (_asked.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 4, 28, 16),
            child: Text(l10n.tavernSearchChatIdle, style: quiet),
          )
        else if (hits.isEmpty)
          Padding(
            key: const ValueKey('tavern-chat-search-none'),
            padding: const EdgeInsets.fromLTRB(28, 4, 28, 16),
            child: Text(l10n.tavernSearchChatNone(_asked), style: quiet),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
            child: Text(l10n.tavernSearchChatFound(hits.length), style: quiet),
          ),
          SheetGroup(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [for (final hit in hits) _Hit(chatId: widget.chatId, message: hit, query: _asked)],
          ),
        ],
      ],
    );
  }
}

/// One hit: who said it and when, and the words around the match.
class _Hit extends StatelessWidget {
  const _Hit({required this.chatId, required this.message, required this.query});

  final String chatId;
  final TavernMessage message;
  final String query;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final (before, match, after) = tavernSearchSnippet(message.text, query);
    return InkWell(
      key: ValueKey('tavern-chat-search-hit-${message.nodeId}'),
      onTap: () => unawaited(_open(context)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    message.speaker,
                    style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(shortTime(message.at), style: theme.textTheme.labelSmall?.copyWith(color: dsh.textTertiary)),
              ],
            ),
            const SizedBox(height: 4),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: before),
                  TextSpan(
                    text: match,
                    style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: after),
                ],
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  /// The whole message, to read or copy.
  Future<void> _open(BuildContext context) => showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (sheet) {
      final l10n = sheet.l10n;
      return SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(message.speaker),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 12, 0, SheetTitleBar.inset + 12, 12),
                  child: MarkdownBody(key: const ValueKey('tavern-chat-search-whole'), text: message.text),
                ),
              ),
              // Into the story: its branch the current one, the chat scrolled there.
              Padding(
                padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 8),
                child: FilledButton(
                  key: const ValueKey('tavern-chat-search-go'),
                  onPressed: () async {
                    final container = ProviderScope.containerOf(context, listen: false);
                    final page = Navigator.of(context);
                    Navigator.of(sheet).pop();
                    await container.read(tavernProvider).selectSibling(chatId, message.nodeId, message.siblingIndex);
                    unawaited(HapticFeedback.selectionClick());
                    container.read(tavernJumpProvider(chatId).notifier).go(message.nodeId);
                    if (page.mounted) page.pop();
                  },
                  child: Text(l10n.tavernSearchGoTo),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                child: OutlinedButton(
                  key: const ValueKey('tavern-chat-search-copy'),
                  onPressed: () {
                    unawaited(Clipboard.setData(ClipboardData(text: message.text)));
                    Navigator.of(sheet).pop();
                    showBriefNotice(context, l10n.commonCopied);
                  },
                  child: Text(l10n.commonCopy),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// [text] around the first [query], on one line: up to 20 characters before
/// it (cut with …) and the rest after; the match as written. Letters match
/// regardless of case, as the engine's search does. No match in the text (it
/// was the speaker's name): the text's start.
(String, String, String) tavernSearchSnippet(String text, String query) {
  final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final at = query.isEmpty ? -1 : line.toLowerCase().indexOf(query.toLowerCase());
  if (at < 0) return (line, '', '');
  final from = at > 20 ? at - 20 : 0;
  return (
    '${from > 0 ? '…' : ''}${line.substring(from, at)}',
    line.substring(at, at + query.length),
    line.substring(at + query.length),
  );
}
