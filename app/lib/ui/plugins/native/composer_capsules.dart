// The capsule row above the composer — ui.json's `composer.quickActions`
// (docs/design/plugin-seams.md §10.2) and the plugins' `composer.actions`
// (docs/design/native-plugins.md §3.3) in one row. ui.json's come first and in
// its order; plugins add up to two each, up to eight in all. A tap puts text in
// the composer or does what the capsule says; nothing is ever sent by it. The
// row steps aside while a reply is generating (the activity strip takes the
// place). Last, outside the eight, 「插件」 opens the conversation's plugin
// sheet (chat_plugins_sheet.dart) while it has something. The chat's own
// pills (「自动允许中」, 「完全权限」, the generation mode) lead the row, pinned
// while the capsules scroll: one row above the composer, not two.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show DshGoScope;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/native/native_model.dart';
import '../../../plugins/native/native_state.dart';
import '../../../ui_config/ui_config_model.dart';
import '../../../ui_config/ui_config_state.dart';
import '../../common/edge_fade.dart';
import '../../pets/pet_perch.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'chat_plugins_sheet.dart';
import 'native_taps.dart';
import 'rise_reveal.dart';

/// One capsule.
@immutable
class CapsuleItem {
  const CapsuleItem({required this.id, required this.label, this.icon, this.source, this.busyKey, required this.onTap});

  /// Stable across rebuilds (`ui:2`, `<package>#<id>`).
  final String id;
  final String label;
  final IconData? icon;

  /// The plugin it comes from (read out with the label).
  final String? source;

  /// The control whose work it shows ([nativeControlKey]); null for one
  /// that never waits.
  final String? busyKey;
  final VoidCallback onTap;
}

/// Capsule geometry, shared with the geometry tests.
abstract final class CapsuleMetrics {
  static const height = 34.0;

  /// Left and right of the content, equal on both sides.
  static const inset = 14.0;
  static const icon = 16.0;
  static const iconGap = 6.0;

  /// Between capsules.
  static const gap = 8.0;

  /// Between the row and the composer (the banners' rhythm).
  static const below = 8.0;
}

/// A glass capsule: an optional icon and a label, the same air left and
/// right, the height of the row. At work, its content gives way to a small
/// ring in the middle: the capsule keeps its size, nothing moves.
class ComposerCapsule extends ConsumerWidget {
  const ComposerCapsule({super.key, required this.item});

  final CapsuleItem item;

  /// The working ring.
  static const ring = 14.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = theme.textTheme.labelMedium?.copyWith(color: colors.onSurface, fontWeight: FontWeight.w500);
    final source = item.source;
    final key = item.busyKey;
    final work = key == null ? null : ref.watch(nativeWorkOfProvider(key));
    final busy = work != null;
    // At work on a deferred result: a tap drops it.
    final cancel = work?.cancel;
    final duration = AppMotion.of(context, AppMotion.quick);
    final l10n = context.l10n;
    return Semantics(
      button: true,
      label: busy ? '${item.label} ${work.label ?? l10n.plugslotsWorking}' : item.label,
      hint: cancel != null
          ? l10n.plugslotsTapToCancel
          : source == null
          ? null
          : l10n.plugslotsFromPlugin(source),
      excludeSemantics: true,
      child: GlassSurface(
        tier: GlassTier.chrome,
        stadium: true,
        grouped: true,
        onTap: busy ? cancel : item.onTap,
        child: SizedBox(
          height: CapsuleMetrics.height,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedOpacity(
                opacity: busy ? 0 : 1,
                duration: duration,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: CapsuleMetrics.inset),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.icon case final icon?) ...[
                        Icon(icon, size: CapsuleMetrics.icon, color: colors.onSurfaceVariant),
                        const SizedBox(width: CapsuleMetrics.iconGap),
                      ],
                      Text(item.label, maxLines: 1, softWrap: false, style: style),
                    ],
                  ),
                ),
              ),
              AnimatedOpacity(
                opacity: busy ? 1 : 0,
                duration: duration,
                child: SizedBox.square(
                  key: busy ? const ValueKey('capsule-ring') : null,
                  dimension: ring,
                  child: busy
                      ? CircularProgressIndicator(strokeWidth: 1.6, color: colors.onSurfaceVariant)
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row of capsules that scrolls sideways when it doesn't fit, fading at
/// the edge that has more.
///
/// The first capsule lines up with the composer's edge, but the scrolling
/// band reaches [bleed] further on each side (the screen's gutter) and
/// [shadowRoom] above and below, so the glass shadows are never cut and
/// capsules slide out under the screen's edge, not the composer's. A
/// [leading] widget stays put at the left; the band starts after it.
class ComposerCapsuleRow extends StatelessWidget {
  const ComposerCapsuleRow({super.key, required this.items, this.leading, this.bleed = 12});

  final List<CapsuleItem> items;

  /// Pinned before the capsules (the chat's pills), centred on the row.
  final Widget? leading;

  /// How far the band reaches past the row on each side.
  final double bleed;

  /// The chrome glass shadow's reach (blur 24, offset 8).
  static const shadowRoom = 32.0;

  @override
  Widget build(BuildContext context) {
    final leading = this.leading;
    return Padding(
      padding: const EdgeInsets.only(bottom: CapsuleMetrics.below),
      child: SizedBox(
        height: CapsuleMetrics.height,
        child: leading == null
            ? _band(left: bleed)
            : Row(
                children: [
                  leading,
                  if (items.isNotEmpty) ...[
                    const SizedBox(width: CapsuleMetrics.gap),
                    // Under the pinned pills nothing slides: the band starts here.
                    Expanded(child: _band(left: 0)),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _band({required double left}) => LayoutBuilder(
    builder: (context, constraints) => OverflowBox(
      alignment: left == bleed ? Alignment.center : Alignment.centerLeft,
      minWidth: constraints.maxWidth + left + bleed,
      maxWidth: constraints.maxWidth + left + bleed,
      minHeight: CapsuleMetrics.height + 2 * shadowRoom,
      maxHeight: CapsuleMetrics.height + 2 * shadowRoom,
      child: BackdropGroup(
        child: HorizontalEdgeFade(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.fromLTRB(left, shadowRoom, bleed, shadowRoom),
            child: Row(
              children: [
                for (final (i, item) in items.indexed) ...[
                  if (i > 0) const SizedBox(width: CapsuleMetrics.gap),
                  ComposerCapsule(key: ValueKey(item.id), item: item),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// The capsules of the composer on screen, in order: ui.json's (commands
/// only with a conversation open), then each plugin's switched-on ones, at
/// most [NativeLimits.capsulesTotal].
List<CapsuleItem> composerCapsules(
  BuildContext context,
  WidgetRef ref, {
  required String? sessionId,
  required List<UiQuickAction> quick,
  required List<NativeAction> plugins,
}) {
  final items = <CapsuleItem>[];
  for (final (i, q) in quick.indexed) {
    if (q.action is UiCommandAction && sessionId == null) continue;
    items.add(CapsuleItem(id: 'ui:$i', label: q.label, onTap: () => unawaited(runUiAction(context, ref, q.action))));
  }
  for (final a in plugins) {
    if (items.length >= NativeLimits.capsulesTotal) break;
    items.add(
      CapsuleItem(
        id: '${a.package}#${a.id}',
        label: a.label,
        icon: a.icon,
        source: ref.read(nativePluginTitleProvider(a.package)),
        busyKey: a.effects.isEmpty ? nativeControlKey(a.package, a.surface, a.id) : null,
        onTap: () => unawaited(runNativeAction(context, ref, a, scope: DshGoScope(sessionId: sessionId))),
      ),
    );
  }
  return items.length > NativeLimits.capsulesTotal ? items.sublist(0, NativeLimits.capsulesTotal) : items;
}

/// The row on the chat screen. [visible] false (a reply generating, read
/// only) folds it away; with no capsules and no [leading] it takes no room.
class ComposerCapsuleBar extends ConsumerStatefulWidget {
  const ComposerCapsuleBar({super.key, required this.sessionId, required this.visible, this.leading});

  final String? sessionId;
  final bool visible;

  /// See [ComposerCapsuleRow.leading].
  final Widget? leading;

  @override
  ConsumerState<ComposerCapsuleBar> createState() => _ComposerCapsuleBarState();
}

class _ComposerCapsuleBarState extends ConsumerState<ComposerCapsuleBar> {
  /// The last capsules and pills shown: they stay while the row folds away.
  List<CapsuleItem> _last = const [];
  Widget? _lastLeading;

  @override
  Widget build(BuildContext context) {
    final quick = ref.watch(uiOverridesProvider.select((o) => o.config.quickActions)) ?? const <UiQuickAction>[];
    final plugins = ref.watch(nativeComposerActionsProvider);
    final hidePluginCapsule = ref.watch(uiHiddenProvider(UiHideItem.pluginCapsule));
    final session = widget.sessionId;
    final items = [
      ...composerCapsules(context, ref, sessionId: session, quick: quick, plugins: plugins),
      if (!hidePluginCapsule && session != null && ref.watch(chatPluginsHaveContentProvider(session)))
        CapsuleItem(
          id: chatPluginsCapsuleId,
          label: context.l10n.plugslotsChatEntry,
          icon: AppIcons.plugin,
          onTap: () => unawaited(showChatPluginsSheet(context, sessionId: session)),
        ),
    ];
    final leading = widget.leading;
    final open = widget.visible && (items.isNotEmpty || leading != null);
    if (open) {
      _last = items;
      _lastLeading = leading;
    }
    return RiseReveal(
      open: open,
      child: _last.isEmpty && _lastLeading == null
          ? const SizedBox(width: double.infinity)
          // The chat page's pet stands on the row's top edge, above the
          // capsules (never on them); not while the row sinks.
          : PetPerch(
              kind: PerchKind.plugin,
              active: open,
              child: ComposerCapsuleRow(items: _last, leading: _lastLeading),
            ),
    );
  }
}
