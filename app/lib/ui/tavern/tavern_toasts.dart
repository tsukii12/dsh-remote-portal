// A card script's toastr on the canvas (tavern_canvas.dart posts it), shown
// as the app's own notice.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../tavern/tavern_canvas.dart';

/// The notices one canvas's card scripts ask for. One already up or waiting
/// takes the new words rather than another queueing behind it, and they get
/// their own time to be read; a notice of the app's own is never put away
/// for one, it waits its turn. The card can put its notice away before its
/// time ([clear]).
class TavernToasts {
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _bar;

  /// The one up is on its way out (its time ran out, or a tap): new words
  /// get a notice of their own rather than leaving with it.
  bool _leaving = false;

  /// The words on it (title, message) and how long they stay up, counted
  /// from when they are seen; [_Toast.shown] makes each new show count anew.
  final _toast = ValueNotifier<_Toast>(const _Toast('', '', Duration.zero, 0));
  bool _disposed = false;

  /// Shows what [data] (the page's {type:'toast', level, title, message})
  /// says on [messenger], if anything.
  void show(ScaffoldMessengerState messenger, Map<Object?, Object?> data) {
    final toast = tavernToast(data);
    if (_disposed || toast == null) return;
    _toast.value = _Toast(toast.title, toast.message, toast.duration, _toast.value.shown + 1, id: _id(data));
    if (_bar != null && !_leaving) return;
    _leaving = false;
    late final ScaffoldFeatureController<SnackBar, SnackBarClosedReason> bar;
    bar = _bar = messenger.showSnackBar(
      SnackBar(
        key: const ValueKey('tavern-canvas-toast'),
        content: _Countdown(
          // Its own each time: a bar that takes an old one's place in the
          // messenger never keeps that one's count.
          key: UniqueKey(),
          toast: _toast,
          onDone: () {
            if (identical(_bar, bar)) _leaving = true;
            bar.close();
          },
          child: Builder(
            builder: (context) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (identical(_bar, bar)) _leaving = true;
                ScaffoldMessenger.of(context).removeCurrentSnackBar(reason: SnackBarClosedReason.dismiss);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                // The title as a heading over the words, as toastr sets it.
                child: ValueListenableBuilder<_Toast>(
                  valueListenable: _toast,
                  builder: (_, toast, _) => Text.rich(
                    key: const ValueKey('tavern-canvas-toast-text'),
                    TextSpan(
                      children: [
                        if (toast.title.isNotEmpty)
                          TextSpan(
                            text: toast.title,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        if (toast.title.isNotEmpty && toast.message.isNotEmpty) const TextSpan(text: '\n'),
                        if (toast.message.isNotEmpty) TextSpan(text: toast.message),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        padding: EdgeInsets.zero,
        // Put away by its own count ([_Countdown]), not the messenger's.
        duration: const Duration(days: 1),
      ),
    );
    unawaited(
      bar.closed.whenComplete(() {
        if (!identical(_bar, bar)) return;
        _bar = null;
        _leaving = false;
        if (_disposed) _toast.dispose();
      }),
    );
  }

  /// The card put its notice away (toastr.clear or remove; the page's
  /// {type:'toastClear', id}): the one up or waiting, when its words are that
  /// call's or [data] names none. Words a later call has put in its place
  /// stay. One still waiting behind the app's own goes as soon as it is up.
  void clear(Map<Object?, Object?> data) {
    final id = _id(data);
    final now = _toast.value;
    if (_disposed || _bar == null || _leaving || now.cleared) return;
    if (id != null && id != now.id) return;
    _toast.value = _Toast(now.title, now.message, now.lasts, now.shown, id: now.id, cleared: true);
  }

  static int? _id(Map<Object?, Object?> data) => switch (data['id']) {
    final num n => n.toInt(),
    _ => null,
  };

  /// Done with: a notice still up reads its words until it goes.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_bar == null) _toast.dispose();
  }
}

final class _Toast {
  const _Toast(this.title, this.message, this.lasts, this.shown, {this.id, this.cleared = false});

  final String title;
  final String message;
  final Duration lasts;
  final int shown;

  /// The page's number for the call that showed these words.
  final int? id;

  /// Put away by the card: it goes now, not when its time is up.
  final bool cleared;
}

/// Puts the notice away once its words have been up their time: counted from
/// when it is on screen, and from the start again for new words; at once when
/// the card has put them away.
class _Countdown extends StatefulWidget {
  const _Countdown({super.key, required this.toast, required this.onDone, required this.child});

  final ValueNotifier<_Toast> toast;
  final VoidCallback onDone;
  final Widget child;

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  Timer? _timer;
  bool _done = false;

  /// Counted from the start for new words, until it has gone off once: a
  /// notice on its way out does not count again. Put away, it goes on the
  /// next turn (not while the messenger is building it), unless new words
  /// come first.
  void _count() {
    if (_done) return;
    _timer?.cancel();
    final toast = widget.toast.value;
    _timer = Timer(toast.cleared ? Duration.zero : toast.lasts, () {
      _done = true;
      widget.onDone();
    });
  }

  @override
  void initState() {
    super.initState();
    widget.toast.addListener(_count);
    _count();
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.toast.removeListener(_count);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
