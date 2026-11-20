// The title row of the sheet skeleton: title on the left, a round close key
// on the right, both centred on one line, 20 in from the sheet's sides like
// the content below it.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme/app_icons.dart';
import 'app_sheet.dart' show groupTitleStyle;
import 'sheet_navigator.dart';
import 'sheet_dismissal.dart';

/// Shared title row. Draggable sheets use their handle for dismissal;
/// button-only and standalone headers keep the close key. The title has
/// mirrored insets when no trailing controls remain.
class SheetTitleBar extends StatelessWidget {
  const SheetTitleBar(this.title, {super.key, this.onClose, this.actions = const [], this.maxLines = 1});

  final String title;
  final List<Widget> actions;

  /// Defaults to popping the sheet's route.
  final VoidCallback? onClose;

  /// One line, cut with an ellipsis, by default. More (null: any number)
  /// wraps instead — a question that must be read whole — and the keys line
  /// up with the first line.
  final int? maxLines;

  /// 弹层内容的左右内缩。
  static const inset = 20.0;

  /// 圆键看得见的直径与可点范围。
  static const keySize = 32.0;
  static const _hit = 44.0;
  static const _slack = (_hit - keySize) / 2;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final sheet = SheetNavigator.maybeOf(context);
    final canGoBack = sheet?.canPop ?? false;
    final close = SheetDismissScope.of(context) == SheetDismissal.button;
    final trailing = close || actions.isNotEmpty;
    final style = theme.textTheme.titleLarge;
    final wraps = maxLines != 1;
    // Wrapping: the first line's centre and the keys' centre on one level.
    var titleTop = 0.0;
    var keyTop = 0.0;
    if (wraps) {
      final line = _lineHeight(context, style);
      titleTop = ((_hit - line) / 2).clamp(0.0, double.infinity);
      keyTop = ((line - _hit) / 2).clamp(0.0, double.infinity);
    }
    Widget key(Widget child) => child.withTopInset(keyTop);
    return Padding(
      padding: EdgeInsets.fromLTRB(canGoBack ? inset - _slack : inset, 0, trailing ? inset - _slack : inset, 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _hit),
        child: Row(
          crossAxisAlignment: wraps ? CrossAxisAlignment.start : CrossAxisAlignment.center,
          children: [
            if (canGoBack) ...[
              key(SheetIconButton(icon: AppIcons.back, tooltip: l10n.commonBack, onPressed: sheet!.pop)),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title, maxLines: maxLines, overflow: wraps ? null : TextOverflow.ellipsis, style: style),
              ).withTopInset(titleTop),
            ),
            if (trailing) const SizedBox(width: 8),
            // Keys sit box to box: the 44 hit areas touch, so the 32 circles
            // are 12 apart.
            for (final action in actions) key(action),
            if (close)
              key(
                SheetIconButton(
                  icon: AppIcons.close,
                  tooltip: l10n.commonClose,
                  onPressed: onClose ?? () => Navigator.of(context).maybePop(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// One line of [style] as [Text] lays it out here.
  static double _lineHeight(BuildContext context, TextStyle? style) {
    final base = DefaultTextStyle.of(context);
    final painter = TextPainter(
      text: TextSpan(text: '国A', style: base.style.merge(style)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      textHeightBehavior: base.textHeightBehavior,
      maxLines: 1,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }
}

extension on Widget {
  /// Pushed down by [top]; itself when that is zero (the one-line title bar).
  Widget withTopInset(double top) => top == 0
      ? this
      : Padding(
          padding: EdgeInsets.only(top: top),
          child: this,
        );
}

/// 弹层标题行里的圆钮:32 的淡色圆 + 18 的图标,点击区 44。
class SheetIconButton extends StatelessWidget {
  const SheetIconButton({super.key, required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: tooltip,
        onTap: onPressed,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: SizedBox.square(
            dimension: 44,
            child: Center(
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: scheme.onSurface.withValues(alpha: dark ? 0.10 : 0.06),
                  shape: const CircleBorder(),
                ),
                child: SizedBox.square(
                  dimension: SheetTitleBar.keySize,
                  child: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 弹层里的分组小标题:**小而淡**,与页面、[SheetGroup] 的组标题同一种字
/// ([groupTitleStyle]),比内容边再进 8,离下面的内容 8。
///
/// ```
///   思考深度              ← inset + 8
///   ((  不思考 ) 低  高  最高 )   ← inset
/// ```
class SheetSectionLabel extends StatelessWidget {
  const SheetSectionLabel(this.text, {super.key, this.inset = SheetTitleBar.inset});

  final String text;

  /// The content's side inset the label sits 8 inside of.
  final double inset;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(inset + 8, 4, inset + 8, 8),
      child: Semantics(
        header: true,
        child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: groupTitleStyle(context)),
      ),
    );
  }
}
