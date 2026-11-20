// One shell for every card in the message stream (approval, question, changed
// files, delivered files), so they read as one family
// (docs/design/page-design.md §4: card radius 20, no rules between rows, 4-grid).

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

/// 卡片的语气:决定标题图标的颜色和外圈细线。
enum ChatCardTone {
  /// 改动卡、产物卡:中性,标题图标次级色。
  neutral,

  /// 审批卡:等你放行。警示色图标 + 警示色细线,醒目但不靠大色块。
  attention,

  /// 提问卡:等你回答。信息色图标 + 信息色细线。
  ask,
}

/// 消息流里的卡片:**同一套解剖**。
///
/// ```
/// ┌──────────────────────────────────┐  card 玻璃,圆角 20
/// │ ▢ 标题                      尾注 │  上 16,图标 20 + 8 + titleSmall
/// │                                  │  标题下 8
/// │ 内容(行之间不画线,靠行高)       │  左右 16
/// │ 底栏 / 按钮                      │
/// └──────────────────────────────────┘
/// ```
///
/// [children] 自己管左右 16 与行高;整行可点的行(文件、产物、底栏)直接
/// 用 `InkWell` 铺满卡宽,水波按卡片圆角裁剪。
class ChatCard extends StatelessWidget {
  const ChatCard({
    super.key,
    required this.icon,
    required this.title,
    required this.children,
    this.trailing,
    this.tone = ChatCardTone.neutral,
    this.titleMaxLines = 1,
  });

  final IconData icon;
  final String title;
  final Widget? trailing;
  final ChatCardTone tone;
  final List<Widget> children;
  final int titleMaxLines;

  /// 卡片四周与标题行的留白。
  static const inset = 16.0;

  /// 语气色(标题图标、外圈细线)。
  static Color toneColor(BuildContext context, ChatCardTone tone) {
    final dsh = DshColors.of(context);
    return switch (tone) {
      ChatCardTone.neutral => Theme.of(context).colorScheme.onSurfaceVariant,
      ChatCardTone.attention => dsh.warning,
      ChatCardTone.ask => dsh.info,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaces = DshSurfaces.of(context);
    final accent = toneColor(context, tone);
    final style = tone == ChatCardTone.neutral
        ? null
        : surfaces.card.copyWith(hairline: accent.withValues(alpha: 0.45), hairlineWidth: 1);

    return GlassSurface(
      tier: GlassTier.card,
      borderRadius: AppShape.radiusLg,
      style: style,
      child: Material(
        type: MaterialType.transparency,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(inset, inset, inset, 8),
              child: Row(
                crossAxisAlignment: titleMaxLines > 1 ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                children: [
                  Icon(icon, size: 20, color: accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: titleMaxLines,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(height: 1.43),
                    ),
                  ),
                  if (trailing case final t?) ...[const SizedBox(width: 8), t],
                ],
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// 卡片的底栏:整行可点,左边主色文字,右边可选的说明 + 箭头。44 高。
class ChatCardFooter extends StatelessWidget {
  const ChatCardFooter({
    super.key,
    required this.label,
    required this.onTap,
    this.meta,
    this.icon = AppIcons.disclosure,
    this.semanticsLabel,
    this.expanded,
    this.iconTurns = 0,
  });

  final String label;
  final VoidCallback onTap;
  final String? meta;
  final IconData icon;
  final String? semanticsLabel;

  /// 展开 / 收起类的底栏传当前状态。
  final bool? expanded;

  /// 图标的旋转(展开类底栏:收起 0,展开 0.5),变化时平滑转过去。
  final double iconTurns;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    return Semantics(
      button: true,
      expanded: expanded,
      label: semanticsLabel ?? label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(ChatCard.inset, 4, ChatCard.inset - 4, 4),
            child: Row(
              children: [
                Text(label, style: theme.textTheme.labelLarge?.copyWith(color: colors.primary)),
                const Spacer(),
                if (meta case final m?) ...[
                  Text(m, style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary)),
                  const SizedBox(width: 4),
                ],
                AnimatedRotation(
                  turns: iconTurns,
                  duration: AppMotion.of(context, AppMotion.collapse),
                  curve: AppMotion.collapseCurve,
                  child: Icon(icon, size: 20, color: dsh.textTertiary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
