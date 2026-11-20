// A plugin's status line above the composer (docs/design/native-plugins.md §3.3
// `composer.strip`): the plugin's icon and one short line bound to its live
// data — 「本对话 ¥0.42 · 今日 ¥3.1」. One at a time; several plugins take turns. It
// gives way to the activity strip while a reply is generating (same place,
// never both).

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show DshGoScope;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../plugins/native/native_icons.dart';
import '../../../plugins/native/native_model.dart';
import '../../../plugins/native/native_state.dart';
import '../../../plugins/native/native_surface.dart';
import '../../../state/plugins_state.dart';
import '../../pets/pet_perch.dart';
import '../../theme/theme.dart';
import '../plugin_widgets.dart' show PluginAvatar;
import 'native_panel.dart';
import 'native_taps.dart';
import 'native_tone.dart';
import 'rise_reveal.dart';

/// Strip geometry, shared with the geometry tests.
abstract final class StripMetrics {
  /// The activity strip's height.
  static const height = 36.0;

  /// The plugin icon: concentric with the left end (equal air top, left,
  /// bottom).
  static const icon = 20.0;
  static const iconInset = (height - icon) / 2;
  static const iconGap = 8.0;

  /// The text's end, like the activity strip's.
  static const end = 14.0;

  /// Between the strip and what is under it (the activity strip's rhythm).
  static const below = 6.0;

  /// How long each plugin's line stays before the next one's.
  static const turn = Duration(seconds: 6);

  /// Lines subscribed at once (the rest wait their turn).
  static const live = 4;
}

/// The status line itself: the plugin's icon and its line.
class ComposerStrip extends StatelessWidget {
  const ComposerStrip({
    super.key,
    required this.package,
    required this.title,
    required this.text,
    this.icon,
    this.avatar,
    this.tone,
    this.onTap,
  });

  final String package;

  /// The plugin's name (read out, and the mark's letter).
  final String title;
  final String text;

  /// An IconName (the line's, else the plugin's); unknown or none draws the
  /// plugin's own avatar.
  final String? icon;

  /// The plugin bundle's own picture (a data: or https: image), if any.
  final String? avatar;

  /// `good` · `warn` · `bad` · `info` · `muted` (the default).
  final String? tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final glyph = nativeIcon(icon);
    final color = nativeToneColor(dsh, tone) ?? theme.colorScheme.onSurface;
    return Semantics(
      button: onTap != null,
      label: '$title $text',
      excludeSemantics: true,
      child: GlassSurface(
        tier: GlassTier.chrome,
        stadium: true,
        onTap: onTap,
        child: SizedBox(
          height: StripMetrics.height,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(StripMetrics.iconInset, 0, StripMetrics.end, 0),
            child: Row(
              children: [
                SizedBox.square(
                  key: const ValueKey('strip-mark'),
                  dimension: StripMetrics.icon,
                  child: glyph != null
                      ? Icon(glyph, size: 16, color: dsh.textTertiary)
                      : PluginAvatar(name: package, title: title, icon: avatar, size: StripMetrics.icon),
                ),
                const SizedBox(width: StripMetrics.iconGap),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: AppMotion.of(context, AppMotion.quick),
                    layoutBuilder: (current, previous) =>
                        Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                    child: Text(
                      text,
                      key: ValueKey(text),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.tabular(
                        theme.textTheme.labelMedium!.copyWith(color: color, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What [strip] shows now: the plugin's data (`{text, icon, tone}`), else
/// its static text; the text cut to 24 characters, empty when there is
/// nothing to say.
({String text, String? icon, String? tone}) nativeStripLine(NativeStrip strip, NativeSurfaceState state) {
  final data = state.data;
  final map = data is Map ? data : null;
  final raw = map == null ? strip.text : (map['text'] is String ? map['text'] as String : null);
  final text = (raw ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  final runes = text.runes.toList();
  final cut = runes.length <= NativeLimits.stripTextMax
      ? text
      : '${String.fromCharCodes(runes.take(NativeLimits.stripTextMax - 1))}…';
  return (
    text: cut,
    icon: map?['icon'] is String ? map!['icon'] as String : strip.icon,
    tone: map?['tone'] is String ? map!['tone'] as String : null,
  );
}

/// The strip on the chat screen. [visible] false (a reply generating, read
/// only) sinks it; without plugin lines it takes no room at all.
class ComposerStripSlot extends ConsumerStatefulWidget {
  const ComposerStripSlot({super.key, required this.sessionId, required this.visible});

  final String? sessionId;
  final bool visible;

  @override
  ConsumerState<ComposerStripSlot> createState() => _ComposerStripSlotState();
}

class _ComposerStripSlotState extends ConsumerState<ComposerStripSlot> with WidgetsBindingObserver {
  Timer? _turn;
  int _index = 0;
  int _readyCount = 0;
  bool _tickerEnabled = true;
  bool _routeCurrent = true;

  bool get _canRotate {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return widget.visible &&
        _tickerEnabled &&
        _routeCurrent &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
  }

  /// The last line shown: it stays while the strip sinks.
  ({NativeStrip strip, String text, String? icon, String? tone})? _last;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _routeCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    _schedule(_readyCount);
  }

  @override
  void didUpdateWidget(ComposerStripSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) _schedule(_readyCount);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _schedule(_readyCount);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _turn?.cancel();
    super.dispose();
  }

  void _schedule(int count) {
    _readyCount = count;
    if (count < 2 || !_canRotate) {
      _turn?.cancel();
      _turn = null;
      return;
    }
    _turn ??= Timer.periodic(StripMetrics.turn, (_) {
      if (mounted) setState(() => _index++);
    });
  }

  void _tap(NativeStrip strip) {
    final plugin = ref.read(nativeContributionsProvider).plugin(strip.package);
    final panel = plugin?.panels.where((p) => p.id == strip.panel).firstOrNull;
    if (panel != null) {
      unawaited(openNativePanel(context, panel, sessionId: widget.sessionId));
    } else if (strip.tappable) {
      unawaited(
        runNativeTap(
          context,
          ref,
          package: strip.package,
          surface: NativeSurface.composerStrip,
          id: strip.id,
          scope: DshGoScope(sessionId: widget.sessionId),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final strips = ref.watch(nativeStripsProvider).take(StripMetrics.live).toList();
    final scope = DshGoScope(sessionId: widget.sessionId);
    // Every line is live (one subscription each); the ones with something
    // to say take turns.
    final ready = <({NativeStrip strip, String text, String? icon, String? tone})>[];
    for (final strip in strips) {
      final state = ref.watch(
        nativeSurfaceProvider(
          NativeSurfaceKey(
            package: strip.package,
            surface: NativeSurface.composerStrip,
            id: strip.id,
            scope: scope,
            live: strip.live,
          ),
        ),
      );
      final line = nativeStripLine(strip, state);
      if (line.text.isNotEmpty) ready.add((strip: strip, text: line.text, icon: line.icon, tone: line.tone));
    }
    _schedule(ready.length);
    final shown = ready.isEmpty ? null : ready[_index % ready.length];
    if (shown != null) _last = shown;
    final last = _last;
    Widget? strip;
    if (last != null) {
      final package = last.strip.package;
      final plugin = ref.watch(nativeContributionsProvider.select((c) => c.plugin(package)));
      final bundle = ref.watch(
        installedPluginsProvider.select((s) => s.value?.where((b) => b.name == package).firstOrNull),
      );
      final opens = plugin?.panels.any((p) => p.id == last.strip.panel) ?? false;
      strip = Padding(
        padding: const EdgeInsets.only(bottom: StripMetrics.below),
        // The chat page's pet stands on the strip while it is up.
        child: PetPerch(
          kind: PerchKind.plugin,
          active: widget.visible && shown != null,
          child: AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.standard),
            child: ComposerStrip(
              key: ValueKey('${last.strip.package}#${last.strip.id}'),
              package: package,
              title: ref.watch(nativePluginTitleProvider(package)),
              icon: last.icon ?? plugin?.icon,
              avatar: bundle?.meta?.icon,
              tone: last.tone,
              text: last.text,
              onTap: opens || last.strip.tappable ? () => _tap(last.strip) : null,
            ),
          ),
        ),
      );
    }
    return RiseReveal(
      open: widget.visible && shown != null,
      child: strip ?? const SizedBox(width: double.infinity),
    );
  }
}
