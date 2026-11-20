// Lets a column of a split screen paint pieces of the
// one page backdrop ([BackdropVeil], [TopFade]) where they really are.

import 'package:flutter/widgets.dart';

/// Where a column sits inside the page backdrop behind it.
///
/// [BackdropVeil] paints a band of the page's backdrop and has to line up with
/// it exactly; it assumes its page starts at the backdrop's top-left corner
/// and is as large as the screen. A column of a wide layout (the chat between
/// the sidebar and the detail panel) is neither, so the layout says where the
/// column is: [origin] is its top-left corner in the backdrop, [area] the
/// whole backdrop.
class BackdropFrame extends InheritedWidget {
  const BackdropFrame({super.key, required this.origin, required this.area, required super.child});

  final Offset origin;
  final Size area;

  static BackdropFrame? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<BackdropFrame>();

  @override
  bool updateShouldNotify(BackdropFrame oldWidget) => oldWidget.origin != origin || oldWidget.area != area;
}
