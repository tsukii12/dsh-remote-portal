// 对话详情 on a medium window (an open foldable, a small
// tablet upright) — a bottom sheet wider than the app's other sheets, with
// two heights: half (the chat stays in sight above it) and full.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/l10n.dart';
import '../../common/app_sheet.dart' show SheetDragHandle, SheetDismissal, SheetDismissScope;
import '../../theme/theme.dart';
import 'adaptive_layout.dart';

/// Opens [builder] in the two-height detail sheet.
///
/// [onWide] runs if the window grows into the expanded class while the sheet
/// is the top route (a tablet turned to landscape): the sheet closes and the
/// caller shows the same thing as a panel instead.
Future<void> showDetailSheet(
  BuildContext context, {
  required WidgetBuilder builder,
  String? label,
  VoidCallback? onWide,
}) {
  final reduced = AppMotion.reduced(context);
  return Navigator.of(context).push(
    _DetailSheetRoute(
      builder: builder,
      label: label ?? context.l10n.shellChatDetails,
      onWide: onWide,
      barrier: DshSurfaces.of(context).scrim,
      inDuration: reduced ? Duration.zero : AppMotion.sheetIn,
      outDuration: reduced ? Duration.zero : AppMotion.sheetOut,
    ),
  );
}

/// What a sheet's content can ask of it.
class DetailSheetScope extends InheritedWidget {
  const DetailSheetScope({
    super.key,
    required this.dragArea,
    required this.full,
    required this.toggle,
    required super.child,
  });

  /// Wraps a fixed part of the content (its title row) so a vertical drag on
  /// it moves the sheet, like the handle.
  final Widget Function(Widget child) dragArea;

  /// At the full height.
  final bool full;

  /// Half ↔ full.
  final VoidCallback toggle;

  static DetailSheetScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DetailSheetScope>();

  @override
  bool updateShouldNotify(DetailSheetScope oldWidget) => oldWidget.full != full;
}

/// The sheet's geometry for a window: as wide as the chat's reading column
/// (wider than the 640 of other sheets), centred; half the window tall, or
/// all of it but the status bar and a 12dp margin.
@immutable
class DetailSheetMetrics {
  const DetailSheetMetrics({required this.width, required this.half, required this.full});

  factory DetailSheetMetrics.of(Size window, EdgeInsets padding) {
    final full = window.height - padding.top - AdaptiveMetrics.edge;
    return DetailSheetMetrics(
      width: math.min(window.width, AppSpace.readingWidth + 24),
      half: math.min((window.height / 2).roundToDouble(), full),
      full: full,
    );
  }

  final double width;
  final double half;
  final double full;
}

class _DetailSheetRoute extends PopupRoute<void> {
  _DetailSheetRoute({
    required this.builder,
    required this.label,
    required this.barrier,
    required this.inDuration,
    required this.outDuration,
    this.onWide,
  });

  final WidgetBuilder builder;
  final String label;
  final Color barrier;
  final Duration inDuration;
  final Duration outDuration;
  final VoidCallback? onWide;

  /// Set by a drag that closes the sheet, in route values a second: the pop
  /// leaves at the finger's speed instead of taking [outDuration].
  double? fallVelocity;

  @override
  Simulation? createSimulation({required bool forward}) {
    final velocity = fallVelocity;
    if (forward || velocity == null) return super.createSimulation(forward: forward);
    return AppMotion.settle(AppMotion.sheetSpring, controller!.value, 0, velocity, landing: false);
  }

  @override
  Color? get barrierColor => barrier;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => appL10n.commonClose;

  @override
  Duration get transitionDuration => inDuration;

  @override
  Duration get reverseTransitionDuration => outDuration;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      SheetDismissScope(
        dismissal: SheetDismissal.drag,
        child: _DetailSheet(route: this),
      );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

class _DetailSheet extends StatefulWidget {
  const _DetailSheet({required this.route});

  final _DetailSheetRoute route;

  @override
  State<_DetailSheet> createState() => _DetailSheetState();
}

class _DetailSheetState extends State<_DetailSheet> with SingleTickerProviderStateMixin {
  /// 0 = half, 1 = full. A drag goes on past both: below 0 it pulls the sheet
  /// down towards closing, above 1 it stretches the sheet on a rubber band.
  late final AnimationController _snap = AnimationController.unbounded(vsync: this);

  late final CurvedAnimation _enter = CurvedAnimation(
    parent: widget.route.animation!,
    curve: AppMotion.sheetRise,
    reverseCurve: AppMotion.sheetFall,
  );

  DetailSheetMetrics _metrics = const DetailSheetMetrics(width: 0, half: 0, full: 0);
  bool _promoted = false;

  static const _fling = 700.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    if (!_promoted && widget.route.onWide != null && WindowClass.ofSize(size) == WindowClass.expanded) {
      _promoted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.route.isCurrent) return;
        widget.route.onWide!();
        Navigator.of(context).pop();
      });
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _snap.dispose();
    super.dispose();
  }

  /// [_snap]'s one unit, in logical pixels.
  double get _range => math.max(_metrics.full - _metrics.half, 1);

  void _settleTo(double target, double velocity, SpringDescription spring) {
    if (AppMotion.reduced(context)) {
      _snap.value = target;
    } else {
      _snap.animateWith(AppMotion.settle(spring, _snap.value, target, velocity));
    }
  }

  void _toggle() {
    HapticFeedback.selectionClick();
    _settleTo(_snap.value >= 0.5 ? 0 : 1, _snap.velocity, AppMotion.layoutSpring);
  }

  void _onDragStart(DragStartDetails _) => _snap.stop();

  void _onDragUpdate(DragUpdateDetails details) {
    _snap.value -= (details.primaryDelta ?? details.delta.dy) / _range;
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final pulled = -_snap.value * _range;
    if (pulled > 0 && (velocity > _fling || (velocity >= -_fling && pulled > _metrics.half * 0.25))) {
      unawaited(_close(velocity));
      return;
    }
    final target = pulled > 0 || velocity > _fling ? 0.0 : (velocity < -_fling || _snap.value >= 0.5 ? 1.0 : 0.0);
    _settleTo(target, -velocity / _range, AppMotion.sheetSpring);
  }

  Future<void> _close(double velocity) async {
    final route = widget.route;
    // Still rising, the route's value isn't the position yet: leave as a tap would.
    if (!AppMotion.reduced(context) && route.animation!.isCompleted) route.fallVelocity = -velocity / _metrics.half;
    await Navigator.of(context).maybePop();
    // Still here: the content's PopScope said no.
    if (mounted && route.isActive) {
      route.fallVelocity = null;
      _settleTo(0, 0, AppMotion.sheetSpring);
    }
  }

  Widget _dragArea(Widget child) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onVerticalDragStart: _onDragStart,
    onVerticalDragUpdate: _onDragUpdate,
    onVerticalDragEnd: _onDragEnd,
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    _metrics = DetailSheetMetrics.of(media.size, media.padding);
    final metrics = _metrics;
    return AnimatedBuilder(
      animation: Listenable.merge([_snap, _enter]),
      builder: (context, child) {
        final snap = _snap.value;
        final stretch = AppMotion.rubberBand(math.max(0, snap - 1) * _range);
        final height = lerpDouble(metrics.half, metrics.full, snap.clamp(0.0, 1.0))! + stretch;
        // Leaving at the finger's speed, the route's value is the position as it is.
        final shown = widget.route.fallVelocity == null ? _enter.value : widget.route.animation!.value;
        final down = math.max(0, -snap * _range) + (1 - shown) * height;
        return Align(
          alignment: Alignment.bottomCenter,
          child: Transform.translate(
            offset: Offset(0, down),
            child: SizedBox(key: const ValueKey('detail-sheet'), width: metrics.width, height: height, child: child),
          ),
        );
      },
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: widget.route.label,
        child: GlassSurface(
          tier: GlassTier.sheet,
          // Opaque: the bands behind the pinned rows take its colour.
          blur: false,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(AppShape.xl)),
          child: Material(
            type: MaterialType.transparency,
            child: ListenableBuilder(
              listenable: _snap,
              builder: (context, content) =>
                  DetailSheetScope(dragArea: _dragArea, full: _snap.value >= 0.5, toggle: _toggle, child: content!),
              child: Column(
                children: [
                  _dragArea(_Handle(snap: _snap, onTap: _toggle)),
                  // The status bar is above the sheet even at full height.
                  Expanded(
                    child: MediaQuery.removePadding(
                      context: context,
                      removeTop: true,
                      child: Builder(builder: widget.route.builder),
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

/// The drag handle, also a key: half ↔ full.
class _Handle extends StatelessWidget {
  const _Handle({required this.snap, required this.onTap});

  final Animation<double> snap;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: snap,
    builder: (context, child) => Semantics(
      button: true,
      label: snap.value >= 0.5 ? context.l10n.commonCollapse : context.l10n.shellExpand,
      onTap: onTap,
      onDismiss: () => Navigator.of(context).maybePop(),
      excludeSemantics: true,
      child: child,
    ),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: const SizedBox(
        width: double.infinity,
        child: Center(child: SheetDragHandle()),
      ),
    ),
  );
}
