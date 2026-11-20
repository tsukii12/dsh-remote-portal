// 检视 (docs/design/roleplay-ui.md §9): what one turn actually sent. Every part
// of the prompt with where it came from and how many tokens it took, the
// lorebook entries that matched and why, what was left out and why, and the
// usage the model reported. Read from the engine's record (Tavern.inspectTurn);
// nothing is assembled again.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_cache_break.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_session_usage.dart';
import '../../tavern/tavern_usage_summary.dart';
import '../bots/bot_format.dart' show shortTime;
import '../common/smooth_size.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_widgets.dart';

class TavernInspectorPage extends ConsumerStatefulWidget {
  const TavernInspectorPage({super.key, required this.chatId, this.nodeId});

  final String chatId;

  /// The reply to look at; null for the chat's latest attempt (failed ones
  /// and 代写 included).
  final String? nodeId;

  static Route<void> route(String chatId, {String? nodeId}) => MaterialPageRoute<void>(
    builder: (_) => TavernInspectorPage(chatId: chatId, nodeId: nodeId),
  );

  @override
  ConsumerState<TavernInspectorPage> createState() => _TavernInspectorPageState();
}

class _TavernInspectorPageState extends ConsumerState<TavernInspectorPage> {
  late final Future<_Records> _records = _read();

  /// This turn's record, the turn before it to see where the cache broke,
  /// and what its requests reported together when it asked more than once
  /// (none when they cannot be found: the page reads the same without them).
  Future<_Records> _read() async {
    final tavern = ref.read(tavernProvider);
    final record = await tavern.inspectTurn(widget.chatId, nodeId: widget.nodeId);
    if (record == null) return (null, null, null);
    TavernUsageSummary? summary;
    if (record.logicalTurnId case final id? when id.isNotEmpty) {
      try {
        summary = switch (await tavern.readToolTurn(id)) {
          final turn? => TavernUsageSummary.fromJson(turn.usageSummary),
          null => null,
        };
      } on Object {
        summary = null;
      }
    }
    if (record.prompt == null) return (record, null, summary);
    try {
      return (record, await tavernPreviousTurn(tavern, record), summary);
    } on Object {
      return (record, null, summary);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FutureBuilder<_Records>(
      future: _records,
      builder: (context, snapshot) {
        final title = l10n.tavernInspectTitle;
        if (snapshot.connectionState != ConnectionState.done) {
          return AppPage.list(title: title, children: const [QuietSpinner()]);
        }
        final (record, previous, summary) = snapshot.data ?? (null, null, null);
        if (snapshot.hasError || record == null) {
          return AppPage.list(
            title: title,
            children: [
              EmptyView(
                key: const ValueKey('tavern-inspect-none'),
                icon: AppIcons.code,
                title: l10n.tavernInspectNone,
                message: l10n.tavernInspectNoneMessage,
              ),
            ],
          );
        }
        return AppPage.list(
          title: title,
          children: [_Body(record: record, previous: previous, summary: summary)],
        );
      },
    );
  }
}

typedef _Records = (TavernTurnInspection?, TavernTurnInspection?, TavernUsageSummary?);

/// A field across the turn's requests: its total when every one reported
/// it, else what was reported and what each request short of it was.
String _usageLine(L10n l10n, String field, TavernUsageSummary summary, TavernUsageField usage) {
  if (usage.complete) return l10n.tavernReqUsageLine(field, usage.known);
  final reported = summary.requests - usage.missing.length - usage.invalid.length - usage.unknown.length;
  return l10n.tavernReqUsageLine(
    field,
    [
      if (reported > 0) l10n.tavernReqUsageKnown(usage.known),
      if (usage.unknown.isNotEmpty) l10n.tavernReqUsageUnknown(usage.unknown.length),
      if (usage.missing.isNotEmpty) l10n.tavernReqUsageMissing(usage.missing.length),
      if (usage.invalid.isNotEmpty) l10n.tavernReqUsageInvalid(usage.invalid.length),
    ].join(l10n.tavernReqUsageJoin),
  );
}

class _Body extends StatelessWidget {
  const _Body({required this.record, this.previous, this.summary});

  final TavernTurnInspection record;

  /// The turn before, to compare prompts with; null when there is none.
  final TavernTurnInspection? previous;

  /// What the turn's requests reported, when it asked the model as a tool
  /// turn (STAGE1-APP-INTEGRATION §7).
  final TavernUsageSummary? summary;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final prompt = record.prompt;
    final segments = prompt?.afterPostProcessing ?? const <PromptSegment>[];
    final before = previous?.prompt?.afterPostProcessing;
    // The first part that differs from the turn before: it and all after it
    // miss DeepSeek's prefix cache.
    final breakAt = before == null ? null : tavernCacheBreak(before, segments);
    final excluded = prompt?.excluded ?? const <PromptExclusion>[];
    final hits = [
      for (final hit in (record.worldInfo['activated'] as List?) ?? const [])
        if (hit is Map) hit,
    ];
    final tokens = segments.fold(0, (sum, s) => sum + s.tokens);
    final usage = record.reportedUsage;
    // What the turn cost, for a DeepSeek model, at the hour it was asked.
    final price = tavernModelPrice(usage?.model);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: l10n.tavernInspectSummary,
          children: [
            SettingsTile(title: l10n.tavernInspectKind, value: Text(_kind(l10n, record.generationType))),
            SettingsTile(
              key: const ValueKey('tavern-inspect-status'),
              title: l10n.tavernInspectStatus,
              subtitle: record.failure == null ? null : [record.failure!.name, ?record.detail].join(' · '),
              value: Text('${_status(l10n, record.status)} · ${shortTime(record.startedAt.toLocal())}'),
            ),
            if (prompt != null) ...[
              SettingsTile(
                key: const ValueKey('tavern-inspect-tokens'),
                title: l10n.tavernInspectPrompt,
                value: Text(prompt.exactTokenCounts ? l10n.tavernTokens(tokens) : l10n.tavernTokensAbout(tokens)),
              ),
              SettingsTile(
                title: l10n.tavernInspectBudget,
                value: Text('${prompt.remainingBudget} / ${prompt.budget}'),
              ),
            ],
            // The numbers under the title, not beside it: beside, a long line
            // of them squeezed the title into a column.
            SettingsTile(
              key: const ValueKey('tavern-inspect-usage'),
              title: l10n.tavernInspectUsage,
              value: switch (summary) {
                final s? when s.requests > 1 => Text(l10n.tavernInspectRequests(s.requests)),
                _ => null,
              },
              subtitle: switch (summary) {
                // Short of some request: no total, only what is known.
                final s? when !s.complete => [
                  _usageLine(l10n, l10n.tavernReqUsagePrompt, s, s.prompt),
                  _usageLine(l10n, l10n.tavernReqUsageCache, s, s.cacheHit),
                  _usageLine(l10n, l10n.tavernReqUsageCompletion, s, s.completion),
                ].join('\n'),
                final s? when usage == null => l10n.tavernInspectUsageTotals(
                  s.prompt.known,
                  s.cacheHit.known,
                  s.completion.known,
                ),
                _ =>
                  usage == null
                      ? l10n.tavernInspectNoUsage
                      : l10n.tavernInspectUsageValue(usage.promptTokens, usage.cacheHitTokens, usage.completionTokens),
              },
            ),
            if (usage != null && price != null)
              SettingsTile(
                key: const ValueKey('tavern-inspect-cost'),
                title: l10n.tavernInspectCost,
                subtitle: tavernDeepSeekPeak(record.startedAt)
                    ? l10n.tavernInspectCostPeak
                    : l10n.tavernInspectCostOffPeak,
                value: Text(tavernCostLabel(l10n, tavernReplyCost(usage, price, record.startedAt))),
              ),
            if (before != null && segments.isNotEmpty)
              SettingsTile(
                key: const ValueKey('tavern-inspect-cache'),
                title: l10n.tavernInspectCache,
                subtitle: breakAt == null ? null : l10n.tavernInspectCacheMiss(tavernTokensFrom(segments, breakAt)),
                value: Text(
                  breakAt == null ? l10n.tavernInspectCacheKept : l10n.tavernInspectCacheBroken(breakAt + 1),
                  style: breakAt == null ? null : TextStyle(color: DshColors.of(context).warning),
                ),
              ),
          ],
        ),
        if (segments.isNotEmpty)
          SettingsSection(
            title: l10n.tavernInspectSegments(segments.length),
            footer: Text(l10n.tavernInspectSegmentsNote),
            children: [
              for (final (i, s) in segments.indexed) TavernPromptSegmentTile(segment: s, breaksCache: i == breakAt),
            ],
          ),
        if (hits.isNotEmpty)
          SettingsSection(
            title: l10n.tavernInspectWorld(hits.length),
            children: [for (final hit in hits) TavernWorldHitTile(hit: hit)],
          ),
        if (excluded.isNotEmpty)
          SettingsSection(
            title: l10n.tavernInspectExcluded(excluded.length),
            children: [
              for (final e in excluded)
                SettingsTile(
                  key: ValueKey('tavern-inspect-excluded-${e.id}'),
                  title: _sources(l10n, e.sources, fallback: e.id),
                  value: Text(_reason(l10n, e.reason)),
                ),
            ],
          ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// One part of the prompt: who says it, where it came from, its tokens; a tap
/// shows the text (long-press copies it).
class TavernPromptSegmentTile extends StatefulWidget {
  const TavernPromptSegmentTile({super.key, required this.segment, this.breaksCache = false});

  final PromptSegment segment;

  /// The first part that differs from the turn before: marked, since the
  /// cache stops here.
  final bool breaksCache;

  @override
  State<TavernPromptSegmentTile> createState() => _TavernPromptSegmentTileState();
}

class _TavernPromptSegmentTileState extends State<TavernPromptSegmentTile> {
  bool _open = false;

  String get _text => switch (widget.segment.message['content']) {
    final String s => s,
    null => '',
    final other => const JsonEncoder.withIndent('  ').convert(other),
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final segment = widget.segment;
    final role = segment.message['role'] as String? ?? '';
    final tile = InkWell(
      key: ValueKey('tavern-inspect-segment-${segment.id}'),
      onTap: () => setState(() => _open = !_open),
      onLongPress: () {
        unawaited(Clipboard.setData(ClipboardData(text: _text)));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.commonCopied)));
      },
      splashFactory: rowSplash(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: SettingsMetrics.inset, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.breaksCache)
              Padding(
                key: const ValueKey('tavern-inspect-cache-break'),
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(AppIcons.warning, size: 14, color: dsh.warning),
                    const SizedBox(width: 6),
                    Text(
                      l10n.tavernInspectCacheBreak,
                      style: theme.textTheme.labelMedium?.copyWith(color: dsh.warning, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                _RoleTag(role: role),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _sources(l10n, segment.sources, fallback: segment.id),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.tavernTokens(segment.tokens),
                  style: AppType.tabular(theme.textTheme.labelMedium!.copyWith(color: dsh.textTertiary)),
                ),
              ],
            ),
            SmoothSize(
              duration: AppMotion.of(context, AppMotion.standard),
              curve: AppMotion.std,
              alignment: Alignment.topCenter,
              child: !_open
                  ? Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _text.replaceAll(RegExp(r'\s+'), ' ').trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                      ),
                    )
                  : Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(AppShape.md),
                      ),
                      child: SelectableText(
                        _text,
                        style: theme.textTheme.bodySmall?.copyWith(height: 1.5, color: theme.colorScheme.onSurface),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
    if (!widget.breaksCache) return tile;
    return ColoredBox(color: dsh.warningContainer.withValues(alpha: 0.45), child: tile);
  }
}

class _RoleTag extends StatelessWidget {
  const _RoleTag({required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (role) {
      'system' => (l10n.tavernRoleSystem, scheme.tertiary),
      'user' => (l10n.tavernRoleUser, scheme.primary),
      'assistant' => (l10n.tavernRoleCharacter, scheme.secondary),
      _ => (role, scheme.outline),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(99)),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
    );
  }
}

/// A lorebook entry that went in: its name, the key that matched, and why.
class TavernWorldHitTile extends StatelessWidget {
  const TavernWorldHitTile({super.key, required this.hit});

  final Map<Object?, Object?> hit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final key = hit['primaryKey'];
    final reason = hit['reason'];
    final content = hit['content'];
    // An entry can be a whole paragraph: its opening words name it here.
    final text = content is String ? content.replaceAll(RegExp(r'\s+'), ' ').trim() : '';
    final name = text.isEmpty
        ? '${hit['bookId']}:${hit['uid']}'
        : text.characters.length > 40
        ? '${text.characters.take(40)}…'
        : text;
    return SettingsTile(
      key: ValueKey('tavern-inspect-world-${hit['bookId']}:${hit['uid']}'),
      title: name,
      subtitle: [
        if (key is String && key.isNotEmpty) l10n.tavernInspectWorldKey(key),
        if (reason is String && reason.isNotEmpty) reason,
      ].join(' · '),
    );
  }
}

String _kind(L10n l10n, String type) => switch (type) {
  'normal' => l10n.tavernTurnSend,
  'regenerate' => l10n.tavernRegenerate,
  'continue' => l10n.tavernContinueReply,
  'impersonate' => l10n.tavernTurnImpersonate,
  _ => type,
};

String _status(L10n l10n, TavernInspectionStatus status) => switch (status) {
  TavernInspectionStatus.preparing => l10n.tavernInspectPreparing,
  TavernInspectionStatus.ready => l10n.tavernInspectReady,
  TavernInspectionStatus.completed => l10n.tavernInspectCompleted,
  TavernInspectionStatus.failed => l10n.tavernInspectFailed,
};

String _reason(L10n l10n, String reason) => switch (reason) {
  'disabled' => l10n.tavernExcludeDisabled,
  'generation-trigger' => l10n.tavernExcludeTrigger,
  'hidden' => l10n.tavernExcludeHidden,
  'is_system' => l10n.tavernExcludeSystem,
  'history-budget' => l10n.tavernExcludeHistoryBudget,
  'whole-example-budget' => l10n.tavernExcludeExampleBudget,
  _ => reason,
};

/// 「预设 · Main Prompt」, 「世界书 · 雨夜旅店」: where a part came from.
String _sources(L10n l10n, List<PromptSource> sources, {required String fallback}) {
  if (sources.isEmpty) return fallback;
  return {
    for (final s in sources)
      [
        switch (s.kind) {
          'preset' => l10n.tavernSourcePreset,
          'card' => l10n.tavernSourceCard,
          'world' || 'worldInfo' => l10n.tavernSourceWorld,
          'persona' => l10n.tavernSourcePersona,
          'history' => l10n.tavernSourceHistory,
          'control' => l10n.tavernSourceControl,
          _ => s.kind,
        },
        if (s.label.isNotEmpty) s.label,
      ].join(' · '),
  }.join(l10n.localeName.startsWith('zh') ? '，' : ', ');
}
