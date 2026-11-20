// The reply being written, as it is shown (docs/design/roleplay-roadmap.md
// P0, engine T21): the live text through the display regex, as the finished
// message will be once it is stored.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/foundation.dart';

/// The live text and its display pass. Each piece of the reply sets [text];
/// a pass runs on the first piece at once, then at most once every [gap] and
/// never two at a time, so a fast stream costs a pass a beat, not a pass a
/// piece. The last piece always gets its own pass.
///
/// [shown] is what to put on screen. While the last pass changed nothing, it
/// is [text] as it arrives, with no lag; once a pass rewrote something (a
/// status block hidden, a tag turned into a line), it is that pass's result,
/// a beat behind, so a half-arrived block never flashes up raw. A result the
/// engine marks superseded is dropped; a pass that fails leaves the text as
/// written for the rest of the reply.
class TavernLiveDisplay extends ChangeNotifier {
  TavernLiveDisplay(this._pass, {this.gap = const Duration(milliseconds: 120)});

  final Future<TavernDisplayResult> Function(String text) _pass;

  /// The least time between the starts of two passes.
  final Duration gap;

  String _text = '';

  /// The last pass: the text it ran on and what it made of it.
  ({String source, String shown})? _last;

  /// The text the last pass ran on, kept or not: the same text is not passed
  /// twice, even when the engine dropped the first result as superseded.
  String? _tried;
  bool _busy = false;
  bool _broken = false;
  bool _disposed = false;
  Timer? _cooling;

  /// Counts [reset]s, so a pass still out for the last reply is not taken
  /// for this one.
  int _turn = 0;

  /// The reply so far, as written.
  String get text => _text;

  set text(String value) {
    if (value == _text) return;
    _text = value;
    notifyListeners();
    _schedule();
  }

  /// What to show of the reply so far.
  String get shown => switch (_last) {
    (:final source, :final shown) when !_broken && shown != source => shown,
    _ => _text,
  };

  /// A new reply: nothing written yet, nothing passed.
  void reset() {
    _turn++;
    _text = '';
    _last = null;
    _tried = null;
    _broken = false;
    _cooling?.cancel();
    _cooling = null;
    notifyListeners();
  }

  void _schedule() {
    if (_disposed || _broken || _busy || _cooling != null) return;
    if (_text.isEmpty || _text == _tried) return;
    unawaited(_run());
  }

  Future<void> _run() async {
    final turn = _turn;
    final text = _tried = _text;
    _busy = true;
    _cooling = Timer(gap, () {
      _cooling = null;
      _schedule();
    });
    try {
      final result = await _pass(text);
      if (turn == _turn && !_disposed && !result.superseded) {
        _last = (source: text, shown: result.text);
        notifyListeners();
      }
    } on Object {
      if (turn == _turn && !_disposed) {
        _broken = true;
        notifyListeners();
      }
    } finally {
      _busy = false;
    }
    _schedule();
  }

  @override
  void dispose() {
    _disposed = true;
    _cooling?.cancel();
    super.dispose();
  }
}
