// Rows that the index knows ([SettingSpot]) carry a [SpotAnchor]: their key
// for tests, and the place a search result or a row link lands. A page
// opened for one row is wrapped in [SpotFocus]; the page's scroll view
// ([AppPage]) brings the row into view and the row flashes its background
// twice (static for a second when animations are off). The flash only paints:
// the row keeps its size.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import 'spots.dart';

/// The key of a row's anchor: `find.byKey(SpotKey('phone-confirm'))`.
class SpotKey extends ValueKey<String> {
  const SpotKey(super.value);
}

/// Which row a page was opened for. One per pushed page; the anchor that
/// matches [target] reports itself, and the page brings it into view once.
class SpotFocus extends StatefulWidget {
  const SpotFocus({super.key, required this.target, required this.child});

  /// The [SettingSpot.id] to bring into view.
  final String target;
  final Widget child;

  static SpotFocusController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_SpotFocusScope>()?.controller;

  @override
  State<SpotFocus> createState() => _SpotFocusState();
}

class _SpotFocusState extends State<SpotFocus> {
  // Once per page: a rebuild of the route doesn't show the row again.
  late final _controller = SpotFocusController(widget.target);

  @override
  Widget build(BuildContext context) => _SpotFocusScope(controller: _controller, child: widget.child);
}

class _SpotFocusScope extends InheritedWidget {
  const _SpotFocusScope({required this.controller, required super.child});

  final SpotFocusController controller;

  @override
  bool updateShouldNotify(_SpotFocusScope oldWidget) => controller != oldWidget.controller;
}

/// The one-shot state of a [SpotFocus]: the target anchor once it is built,
/// and whether it has been shown.
class SpotFocusController {
  SpotFocusController(this.target);

  final String target;
  _SpotAnchorState? _anchor;
  bool _done = false;

  /// True once the target has been brought into view (or given up on).
  bool get done => _done;

  /// The target's anchor is on screen (built): its context.
  BuildContext? get anchor => _anchor?.mounted == true ? _anchor!.context : null;

  void _attach(_SpotAnchorState state) => _anchor = state;

  void _detach(_SpotAnchorState state) {
    if (_anchor == state) _anchor = null;
  }

  /// Scrolls the target to a third of the way down its viewport, then flashes
  /// it. Call once its anchor is built.
  Future<void> reveal() async {
    final state = _anchor;
    if (_done || state == null || !state.mounted) return;
    _done = true;
    final context = state.context;
    await Scrollable.ensureVisible(
      context,
      alignment: 1 / 3,
      duration: AppMotion.of(context, AppMotion.standard),
      curve: AppMotion.std,
    );
    if (state.mounted) state.flash();
  }

  /// Nothing to show (the row isn't on this page in its state).
  void giveUp() => _done = true;
}

/// Brings [SpotFocus]'s target into view in a page scrolled by [controller]:
/// rows a lazy list hasn't built yet are reached by scrolling down a screen
/// at a time until the anchor exists or the end is reached.
Future<void> seekSpot(BuildContext context, ScrollController controller) async {
  final focus = SpotFocus.maybeOf(context);
  if (focus == null || focus.done) return;
  // Content that arrives late (engine settings, presets) gets a few seconds;
  // walking down a page takes a frame per screen.
  var waits = 0;
  var steps = 0;
  while (!focus.done && context.mounted) {
    if (focus.anchor != null) return focus.reveal();
    if (controller.hasClients && steps < 40) {
      final position = controller.position;
      if (position.pixels < position.maxScrollExtent) {
        steps++;
        position.jumpTo(math.min(position.pixels + position.viewportDimension * 0.8, position.maxScrollExtent));
        await WidgetsBinding.instance.endOfFrame;
        continue;
      }
    }
    if (++waits > _seekWaits) break;
    await Future<void>.delayed(_seekWait);
  }
  if (focus.anchor != null) return focus.reveal();
  focus.giveUp();
}

const _seekWait = Duration(milliseconds: 50);
const _seekWaits = 60;

/// Marks [child] as [spot]'s row: keyed [SpotKey], and the place a search
/// result lands.
class SpotAnchor extends StatefulWidget {
  SpotAnchor({required this.spot, required this.child}) : super(key: SpotKey(spot.id));

  final SettingSpot spot;
  final Widget child;

  /// The flash: twice 0 → [peak] → 0 over [flashDuration].
  static const flashDuration = Duration(milliseconds: 1600);
  static const peak = 0.5;

  /// With animations off: a still highlight for this long.
  static const stillDuration = Duration(seconds: 1);

  @override
  State<SpotAnchor> createState() => _SpotAnchorState();
}

class _SpotAnchorState extends State<SpotAnchor> with SingleTickerProviderStateMixin {
  late final AnimationController _flash = AnimationController(vsync: this, duration: SpotAnchor.flashDuration);
  SpotFocusController? _focus;
  Timer? _still;
  bool _lit = false;

  static final _twice = TweenSequence<double>([
    for (var i = 0; i < 2; i++) ...[
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: SpotAnchor.peak).chain(CurveTween(curve: AppMotion.std)),
        weight: 1,
      ),
      TweenSequenceItem(
        tween: Tween(begin: SpotAnchor.peak, end: 0.0).chain(CurveTween(curve: AppMotion.std)),
        weight: 1,
      ),
    ],
  ]);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final focus = SpotFocus.maybeOf(context);
    if (focus == _focus) return;
    _focus?._detach(this);
    _focus = focus;
    if (focus != null && focus.target == widget.spot.id && !focus.done) {
      focus._attach(this);
      // Rows outside an [AppPage] (a sheet, a tab) bring themselves in.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !focus.done) unawaited(focus.reveal());
      });
    }
  }

  void flash() {
    if (AppMotion.reduced(context)) {
      setState(() => _lit = true);
      _still?.cancel();
      _still = Timer(SpotAnchor.stillDuration, () {
        if (mounted) setState(() => _lit = false);
      });
      return;
    }
    unawaited(_flash.forward(from: 0));
  }

  @override
  void dispose() {
    _focus?._detach(this);
    _still?.cancel();
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primaryContainer;
    // Always the same box, so the row underneath keeps its state when the
    // highlight comes and goes.
    return AnimatedBuilder(
      animation: _flash,
      builder: (context, child) {
        final alpha = _lit ? SpotAnchor.peak : (_flash.isAnimating ? _twice.evaluate(_flash) : 0.0);
        return DecoratedBox(
          decoration: BoxDecoration(color: alpha <= 0 ? null : color.withValues(alpha: alpha)),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// [child] as [spot]'s row when there is one.
Widget anchorSpot(SettingSpot? spot, Widget child) => spot == null ? child : SpotAnchor(spot: spot, child: child);
