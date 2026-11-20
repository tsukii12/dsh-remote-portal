import 'dart:async';

import 'package:dsh_app/state/run_pulse.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

// No widget binding or frame pumping: observe actual periodic timer ownership.
class _Periodic implements Timer {
  _Periodic(this.callback);
  final void Function(Timer) callback;
  bool _active = true;
  int _tick = 0;
  @override
  bool get isActive => _active;
  @override
  int get tick => _tick;
  @override
  void cancel() => _active = false;
  void fire() {
    if (!_active) return;
    _tick++;
    callback(this);
  }
}

void _withTimers(void Function(List<_Periodic>) body) {
  final timers = <_Periodic>[];
  runZoned(
    () => body(timers),
    zoneSpecification: ZoneSpecification(
      createPeriodicTimer: (self, parent, zone, duration, callback) {
        if (duration != const Duration(milliseconds: 250)) {
          return parent.createPeriodicTimer(zone, duration, callback);
        }
        final timer = _Periodic(callback);
        timers.add(timer);
        return timer;
      },
    ),
  );
}

AssistantChunkEvent _chunk(int index, DateTime time, [StreamChunk? value]) =>
    AssistantChunkEvent('a', index, index: index, time: time, chunk: value ?? const TextDeltaChunk(0, 'abcdefghij'));

void main() {
  test('sampling switch cancels real Dart Timer handles', () {
    final timers = <Timer>[];
    runZoned(
      () {
        final now = DateTime(2026, 10, 24, 10);
        final pulse = RunPulse(clock: () => now);
        addTearDown(pulse.dispose);
        pulse.observe(_chunk(0, now));
        expect(timers, hasLength(1));
        expect(timers.single.isActive, isTrue);
        pulse.setSamplingEnabled(false);
        expect(timers.single.isActive, isFalse);
        pulse.observe(_chunk(1, now));
        expect(timers, hasLength(1));
        pulse.setSamplingEnabled(true);
        expect(timers, hasLength(2));
        expect(timers.last.isActive, isTrue);
        pulse.setSamplingEnabled(false);
        expect(timers.every((timer) => !timer.isActive), isTrue);
      },
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
          // Preserve the runtime timer and callback; observe only its handle.
          final timer = parent.createPeriodicTimer(zone, duration, callback);
          if (duration == const Duration(milliseconds: 250)) timers.add(timer);
          return timer;
        },
      ),
    );
  });

  test('background preserves dedup usage and compaction; resume ages stale rate', () {
    _withTimers((timers) {
      var now = DateTime(2026, 10, 24, 10);
      var reads = 0;
      final pulse = RunPulse(
        clock: () {
          reads++;
          return now;
        },
      );
      var disposed = false;
      addTearDown(() {
        if (!disposed) pulse.dispose();
      });
      pulse.observe(_chunk(0, now));
      final active = timers.single;
      pulse.setSamplingEnabled(false);
      final before = reads;
      active.fire();
      active.fire();
      expect(reads, before, reason: 'cancelled sampling must not read the clock');
      for (var i = 1; i < 20; i++) {
        pulse.observe(_chunk(i, now));
      }
      final rate = pulse.meter.rateAt(now);
      pulse.observe(_chunk(19, now));
      expect(pulse.meter.rateAt(now), rate);
      pulse.observe(_chunk(20, now, const UsageChunk(TokenUsage(inputTokens: 1, outputTokens: 120))));
      pulse.observe(_chunk(21, now));
      expect(pulse.tokensPerSecond, closeTo(pulse.meter.rateAt(now) * 1.5, 1e-9));
      pulse.observe(UnknownEvent(22, now, 'compaction/start', const {}));
      expect(pulse.compactingSince, now);
      pulse.observe(UnknownEvent(23, now, 'compaction/end', const {}));
      expect(pulse.compactingSince, isNull);
      expect(timers.where((t) => t.isActive), isEmpty);
      now = now.add(const Duration(seconds: 10));
      pulse.setSamplingEnabled(true);
      expect(pulse.level, 1);
      expect(pulse.tokensPerSecond, 0);
      expect(timers.where((t) => t.isActive), isEmpty);
      pulse.observe(_chunk(24, now));
      expect(timers.where((t) => t.isActive), hasLength(1));
      pulse.dispose();
      disposed = true;
      expect(timers.where((t) => t.isActive), isEmpty);
    });
  });
}
