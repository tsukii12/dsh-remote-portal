import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Opt-in diagnostics only. Neither collection nor reporting requests frames.
const _enabled = !kReleaseMode && bool.fromEnvironment('DSH_FRAME_PROBE');

/// The probe brings its own binding, created before the app starts.
const frameProbeEnabled = _enabled;
const _requestedSampleEvery = int.fromEnvironment('DSH_FRAME_PROBE_SAMPLE_EVERY', defaultValue: 60);
const _sampleEvery = _requestedSampleEvery > 0 ? _requestedSampleEvery : 60;

/// Android's logcat cuts a line at about 4 KB, so a report goes out as lines
/// under this many bytes (UTF-8, prefix included).
const frameProbeLineBytes = 3000;

/// One report ([json]) as log lines, `DSH_FRAME_PROBE seq line/lines part`
/// (`DSH_FRAME_PROBE 12 2/3 …`). Every line of a report carries its [seq];
/// joining the parts of one seq in line order gives the JSON back.
@visibleForTesting
List<String> frameProbeLines(int seq, String json, {int maxBytes = frameProbeLineBytes}) {
  // Room for `DSH_FRAME_PROBE <seq> <line>/<lines> ` whatever the numbers.
  final budget = maxBytes - 64;
  final parts = <String>[];
  final part = StringBuffer();
  var bytes = 0;
  for (final rune in json.runes) {
    final size = rune < 0x80
        ? 1
        : rune < 0x800
        ? 2
        : rune < 0x10000
        ? 3
        : 4;
    if (bytes + size > budget) {
      parts.add(part.toString());
      part.clear();
      bytes = 0;
    }
    part.writeCharCode(rune);
    bytes += size;
  }
  if (part.isNotEmpty || parts.isEmpty) parts.add(part.toString());
  return [for (var i = 0; i < parts.length; i++) 'DSH_FRAME_PROBE $seq ${i + 1}/${parts.length} ${parts[i]}'];
}

Future<void> runWithFrameProbe(Future<void> Function() startApp) {
  if (!_enabled) return startApp();
  final probe = _Probe();
  final reportingZone = Zone.current;
  return runZoned<Future<void>>(
    () {
      final binding = _ProbeBinding(probe);
      binding.addTimingsCallback((timings) {
        probe.count('timingDelivered', timings.length);
      });
      // Deliberately outside the measured zone: one reporter wakeup per 5 s.
      reportingZone.run(() {
        Timer.periodic(const Duration(seconds: 5), (_) => probe.report(binding));
      });
      return startApp();
    },
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        final source = probe.capture();
        final timer = _ProbeTimer(source, false);
        timer.inner = parent.createTimer(zone, duration, () {
          timer.finish(cancelled: false);
          source.fired++;
          probe.withOrigin(source, callback);
        });
        timer.created();
        return timer;
      },
      createPeriodicTimer: (self, parent, zone, duration, callback) {
        final source = probe.capture();
        final timer = _ProbeTimer(source, true);
        timer.inner = parent.createPeriodicTimer(zone, duration, (_) {
          source.fired++;
          // The same proxy is returned by Timer.periodic and to its callback.
          probe.withOrigin(source, () => callback(timer));
        });
        timer.created();
        return timer;
      },
    ),
  );
}

class _ProbeBinding extends WidgetsFlutterBinding {
  _ProbeBinding(this.probe);

  final _Probe probe;
  final Map<int, _Source> _pending = {};
  FrameCallback? _executingCallback;

  @override
  void scheduleFrame() {
    probe.request('request', hasScheduledFrame, framesEnabled);
    super.scheduleFrame();
  }

  @override
  void scheduleForcedFrame() {
    probe.request('forced', hasScheduledFrame, true);
    super.scheduleForcedFrame();
  }

  @override
  int scheduleFrameCallback(FrameCallback callback, {bool rescheduling = false, bool scheduleNewFrame = true}) {
    // Retain the initial registration site across a ticker's self-rescheduling.
    final source = rescheduling && callback == _executingCallback ? probe.origin ?? probe.capture() : probe.capture();
    probe.count('callbackRegistration');
    if (++probe.callbackCalls % _sampleEvery == 1 || _sampleEvery == 1) {
      // Capture the sampled current stack as well as retaining its causal site.
      probe.capture(inherit: true);
      source.callbackSamples++;
    }
    late int id;
    id = super.scheduleFrameCallback(
      (timestamp) {
        _pending.remove(id);
        source.callbackFired++;
        final previousCallback = _executingCallback;
        _executingCallback = callback;
        try {
          probe.withOrigin(source, () => callback(timestamp));
        } finally {
          _executingCallback = previousCallback;
        }
      },
      rescheduling: rescheduling,
      scheduleNewFrame: scheduleNewFrame,
    );
    if (_pending.length < 512) {
      _pending[id] = source;
    } else {
      probe.count('pendingTrackingOverflow');
    }
    return id;
  }

  @override
  void cancelFrameCallbackWithId(int id) {
    super.cancelFrameCallbackWithId(id);
    _pending.remove(id);
  }

  @override
  void handleBeginFrame(Duration? rawTimeStamp) {
    probe.count(rawTimeStamp == null ? 'warmBegin' : 'begin');
    super.handleBeginFrame(rawTimeStamp);
  }

  @override
  void handleDrawFrame() {
    super.handleDrawFrame();
    probe.count('drawCompleted');
  }
}

class _ProbeTimer implements Timer {
  _ProbeTimer(this.source, this.periodic);

  final _Source source;
  final bool periodic;
  late final Timer inner;
  bool _finished = false;

  void created() {
    source.created++;
    if (periodic) {
      source.activePeriodic++;
    } else {
      source.activeOnce++;
    }
  }

  void finish({required bool cancelled}) {
    if (_finished) return;
    _finished = true;
    if (periodic) {
      source.activePeriodic--;
    } else {
      source.activeOnce--;
    }
    if (cancelled) {
      source.cancelled++;
    } else {
      source.finished++;
    }
  }

  @override
  void cancel() {
    inner.cancel();
    finish(cancelled: true);
  }

  @override
  bool get isActive => inner.isActive;

  @override
  int get tick => inner.tick;
}

class _Source {
  _Source(this.site, this.ticker, [this.frameworkGenerator]);
  final String site;
  final bool ticker;
  final String? frameworkGenerator;
  int requestSamples = 0, forcedSamples = 0, callbackSamples = 0;
  int callbackFired = 0, created = 0, fired = 0, finished = 0, cancelled = 0;
  int activeOnce = 0, activePeriodic = 0;
  int pending = 0;

  int get activity =>
      requestSamples +
      forcedSamples +
      callbackSamples +
      callbackFired +
      created +
      fired +
      finished +
      cancelled +
      activeOnce +
      activePeriodic +
      pending;

  Map<String, Object> toJson() => {
    'site': site,
    'tickerLike': ticker,
    'frameworkGenerator': ?frameworkGenerator,
    'samples': [requestSamples, forcedSamples, callbackSamples],
    'callbackFired': callbackFired,
    'timer': [created, fired, finished, cancelled, activeOnce, activePeriodic],
    'pending': pending,
  };

  void resetWindow() {
    requestSamples = forcedSamples = callbackSamples = callbackFired = 0;
    created = fired = finished = cancelled = pending = 0;
  }
}

class _Probe {
  final Stopwatch clock = Stopwatch()..start();
  final Map<String, _Source> sources = {};
  final _Source overflow = _Source('other/source-cap-128', false);
  final Map<String, int> totals = {};
  final Map<int, Map<String, int>> seconds = {};
  int callbackCalls = 0, requestCalls = 0, forcedCalls = 0;
  int lastReportUs = 0;
  int reports = 0;
  _Source? origin;

  void withOrigin(_Source source, void Function() callback) {
    final previous = origin;
    origin = source;
    try {
      callback();
    } finally {
      origin = previous;
    }
  }

  _Source capture({bool inherit = false}) {
    final lines = StackTrace.current.toString().split('\n');
    if (inherit && origin != null) return origin!;
    final ticker = lines.any((line) => line.contains('Ticker.') || line.contains('/scheduler/ticker.dart'));
    // Keep known frame generators even when no app widget is on the stack.
    // These are bounded hints, not widget identity or proof of visibility.
    final String? generator;
    if (lines.any((line) => line.contains('package:flutter/src/material/progress_indicator.dart'))) {
      generator = lines.any((line) => line.contains('_CircularProgressIndicatorState'))
          ? 'CircularProgressIndicator (progress_indicator.dart)'
          : lines.any((line) => line.contains('_LinearProgressIndicatorState'))
          ? 'LinearProgressIndicator (progress_indicator.dart)'
          : 'progress_indicator.dart';
    } else if (lines.any((line) => line.contains('package:flutter/src/painting/image_stream.dart'))) {
      generator = 'image_stream.dart';
    } else {
      generator = null;
    }
    final frames = lines
        .where((line) => line.contains('(') && !line.contains('frame_probe.dart') && !line.contains('(dart:'))
        .toList();
    final useful = frames.where((line) => !line.contains('package:flutter/')).toList();
    final app = useful.where(
      (line) =>
          line.contains('package:dsh_app/') ||
          line.contains('package:dsh_client/') ||
          line.contains('package:dsh_remote/'),
    );
    final selected = (app.isNotEmpty ? app : useful)
        .take(2)
        .map((line) {
          final clean = line.replaceFirst(RegExp(r'^#\d+\s+'), '').trim();
          // Preserve the file/line suffix even for long anonymous-call stacks.
          return clean.length > 120 ? '${clean.substring(0, 40)}…${clean.substring(clean.length - 79)}' : clean;
        })
        .join(' <- ');
    // A framework-only continuation can still inherit its timer/callback origin.
    final framework = frames.take(2).map((line) => line.replaceFirst(RegExp(r'^#\d+\s+'), '').trim()).join(' <- ');
    final fallback = framework.length > 240 ? framework.substring(0, 240) : framework;
    final site = selected.isNotEmpty
        ? selected
        : origin?.site ?? (fallback.isEmpty ? 'framework/unknown' : 'framework:$fallback');
    final key = '${ticker ? 'ticker' : 'other'}:$generator:$site';
    final existing = sources[key];
    if (existing != null) return existing;
    if (sources.length == 128) return overflow;
    return sources[key] = _Source(site, ticker, generator);
  }

  void count(String name, [int value = 1]) {
    totals.update(name, (count) => count + value, ifAbsent: () => value);
    final second = clock.elapsedMilliseconds ~/ 1000;
    final bucket = seconds.putIfAbsent(second, () => {});
    bucket.update(name, (count) => count + value, ifAbsent: () => value);
    // A suspended reporter cannot grow this map indefinitely.
    seconds.removeWhere((key, _) => key < second - 6);
  }

  void request(String kind, bool scheduled, bool enabled) {
    count(kind);
    count(
      '$kind.${scheduled
          ? 'merged'
          : enabled
          ? 'eligible'
          : 'disabled'}',
    );
    final n = kind == 'forced' ? ++forcedCalls : ++requestCalls;
    if (n % _sampleEvery == 1 || _sampleEvery == 1) {
      final source = capture(inherit: true);
      if (kind == 'forced') {
        source.forcedSamples++;
      } else {
        source.requestSamples++;
      }
    }
  }

  void report(_ProbeBinding binding) {
    final nowUs = clock.elapsedMicroseconds;
    final second = nowUs ~/ 1000000;
    final all = [...sources.values, overflow];
    for (final source in all) {
      source.pending = 0;
    }
    for (final source in binding._pending.values) {
      source.pending++;
    }
    final ranked = all.where((source) => source.activity > 0).toList()
      ..sort((a, b) => b.activity.compareTo(a.activity));
    final activeTimers = all.where((s) => s.activeOnce + s.activePeriodic > 0).toList()
      ..sort((a, b) => (b.activeOnce + b.activePeriodic).compareTo(a.activeOnce + a.activePeriodic));
    final result = <String, Object?>{
      'elapsedMs': nowUs ~/ 1000,
      'windowMs': (nowUs - lastReportUs) ~/ 1000,
      'sampleEvery': _sampleEvery,
      'counts': Map<String, int>.of(totals),
      'seconds': [
        for (var s = second - 5; s < second; s++)
          if (s >= 0)
            [
              s,
              for (final key in [
                'request',
                'request.merged',
                'request.eligible',
                'begin',
                'warmBegin',
                'drawCompleted',
                'timingDelivered',
              ])
                seconds[s]?[key] ?? 0,
            ],
      ],
      'pendingTransient': binding.transientCallbackCount,
      'trackedPending': binding._pending.length,
      'activeTimers': [all.fold<int>(0, (n, s) => n + s.activeOnce), all.fold<int>(0, (n, s) => n + s.activePeriodic)],
      'sourceGroups': sources.length,
      'sourceCapReached': sources.length == 128,
      'top': ranked.take(4).map((source) => source.toJson()).toList(),
      'activeTimerTop': activeTimers
          .take(2)
          .map(
            (source) => {
              'site': source.site,
              'active': [source.activeOnce, source.activePeriodic],
            },
          )
          .toList(),
      'omittedGroups': ranked.length > 4 ? ranked.length - 4 : 0,
      'reporter': '1 periodic/5s, excluded; no frame requests',
    };
    // Bounded, unthrottled lines; debugPrint would add its own timer.
    for (final line in frameProbeLines(++reports, jsonEncode(result))) {
      Zone.root.print(line);
    }
    totals.clear();
    // Retire idle groups so startup does not permanently occupy the source cap.
    // Do not retire if some pending callbacks could not be tracked.
    if (binding._pending.length == binding.transientCallbackCount) {
      sources.removeWhere((_, source) => source.activeOnce == 0 && source.activePeriodic == 0 && source.pending == 0);
    }
    for (final source in all) {
      source.resetWindow();
    }
    lastReportUs = nowUs;
  }
}
