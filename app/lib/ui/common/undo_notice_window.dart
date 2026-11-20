import 'dart:async';

import 'package:flutter/material.dart';

/// One undo notice per messenger, shared by archive and plugin removal.
/// Reserving an intent changes nothing; a rejected request keeps the current
/// window. A newer valid claim ends the previous window: a plan whose notice
/// was shown is sent now, so what the notice said stays true once its 撤销 is
/// gone; one whose notice never went up (its claim still returning when a
/// listener's newer plan took the window) is dropped, as nobody was told.
final _windows = Expando<_UndoWindow>('archive and plugin undo window');

class _UndoWindow {
  int intent = 0;
  UndoNoticeLease? current;
}

class UndoNoticeIntent {
  UndoNoticeIntent._(this._window, this._serial);
  final _UndoWindow _window;
  final int _serial;
  int? _claimedSerial;
  bool get isCurrent => _window.intent == (_claimedSerial ?? _serial);

  UndoNoticeLease? claim({
    required Object identity,
    required bool Function() canUndo,
    required bool Function() cancel,
    required bool Function() commit,
    required Future<void> windowClosed,
  }) {
    // Reentrant scheduling may return the exact plan already claimed by C.
    // This grants no new ownership: callers recognize the existing intent and
    // return without cancelling or releasing C's shared pending handle.
    final current = _window.current;
    if (current != null && identical(current.identity, identity) && current.canUndo() && canUndo()) return current;
    if (!isCurrent || !canUndo()) {
      if (canUndo()) cancel();
      return null;
    }
    final old = _window.current;
    final lease = UndoNoticeLease._(this, identity, canUndo, cancel, commit, windowClosed);
    // Only a valid claim advances the generation. A rejected reservation does
    // not invalidate an outer claim still returning from a listener.
    _claimedSerial = ++_window.intent;
    // Publish identity before ending the old plan: that may synchronously
    // schedule C, which then wins.
    _window.current = lease;
    if (old != null && old.canUndo()) lease.replacedPrevious = old.shown ? old.commit() : old.cancel();
    if (!isCurrent || !identical(_window.current, lease) || !canUndo()) {
      if (canUndo()) cancel();
      if (identical(_window.current, lease)) _window.current = null;
      return null;
    }
    unawaited(windowClosed.then((_) => lease._closed()));
    return lease;
  }
}

class UndoNoticeLease {
  UndoNoticeLease._(this.intent, this.identity, this.canUndo, this.cancel, this.commit, this.windowClosed);
  final UndoNoticeIntent intent;
  final Object identity;
  final bool Function() canUndo;
  final bool Function() cancel;
  final bool Function() commit;
  final Future<void> windowClosed;

  /// This claim ended an older window early (its plan was sent at once).
  bool replacedPrevious = false;
  VoidCallback? _closeNotice;
  bool get isCurrent => identical(intent._window.current, this);

  /// Its notice went up ([attach]).
  bool get shown => _closeNotice != null;

  void attach(ScaffoldMessengerState messenger, ScaffoldFeatureController<SnackBar, SnackBarClosedReason> notice) {
    var open = true;
    unawaited(
      notice.closed.then((_) {
        open = false;
      }),
    );
    _closeNotice = () {
      if (open && messenger.mounted) notice.close();
    };
  }

  void _closed() {
    if (!isCurrent) return;
    _closeNotice?.call();
    intent._window.current = null;
  }
}

UndoNoticeIntent reserveUndoNotice(ScaffoldMessengerState messenger) {
  final window = _windows[messenger] ??= _UndoWindow();
  return UndoNoticeIntent._(window, window.intent);
}

/// Results stay outside the Messenger queue, and callers recheck ownership
/// in the same synchronous continuation that actually publishes their result.
Future<void> publishAfterUndoNotice(
  ScaffoldMessengerState messenger,
  bool Function() owned,
  VoidCallback publish,
) async {
  while (owned()) {
    final window = _windows[messenger];
    final lease = window?.current;
    if (lease == null) {
      publish();
      return;
    }
    await lease.windowClosed;
    if (identical(window?.current, lease)) lease._closed();
  }
}
