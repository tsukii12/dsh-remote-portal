// The pieces the share sheets share — the row of equal round keys (the share
// panel's destinations, a link's actions, a share code's ways out), the round
// check of the checklists, the profile tile.

import 'package:flutter/material.dart';

import '../common/pressable.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// One action of [ShareActionRow].
class ShareAction {
  const ShareAction({
    required this.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
    this.done = false,
  });

  final Key key;
  final IconData icon;
  final String label;

  /// Null disables the action.
  final VoidCallback? onTap;

  /// A small ring in place of the icon.
  final bool busy;

  /// A check in place of the icon (just copied / saved).
  final bool done;
}

/// 「复制链接 · 二维码 · 分享 · 存为文件」: equal cells, a 52 round key over a
/// one-line label, keys centred in their cells (mirrored edges). A label too
/// wide for its cell (large text, a narrow phone) shrinks to fit rather than
/// being cut.
class ShareActionRow extends StatelessWidget {
  const ShareActionRow({super.key, required this.actions});

  final List<ShareAction> actions;

  static const keySize = 52.0;
  static const labelGap = 8.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final duration = AppMotion.of(context, AppMotion.quick);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final a in actions)
          Expanded(
            child: Pressable(
              key: a.key,
              enabled: a.onTap != null && !a.busy,
              onTap: a.onTap,
              semanticLabel: a.label,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DecoratedBox(
                    decoration: ShapeDecoration(
                      color: scheme.onSurface.withValues(alpha: dark ? 0.10 : 0.06),
                      shape: const CircleBorder(),
                    ),
                    child: SizedBox.square(
                      dimension: keySize,
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: duration,
                          child: a.busy
                              ? SizedBox.square(
                                  key: const ValueKey('busy'),
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    strokeCap: StrokeCap.round,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                )
                              : Icon(
                                  a.done ? AppIcons.done : a.icon,
                                  key: ValueKey(a.done),
                                  size: 22,
                                  color: a.onTap == null ? colors.textDisabled : scheme.onSurface,
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: labelGap),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        a.label,
                        maxLines: 1,
                        softWrap: false,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: a.onTap == null ? colors.textDisabled : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The checklist's round check: ink-filled with a white tick when on, a
/// hairline ring when off; greyed when the row can't be ticked.
class ShareCheck extends StatelessWidget {
  const ShareCheck({super.key, required this.value, this.enabled = true});

  final bool value;
  final bool enabled;

  static const size = 22.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = DshColors.of(context);
    final on = value && enabled;
    final ink = scheme.onSurface;
    return AnimatedContainer(
      duration: AppMotion.of(context, AppMotion.quick),
      curve: AppMotion.std,
      width: size,
      height: size,
      decoration: ShapeDecoration(
        color: on ? ink : Colors.transparent,
        shape: CircleBorder(
          side: on
              ? BorderSide.none
              : BorderSide(color: enabled ? scheme.outline : colors.textDisabled.withValues(alpha: 0.5), width: 1.5),
        ),
      ),
      child: on ? Icon(AppIcons.selected, size: 15, color: scheme.surface) : null,
    );
  }
}

/// A profile's tile: a soft squircle with the settings glyph.
class ProfileTile extends StatelessWidget {
  const ProfileTile({super.key, this.size = 56});

  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    final slot = DshColors.identityIndex('dsh-go profile');
    return DecoratedBox(
      decoration: ShapeDecoration(color: colors.identity[slot], shape: Squircle.border(size * 0.25)),
      child: SizedBox.square(
        dimension: size,
        child: Icon(AppIcons.configure, size: size * 0.46, color: colors.onIdentity[slot]),
      ),
    );
  }
}

/// Head of a share sheet: [leading], a title (two lines at most) and one
/// quiet line.
class ShareHero extends StatelessWidget {
  const ShareHero({super.key, required this.leading, required this.title, this.subtitle});

  final Widget leading;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Row(
      children: [
        leading,
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(height: 1.3),
              ),
              if (subtitle case final s? when s.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  s,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
