// The shared pieces of the multi-agent pages: agent
// avatars, the state chip, and the lineage tree used by the conversation
// details' 子代理 tab and the header's lineage sheet.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/agents_state.dart';
import '../chat/run_info.dart' show formatSpan;
import '../chat/widgets/live_clock.dart';
import '../common/fade_in.dart';
import '../common/list_page_row.dart';
import '../common/overview_card.dart' show OverviewChevron;
import '../common/status_chip.dart';
import '../fx/bot_avatar/bot_avatar.dart' as fx;
import '../theme/theme.dart';

StatusTone agentTone(AgentRunState state) => switch (state) {
  AgentRunState.running => StatusTone.busy,
  AgentRunState.completed => StatusTone.ok,
  AgentRunState.failed => StatusTone.error,
  AgentRunState.idle => StatusTone.idle,
};

/// 智能体的头像:按名字固定一只 Libraries.dev 小机器人(形状、颜色跟主题色),
/// 运行中会跳动干活,其余时候是一帧静止画面。「+3」这种余数仍是一个圆里写字。
class AgentAvatar extends StatelessWidget {
  const AgentAvatar(this.name, {super.key, this.size = 28, this.ring, this.working = false});

  final String name;
  final double size;

  /// A ring in the surface colour (overlapping avatars in a stack): the bot
  /// then sits on a disc of it, so the stack still reads as separate faces.
  final Color? ring;

  /// The agent is running: the bot hops while it works.
  final bool working;

  static String letterOf(String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final disc = ring;
    if (name.startsWith('+')) return _LetterAvatar(name, size: size, ring: disc);
    final bot = fx.BotAvatar(
      id: name.trim(),
      size: disc == null ? size : size * 0.82,
      state: working ? fx.BotAvatarState.working : fx.BotAvatarState.idle,
      // Glossy plastic: drawn on the first frame; plush fur bakes in the background.
      shading: fx.BotAvatarShading.plastic,
      excludeFromSemantics: true,
    );
    if (disc == null) return bot;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: ShapeDecoration(color: disc, shape: const CircleBorder()),
      child: bot,
    );
  }
}

/// 余数「+3」:中性色圆 + 字。
class _LetterAvatar extends StatelessWidget {
  const _LetterAvatar(this.text, {required this.size, this.ring});

  final String text;
  final double size;
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final fill = dark
        ? Color.alphaBlend(Colors.white.withValues(alpha: 0.12), theme.colorScheme.surface)
        : Color.alphaBlend(theme.colorScheme.onSurface.withValues(alpha: 0.07), theme.colorScheme.surface);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: fill,
          shape: CircleBorder(side: ring == null ? BorderSide.none : BorderSide(color: ring!, width: 2)),
        ),
        child: Text(
          text,
          textScaler: TextScaler.noScaling,
          style: theme.textTheme.titleMedium?.copyWith(
            fontSize: size * 0.42,
            height: 1,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 一行的副标题:模式 · 用时 · 下级。运行中的用时每秒走。
class _NodeSubtitle extends StatelessWidget {
  const _NodeSubtitle({required this.node});

  final SubagentNode node;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary);
    String line(Duration? elapsed) => [
      subagentModeLabel(node.mode),
      if (elapsed != null && elapsed > Duration.zero) formatSpan(elapsed),
      if (node.children.isNotEmpty) l10n.botsChildCount(node.children.length),
    ].join(' · ');
    Widget text(String value) =>
        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: style == null ? null : AppType.tabular(style));
    final timing = node.timing;
    final since = timing?.activeSince;
    if (node.running && since != null) {
      return LiveElapsed(
        since: since,
        builder: (context, elapsed) => text(line(timing!.settled + (elapsed ?? Duration.zero))),
      );
    }
    return text(line(timing?.total));
  }
}

/// 一个智能体的一行(谱系和团队成员共用):左头像、标题(可带小标签)、
/// 副标题,右边状态胶囊和 ›;不能点的行在 › 的位置留白,胶囊仍在一列。
class AgentRow extends StatelessWidget {
  const AgentRow({
    super.key,
    required this.name,
    required this.title,
    required this.subtitle,
    required this.tone,
    required this.stateLabel,
    this.badge,
    this.depth = 0,
    this.onTap,
  });

  /// Whose initial the avatar shows.
  final String name;
  final String title;
  final Widget subtitle;
  final StatusTone tone;
  final String stateLabel;

  /// Small widget right after the title (「当前」).
  final Widget? badge;

  /// Tree level: each one indents by [indent].
  final int depth;
  final VoidCallback? onTap;

  /// Indent per level: the avatar column of the level above.
  static const indent = 20.0;

  /// The › column (4 + glyph 20, as in [ListPageRow]); kept on rows without
  /// one so every status chip ends on the same edge.
  static const chevronSlot = 24.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.4, color: theme.colorScheme.onSurface),
    );
    return Semantics(
      button: onTap != null,
      label: l10n.botsAgentSemantics(title, stateLabel),
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: EdgeInsets.fromLTRB(ListPageRow.horizontal + depth * indent, 10, ListPageRow.trailingPad, 10),
            child: Row(
              children: [
                SizedBox(
                  width: ListPageRow.glyphSlot,
                  child: Center(child: AgentAvatar(name, working: tone == StatusTone.busy)),
                ),
                const SizedBox(width: ListPageRow.gap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (badge case final badge?)
                        Row(
                          children: [
                            Flexible(child: titleText),
                            const SizedBox(width: 8),
                            badge,
                          ],
                        )
                      else
                        titleText,
                      const SizedBox(height: 2),
                      DefaultTextStyle.merge(
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                        child: subtitle,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                StatusChip(tone: tone, label: stateLabel),
                SizedBox(
                  width: chevronSlot,
                  child: onTap == null ? null : const Align(alignment: Alignment.centerRight, child: OverviewChevron()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 谱系里的一行:缩进表示层级。
class SubagentRow extends StatelessWidget {
  const SubagentRow({super.key, required this.node, this.depth = 0, this.current = false, this.onOpen});

  final SubagentNode node;
  final int depth;

  /// The conversation on screen (no ›, says so).
  final bool current;
  final ValueChanged<SubagentNode>? onOpen;

  static const indent = AgentRow.indent;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tappable = node.openable && !current && onOpen != null;
    return AgentRow(
      name: node.label,
      title: node.label,
      subtitle: current ? Text(l10n.botsCurrentChat) : _NodeSubtitle(node: node),
      tone: agentTone(node.state),
      stateLabel: node.state.label,
      depth: depth,
      onTap: tappable ? () => onOpen!(node) : null,
    );
  }
}

/// 一棵谱系:直接下级在前,下级的下级缩进跟在各自下面(都展开;默认委派深度
/// 只有一层,深树很少见)。
class SubagentTreeCard extends StatelessWidget {
  const SubagentTreeCard({
    super.key,
    required this.nodes,
    this.title,
    this.currentId,
    this.onOpen,
    this.margin = const EdgeInsets.fromLTRB(16, 0, 16, 0),
  });

  final List<SubagentNode> nodes;
  final String? title;
  final String? currentId;
  final ValueChanged<SubagentNode>? onOpen;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    void add(SubagentNode node, int depth) {
      rows.add(
        FadeSlideIn(
          index: rows.length,
          child: SubagentRow(node: node, depth: depth, current: node.id == currentId, onOpen: onOpen),
        ),
      );
      for (final child in node.children) {
        add(child, depth + 1);
      }
    }

    for (final node in nodes) {
      add(node, 0);
    }
    return ListPageCard(title: title, margin: margin, children: rows);
  }
}

/// 「3 个子代理」「其中 1 个运行中」。
String lineageTitle(List<SubagentNode> nodes) => appL10n.botsSubagentCount(nodes.length);

String? lineageSubtitle(List<SubagentNode> nodes) {
  final all = nodes.expand((n) => n.flattened).toList();
  final running = all.where((n) => n.running).length;
  final failed = all.where((n) => n.state == AgentRunState.failed).length;
  final nested = all.length - nodes.length;
  final parts = [
    if (running > 0) appL10n.botsRunningCount(running),
    if (failed > 0) appL10n.botsFailedCount(failed),
    if (nested > 0) appL10n.botsNestedCount(nested),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// The tree's header facts as a quiet one-liner with a state dot.
class LineageSummary extends StatelessWidget {
  const LineageSummary({super.key, required this.nodes});

  final List<SubagentNode> nodes;

  @override
  Widget build(BuildContext context) {
    final text = lineageSubtitle(nodes);
    if (text == null) return const SizedBox.shrink();
    final all = nodes.expand((n) => n.flattened);
    final tone = all.any((n) => n.running)
        ? StatusTone.busy
        : all.any((n) => n.state == AgentRunState.failed)
        ? StatusTone.error
        : StatusTone.ok;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusDot(tone: tone, size: 6),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
          ),
        ),
      ],
    );
  }
}
