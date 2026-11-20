import 'package:flutter/widgets.dart';

/// A sheet has one dismissal affordance: a handle or an explicit title key.
enum SheetDismissal { drag, button }

/// Shared by ordinary modal sheets and the adaptive detail route.
class SheetDismissScope extends InheritedWidget {
  const SheetDismissScope({super.key, required this.dismissal, this.holds, required super.child});

  final SheetDismissal dismissal;

  /// A draggable modal sheet's holds (see [SheetDragHolds]); null elsewhere.
  final SheetDragHolds? holds;

  /// Standalone title bars keep their explicit close key.
  static SheetDismissal of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SheetDismissScope>()?.dismissal ?? SheetDismissal.button;

  /// The holds of the draggable sheet around [context], if any. No dependency:
  /// the holds of a sheet never change.
  static SheetDragHolds? holdsOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SheetDismissScope>()?.holds;

  @override
  bool updateShouldNotify(SheetDismissScope oldWidget) => dismissal != oldWidget.dismissal || holds != oldWidget.holds;
}

/// What keeps a draggable sheet from being dragged away: input not yet used.
///
/// Flutter closes a dragged modal sheet with `Navigator.pop`, which skips
/// [PopScope]; the handle, the scrim and system back go through
/// `Navigator.maybePop` and do ask it. While any hold is on, the sheet turns
/// a drag down into `maybePop` too, so the content's [PopScope] (a
/// `DiscardGuard`) asks first. `DiscardGuard` adds its `isDirty` here.
class SheetDragHolds {
  final _holds = <bool Function()>{};

  /// True while some content has input a drag would throw away.
  bool get held => _holds.any((hold) => hold());

  /// Adds [hold]; the returned callback removes it.
  VoidCallback add(bool Function() hold) {
    _holds.add(hold);
    return () => _holds.remove(hold);
  }
}
