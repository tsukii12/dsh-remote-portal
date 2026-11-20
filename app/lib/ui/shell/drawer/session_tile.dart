// The drawer's conversation row and section label.

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../state/session_attention_state.dart';
import '../../common/status_dot.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../sessions_drawer.dart' show sessionSelectionColor;

/// One conversation row: 44 high, the highlight on the 10 line, the title on
/// the 20 line (plus [indent] inside a folder). At the end, one marker at
/// most: what it waits for (待确认 / 待回答), a breathing dot while it works,
/// or a quiet dot when it moved on since it was last seen. In multi-select a
/// check slides in before the title.
class SessionTile extends StatelessWidget {
  const SessionTile({
    super.key,
    required this.title,
    required this.running,
    required this.current,
    required this.onTap,
    required this.onLongPress,
    this.pending,
    this.unread = false,
    this.pinned = false,
    this.indent = 0,
    this.selecting = false,
    this.selected = false,
  });

  final String title;
  final bool running;

  /// The open conversation (soft fill; ignored while selecting).
  final bool current;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final PendingKind? pending;
  final bool unread;

  /// Shown as a small pin (inside folders; elsewhere 置顶 says it).
  final bool pinned;

  /// Content inset from the 20 line (folder members: [folderIndent]).
  final double indent;
  final bool selecting;
  final bool selected;

  static const height = 44.0;

  /// A folder's glyph (20) plus its gap (10): members' titles line up with
  /// the folder's name.
  static const folderIndent = 30.0;

  /// Width of the check slot while selecting (a 20 circle and a 10 gap).
  static const checkSlot = 30.0;

  /// Size of the quiet markers at the end of the row.
  static const dot = 7.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final shape = Squircle.border(AppShape.md);
    final highlighted = selecting ? selected : current;
    final Widget? marker = switch ((pending, running, unread)) {
      (final PendingKind kind, _, _) => Text(
        kind.label,
        key: const ValueKey('pending'),
        style: theme.textTheme.labelMedium?.copyWith(color: colors.warning, fontWeight: FontWeight.w500),
      ),
      (_, true, _) => const StatusDot(key: ValueKey('running'), tone: StatusTone.busy, size: dot),
      (_, _, true) => _UnreadDot(key: const ValueKey('unread'), color: scheme.onSurfaceVariant),
      _ => null,
    };
    final label = [
      title,
      ?pending?.label,
      if (pending == null && running) l10n.shellCurrentlyRunning,
      if (pending == null && !running && unread) l10n.shellUnread,
      if (pinned) l10n.shellPinned,
    ].join(l10n.shellSemanticsSeparator);
    return Semantics(
      selected: highlighted,
      checked: selecting ? selected : null,
      label: label,
      button: true,
      onTap: onTap,
      onLongPress: onLongPress,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          customBorder: shape,
          // Ink (not a container's decoration), so the splash draws over the
          // fill; the fill fades in and out.
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: highlighted ? 1 : 0),
            duration: AppMotion.of(context, AppMotion.quick),
            curve: AppMotion.std,
            builder: (context, t, child) {
              final fill = sessionSelectionColor(context);
              return Ink(
                decoration: ShapeDecoration(
                  color: fill.withValues(alpha: fill.a * t),
                  shape: shape,
                ),
                height: height,
                padding: EdgeInsets.only(left: 10 + indent, right: 10),
                child: child,
              );
            },
            child: Row(
              children: [
                _CheckSlot(selecting: selecting, selected: selected),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontSize: 15,
                      height: 1.4,
                      color: scheme.onSurface,
                      fontWeight: current && !selecting ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                if (pinned) ...[
                  const SizedBox(width: 8),
                  Icon(AppIcons.pinActive, size: 14, color: colors.textTertiary),
                ],
                AnimatedSwitcher(
                  duration: AppMotion.of(context, AppMotion.quick),
                  layoutBuilder: (current, previous) =>
                      Stack(alignment: Alignment.centerRight, children: [...previous, ?current]),
                  child: marker == null
                      ? const SizedBox.shrink(key: ValueKey('none'))
                      : Padding(key: marker.key, padding: const EdgeInsets.only(left: 10), child: marker),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UnreadDot extends StatelessWidget {
  const _UnreadDot({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: SessionTile.dot,
    height: SessionTile.dot,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// The check that slides in before the title while selecting: a 20 ring,
/// filled with ink and a tick once chosen (ink, not the brand colour — the
/// drawer keeps one primary element).
class _CheckSlot extends StatelessWidget {
  const _CheckSlot({required this.selecting, required this.selected});

  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: selecting ? 1 : 0),
      duration: AppMotion.of(context, AppMotion.standard),
      curve: AppMotion.std,
      builder: (context, t, child) {
        if (t == 0) return const SizedBox.shrink();
        return SizedBox(
          width: SessionTile.checkSlot * t,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: SessionTile.checkSlot,
              maxWidth: SessionTile.checkSlot,
              child: Opacity(opacity: t, child: child),
            ),
          ),
        );
      },
      child: Align(
        alignment: Alignment.centerLeft,
        child: AnimatedSwitcher(
          duration: AppMotion.of(context, AppMotion.quick),
          child: selected
              ? DecoratedBox(
                  key: const ValueKey('on'),
                  decoration: ShapeDecoration(color: scheme.onSurface, shape: const CircleBorder()),
                  child: SizedBox.square(
                    dimension: 20,
                    child: Icon(AppIcons.selected, size: 14, color: scheme.surface),
                  ),
                )
              : DecoratedBox(
                  key: const ValueKey('off'),
                  decoration: ShapeDecoration(
                    shape: CircleBorder(
                      side: BorderSide(color: scheme.onSurfaceVariant.withValues(alpha: 0.55), width: 1.5),
                    ),
                  ),
                  child: const SizedBox.square(dimension: 20),
                ),
        ),
      ),
    );
  }
}

/// A section label in the drawer list: small, faint, on the 20 line.
class DrawerEyebrow extends StatelessWidget {
  const DrawerEyebrow(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 16, 10, 6),
      child: Semantics(
        header: true,
        child: Text(text, style: AppType.eyebrow(color: DshColors.of(context).textTertiary)),
      ),
    );
  }
}
