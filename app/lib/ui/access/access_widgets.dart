// The pieces the system-permission pages share: the step header, a feature
// row with its checkbox, an item row with its state, and the buttons under
// a step.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/access_state.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'access_text.dart';

/// Top of a step, drawn as `OnboardingHeader` is (52 tile, 22, title, 6, one
/// line), with an optional counter level with the tile's centre and the tile
/// turning into a check once the item is on.
class AccessHeader extends StatelessWidget {
  const AccessHeader({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.counter,
    this.done = false,
  });

  final IconData icon;
  final String title;
  final String? message;

  /// 「2 / 5」, top right.
  final String? counter;
  final bool done;

  static const tile = 52.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            DecoratedBox(
              key: const ValueKey('access-tile'),
              decoration: ShapeDecoration(color: scheme.primaryContainer, shape: Squircle.border(AppShape.md)),
              child: SizedBox.square(
                dimension: tile,
                child: AnimatedSwitcher(
                  duration: AppMotion.of(context, AppMotion.standard),
                  switchInCurve: AppMotion.enter,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(scale: Tween(begin: 0.85, end: 1.0).animate(animation), child: child),
                  ),
                  child: Icon(
                    done ? AppIcons.done : icon,
                    key: ValueKey(done),
                    size: 26,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
            const Spacer(),
            if (counter case final counter?)
              Text(
                counter,
                key: const ValueKey('access-counter'),
                style: AppType.tabular(theme.textTheme.labelLarge!.copyWith(color: colors.textTertiary)),
              ),
          ],
        ),
        const SizedBox(height: 22),
        Text(title, style: theme.textTheme.headlineMedium),
        if (message case final message?) ...[
          const SizedBox(height: 6),
          Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ],
    );
  }
}

/// One line under a feature's name: what it needs, or what it costs.
typedef AccessLine = ({String text, Color? color});

/// A feature to pick: line icon · name over what it needs · checkbox. The
/// checkbox ends 16 in, as far in as the icon starts.
class AccessFeatureRow extends StatelessWidget {
  const AccessFeatureRow({
    super.key,
    required this.feature,
    required this.selected,
    required this.onTap,
    this.lines = const [],
  });

  final AccessFeature feature;
  final bool selected;
  final VoidCallback? onTap;

  /// Under the name; empty: [AccessFeatureText.needs].
  final List<AccessLine> lines;

  static const box = 22.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final under = lines.isEmpty ? [(text: feature.needs(l10n), color: null)] : lines;
    return MergeSemantics(
      child: Semantics(
        checked: selected,
        child: InkWell(
          key: ValueKey('access-feature-${feature.name}'),
          onTap: onTap,
          splashFactory: rowSplash(context),
          highlightColor: scheme.onSurface.withValues(alpha: 0.05),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: SettingsMetrics.rowHeightTwoLine),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 10, SettingsMetrics.inset, 10),
              child: Row(
                children: [
                  SettingsLineIcon(feature.icon),
                  const SizedBox(width: SettingsMetrics.iconGap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(feature.title(l10n), style: settingsTitleStyle(context)?.copyWith(color: scheme.onSurface)),
                        for (final line in under) ...[
                          const SizedBox(height: 1),
                          Text(
                            line.text,
                            style: theme.textTheme.bodySmall?.copyWith(color: line.color ?? colors.textTertiary),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: SettingsMetrics.iconGap),
                  SizedBox.square(
                    key: ValueKey('access-check-${feature.name}'),
                    dimension: box,
                    child: AnimatedSwitcher(
                      duration: AppMotion.of(context, AppMotion.quick),
                      child: Icon(
                        selected ? AppIcons.checkboxOn : AppIcons.checkboxOff,
                        key: ValueKey(selected),
                        size: box,
                        color: selected ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An item with where it stands: 已开启 / 未开启 / 已去设置 / 去设置. Opens its
/// step unless it is on.
class AccessItemTile extends StatelessWidget {
  const AccessItemTile({super.key, required this.item, required this.state, this.vendor, this.onTap});

  final AccessItem item;
  final AccessState state;
  final String? vendor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsTile(
      key: ValueKey('access-item-${item.name}'),
      icon: item.icon,
      tinted: false,
      title: item.title(l10n, vendor: vendor),
      value: Text(
        state.label(l10n),
        style: state == AccessState.off ? TextStyle(color: DshColors.of(context).warning) : null,
      ),
      onTap: state == AccessState.on ? null : onTap,
    );
  }
}

/// The buttons under a step: the one thing to do, and under it the quiet
/// ways on in equal halves (or one, full width). [hidden] keeps their room,
/// so nothing moves while an item that just came on moves along.
class AccessActions extends StatelessWidget {
  const AccessActions({
    super.key,
    required this.primary,
    required this.onPrimary,
    required this.secondary,
    this.hidden = false,
  });

  final String primary;
  final VoidCallback? onPrimary;
  final List<(String, VoidCallback?)> secondary;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      ignoring: hidden,
      child: AnimatedOpacity(
        opacity: hidden ? 0 : 1,
        duration: AppMotion.of(context, AppMotion.quick),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(key: const ValueKey('access-primary'), onPressed: onPrimary, child: Text(primary)),
            const SizedBox(height: 6),
            Row(
              children: [
                for (final (i, (label, onTap)) in secondary.indexed)
                  Expanded(
                    child: TextButton(
                      key: ValueKey('access-secondary-$i'),
                      onPressed: onTap,
                      style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
                      child: Text(label, textAlign: TextAlign.center),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
