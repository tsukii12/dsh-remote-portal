// View-v2 selection controls: segmented track, chips, tabs and rating stars.
// Selection is a tonal accent fill plus an accent outline (and a check or an
// indicator bar), so it never depends on colour alone. Focus, hover and press
// thicken an outline; nothing paints a translucent wash over checked text.
import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'dsh_ui_plugin_controls.dart' show DshUiControlChoices;
import 'dsh_ui_plugin_row.dart';
import 'dsh_ui_plugin_tones.dart';

/// One option shown by a selection control.
class DshUiChoice {
  const DshUiChoice({required this.key, required this.label, required this.selected, this.semanticLabel});
  final Key key;
  final String label;
  final bool selected;
  final String? semanticLabel;
}

/// Tracks focus / hover / press for an outline-only state treatment.
class DshUiPressable extends StatefulWidget {
  const DshUiPressable({super.key, required this.onTap, required this.builder});
  final VoidCallback? onTap;
  final Widget Function(BuildContext context, bool active) builder;
  @override
  State<DshUiPressable> createState() => _DshUiPressableState();
}

class _DshUiPressableState extends State<DshUiPressable> {
  bool _focused = false;
  bool _hovered = false;
  bool _pressed = false;
  @override
  Widget build(BuildContext context) => InkWell(
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    splashFactory: NoSplash.splashFactory,
    onFocusChange: (v) => setState(() => _focused = v),
    onHover: (v) => setState(() => _hovered = v),
    onHighlightChanged: (v) => setState(() => _pressed = v),
    onTap: widget.onTap,
    child: widget.builder(context, widget.onTap != null && (_focused || _hovered || _pressed)),
  );
}

TextStyle? _optionStyle(BuildContext context, {required bool selected, required Color color}) => Theme.of(
  context,
).textTheme.labelLarge?.copyWith(fontSize: 15, fontWeight: selected ? FontWeight.w600 : FontWeight.w500, color: color);

/// Single choice as a segmented control: options sit in one recessed track,
/// the chosen one is a raised tonal segment. Columns shrink before a label
/// would get narrower than its readable width; every row is equal height and
/// every segment's target, including its share of the track, is ≥ 48 dp.
class DshUiSegmented extends StatelessWidget {
  const DshUiSegmented({super.key, required this.choices, required this.onSelect});
  final List<DshUiChoice> choices;
  final ValueChanged<int>? onSelect;

  static const inset = 4.0;
  static const _half = inset / 2;
  static const _separatorInset = 12.0;

  @override
  Widget build(BuildContext context) {
    final tones = DshUiPluginTones.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final count = DshUiControlChoices.fit(
          count: choices.length,
          columns: 4,
          width: box.maxWidth - 2 * inset,
          minimum: 80 * scale,
          gap: inset,
        );
        final rows = (choices.length / count).ceil();
        return DecoratedBox(
          key: const ValueKey('plugin-segmented-track'),
          decoration: ShapeDecoration(color: tones.well, shape: Squircle.border(AppShape.md)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var row = 0; row < rows; row++)
                DshUiEqualRow(
                  flex: List.filled(math.min(count, choices.length - row * count), 1),
                  stretch: List.filled(math.min(count, choices.length - row * count), true),
                  children: [
                    for (var i = row * count; i < math.min((row + 1) * count, choices.length); i++)
                      _segment(
                        context,
                        tones,
                        i,
                        // A hairline between two unchosen neighbours, as in a
                        // native segmented control: never beside the chosen one.
                        leading: i > row * count && !choices[i].selected && !choices[i - 1].selected,
                        above:
                            row > 0 &&
                            !choices[i].selected &&
                            !choices.sublist((row - 1) * count, row * count).any((c) => c.selected),
                        EdgeInsetsDirectional.fromSTEB(
                          i == row * count ? inset : _half,
                          row == 0 ? inset : _half,
                          i == math.min((row + 1) * count, choices.length) - 1 ? inset : _half,
                          row == rows - 1 ? inset : _half,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _segment(
    BuildContext context,
    DshUiPluginTones tones,
    int i,
    EdgeInsetsDirectional margin, {
    required bool leading,
    required bool above,
  }) {
    final choice = choices[i];
    final selected = choice.selected;
    final onSelect = this.onSelect;
    return Semantics(
      key: choice.key,
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      enabled: onSelect != null,
      label: choice.semanticLabel ?? choice.label,
      child: DshUiPressable(
        onTap: onSelect == null ? null : () => onSelect(i),
        builder: (context, active) => Stack(
          // The row's minimum height reaches the visible segment.
          fit: StackFit.passthrough,
          clipBehavior: Clip.none,
          children: [
            Padding(
              padding: margin,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: selected ? tones.tint : tones.well,
                  shape: Squircle.border(
                    AppShape.sm,
                    side: selected || active
                        ? BorderSide(color: selected ? tones.accentLine : tones.line, width: active ? 2 : 1)
                        : BorderSide.none,
                  ),
                ),
                child: ConstrainedBox(
                  // The segment plus its share of the track is a 48 dp target.
                  constraints: BoxConstraints(minHeight: 48 - margin.vertical, minWidth: 48 - margin.horizontal),
                  child: Padding(
                    key: ValueKey('plugin-choice-padding:$i'),
                    padding: const EdgeInsets.all(8),
                    child: Center(
                      child: ExcludeSemantics(
                        child: Text(
                          choice.label,
                          textAlign: TextAlign.center,
                          style: _optionStyle(
                            context,
                            selected: selected,
                            color: selected ? tones.onTint : tones.wellInk,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Centred in the gap the two neighbours share.
            if (leading)
              PositionedDirectional(
                key: ValueKey('plugin-segment-separator:$i'),
                start: -0.5,
                top: _separatorInset,
                bottom: _separatorInset,
                width: 1,
                child: ColoredBox(color: tones.hairline),
              ),
            if (above)
              PositionedDirectional(
                key: ValueKey('plugin-segment-rule:$i'),
                top: -0.5,
                start: _separatorInset,
                end: _separatorInset,
                height: 1,
                child: ColoredBox(color: tones.hairline),
              ),
          ],
        ),
      ),
    );
  }
}

/// Chips wrap at their own width. A chosen chip adds a check mark, a tonal
/// fill and an accent outline. Each chip's target extends 4 dp above and
/// below the visible chip to reach 48 dp.
class DshUiChips extends StatelessWidget {
  const DshUiChips({super.key, required this.choices, required this.onToggle, this.multi = false});
  final List<DshUiChoice> choices;
  final ValueChanged<int>? onToggle;
  final bool multi;

  static const reach = 4.0;

  @override
  Widget build(BuildContext context) {
    final tones = DshUiPluginTones.of(context);
    final onToggle = this.onToggle;
    return Wrap(
      spacing: 8,
      children: [
        for (final (i, choice) in choices.indexed)
          Semantics(
            key: choice.key,
            button: true,
            selected: choice.selected,
            inMutuallyExclusiveGroup: !multi,
            enabled: onToggle != null,
            label: choice.semanticLabel ?? choice.label,
            child: DshUiPressable(
              onTap: onToggle == null ? null : () => onToggle(i),
              builder: (context, active) => Padding(
                padding: const EdgeInsets.symmetric(vertical: reach),
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: choice.selected ? tones.tint : tones.surface,
                    shape: Squircle.border(
                      AppShape.sm,
                      side: BorderSide(
                        color: choice.selected
                            ? tones.accentLine
                            : active
                            ? tones.line
                            : tones.hairline,
                        width: active ? 2 : 1,
                      ),
                    ),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48 - 2 * reach, minWidth: 48),
                    child: Padding(
                      key: ValueKey('plugin-choice-padding:$i'),
                      padding: const EdgeInsets.all(8),
                      child: ExcludeSemantics(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (choice.selected) ...[
                              Icon(AppIcons.selected, size: 16, color: tones.onTint),
                              const SizedBox(width: 6),
                            ],
                            Flexible(
                              child: Text(
                                choice.label,
                                textAlign: TextAlign.center,
                                style: _optionStyle(
                                  context,
                                  selected: choice.selected,
                                  color: choice.selected ? tones.onTint : tones.ink,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Underlined tabs: equal columns over a hairline, the chosen tab in accent
/// with a 3 dp bar. Exposed to assistive technology as a tab bar.
class DshUiTabBar extends StatelessWidget {
  const DshUiTabBar({super.key, required this.labels, required this.selected, required this.onSelect});
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;

  static const indicator = 3.0;

  @override
  Widget build(BuildContext context) {
    final tones = DshUiPluginTones.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final count = DshUiControlChoices.fit(
          count: labels.length,
          columns: 4,
          width: box.maxWidth,
          minimum: 80 * scale,
          gap: 0,
        );
        return Semantics(
          role: SemanticsRole.tabBar,
          container: true,
          explicitChildNodes: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var start = 0; start < labels.length; start += count)
                DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: tones.hairline)),
                  ),
                  child: DshUiEqualRow(
                    flex: List.filled(count, 1),
                    stretch: List.filled(count, true),
                    children: [
                      for (var i = start; i < start + count; i++)
                        i < labels.length ? _tab(context, tones, i) : const SizedBox.shrink(),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _tab(BuildContext context, DshUiPluginTones tones, int i) {
    final chosen = i == selected;
    return Semantics(
      key: ValueKey('plugin-tab:$i'),
      role: SemanticsRole.tab,
      container: true,
      selected: chosen,
      button: true,
      label: labels[i],
      child: DshUiPressable(
        onTap: () => onSelect(i),
        builder: (context, active) => DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: ShapeDecoration(
            shape: Squircle.border(
              AppShape.sm,
              side: active ? BorderSide(color: tones.line, width: 2) : BorderSide.none,
            ),
          ),
          child: Stack(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
                child: Padding(
                  key: ValueKey('plugin-choice-padding:$i'),
                  padding: const EdgeInsets.all(12),
                  child: Center(
                    child: ExcludeSemantics(
                      child: Text(
                        labels[i],
                        textAlign: TextAlign.center,
                        style: _optionStyle(context, selected: chosen, color: chosen ? tones.accent : tones.muted),
                      ),
                    ),
                  ),
                ),
              ),
              if (chosen)
                PositionedDirectional(
                  key: const ValueKey('plugin-tab-indicator'),
                  start: 12,
                  end: 12,
                  bottom: 0,
                  height: indicator,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: tones.accent,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(indicator)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row of stars that never wraps. Each star is its own labelled button with
/// a 48 dp target; when the row is narrower than 48 dp per star the gaps go
/// first, then the targets share the width equally. The first glyph starts at
/// the field edge, like the left edge of every other control.
class DshUiRatingStars extends StatelessWidget {
  const DshUiRatingStars({
    super.key,
    required this.max,
    required this.value,
    required this.semanticLabel,
    required this.onChanged,
    this.keyPrefix = 'rating',
  });
  final int max;
  final int value;
  final String Function(int star) semanticLabel;
  final ValueChanged<int>? onChanged;
  final String keyPrefix;

  static const star = 28.0;

  @override
  Widget build(BuildContext context) {
    final tones = DshUiPluginTones.of(context);
    final onChanged = this.onChanged;
    return LayoutBuilder(
      builder: (context, box) {
        final slot = math.min(48.0, box.maxWidth / max);
        final glyph = math.min(star, slot - 4);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 1; i <= max; i++)
              Semantics(
                key: ValueKey('$keyPrefix:$i'),
                button: true,
                selected: i == value,
                enabled: onChanged != null,
                label: semanticLabel(i),
                child: SizedBox(
                  width: slot,
                  height: 48,
                  child: DshUiPressable(
                    onTap: onChanged == null ? null : () => onChanged(i),
                    builder: (context, active) => Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: SizedBox(
                        width: glyph,
                        height: glyph + 12,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: Center(
                                child: ExcludeSemantics(
                                  child: Icon(
                                    i <= value ? AppIcons.favoriteActive : AppIcons.favorite,
                                    size: glyph,
                                    color: onChanged == null
                                        ? (i <= value ? tones.muted : tones.inactive)
                                        : (i <= value ? tones.accent : tones.line),
                                  ),
                                ),
                              ),
                            ),
                            // Focus / hover / press: a bar under the glyph,
                            // inside the target rather than over the edge.
                            if (active)
                              Positioned(
                                key: const ValueKey('plugin-rating-focus'),
                                left: 0,
                                right: 0,
                                bottom: 0,
                                height: 2,
                                child: ColoredBox(color: tones.line),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
