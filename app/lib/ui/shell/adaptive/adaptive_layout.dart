// The window classes and the column plan of the home
// screen on tablets and foldables. Geometry follows DSH Web's AppFrame
// (`@deepseek-ai/dsh-client-ui-layout`): the right panel gives way first to
// keep the chat column wide enough, and opening it folds a sidebar that no
// longer fits into the rail.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Window size classes (Material 3 breakpoints), with one rule on top: a
/// window under [compactHeight] tall is [compact] whatever its width.
///
/// That is a phone on its side (915 × 412): wide, but with the status bar,
/// the header and the composer there is room for a few lines of chat, and
/// the keyboard takes half of it. Columns side by side would each get that
/// sliver; one centred column keeps the width for code and tables, the way
/// Android has always told phones from tablets (by the shortest side).
enum WindowClass {
  /// < 600, or under [compactHeight]: phones, upright or on their side. The
  /// conversation detail is a pushed page.
  compact,

  /// 600–840: an open foldable, a small tablet in portrait. The detail is a
  /// wide bottom sheet with two heights.
  medium,

  /// ≥ 840: tablets in landscape, large screens. The detail is a persistent
  /// right panel; the conversation list is a rail or a sidebar.
  expanded;

  static const mediumMin = 600.0;
  static const expandedMin = 840.0;

  /// Material 3's compact height: below it, a window is a phone on its side.
  static const compactHeight = 480.0;

  static WindowClass of(double width, [double height = double.infinity]) => height < compactHeight
      ? compact
      : width >= expandedMin
      ? expanded
      : width >= mediumMin
      ? medium
      : compact;

  /// [of] for a window [size].
  static WindowClass ofSize(Size size) => of(size.width, size.height);
}

/// What stands at the left edge of a wide window.
enum LeftPane {
  /// Nothing persistent: the conversation list is the pull-over drawer.
  none,

  /// A column of round keys (open the list, search, host, 网页版, 设置).
  rail,

  /// The conversation list itself, always shown.
  sidebar,
}

/// What the ≡ key does in the current layout.
enum MenuAction {
  /// Pull the drawer over everything (phones, or no room for the sidebar).
  overlay,

  /// Unfold the rail into the persistent sidebar.
  expand,

  /// Fold the persistent sidebar back into the rail.
  collapse,
}

/// How the conversation detail opens.
enum DetailPresentation { page, sheet, panel }

/// Column widths and margins, in logical pixels.
abstract final class AdaptiveMetrics {
  /// Round keys: 44, 12 from the edges like the header's.
  static const key = 44.0;
  static const edge = 12.0;
  static const gap = 8.0;

  /// 12 + 44 + 12.
  static const railWidth = edge + key + edge;

  /// The phone drawer's own width, so the list reads the same.
  static const sidebarWidth = 320.0;

  /// The right panel: about a phone's width, which its tabs were drawn for.
  static const panelMin = 320.0;
  static const panelIdealMin = 360.0;
  static const panelMax = 420.0;
  static const panelFraction = 0.3;
  static const panelStep = 4.0;

  /// The chat column never gets narrower than a phone (DSH Web keeps 400).
  static const chatMin = 400.0;

  /// The sidebar stays unfolded only while the chat keeps this much.
  static const chatComfort = 600.0;

  /// Snapped to the 4dp grid.
  static double panelIdeal(double windowWidth) {
    final raw = (windowWidth * panelFraction / panelStep).roundToDouble() * panelStep;
    return raw.clamp(panelIdealMin, panelMax);
  }
}

/// The resolved plan for one window: which columns show and how wide they are.
///
/// Pure: [resolve] turns the window, the system insets and the person's
/// choices (sidebar / panel unfolded) into columns. Everything that has to
/// agree — the scaffold, the header keys, where 对话详情 opens — reads the
/// same value.
@immutable
class AdaptiveLayout {
  const AdaptiveLayout({
    required this.windowClass,
    required this.window,
    required this.padding,
    required this.left,
    required this.panelWidth,
    required this.panelAvailable,
    required this.panelShown,
    required this.sidebarFits,
  });

  /// Every column hidden: the phone layout.
  const AdaptiveLayout.compact({
    this.window = Size.zero,
    this.padding = EdgeInsets.zero,
    this.windowClass = WindowClass.compact,
  }) : left = LeftPane.none,
       panelWidth = 0,
       panelAvailable = false,
       panelShown = false,
       sidebarFits = false;

  /// [window] is the whole window, [padding] the system insets (status and
  /// navigation bars, cutouts). [hasSession]: no conversation, no panel.
  factory AdaptiveLayout.resolve({
    required Size window,
    EdgeInsets padding = EdgeInsets.zero,
    required bool hasSession,
    bool sidebarOpen = true,
    bool panelOpen = true,
  }) {
    final windowClass = WindowClass.ofSize(window);
    if (windowClass != WindowClass.expanded) {
      return AdaptiveLayout.compact(window: window, padding: padding, windowClass: windowClass);
    }
    final inner = window.width - padding.left - padding.right;
    // The panel gives way first: down to its minimum, then it doesn't show.
    final room = inner - AdaptiveMetrics.railWidth - AdaptiveMetrics.chatMin;
    final width = math.min(AdaptiveMetrics.panelIdeal(window.width), room);
    final available = hasSession && width >= AdaptiveMetrics.panelMin;
    final shown = available && panelOpen;
    final sidebarRoom = inner - AdaptiveMetrics.sidebarWidth - AdaptiveMetrics.chatComfort;
    // A 4dp rounding step must not fold the sidebar as the window grows.
    // Decide from the continuous lower bound, then keep the drawn panel on
    // its grid within the chat's 600dp budget.
    final panelLowerBound = (window.width * AdaptiveMetrics.panelFraction - AdaptiveMetrics.panelStep / 2).clamp(
      AdaptiveMetrics.panelIdealMin,
      AdaptiveMetrics.panelMax,
    );
    final fits = sidebarRoom >= (shown ? panelLowerBound : 0.0);
    final fittedWidth = shown && fits
        ? math.min(width, (sidebarRoom / AdaptiveMetrics.panelStep).floorToDouble() * AdaptiveMetrics.panelStep)
        : width;
    return AdaptiveLayout(
      windowClass: windowClass,
      window: window,
      padding: padding,
      left: sidebarOpen && fits ? LeftPane.sidebar : LeftPane.rail,
      panelWidth: available ? fittedWidth : 0,
      panelAvailable: available,
      panelShown: shown,
      sidebarFits: fits,
    );
  }

  final WindowClass windowClass;
  final Size window;
  final EdgeInsets padding;
  final LeftPane left;

  /// The panel's content width (system insets excluded); 0 when it can't show.
  final double panelWidth;

  /// A conversation is open and the window has room for the panel.
  final bool panelAvailable;

  /// The panel is on screen (available and not folded away).
  final bool panelShown;

  /// The sidebar would fit next to the chat (and the panel, when shown).
  final bool sidebarFits;

  bool get isExpanded => windowClass == WindowClass.expanded;

  /// The left column's content width.
  double get leftWidth => switch (left) {
    LeftPane.none => 0,
    LeftPane.rail => AdaptiveMetrics.railWidth,
    LeftPane.sidebar => AdaptiveMetrics.sidebarWidth,
  };

  /// The left column on screen, the inset it covers included.
  double get leftExtent => left == LeftPane.none ? 0 : leftWidth + padding.left;

  /// The panel on screen, the inset it covers included.
  double get panelExtent => panelShown ? panelWidth + padding.right : 0;

  /// The chat column.
  Rect get chatRect => Rect.fromLTRB(leftExtent, 0, window.width - panelExtent, window.height);

  MenuAction get menuAction => switch (left) {
    LeftPane.none => MenuAction.overlay,
    LeftPane.sidebar => MenuAction.collapse,
    LeftPane.rail => sidebarFits ? MenuAction.expand : MenuAction.overlay,
  };

  /// Where 对话详情 opens.
  DetailPresentation get detail => panelAvailable
      ? DetailPresentation.panel
      : windowClass == WindowClass.compact
      ? DetailPresentation.page
      : DetailPresentation.sheet;

  @override
  bool operator ==(Object other) =>
      other is AdaptiveLayout &&
      other.windowClass == windowClass &&
      other.window == window &&
      other.padding == padding &&
      other.left == left &&
      other.panelWidth == panelWidth &&
      other.panelAvailable == panelAvailable &&
      other.panelShown == panelShown &&
      other.sidebarFits == sidebarFits;

  @override
  int get hashCode =>
      Object.hash(windowClass, window, padding, left, panelWidth, panelAvailable, panelShown, sidebarFits);

  @override
  String toString() =>
      'AdaptiveLayout(${windowClass.name}, ${window.width}×${window.height}, '
      'left: ${left.name}, panel: ${panelShown ? panelWidth : '—'})';
}
