// The capsule segmented control used across the app
// (settings, the model sheet, page tabs) in place of Material's
// SegmentedButton, whose equal flex segments wrap CJK labels one character
// per line on narrow phones or with large system text.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../fx/gooey/gooey.dart';
import '../theme/theme.dart';

/// One option of a [SegmentedPill].
class PillSegment<T> {
  const PillSegment(this.value, this.label);
  final T value;
  final String label;
}

/// 胶囊分段控件:一条胶囊底槽,选中项是一颗会滑动的胶囊。
///
/// ```
/// (( 跟随系统 )  浅色    深色  )
/// ```
///
/// - 各段**等宽**,滑块与底槽四周留同样的 [inset],两端同心;
/// - 文字永远一行,放不下时整体缩小,不会折成竖排;
/// - 点一段直接选中;按住滑块左右拖,松手吸附到最近的一段;
/// - [expand] 为 false 时按最长的一段算宽度(给行内放置用,见
///   [SegmentedPill.naturalWidth])。
class SegmentedPill<T> extends StatefulWidget {
  const SegmentedPill({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.expand = true,
    this.height = 36,
    this.onReselect,
  }) : assert(segments.length >= 2);

  final List<PillSegment<T>> segments;
  final T selected;

  /// Null disables the control.
  final ValueChanged<T>? onChanged;

  /// A tap on the segment already selected (a 「自定义」 one opening its
  /// editor again); a drag that ends where it began is not one.
  final ValueChanged<T>? onReselect;

  /// Fill the available width (each segment an equal share); false sizes the
  /// control to its longest label.
  final bool expand;
  final double height;

  static const inset = 3.0;
  static const _labelPadding = 14.0;

  static TextStyle labelStyle(BuildContext context) =>
      Theme.of(context).textTheme.labelLarge!.copyWith(fontSize: 13.5, height: 1.2, letterSpacing: 0.1);

  /// The width of a non-expanded pill with [labels], at the current text size.
  static double naturalWidth(BuildContext context, List<String> labels) {
    final style = labelStyle(context).copyWith(fontWeight: FontWeight.w600); // the selected weight is widest
    final scaler = MediaQuery.textScalerOf(context);
    var widest = 0.0;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textScaler: scaler,
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      if (painter.width > widest) widest = painter.width;
      painter.dispose();
    }
    return labels.length * (widest + 2 * _labelPadding) + 2 * inset;
  }

  @override
  State<SegmentedPill<T>> createState() => _SegmentedPillState<T>();
}

class _SegmentedPillState<T> extends State<SegmentedPill<T>> {
  /// The thumb's left edge while a finger drags it; null at rest.
  double? _drag;

  int get _index {
    final i = widget.segments.indexWhere((s) => s.value == widget.selected);
    return i < 0 ? 0 : i;
  }

  void _pick(int index, {bool tick = true}) {
    final onChanged = widget.onChanged;
    if (onChanged == null) return;
    final value = widget.segments[index].value;
    if (value != widget.selected) {
      if (tick) HapticFeedback.selectionClick();
      onChanged(value);
    }
  }

  void _tap(int index) {
    final value = widget.segments[index].value;
    if (value == widget.selected && widget.onReselect != null) return widget.onReselect!(value);
    _pick(index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final enabled = widget.onChanged != null;
    final n = widget.segments.length;
    final track = dark ? Colors.white.withValues(alpha: 0.07) : colors.onSurface.withValues(alpha: 0.06);
    // Dark: a lifted grey like iOS's control, clearly apart from the track.
    final thumb = dark ? Colors.white.withValues(alpha: 0.2) : Colors.white;
    final style = SegmentedPill.labelStyle(context);
    // Grows with large system text instead of squeezing the labels.
    final height = math.max(
      widget.height,
      MediaQuery.textScalerOf(context).scale(style.fontSize!) * style.height! + 2 * SegmentedPill.inset + 14,
    );

    final fluid = AppMotion.fluid(context);

    Widget pill(double width) {
      final segment = (width - 2 * SegmentedPill.inset) / n;
      final rest = SegmentedPill.inset + _index * segment;
      final left = (_drag ?? rest).clamp(SegmentedPill.inset, SegmentedPill.inset + (n - 1) * segment);
      // While dragging, the label under the thumb reads as selected.
      final current = _drag == null ? _index : ((left - SegmentedPill.inset) / segment).round().clamp(0, n - 1);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: enabled ? (_) => setState(() => _drag = rest) : null,
        onHorizontalDragUpdate: enabled
            ? (d) {
                final next = ((_drag ?? rest) + d.delta.dx).clamp(
                  SegmentedPill.inset,
                  SegmentedPill.inset + (n - 1) * segment,
                );
                // One tick per segment crossed.
                final under = ((next - SegmentedPill.inset) / segment).round();
                if (fluid && under != current) HapticFeedback.selectionClick();
                setState(() => _drag = (_drag ?? rest) + d.delta.dx);
              }
            : null,
        onHorizontalDragEnd: enabled
            ? (_) {
                final target = current;
                setState(() => _drag = null);
                // The fluid tier ticked as the thumb crossed over.
                _pick(target, tick: !fluid);
              }
            : null,
        onHorizontalDragCancel: () => setState(() => _drag = null),
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Container(
            width: width,
            height: height,
            decoration: ShapeDecoration(color: track, shape: const StadiumBorder()),
            child: Stack(
              children: [
                if (fluid)
                  // The fluid tier's thumb is liquid (Libraries.dev Gooey, the tab recipe):
                  // it stretches and trails as it slides, and is a plain pill at rest.
                  Positioned.fill(
                    child: Liquid(
                      blur: LiquidTabs.blur,
                      fill: thumb,
                      shadows: dark ? const [] : LiquidShadows.tabPill(Brightness.light),
                      child: Stack(
                        children: [
                          AnimatedPositioned(
                            duration: _drag != null ? Duration.zero : AppMotion.thumbCurve.duration,
                            curve: AppMotion.thumbCurve,
                            left: left,
                            top: SegmentedPill.inset,
                            bottom: SegmentedPill.inset,
                            width: segment,
                            child: const LiquidItem(
                              effect: LiquidEffect.move,
                              move: LiquidTabs.move,
                              radius: BorderRadius.all(Radius.circular(999)),
                              child: SizedBox.expand(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  AnimatedPositioned(
                    duration: _drag != null ? Duration.zero : AppMotion.of(context, AppMotion.standard),
                    curve: AppMotion.std,
                    left: left,
                    top: SegmentedPill.inset,
                    bottom: SegmentedPill.inset,
                    width: segment,
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: thumb,
                        shape: const StadiumBorder(),
                        shadows: dark
                            ? null
                            : [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.08),
                                  blurRadius: 6,
                                  offset: const Offset(0, 1),
                                ),
                              ],
                      ),
                    ),
                  ),
                Row(
                  children: [
                    for (var i = 0; i < n; i++)
                      Expanded(
                        child: Semantics(
                          button: true,
                          enabled: enabled,
                          onTap: enabled ? () => _tap(i) : null,
                          selected: i == _index,
                          inMutuallyExclusiveGroup: true,
                          label: widget.segments[i].label,
                          excludeSemantics: true,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: enabled ? () => _tap(i) : null,
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: AnimatedDefaultTextStyle(
                                    duration: AppMotion.of(context, AppMotion.quick),
                                    style: style.copyWith(
                                      fontWeight: i == current ? FontWeight.w600 : FontWeight.w500,
                                      color: i == current ? colors.onSurface : colors.onSurfaceVariant,
                                    ),
                                    child: Text(widget.segments[i].label, maxLines: 1, softWrap: false),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!widget.expand) {
      return pill(SegmentedPill.naturalWidth(context, [for (final s in widget.segments) s.label]));
    }
    return LayoutBuilder(builder: (context, c) => pill(c.maxWidth));
  }
}
