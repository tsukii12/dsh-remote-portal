// The home screen's frame on tablets and foldables:
// the conversation list as a rail or a sidebar on the left, the chat in the
// middle, 对话详情 as a column on the right (DSH Web's AppFrame, `push`
// presentation: the chat gives way, the panel's left edge moves with it).

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../common/side_insets.dart';
import '../../theme/backdrop_frame.dart';
import '../../theme/theme.dart';
import 'adaptive_layout.dart';

/// The resolved [AdaptiveLayout] for everything under the home frame.
///
/// The chat header reads it to drop its ≡ key next to the rail, to name what
/// ≡ does, and to show the corner key that brings a folded panel back; 对话详情
/// reads it to choose page, sheet or panel.
class AdaptiveChrome extends InheritedWidget {
  const AdaptiveChrome({super.key, required this.layout, required super.child});

  final AdaptiveLayout layout;

  static AdaptiveChrome? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AdaptiveChrome>();

  /// The layout without listening (for a tap handler).
  static AdaptiveLayout? layoutOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AdaptiveChrome>()?.layout;

  /// The chat header draws its ≡ key (the rail carries its own).
  bool get showsMenuKey => layout.left != LeftPane.rail;

  /// What the ≡ key says it does.
  String get menuTooltip => menuTooltipFor(layout);

  static String menuTooltipFor(AdaptiveLayout layout) => switch (layout.menuAction) {
    MenuAction.collapse => appL10n.shellCollapseChatList,
    MenuAction.expand => appL10n.shellExpandChatList,
    MenuAction.overlay => appL10n.shellChatList,
  };

  /// The chat header shows the key that unfolds 对话详情 again.
  bool get showsPanelKey => layout.panelAvailable && !layout.panelShown;

  @override
  bool updateShouldNotify(AdaptiveChrome oldWidget) => oldWidget.layout != layout;
}

/// Lays out the home screen by [layout]:
///
/// ```
/// compact / medium   ┌──────────── body ────────────┐
///
/// expanded           ┌ rail ┬──── body ────┬ panel ┐   (panel shown)
///                    ┌── sidebar ──┬──── body ────┐    (room for the list)
/// ```
///
/// - Columns move on one curve when the person folds or unfolds one (the
///   chat's edges travel with the sidebar's and the panel's); a new window
///   size or class snaps instead.
/// - Each column sees itself as the window ([MediaQuery] size and insets):
///   the system insets belong to the rail, the sidebar and the panel at
///   their edge; the chat is set in from them instead (the larger side inset
///   on both sides on a phone, see [sideInsetFor]) and sees none, and
///   [BackdropFrame] tells its veils where the column sits in the one page
///   backdrop painted behind all of them.
/// - The body keeps its element across every change (rotation, unfolding),
///   so the chat keeps its scroll position and draft.
/// - The panel is a flat column on the page (not a card), set off from the
///   chat by a hairline. The sidebar keeps the drawer's own glass.
class AdaptiveScaffold extends StatefulWidget {
  const AdaptiveScaffold({
    super.key,
    required this.layout,
    required this.body,
    this.sidebar,
    this.rail,
    this.panel,
    this.animate = true,
  });

  final AdaptiveLayout layout;

  /// The chat.
  final Widget body;

  /// The persistent conversation list ([LeftPane.sidebar]).
  final Widget? sidebar;

  /// The folded list ([LeftPane.rail]).
  final Widget? rail;

  /// 对话详情 in panel form, for the open conversation (null without one).
  /// The last one is kept while it slides away.
  final Widget? panel;

  /// False snaps every change (stored choices arriving at launch).
  final bool animate;

  @override
  State<AdaptiveScaffold> createState() => _AdaptiveScaffoldState();
}

class _AdaptiveScaffoldState extends State<AdaptiveScaffold> with TickerProviderStateMixin {
  /// 0 = rail, 1 = sidebar.
  late final AnimationController _side = AnimationController(vsync: this);

  /// 0 = panel away, 1 = panel shown.
  late final AnimationController _panel = AnimationController(vsync: this);

  AdaptiveLayout? _last;

  /// While the panel slides away it keeps its width and content.
  double _panelWidth = 0;
  Widget? _panelChild;

  @override
  void initState() {
    super.initState();
    _panel.addStatusListener((status) {
      // Gone for good: let the content go (its tab is in the shared state).
      if (status == AnimationStatus.dismissed && !widget.layout.panelShown) {
        setState(() => _panelChild = widget.panel);
      }
    });
  }

  @override
  void dispose() {
    _side.dispose();
    _panel.dispose();
    super.dispose();
  }

  void _sync(AdaptiveLayout layout) {
    final last = _last;
    _last = layout;
    if (layout.panelWidth > 0) _panelWidth = layout.panelWidth;
    if (widget.panel != null) _panelChild = widget.panel;
    final side = layout.left == LeftPane.sidebar ? 1.0 : 0.0;
    final panel = layout.panelShown ? 1.0 : 0.0;
    final snap =
        last == null ||
        !widget.animate ||
        last.window != layout.window ||
        last.windowClass != layout.windowClass ||
        !layout.isExpanded;
    if (snap) {
      // Children are built after this, in the same frame: they see the new
      // values directly.
      _side.value = side;
      _panel.value = panel;
      if (!layout.panelShown) _panelChild = widget.panel;
      return;
    }
    final duration = AppMotion.of(context, AppMotion.emphasized);
    if (_side.value != side && (_side.isAnimating ? _sideTarget != side : true)) {
      _sideTarget = side;
      _side.animateTo(side, duration: duration, curve: AppMotion.glide);
    }
    if (_panel.value != panel && (_panel.isAnimating ? _panelTarget != panel : true)) {
      _panelTarget = panel;
      _panel.animateTo(panel, duration: duration, curve: AppMotion.glide);
    }
  }

  double? _sideTarget;
  double? _panelTarget;

  @override
  Widget build(BuildContext context) {
    final layout = widget.layout;
    _sync(layout);
    return AdaptiveChrome(
      layout: layout,
      child: LayoutBuilder(
        builder: (context, constraints) => AnimatedBuilder(
          animation: Listenable.merge([_side, _panel]),
          builder: (context, _) => _frame(context, layout, constraints.biggest),
        ),
      ),
    );
  }

  Widget _frame(BuildContext context, AdaptiveLayout layout, Size window) {
    final media = MediaQuery.of(context);
    final inset = media.padding;
    final expanded = layout.isExpanded;
    final side = _side.value;
    final shown = _panel.value;

    final railExtent = AdaptiveMetrics.railWidth + inset.left;
    final sidebarExtent = AdaptiveMetrics.sidebarWidth + inset.left;
    final leftExtent = expanded ? lerpDouble(railExtent, sidebarExtent, side)! : 0.0;
    final panelFull = _panelWidth + inset.right;
    final panelExtent = expanded && _panelChild != null ? panelFull * shown : 0.0;
    // The chat keeps clear of the system insets at its edges: on a phone
    // (on its side) the larger one on both sides (`side_insets.dart`), on a
    // wide window the rail or sidebar takes the left one and the panel, or
    // the chat itself, the right one.
    final mirrored = expanded ? 0.0 : sideInsetFor(inset);
    final chatLeft = expanded ? leftExtent : mirrored;
    final chatRight = expanded ? math.max(panelExtent, inset.right) : mirrored;
    final chatWidth = (window.width - chatLeft - chatRight).clamp(0.0, window.width);

    return Stack(
      fit: StackFit.expand,
      children: [
        // The chat. Always the first child, always the same subtree.
        Positioned(
          left: chatLeft,
          top: 0,
          bottom: 0,
          width: chatWidth,
          child: _Column(
            media: media,
            origin: Offset(chatLeft, 0),
            area: window,
            width: chatWidth,
            leftEdge: false,
            rightEdge: false,
            child: widget.body,
          ),
        ),
        // 对话详情: full width while it slides, its left edge with the chat's.
        Positioned(
          left: window.width - panelExtent,
          top: 0,
          bottom: 0,
          width: panelFull,
          child: panelExtent == 0
              ? const SizedBox.shrink()
              : _PanelColumn(
                  media: media,
                  origin: Offset(window.width - panelExtent, 0),
                  area: window,
                  width: _panelWidth,
                  child: _panelChild!,
                ),
        ),
        // The rail fades as the sidebar slides over it.
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: railExtent,
          child: !expanded || widget.rail == null || side == 1
              ? const SizedBox.shrink()
              : IgnorePointer(
                  ignoring: side > 0.5,
                  child: Opacity(
                    opacity: (1 - side * 2).clamp(0.0, 1.0),
                    child: _Column(
                      media: media,
                      origin: Offset.zero,
                      area: window,
                      width: railExtent,
                      leftEdge: true,
                      rightEdge: false,
                      child: widget.rail!,
                    ),
                  ),
                ),
        ),
        Positioned(
          left: (side - 1) * sidebarExtent,
          top: 0,
          bottom: 0,
          width: sidebarExtent,
          child: !expanded || widget.sidebar == null || side == 0
              ? const SizedBox.shrink()
              : _Column(
                  media: media,
                  origin: Offset((side - 1) * sidebarExtent, 0),
                  area: window,
                  width: sidebarExtent,
                  leftEdge: true,
                  rightEdge: false,
                  child: RepaintBoundary(child: widget.sidebar),
                ),
        ),
      ],
    );
  }
}

/// One column: its own [MediaQuery] (size, and the system insets only on the
/// window edges it touches) and its place in the backdrop.
class _Column extends StatelessWidget {
  const _Column({
    required this.media,
    required this.origin,
    required this.area,
    required this.width,
    required this.leftEdge,
    required this.rightEdge,
    required this.child,
  });

  final MediaQueryData media;
  final Offset origin;
  final Size area;
  final double width;
  final bool leftEdge;
  final bool rightEdge;
  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: columnMedia(media, width: width, leftEdge: leftEdge, rightEdge: rightEdge),
    child: BackdropFrame(origin: origin, area: area, child: child),
  );
}

/// The panel: a hairline on its left edge, its content clear of the right
/// inset (the navigation bar of a landscape tablet), which shows the page.
class _PanelColumn extends StatelessWidget {
  const _PanelColumn({
    required this.media,
    required this.origin,
    required this.area,
    required this.width,
    required this.child,
  });

  final MediaQueryData media;
  final Offset origin;
  final Size area;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final hairline = DshSurfaces.of(context).chrome.hairline;
    final line = 1 / media.devicePixelRatio;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: width,
          child: MediaQuery(
            data: columnMedia(media, width: width, leftEdge: false, rightEdge: false),
            child: BackdropFrame(
              origin: origin,
              area: area,
              child: RepaintBoundary(
                child: Material(type: MaterialType.transparency, child: child),
              ),
            ),
          ),
        ),
        Positioned(
          key: const ValueKey('adaptive-panel-hairline'),
          left: 0,
          top: 0,
          bottom: 0,
          width: line,
          child: IgnorePointer(child: ColoredBox(color: hairline)),
        ),
      ],
    );
  }
}

/// [media] for a column [width] wide that touches the window's left / right
/// edge or not: insets on a side it doesn't touch belong to its neighbour.
MediaQueryData columnMedia(
  MediaQueryData media, {
  required double width,
  required bool leftEdge,
  required bool rightEdge,
}) {
  EdgeInsets trim(EdgeInsets e) => EdgeInsets.fromLTRB(leftEdge ? e.left : 0, e.top, rightEdge ? e.right : 0, e.bottom);
  return media.copyWith(
    size: Size(width, media.size.height),
    padding: trim(media.padding),
    viewPadding: trim(media.viewPadding),
    viewInsets: trim(media.viewInsets),
    systemGestureInsets: trim(media.systemGestureInsets),
  );
}
