// The live token-speed estimate behind the whale tail (estimate, sliding
// window, four levels with hysteresis), and the compaction flag, fed the
// events ChatController sees.

import 'package:dsh_app/state/run_pulse.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

final t0 = DateTime(2026, 10, 24, 10);
DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

AssistantChunkEvent chunk(int index, StreamChunk chunk, {String attempt = 'a1', DateTime? time}) =>
    AssistantChunkEvent(attempt, index, index: index, time: time ?? t0, chunk: chunk);

UnknownEvent logEvent(int seq, String type, DateTime time) => UnknownEvent(seq, time, type, const {});

void main() {
  group('token estimate', () {
    test('Chinese 0.6 per character, the rest 0.3, whitespace free', () {
      expect(estimateTokens('你好世界'), closeTo(2.4, 1e-9));
      expect(estimateTokens('hello world'), closeTo(3.0, 1e-9));
      expect(estimateTokens('  \n\t'), 0);
      expect(estimateTokens('改 main.dart'), closeTo(0.6 + 2.7, 1e-9));
    });
  });

  group('rate meter', () {
    test('tokens over the window; a fresh burst counts at least 0.5 s', () {
      final meter = TokenRateMeter();
      expect(meter.rateAt(t0), 0);
      meter.add(at(0), 10);
      // 10 tokens, 0.1 s in: divided by the 0.5 s floor, not by 0.1 s.
      expect(meter.rateAt(at(100)), closeTo(20, 1e-9));
      for (var ms = 100; ms <= 2000; ms += 100) {
        meter.add(at(ms), 10);
      }
      // 21 chunks of 10 over 2 s since the burst began.
      expect(meter.rateAt(at(2000)), closeTo(210 / 2.0, 1e-6));
    });

    test('only the last 2.5 s count', () {
      final meter = TokenRateMeter();
      for (var ms = 0; ms <= 6000; ms += 100) {
        meter.add(at(ms), ms < 3000 ? 20 : 5);
      }
      // The fast first half has left the window: 5 per 100 ms = 50/s.
      expect(meter.rateAt(at(6000)), closeTo(50, 2.5));
    });

    test('quiet for 1.2 s is a stall: 0', () {
      final meter = TokenRateMeter()..add(at(0), 30);
      expect(meter.rateAt(at(1100)), greaterThan(0));
      expect(meter.rateAt(at(1300)), 0);
    });
  });

  group('gauge', () {
    test('levels from the thresholds', () {
      expect(SpeedGauge.targetFor(0, 1), 1);
      expect(SpeedGauge.targetFor(3, 1), 2);
      expect(SpeedGauge.targetFor(29, 1), 2);
      expect(SpeedGauge.targetFor(30, 1), 3);
      expect(SpeedGauge.targetFor(74, 2), 3);
      expect(SpeedGauge.targetFor(75, 2), 4);
      expect(SpeedGauge.targetFor(200, 1), 4);
    });

    test('hysteresis: a level holds until 0.8 of its entry line', () {
      expect(SpeedGauge.targetFor(65, 4), 4, reason: 'exit 4 below 60');
      expect(SpeedGauge.targetFor(59, 4), 3);
      expect(SpeedGauge.targetFor(25, 3), 3, reason: 'exit 3 below 24');
      expect(SpeedGauge.targetFor(23, 3), 2);
      expect(SpeedGauge.targetFor(15, 4), 2);
      expect(SpeedGauge.targetFor(0, 4), 1, reason: 'a stall drops to 1');
    });

    test('a level stays at least the dwell time', () {
      final gauge = SpeedGauge();
      expect(gauge.update(80, at(0)), 4);
      expect(gauge.update(10, at(300)), 4);
      expect(gauge.update(10, at(899)), 4);
      expect(gauge.update(10, at(900)), 2);
      // Jitter around a line does not flap.
      expect(gauge.update(28, at(2000)), 2);
      expect(gauge.update(31, at(3000)), 3);
      expect(gauge.update(26, at(4000)), 3);
      expect(gauge.update(31, at(5000)), 3);
    });
  });

  group('pulse', () {
    late DateTime now;
    late RunPulse pulse;
    late int notified;

    setUp(() {
      now = t0;
      notified = 0;
      pulse = RunPulse(clock: () => now)..addListener(() => notified++);
    });

    tearDown(() => pulse.dispose());

    /// Streams [perChunk] text chunks every 50 ms for [ms] milliseconds.
    void stream(String text, int ms, {String attempt = 'a1', int from = 0}) {
      var index = from;
      for (var t = 0; t < ms; t += 50) {
        now = now.add(const Duration(milliseconds: 50));
        pulse.observe(
          chunk(index++, TextDeltaChunk(0, text), attempt: attempt, time: now),
          skew: Duration.zero,
        );
      }
    }

    test('speeds up through the levels and settles back to 1', () {
      expect(pulse.level, 1);
      // 'abcdefghij' = 3 tokens per 50 ms = 60 tok/s: level 3.
      stream('abcdefghij', 3000);
      expect(pulse.tokensPerSecond, closeTo(60, 3));
      expect(pulse.level, 3);
      // 30 characters per 50 ms = 180 tok/s: level 4.
      stream('abcdefghij' * 3, 3000, from: 60);
      expect(pulse.level, 4);
      expect(notified, greaterThanOrEqualTo(3));

      // The stream stops (a tool runs): after the stall and the dwell, 1.
      now = now.add(const Duration(milliseconds: 1500));
      pulse.tickNow();
      expect(pulse.tokensPerSecond, 0);
      expect(pulse.level, 1);
    });

    test('reasoning and tool-call arguments count too', () {
      for (var index = 0; index < 40; index++) {
        now = now.add(const Duration(milliseconds: 50));
        pulse.observe(
          chunk(
            index,
            index.isEven
                ? const ReasoningDeltaChunk(0, '我想一想这个')
                : const ToolCallDeltaChunk(1, id: 'c1', argumentsDelta: '{"command'),
            time: now,
          ),
          skew: Duration.zero,
        );
      }
      expect(pulse.level, greaterThan(1));
    });

    test('replayed chunks (same attempt and index) are not counted twice', () {
      final first = chunk(0, const TextDeltaChunk(0, 'abcdefghij'), time: now);
      pulse.observe(first, skew: Duration.zero);
      final once = pulse.meter.rateAt(now);
      pulse.observe(first, skew: Duration.zero);
      expect(pulse.meter.rateAt(now), once);
    });

    test('Host times place a late burst in the past, not in a spike', () {
      // A batch delivered 5 s late (the app was in the background).
      for (var i = 0; i < 40; i++) {
        pulse.observe(
          chunk(i, const TextDeltaChunk(0, 'abcdefghij'), time: now.subtract(Duration(milliseconds: 5000 - i * 50))),
          skew: Duration.zero,
        );
      }
      expect(pulse.level, 1);
      expect(pulse.tokensPerSecond, 0);
    });

    test('usage calibrates the estimate', () {
      stream('abcdefghij', 1000); // 20 chunks × 3 = 60 estimated
      pulse.observe(
        chunk(20, const UsageChunk(TokenUsage(inputTokens: 10, outputTokens: 120)), time: now),
        skew: Duration.zero,
      );
      final before = pulse.tokensPerSecond;
      stream('abcdefghij', 50, attempt: 'a2');
      // Ratio 2 halfway in: estimates now count 1.5×.
      expect(pulse.tokensPerSecond, greaterThan(before * 1.3));
    });

    test('compaction: start → on, end → off; turn end clears a stale one', () {
      pulse.observe(logEvent(5, 'compaction/start', at(10)));
      expect(pulse.compactingSince, at(10));
      pulse.observe(logEvent(6, 'compaction/end', at(20)));
      expect(pulse.compactingSince, isNull);
      pulse.observe(logEvent(7, 'compaction/start', at(30)));
      pulse.observe(logEvent(8, 'turn/end', at(40)));
      expect(pulse.compactingSince, isNull);
      expect(notified, 4);
    });

    test('a snapshot taken mid-compaction shows it', () {
      expect(
        compactingAfter([logEvent(1, 'turn/start', at(0)), logEvent(2, 'compaction/start', at(10))], null, false),
        at(10),
      );
      expect(
        compactingAfter([logEvent(1, 'compaction/start', at(0)), logEvent(2, 'compaction/end', at(5))], at(0), false),
        isNull,
      );
    });
  });
}
