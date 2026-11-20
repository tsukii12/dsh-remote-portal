// The rows of the engine settings forms: one anatomy shared by switches,
// capsules, values with a sheet behind them and read-only facts, measured
// like the app's settings rows (lib/ui/settings/settings_widgets.dart).

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../common/overview_card.dart' show OverviewChevron;
import '../common/segmented_pill.dart';
import '../settings/settings_widgets.dart' show SettingsLineIcon, SettingsMetrics, settingsTitleStyle;
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// 「已修改」: a quiet tag after a title whose value is the user's own.
class FieldBadge extends StatelessWidget {
  const FieldBadge(this.text, {super.key});

  final String text;

  /// Side padding around the text.
  static const padding = 6.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: dark ? Colors.white.withValues(alpha: 0.09) : scheme.onSurface.withValues(alpha: 0.06),
        shape: Squircle.border(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: padding, vertical: 1),
        child: Text(text, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
      ),
    );
  }
}

/// Title (+ tag) over an optional second line, as every field row starts.
class FieldHeading extends StatelessWidget {
  const FieldHeading({
    super.key,
    required this.title,
    this.subtitle,
    this.badge,
    this.subtitleColor,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final Widget? badge;
  final Color? subtitleColor;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final titleText = Text(
      title,
      style: settingsTitleStyle(context)?.copyWith(color: enabled ? scheme.onSurface : colors.textTertiary),
    );
    return Column(
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
        if (subtitle case final sub? when sub.isNotEmpty) ...[
          const SizedBox(height: 1),
          Text(sub, style: theme.textTheme.bodySmall?.copyWith(color: subtitleColor ?? colors.textTertiary)),
        ],
      ],
    );
  }
}

/// One field row:
///
/// ```
/// |16| (32) |12| 标题 [已修改] / 副标题 ……… 值 |4| › |12|
/// |16| 标题 ………………………………………………… [ 开关 ] |12|
/// |16| 标题 ………………………………………………………… 值 |16|
/// ```
///
/// 52 tall with one line, 64 with two; the whole row is the tap target.
class EngineFieldRow extends StatelessWidget {
  const EngineFieldRow({
    super.key,
    required this.title,
    this.icon,
    this.subtitle,
    this.subtitleColor,
    this.badge,
    this.value,
    this.valueColor,
    this.trailing,
    this.onTap,
    this.chevron,
    this.enabled = true,
    this.semanticsLabel,
    this.expanded,
    this.opensExternally = false,
  });

  final String title;
  final IconData? icon;
  final String? subtitle;
  final Color? subtitleColor;
  final Widget? badge;

  /// Right-aligned current value (secondary colour, tabular figures).
  final String? value;
  final Color? valueColor;

  /// Replaces the chevron (a switch).
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Defaults to "has [onTap] and no [trailing]".
  final bool? chevron;
  final bool enabled;
  final String? semanticsLabel;

  /// Set on a row that opens in place (a collapse group's header): its
  /// chevron turns down while open.
  final bool? expanded;

  /// A row that leaves the app (to the web): the open-external glyph in the
  /// chevron's place.
  final bool opensExternally;

  /// The share of the text's width (title, gap and value) a value keeps when
  /// the title needs the line: the title gets the rest, so a long title
  /// breaks between words, never inside one, and the value is cut.
  static const valueShare = 0.4;
  static const valueGap = 12.0;

  /// The least share a value keeps so a long title word fits whole.
  static const valueFloor = 0.25;

  /// How wide the value may be in [width] of text: [valueShare] of it, or
  /// whatever the title's one line leaves when that is more (a short title
  /// beside a long value) — but no more than lets the title's longest word
  /// fit, down to [valueFloor] (very large text).
  double valueRoom(BuildContext context, double width) {
    final scaler = MediaQuery.textScalerOf(context);
    final base = DefaultTextStyle.of(context).style;
    double measure(String text, TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: base.merge(style)),
        textScaler: scaler,
        textDirection: Directionality.of(context),
        maxLines: 1,
      )..layout();
      final measured = painter.width;
      painter.dispose();
      return measured;
    }

    final style = settingsTitleStyle(context);
    // The 已修改 tag sits beside the title's last line, in its room.
    final tag = switch (badge) {
      null => 0.0,
      final FieldBadge badge =>
        8 + measure(badge.text, Theme.of(context).textTheme.labelSmall) + 2 * FieldBadge.padding,
      _ => 8 + FieldSegmentRow.badgeRoom,
    };
    final line = (measure(title, style) + tag).ceilToDouble();
    // Latin words: Chinese titles may break between any two characters.
    final word = (_latinWord.allMatches(title).map((match) => measure(match[0]!, style)).fold(0.0, math.max) + tag)
        .ceilToDouble();
    final room = math.max(width * valueShare, width - valueGap - line);
    return math.min(room, math.max(width - valueGap - word, width * valueFloor));
  }

  static final _latinWord = RegExp(r'[A-Za-z0-9À-ɏ]+');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final expanded = this.expanded;
    final showChevron = enabled && (chevron ?? (onTap != null && trailing == null));
    final endsInGlyph = showChevron || trailing != null;
    final two = subtitle != null && subtitle!.isNotEmpty;
    final heading = FieldHeading(
      title: title,
      subtitle: subtitle,
      subtitleColor: subtitleColor,
      badge: badge,
      enabled: enabled,
    );
    final row = InkWell(
      onTap: enabled ? onTap : null,
      splashFactory: rowSplash(context),
      highlightColor: scheme.onSurface.withValues(alpha: 0.05),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: two ? SettingsMetrics.rowHeightTwoLine : SettingsMetrics.rowHeight),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            SettingsMetrics.inset,
            6,
            endsInGlyph ? SettingsMetrics.trailingPad : SettingsMetrics.inset,
            6,
          ),
          child: Row(
            children: [
              if (icon case final icon?) ...[SettingsLineIcon(icon), const SizedBox(width: SettingsMetrics.iconGap)],
              Expanded(
                child: switch (value) {
                  final value? when value.isNotEmpty => LayoutBuilder(
                    builder: (context, constraints) => Row(
                      children: [
                        Expanded(child: heading),
                        const SizedBox(width: valueGap),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: valueRoom(context, constraints.maxWidth)),
                          child: Text(
                            value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.end,
                            style: AppType.tabular(
                              theme.textTheme.bodyMedium!.copyWith(
                                color: valueColor ?? (enabled ? scheme.onSurfaceVariant : colors.textTertiary),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _ => heading,
                },
              ),
              if (trailing case final trailing?) ...[
                const SizedBox(width: 8),
                SwitchTheme(
                  data: SwitchTheme.of(context).copyWith(materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  child: trailing,
                ),
              ],
              if (showChevron) ...[
                const SizedBox(width: 4),
                if (opensExternally)
                  const ExternalGlyph()
                else if (expanded == null)
                  const OverviewChevron()
                else
                  DisclosureChevron(open: expanded),
              ],
            ],
          ),
        ),
      ),
    );
    return Semantics(
      button: onTap != null && trailing == null,
      enabled: enabled,
      expanded: expanded,
      label: semanticsLabel,
      child: row,
    );
  }
}

/// The row chevron of a row that opens in place: the same glyph in the same
/// place, turned a quarter to point down while [open]. It turns about the
/// centre of its ink, so the open caret stays in the chevron column.
class DisclosureChevron extends StatelessWidget {
  const DisclosureChevron({super.key, required this.open});

  final bool open;

  /// Phosphor's caret-right inks x 88–184 of its 256 grid; the icon font
  /// scales glyphs 1.1 about the grid's centre, so 84–189.6.
  static const inkCentre = Alignment((84 + 189.6) / 256 - 1, 0);

  /// Where the caret's ink ends in its box, as a fraction of the box.
  static const inkRight = 189.6 / 256;

  @override
  Widget build(BuildContext context) => Transform.translate(
    offset: const Offset(OverviewChevron.nudge, 0),
    child: AnimatedRotation(
      turns: open ? .25 : 0,
      alignment: inkCentre,
      duration: AppMotion.of(context, AppMotion.standard),
      curve: AppMotion.std,
      child: ExcludeSemantics(child: Icon(AppIcons.disclosure, size: 20, color: DshColors.of(context).textTertiary)),
    ),
  );
}

/// The open-external glyph in a chevron's place: a size smaller (a square
/// reads heavier than a caret), its ink ending where the chevron's does.
class ExternalGlyph extends StatelessWidget {
  const ExternalGlyph({super.key});

  static const size = 18.0;

  /// arrow-square-out inks 32–224 of its 256 grid, scaled 1.1 by the font:
  /// 22.4–233.6.
  static const inkRight = 233.6 / 256;

  /// Both boxes end at the same place; this lines the inks up.
  static const _shift = OverviewChevron.nudge - 20 + 20 * DisclosureChevron.inkRight + size - size * inkRight;

  @override
  Widget build(BuildContext context) => Transform.translate(
    offset: const Offset(_shift, 0),
    child: ExcludeSemantics(
      child: Icon(AppIcons.openExternal, size: size, color: DshColors.of(context).textTertiary),
    ),
  );
}

/// A two-to-three-way choice: title and capsule on one line when they fit,
/// otherwise the capsule across the row under the title. Insets match
/// [EngineFieldRow]; the capsule's right edge sits where a switch track ends.
class FieldSegmentRow<T> extends StatelessWidget {
  const FieldSegmentRow({
    super.key,
    required this.title,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.subtitle,
    this.subtitleColor,
    this.badge,
  });

  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final Widget? badge;
  final List<PillSegment<T>> segments;
  final T selected;
  final ValueChanged<T>? onChanged;

  /// Room kept for the 已修改 tag whether or not it shows, so a row does
  /// not change layout when its value becomes the user's.
  static const badgeRoom = 56.0;

  /// Whether a row with [title] (and [subtitle]) fits beside a capsule of
  /// [labels] in [width] (the row's content width).
  static bool fitsInline(
    BuildContext context, {
    required String title,
    required List<String> labels,
    required double width,
    String? subtitle,
  }) {
    double measure(String text, TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      final w = painter.width;
      painter.dispose();
      return w;
    }

    // Title (with its tag) and the second line must each stay on one line
    // beside the capsule; otherwise the capsule goes underneath.
    final subtitleWidth = subtitle == null || subtitle.isEmpty
        ? 0.0
        : measure(subtitle, Theme.of(context).textTheme.bodySmall);
    final textWidth = math.max(measure(title, settingsTitleStyle(context)) + badgeRoom, subtitleWidth);
    return textWidth + 16 + SegmentedPill.naturalWidth(context, labels) <= width;
  }

  @override
  Widget build(BuildContext context) {
    final stackedCard = SegmentLayout.stackedOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 8, SettingsMetrics.inset, 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final inline =
              !stackedCard &&
              fitsInline(
                context,
                title: title,
                subtitle: subtitle,
                labels: [for (final s in segments) s.label],
                width: constraints.maxWidth,
              );
          final heading = FieldHeading(
            title: title,
            subtitle: subtitle,
            subtitleColor: subtitleColor,
            badge: badge,
            enabled: onChanged != null,
          );
          final pill = SegmentedPill<T>(segments: segments, selected: selected, onChanged: onChanged, expand: !inline);
          if (inline) {
            return ConstrainedBox(
              constraints: BoxConstraints(
                minHeight:
                    (subtitle == null || subtitle!.isEmpty
                        ? SettingsMetrics.rowHeight
                        : SettingsMetrics.rowHeightTwoLine) -
                    16,
              ),
              child: Row(
                children: [
                  Expanded(child: heading),
                  const SizedBox(width: 16),
                  pill,
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: SettingsMetrics.icon),
                child: Align(alignment: Alignment.centerLeft, child: heading),
              ),
              const SizedBox(height: 10),
              pill,
              const SizedBox(height: 4),
            ],
          );
        },
      ),
    );
  }
}

/// One layout for every capsule row of a card: when one of them has to put
/// its capsule under the title, they all do.
class SegmentLayout extends InheritedWidget {
  const SegmentLayout({super.key, required this.stacked, required super.child});

  final bool stacked;

  static bool stackedOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SegmentLayout>()?.stacked ?? false;

  @override
  bool updateShouldNotify(SegmentLayout oldWidget) => stacked != oldWidget.stacked;
}
