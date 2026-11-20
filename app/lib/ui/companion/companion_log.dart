// 伙伴小屋's backlog: everything said in this room, read like the log of a visual
// novel, over her instead of on another page. Her lines carry her name, the
// person's carry 你, and in full mode what she did on the host shows as a quiet
// line of narration between them. Newest at the bottom; scrolling up reads back,
// and in full mode reaching the top fetches what came before.

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';

import '../../companion/companion_light.dart';
import '../../companion/companion_reply.dart';
import '../../l10n/l10n.dart';
import '../../state/app_notes.dart';
import '../chat/tool_view.dart';
import '../theme/app_icons.dart';
import '../theme/motion.dart';
import '../theme/semantic_colors.dart';
import '../theme/surfaces.dart';
import '../theme/typography.dart';
import 'companion_chrome.dart';

/// Her colour in the log: the pink of her bond pearls.
const companionLogHerTone = Color(0xFFFF9DB5);

/// The person's colour in the log: the light water blue of the room's pills.
const companionLogYouTone = Color(0xFF9FD8F2);

/// One line of the log.
@immutable
class CompanionLogEntry {
  const CompanionLogEntry.her(this.text, {this.who, this.tone}) : speaker = CompanionLogSpeaker.her, code = false;
  const CompanionLogEntry.you(this.text) : speaker = CompanionLogSpeaker.you, code = false, who = null, tone = null;

  /// What she did, not said: [text] is the verb and what it was done to.
  const CompanionLogEntry.did(this.text, {this.code = false})
    : speaker = CompanionLogSpeaker.narration,
      who = null,
      tone = null;

  final CompanionLogSpeaker speaker;
  final String text;

  /// Narration whose subject is a command or a path (set in monospace).
  final bool code;

  /// Who says a line of hers when it is someone other than [CompanionLog.name]
  /// (the tavern: one of a group, the narrator), and their colour; null: her.
  final String? who;
  final Color? tone;

  @override
  bool operator ==(Object other) =>
      other is CompanionLogEntry &&
      other.speaker == speaker &&
      other.text == text &&
      other.code == code &&
      other.who == who &&
      other.tone == tone;

  @override
  int get hashCode => Object.hash(speaker, text, code, who, tone);

  @override
  String toString() => '${speaker.name}: $text';
}

enum CompanionLogSpeaker { her, you, narration }

/// The log of a light conversation, kept on this phone. Her marks are taken
/// out; so is the aside the page put in front of the person's lines.
/// [speaking]: what she is saying right now, still arriving.
List<CompanionLogEntry> companionLogFromLight(
  List<CompanionLine> lines, {
  Map<String, String> emotions = const {},
  Map<String, String> actions = const {},
  String? speaking,
}) => [
  for (final line in lines)
    if (line.fromHer)
      ?_her(line.text, emotions, actions)
    else if (companionSaidText(line.text) case final said when said.isNotEmpty)
      CompanionLogEntry.you(said),
  if (speaking != null) ?_her(speaking, emotions, actions, streaming: true),
];

/// The log of her full-mode session: what the person said, what she said, and
/// what she used on the host in between.
List<CompanionLogEntry> companionLogFromChat(
  List<ChatItem> items, {
  Map<String, String> emotions = const {},
  Map<String, String> actions = const {},
}) {
  // Items don't change once made (an update is a new item), so what one reads
  // as is kept with it; her labels changing starts over.
  final labels = Object.hash(
    appL10n.localeName,
    Object.hashAllUnordered(emotions.entries.map((e) => (e.key, e.value))),
    Object.hashAllUnordered(actions.entries.map((e) => (e.key, e.value))),
  );
  if (labels != _readLabels) {
    _read = Expando();
    _readLabels = labels;
  }
  final out = <CompanionLogEntry>[];
  for (final item in items) {
    final kept = _read[item] ??= [?_entryOf(item, emotions, actions)];
    out.addAll(kept);
  }
  return out;
}

Expando<List<CompanionLogEntry>> _read = Expando();
int? _readLabels;

CompanionLogEntry? _entryOf(ChatItem item, Map<String, String> emotions, Map<String, String> actions) {
  switch (item) {
    case UserChatItem(:final text):
      final said = companionSaidText(withoutAppNotes(text));
      return said.isEmpty ? null : CompanionLogEntry.you(said);
    case AssistantChatItem(:final text, :final streaming):
      return _her(text, emotions, actions, streaming: streaming);
    case ToolChatItem():
      final view = ToolView.of(item);
      final subject = view.summary.trim();
      return CompanionLogEntry.did(
        subject.isEmpty ? view.verb : '${view.verb}  $subject',
        code: subject.isNotEmpty && view.summaryIsCode,
      );
    default:
      return null;
  }
}

CompanionLogEntry? _her(
  String text,
  Map<String, String> emotions,
  Map<String, String> actions, {
  bool streaming = false,
}) {
  final words = parseCompanionReply(text, streaming: streaming, emotions: emotions, actions: actions).words;
  return words.isEmpty ? null : CompanionLogEntry.her(words);
}

/// The backlog over the room. [onLoadOlder] is there while there is more to
/// fetch (full mode), and [history] counts what has been fetched (every item,
/// shown or not), so a fetch that brought nothing can be told from one that
/// brought only what the log leaves out. [onOpenChat] when the conversation
/// also lives in the main chat, for its tool details.
class CompanionLog extends StatefulWidget {
  const CompanionLog({
    super.key,
    required this.entries,
    required this.name,
    required this.onClose,
    this.onLoadOlder,
    this.loadingOlder = false,
    this.history = 0,
    this.onOpenChat,
    this.scrim,
    this.herTone = companionLogHerTone,
    this.youTone = companionLogYouTone,
  });

  final List<CompanionLogEntry> entries;

  /// The veil over the stage, top to bottom; null: 伙伴小屋's night blue.
  /// A page with its own look (the tavern's 视觉小说) passes its colours.
  final List<Color>? scrim;

  /// The speakers' name colours.
  final Color herTone;
  final Color youTone;

  /// Her name, over her lines.
  final String name;
  final VoidCallback onClose;
  final Future<void> Function()? onLoadOlder;
  final bool loadingOlder;
  final int history;
  final VoidCallback? onOpenChat;

  @override
  State<CompanionLog> createState() => _CompanionLogState();
}

class _CompanionLogState extends State<CompanionLog> {
  final _scroll = ScrollController();

  /// The last fetch brought nothing (it failed): no more on its own.
  bool _stalled = false;

  /// A fetch is out: one at a time, over when its future is.
  bool _fetching = false;

  Future<void> _load() async {
    final load = widget.onLoadOlder;
    if (load == null || widget.loadingOlder || _fetching) return;
    _fetching = true;
    final before = widget.history;
    try {
      await load();
      // What it brought reaches this widget with the next build.
      await WidgetsBinding.instance.endOfFrame;
    } on Object {
      // Counted below as bringing nothing.
    }
    if (!mounted) return;
    _fetching = false;
    if (widget.history <= before) {
      setState(() => _stalled = true);
    } else {
      // Brought something, maybe nothing the log shows: on to the next page.
      WidgetsBinding.instance.addPostFrameCallback((_) => _fillUp());
    }
  }

  void _retry() {
    setState(() => _stalled = false);
    unawaited(_load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Near the top (the end of a reversed list): fetch what came before.
  bool _onScroll(ScrollNotification notification) {
    if (!_stalled && notification.metrics.extentAfter < 240) unawaited(_load());
    return false;
  }

  /// A log too short to scroll never scrolls near its top: look after layout.
  /// One with nothing to show yet has no list at all: fetch on.
  void _fillUp() {
    if (!mounted || _stalled) return;
    if (widget.entries.isEmpty || (_scroll.hasClients && _scroll.position.extentAfter < 240)) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final padding = MediaQuery.paddingOf(context);
    final blur = DshSurfaces.of(context).blurEnabled;
    final entries = widget.entries;
    final older = widget.onLoadOlder != null || widget.loadingOlder;
    if (widget.onLoadOlder != null && !widget.loadingOlder && !_stalled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fillUp());
    }

    final list = entries.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: older && !_stalled
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          l10n.companionLogEmpty,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(color: colors.textTertiary),
                        ),
                        if (older) TextButton(onPressed: _retry, child: Text(l10n.companionLogOlder)),
                      ],
                    ),
            ),
          )
        : NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.06, 1],
                colors: [Color(0x00FFFFFF), Color(0xFFFFFFFF), Color(0xFFFFFFFF)],
              ).createShader(rect),
              child: ListView.builder(
                controller: _scroll,
                reverse: true,
                padding: EdgeInsets.fromLTRB(28, 20, 28, padding.bottom + 28),
                itemCount: entries.length + (older ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == entries.length) {
                    if (_stalled && !widget.loadingOlder) {
                      return Center(
                        child: TextButton(onPressed: _retry, child: Text(l10n.companionLogOlder)),
                      );
                    }
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                    );
                  }
                  final at = entries.length - 1 - index;
                  final entry = entries[at];
                  final before = at > 0 ? entries[at - 1] : null;
                  return _LogLine(
                    entry: entry,
                    name: widget.name,
                    herTone: widget.herTone,
                    youTone: widget.youTone,
                    // A speaker's name only where the speaker changes.
                    named: before == null || before.speaker != entry.speaker || before.who != entry.who,
                    first: before == null,
                  );
                },
              ),
            ),
          );

    return Listener(
      // Nothing reaches her stage underneath while the log is open.
      behavior: HitTestBehavior.opaque,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (blur) BackdropFilter(filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: const SizedBox.expand()),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors:
                    widget.scrim ??
                    (blur
                        ? const [Color(0xD90A1B2C), Color(0xEB071524)]
                        : const [Color(0xF20A1B2C), Color(0xFA071524)]),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(28, padding.top + 8, companionEdge, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          l10n.companionLogTitle,
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    if (widget.onOpenChat case final open?)
                      TextButton(
                        onPressed: open,
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.onSurfaceVariant,
                          shape: const StadiumBorder(),
                        ),
                        child: Text(l10n.companionLogOpenChat),
                      ),
                    const SizedBox(width: 6),
                    CompanionRoundButton(
                      icon: AppIcons.close,
                      label: MaterialLocalizations.of(context).closeButtonTooltip,
                      onTap: widget.onClose,
                    ),
                  ],
                ),
              ),
              Expanded(child: list),
            ],
          ),
        ],
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({
    required this.entry,
    required this.name,
    required this.named,
    required this.first,
    this.herTone = companionLogHerTone,
    this.youTone = companionLogYouTone,
  });

  final CompanionLogEntry entry;
  final String name;
  final Color herTone;
  final Color youTone;
  final bool named;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final gap = first ? 0.0 : (named ? 22.0 : 10.0);
    if (entry.speaker == CompanionLogSpeaker.narration) {
      final style = entry.code
          ? AppType.monoSmall(color: colors.textTertiary)
          : theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary);
      return Padding(
        padding: EdgeInsets.only(top: first ? 0 : 10),
        child: Row(
          children: [
            Container(width: 14, height: 1, color: colors.textTertiary.withValues(alpha: 0.5)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(entry.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
            ),
          ],
        ),
      );
    }
    final her = entry.speaker == CompanionLogSpeaker.her;
    final who = her ? (entry.who ?? name) : l10n.companionLogYou;
    final tone = her ? (entry.tone ?? herTone) : youTone;
    return Padding(
      padding: EdgeInsets.only(top: gap),
      child: Semantics(
        label: '$who：${entry.text}',
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (named)
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Text(
                  who,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: tone,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            SelectableText(
              entry.text,
              style: theme.textTheme.bodyLarge?.copyWith(
                height: 1.65,
                color: her ? theme.colorScheme.onSurface : theme.colorScheme.onSurface.withValues(alpha: 0.78),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The log rising over the room, and sinking away again.
class CompanionLogTransition extends StatelessWidget {
  const CompanionLogTransition({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: AppMotion.of(context, AppMotion.standard),
    switchInCurve: AppMotion.enter,
    switchOutCurve: AppMotion.exit,
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.025), end: Offset.zero).animate(animation),
        child: child,
      ),
    ),
    child: child ?? const SizedBox.shrink(key: ValueKey('no-log')),
  );
}
