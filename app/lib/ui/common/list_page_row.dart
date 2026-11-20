// The one row anatomy of the list pages (automation, background jobs, skills,
// the phone app list and action log).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../settings/index/spot_anchor.dart' show anchorSpot;
import '../settings/index/spots.dart' show SettingSpot;
import '../theme/theme.dart';
import 'app_sheet.dart' show groupTitleStyle;
import 'overview_card.dart' show OverviewChevron;

/// 列表页的行:
///
/// ```
/// │ ◌  主标题(一行)                 元信息 › │
/// │    副标题(一行)                          │
/// ```
///
/// - 左边 32 宽的图形位:默认 20 号线性图标、次要色,**不带底色**;也可以
///   放状态点、头像这类自定义图形([leading]);
/// - 单行最低 52、两行最低 64;左右可见内容离卡片边都是 16;
/// - 右侧放元信息文字([meta])或任意组件([trailing]),最后是可选的 ›。
class ListPageRow extends StatelessWidget {
  const ListPageRow({
    super.key,
    this.icon,
    this.leading,
    this.leadingWidth = glyphSlot,
    this.title,
    this.spot,
    this.titleStyle,
    this.titleNote,
    this.titleMaxLines = 1,
    this.subtitle,
    this.subtitleColor,
    this.subtitleMaxLines = 1,
    this.badge,
    this.value,
    this.meta,
    this.metaColor,
    this.trailing,
    this.trailingSemanticLabel,
    this.onTap,
    this.chevron,
    this.danger = false,
    this.iconColor,
  }) : assert(title != null || spot != null);

  final IconData? icon;

  /// Custom glyph (status dot, avatar); wins over [icon].
  final Widget? leading;

  /// Width of the glyph slot: 32, or 40 for app-style icons (plugins).
  final double leadingWidth;

  /// Defaults to [spot]'s title.
  final String? title;

  /// The row in the settings index (its anchor and, unless [title] says
  /// otherwise, its title).
  final SettingSpot? spot;

  /// Replaces the title style (monospace command lines).
  final TextStyle? titleStyle;

  /// A few words after the title, in the tertiary colour and cut first when
  /// the line is short (a search result's matching synonym).
  final String? titleNote;
  final int titleMaxLines;
  final String? subtitle;
  final Color? subtitleColor;
  final int subtitleMaxLines;

  /// Small widget right after the title (a tag).
  final Widget? badge;

  /// Right-aligned current value (a setting, a fact): body size, secondary
  /// colour.
  final String? value;

  /// Right-aligned secondary text (a time, a count): small, tertiary.
  final String? meta;
  final Color? metaColor;
  final Widget? trailing;

  /// Names a separate trailing control without merging it with the row action.
  final String? trailingSemanticLabel;
  final VoidCallback? onTap;

  /// Defaults to "has [onTap] and no [trailing]".
  final bool? chevron;
  final bool danger;
  final Color? iconColor;

  static const glyphSlot = 32.0;
  static const gap = 12.0;
  static const horizontal = 16.0;

  /// Right padding of a row ending in a switch or chevron: the switch's track
  /// and the chevron's ink both end [horizontal] in, like a value or a capsule.
  static const trailingPad = 12.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final showChevron = chevron ?? (onTap != null && trailing == null);
    final two = subtitle != null && subtitle!.isNotEmpty;
    final glyph =
        leading ??
        (icon == null
            ? null
            : Icon(icon, size: 20, color: iconColor ?? (danger ? colors.danger : scheme.onSurfaceVariant)));
    final resolvedTitle = title ?? spot!.title(context.l10n);
    final resolvedTitleStyle =
        titleStyle ??
        theme.textTheme.bodyLarge?.copyWith(
          fontSize: 15,
          height: 1.4,
          color: danger ? colors.danger : scheme.onSurface,
        );
    final note = titleNote;
    final titleText = note == null || note.isEmpty
        ? Text(resolvedTitle, maxLines: titleMaxLines, overflow: TextOverflow.ellipsis, style: resolvedTitleStyle)
        : Text.rich(
            TextSpan(
              text: resolvedTitle,
              children: [
                TextSpan(
                  text: ' · $note',
                  style: TextStyle(color: colors.textTertiary),
                ),
              ],
            ),
            maxLines: titleMaxLines,
            overflow: TextOverflow.ellipsis,
            style: resolvedTitleStyle,
          );
    Widget row(double maxValueWidth) => InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: two ? 64 : 52),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            horizontal,
            10,
            showChevron || trailing is Switch ? trailingPad : horizontal,
            10,
          ),
          child: Row(
            children: [
              if (glyph != null) ...[
                SizedBox(
                  width: leadingWidth,
                  child: Center(child: glyph),
                ),
                const SizedBox(width: gap),
              ],
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
                    if (two) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: subtitleMaxLines,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: subtitleColor ?? colors.textTertiary),
                      ),
                    ],
                  ],
                ),
              ),
              if (value case final value? when value.isNotEmpty) ...[
                const SizedBox(width: 12),
                // At most 45% of the row: a long value wraps instead of
                // squeezing the title; a short one hugs the right edge.
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxValueWidth),
                  child: Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: AppType.tabular(theme.textTheme.bodyMedium!.copyWith(color: scheme.onSurfaceVariant)),
                  ),
                ),
              ],
              if (meta case final meta? when meta.isNotEmpty) ...[
                const SizedBox(width: 12),
                Text(
                  meta,
                  style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: metaColor ?? colors.textTertiary)),
                ),
              ],
              if (trailing case final trailing?) ...[
                const SizedBox(width: 12),
                SwitchTheme(
                  data: SwitchTheme.of(context).copyWith(materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  child: trailingSemanticLabel == null
                      ? trailing
                      : Semantics(label: trailingSemanticLabel, child: trailing),
                ),
              ],
              if (showChevron) ...[const SizedBox(width: 4), const OverviewChevron()],
            ],
          ),
        ),
      ),
    );
    // Only rows with a value need their width (a LayoutBuilder can't report
    // intrinsics, which dialogs ask for).
    if (value == null || value!.isEmpty) return anchorSpot(spot, row(double.infinity));
    return anchorSpot(spot, LayoutBuilder(builder: (context, c) => row(c.maxWidth * 0.45)));
  }
}

/// A card of [ListPageRow]s: card-tier glass, radius 20, rows touching (no
/// dividers), 4 above and below.
class ListPageCard extends StatelessWidget {
  const ListPageCard({
    super.key,
    required this.children,
    this.title,
    this.spot,
    this.margin = const EdgeInsets.fromLTRB(16, 0, 16, 0),
  });

  final List<Widget> children;

  /// The card as one place in the settings index (a group of choices): its
  /// rows are where a search result lands.
  final SettingSpot? spot;

  /// Small faint group title above the card.
  final String? title;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title case final title?)
            Padding(
              // Like SheetGroup: 8 in from the card, on the page's 24 column.
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Semantics(header: true, child: Text(title, style: groupTitleStyle(context))),
            ),
          GlassSurface(
            tier: GlassTier.card,
            borderRadius: AppShape.radiusLg,
            child: Material(
              type: MaterialType.transparency,
              clipBehavior: Clip.antiAlias,
              shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: anchorSpot(
                  spot,
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: children,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
