import 'package:flutter/foundation.dart';

abstract final class RemoteBenchmark {
  static const enabled = bool.fromEnvironment('YUREMOTE_BENCHMARK');
  static final _timers = <String, Stopwatch>{};
  static final _completed = <String>{};

  static void start(String label) {
    if (enabled && !_completed.contains(label)) _timers.putIfAbsent(label, () => Stopwatch()..start());
  }

  static void finish(String label) {
    if (!enabled) return;
    final timer = _timers.remove(label);
    if (timer == null) return;
    _completed.add(label);
    debugPrint('YUREMOTE_PERF $label ${timer.elapsedMicroseconds} us');
  }

  static void cancel(String label) {
    if (enabled) _timers.remove(label);
  }
}
