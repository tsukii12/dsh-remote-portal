// Picks how the feature tiles are drawn (TileStyle), for the
// appearance page.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/tile_style_state.dart';
import '../../common/feature_tile.dart';
import '../../common/pressable.dart';
import '../../theme/theme.dart';

/// Three previews in a row, one per [TileStyle], the chosen one ringed in the
/// accent:
///
/// ```
/// ╭────────╮  ╭────────╮  ╭────────╮
/// │ ▣   ◷  │  │ ▣   ◷  │  │ ▣   ◷  │   2 × 2 tiles, equal insets round them
/// │ ✣   ▭  │  │ ✣   ▭  │  │ ✣   ▭  │
/// ╰────────╯  ╰────────╯  ╰────────╯
///  扁平双色     极简几何     玻璃渐变
/// ```
///
/// Equal columns [gap] apart, [padding] on every side; each preview is square,
/// its tiles [inset] × its side from every edge and [tileGap] × its side apart.
/// Sits in a card (`SettingsSection`) or straight on a page.
class TileStylePicker extends ConsumerWidget {
  const TileStylePicker({super.key, this.padding = const EdgeInsets.all(16)});

  final EdgeInsetsGeometry padding;

  static const gap = 12.0;

  /// Preview tiles' inset from the preview's edges and their gap, as fractions
  /// of its side.
  static const inset = 0.17;
  static const tileGap = 0.1;

  /// The ring round the chosen preview.
  static const ring = 2.0;

  /// The four features each preview shows.
  static const sample = [FeatureKind.terminal, FeatureKind.automation, FeatureKind.models, FeatureKind.community];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(tileStyleProvider);
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, style) in TileStyle.values.indexed) ...[
            if (i > 0) const SizedBox(width: gap),
            Expanded(
              child: _Option(
                style: style,
                selected: style == selected,
                onTap: () => ref.read(tileStyleProvider.notifier).select(style),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.style, required this.selected, required this.onTap});

  final TileStyle style;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final duration = AppMotion.of(context, AppMotion.quick);
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Pressable(
        onTap: onTap,
        semanticLabel: style.label,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: AnimatedContainer(
                key: ValueKey('tile-style-${style.name}'),
                duration: duration,
                curve: AppMotion.std,
                decoration: ShapeDecoration(
                  color: dark ? Colors.white.withValues(alpha: 0.05) : scheme.onSurface.withValues(alpha: 0.04),
                  shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusMd),
                ),
                // The ring is drawn over the preview, inside its edge: it takes no
                // room, so choosing moves nothing.
                foregroundDecoration: ShapeDecoration(
                  shape: RoundedSuperellipseBorder(
                    borderRadius: AppShape.radiusMd,
                    side: BorderSide(
                      color: selected ? scheme.primary : scheme.outlineVariant.withValues(alpha: dark ? 0.5 : 0.7),
                      width: selected ? TileStylePicker.ring : 1,
                      strokeAlign: BorderSide.strokeAlignInside,
                    ),
                  ),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final side = constraints.maxWidth;
                    final tile = side * (1 - 2 * TileStylePicker.inset - TileStylePicker.tileGap) / 2;
                    final gap = side * TileStylePicker.tileGap;
                    Widget cell(FeatureKind kind) => FeatureTile(kind, size: tile, style: style);
                    const s = TileStylePicker.sample;
                    return Center(
                      child: SizedBox.square(
                        dimension: tile * 2 + gap,
                        child: Column(
                          children: [
                            Row(
                              children: [
                                cell(s[0]),
                                SizedBox(width: gap),
                                cell(s[1]),
                              ],
                            ),
                            SizedBox(height: gap),
                            Row(
                              children: [
                                cell(s[2]),
                                SizedBox(width: gap),
                                cell(s[3]),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 8),
            AnimatedDefaultTextStyle(
              duration: duration,
              style: theme.textTheme.labelMedium!.copyWith(
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
              child: Text(style.label, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}
