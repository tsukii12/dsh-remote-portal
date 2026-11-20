import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Header of a detail page (skeleton B): a graphic, the title (two lines at
/// most), one line of status, and two or three figures underneath.
///
/// ```dart
/// AppPage(
///   title: '引擎',                       // shown in the bar once the hero is gone
///   hero: PageHero(
///     leading: EngineRing(...),
///     title: '本机引擎',
///     subtitle: const Text('运行中 · DSH 0.2.1'),
///     stats: const [('2 小时', '已运行'), ('34', '对话'), ('1.2 GB', '占用')],
///   ),
///   slivers: [...],
/// )
/// ```
///
/// Inside [AppPage.hero] it fades out as the page scrolls and the page title
/// moves into the bar; on its own it is a plain header.
///
/// [stats] values are `(value, label)`. A value like `12 分钟` is split into the
/// number (tabular figures) and a smaller, quieter unit.
class PageHero extends StatelessWidget {
  const PageHero({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.stats = const [],
    this.trailing,
    this.titleMaxLines = 2,
    this.padding = const EdgeInsets.fromLTRB(24, 4, 24, 20),
  });

  /// The graphic on the left, 56dp works best (status ring, avatar, icon tile).
  final Widget? leading;
  final String title;

  /// One line under the title: status, version, a short fact.
  final Widget? subtitle;

  /// Two or three `(value, label)` figures under the title row.
  final List<(String value, String label)> stats;

  /// Optional widget at the end of the title row (a status chip, a button).
  final Widget? trailing;
  final int titleMaxLines;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (leading case final leading?) ...[leading, const SizedBox(width: 16)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        maxLines: titleMaxLines,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                    if (subtitle case final subtitle?) ...[
                      const SizedBox(height: 2),
                      DefaultTextStyle.merge(
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary),
                        child: subtitle,
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing case final trailing?) ...[const SizedBox(width: 12), trailing],
            ],
          ),
          if (stats.isNotEmpty) ...[
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, (value, label)) in stats.indexed) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(
                    child: HeroStat(value: value, label: label),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// One figure of a [PageHero]: the value (number in tabular figures, unit
/// smaller and quieter) over a short label.
class HeroStat extends StatelessWidget {
  const HeroStat({super.key, required this.value, required this.label});

  final String value;
  final String label;

  /// `12 分钟`, `1.2 GB`, `85%` → number + unit. The unit must start with a
  /// non-digit, so a bare `34` or `3080` stays whole; nor with `-` / `+`, so a
  /// version like `0.2.1-rc.2` stays whole too.
  static final _numberThenUnit = RegExp(r'^([0-9][0-9.,:]*)(\s*)([^0-9\s.,:+\-].*)$');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final numberStyle = AppType.tabular(theme.textTheme.titleLarge!);
    final unitStyle = theme.textTheme.labelMedium?.copyWith(color: colors.textTertiary, fontWeight: FontWeight.w400);
    final match = _numberThenUnit.firstMatch(value.trim());
    final Widget figure = match == null
        ? Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: numberStyle)
        : Text.rich(
            TextSpan(
              children: [
                TextSpan(text: match.group(1), style: numberStyle),
                // Keep the author's spacing: `2 小时` has a space, `85%` none.
                TextSpan(text: '${match.group(2)}${match.group(3)}', style: unitStyle),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
    return Semantics(
      label: '$label $value',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          figure,
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
          ),
        ],
      ),
    );
  }
}
