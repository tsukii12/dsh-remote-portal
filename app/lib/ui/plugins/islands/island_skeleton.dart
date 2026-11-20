import '../../../l10n/l10n.dart';

import 'package:flutter/material.dart';

/// What an island shows while DSH Web starts behind it: quiet grey bars
/// where settings rows usually are (nothing loops, like the other list
/// skeletons).
class IslandSkeleton extends StatelessWidget {
  const IslandSkeleton({super.key, this.rows = 6});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final fill = theme.colorScheme.onSurface.withValues(alpha: theme.brightness == Brightness.dark ? 0.08 : 0.06);
    Widget bar(double height, {double? width}) => Container(
      width: width,
      height: height,
      decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
    );
    final rowsColumn = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < rows; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FractionallySizedBox(widthFactor: i.isEven ? 0.7 : 0.5, child: bar(14)),
                      const SizedBox(height: 10),
                      FractionallySizedBox(widthFactor: i.isEven ? 0.9 : 0.8, child: bar(10)),
                    ],
                  ),
                ),
                const SizedBox(width: 24),
                bar(22, width: 44),
              ],
            ),
          ),
      ],
    );
    // As many rows as fit: a box shorter than the skeleton clips it.
    return Semantics(
      label: l10n.pluginsLoading,
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.hasBoundedHeight
            ? ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minHeight: 0,
                  maxHeight: double.infinity,
                  child: rowsColumn,
                ),
              )
            : rowsColumn,
      ),
    );
  }
}
