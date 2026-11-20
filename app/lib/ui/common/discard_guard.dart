import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme/theme.dart';
import 'app_dialog.dart';
import 'sheet_dismissal.dart';

/// Wraps an edit page: while [isDirty], back (button, gesture or a
/// notification popping back to the chat) asks 「放弃修改？」 first. In a
/// draggable sheet a drag down asks too ([SheetDragHolds]).
///
/// [listenable] is what the page's edits notify through (its text fields);
/// edits made with `setState` rebuild the guard with the page.
class DiscardGuard extends StatefulWidget {
  const DiscardGuard({super.key, required this.listenable, required this.isDirty, required this.child});

  final Listenable listenable;
  final bool Function() isDirty;
  final Widget child;

  static final _guards = <_DiscardGuardState>{};
  static Future<bool>? _asking;

  /// True when nothing open has unsaved edits, or the person chose 「放弃」.
  static Future<bool> confirmLeave(BuildContext context) {
    if (!_guards.any((guard) => guard.widget.isDirty())) return Future.value(true);
    return _confirm(context);
  }

  /// One dialog at a time: a second ask while it is up gets the same answer.
  static Future<bool> _confirm(BuildContext context) => _asking ??= _ask(context).whenComplete(() => _asking = null);

  static Future<bool> _ask(BuildContext context) async {
    final discard = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.botsDiscardTitle),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.botsKeepEditing)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.botsDiscard),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  @override
  State<DiscardGuard> createState() => _DiscardGuardState();
}

class _DiscardGuardState extends State<DiscardGuard> {
  VoidCallback? _releaseSheetHold;

  @override
  void initState() {
    super.initState();
    DiscardGuard._guards.add(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _releaseSheetHold ??= SheetDismissScope.holdsOf(context)?.add(() => widget.isDirty());
  }

  @override
  void dispose() {
    _releaseSheetHold?.call();
    DiscardGuard._guards.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.listenable,
    child: widget.child,
    builder: (context, child) => PopScope<Object?>(
      canPop: !widget.isDirty(),
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await DiscardGuard._confirm(context) && context.mounted) Navigator.of(context).pop(result);
      },
      child: child!,
    ),
  );
}
