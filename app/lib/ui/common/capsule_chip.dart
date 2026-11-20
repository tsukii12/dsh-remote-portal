// The quiet filter capsule used where a filter has too
// many options for a SegmentedPill (plugin categories, phone brands).

import 'package:flutter/material.dart';

/// 筛选胶囊:未选是很淡的底,选中是墨色实心(筛选不是主操作,不用品牌色)。
/// 放在横向滚动的一行里,彼此间距 8。
class CapsuleChoiceChip extends StatelessWidget {
  const CapsuleChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  /// A small mark before the label, for a capsule of another kind in the row.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Theme(
      // The chip's Material paints canvasColor under the fill; in dark mode
      // that opaque canvas hides the card the 7% white should sit on.
      data: dark ? theme.copyWith(canvasColor: Colors.transparent) : theme,
      child: ChoiceChip(
        label: Text(label),
        avatar: icon == null ? null : Icon(icon, size: 14, color: selected ? scheme.surface : scheme.primary),
        selected: selected,
        showCheckmark: false,
        onSelected: (_) => onSelected(),
        shape: const StadiumBorder(),
        side: BorderSide.none,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        backgroundColor: dark ? Colors.white.withValues(alpha: 0.07) : scheme.onSurface.withValues(alpha: 0.05),
        selectedColor: scheme.onSurface,
        labelStyle: theme.textTheme.labelLarge?.copyWith(
          fontSize: 13,
          color: selected ? scheme.surface : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
