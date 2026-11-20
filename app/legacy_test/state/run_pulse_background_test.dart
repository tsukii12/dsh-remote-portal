import 'dart:async';

import 'package:dsh_app/state/notify_state.dart' show appForegroundProvider;
import 'package:dsh_app/state/run_pulse.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  test('provider cancels an existing sampling timer without replacing pulse', () {
    _withTimers((timers) {
      final container = ProviderContainer();
      var disposed = false;
      addTearDown(() {
        if (!disposed) container.dispose();
      });
      final subscription = container.listen(runPulseProvider('s'), (_, _) {});
      final pulse = subscription.read();
      pulse.observe(_chunk(0, DateTime.now()));
      expect(timers.where((t) => t.isActive), hasLength(1));
      container.read(appForegroundProvider.notifier).set(false);
      expect(timers.where((t) => t.isActive), isEmpty);
      expect(identical(container.read(runPulseProvider('s')), pulse), isTrue);
      pulse.observe(_chunk(1, DateTime.now()));
      expect(timers.where((t) => t.isActive), isEmpty);
      container.read(appForegroundProvider.notifier).set(true);
      expect(timers.where((t) => t.isActive), hasLength(1));
      container.dispose();
      disposed = true;
      expect(timers.where((t) => t.isActive), isEmpty);
    });
  });

  test('provider born in background ingests chunks without starting a timer', () {
    _withTimers((timers) {
      final container = ProviderContainer();
      var disposed = false;
      addTearDown(() {
        if (!disposed) container.dispose();
      });
      container.read(appForegroundProvider.notifier).set(false);
      final subscription = container.listen(runPulseProvider('s'), (_, _) {});
      final pulse = subscription.read();
      pulse.observe(_chunk(0, DateTime.now()));
      expect(pulse.tokensPerSecond, greaterThan(0));
      expect(timers, isEmpty);
      container.dispose();
      disposed = true;
    });
  });
}
