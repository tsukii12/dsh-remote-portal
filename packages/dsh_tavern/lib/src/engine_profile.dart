part of 'engine.dart';

// Opt-in diagnostics for the owner benchmark. No prompt, model configuration,
// resource identity or response text is included in this output.
class _TurnProfile {
  _TurnProfile._();
  static final _enabled = Platform.environment['DSH_TAVERN_PROFILE'] == '1';
  static _TurnProfile? start() => _enabled ? _TurnProfile._() : null;

  final _watch = Stopwatch()..start();
  final _phases = <String, int>{};
  final _work = <String, _ProfileWork>{};
  final _elapsedSpans = <String, _ProfileWork>{};
  Map<String, Object?> _history = const {};
  _ProfiledPromptCounter? _counter;
  var _last = 0;

  int get now => _watch.elapsedMicroseconds;

  // Main phases partition elapsed time, including any awaits in that phase.
  void mark(String name) {
    final at = now;
    _phases.update(name, (value) => value + at - _last, ifAbsent: () => at - _last);
    _last = at;
  }

  // Work samples are synchronous subspans and may overlap a main phase.
  void record(String name, int start) => _work.putIfAbsent(name, _ProfileWork.new).add(now - start);

  // A synchronous staged call uses one cursor, without adding a store timer.
  void Function(String) stageRecorder(String prefix) {
    var start = now;
    return (stage) {
      record('$prefix$stage', start);
      start = now;
    };
  }

  // These nested spans include awaits; keep them separate from CPU/SQL work.
  void recordElapsed(String name, int start) => _elapsedSpans.putIfAbsent(name, _ProfileWork.new).add(now - start);

  PromptTokenCounter counter(PromptTokenCounter original) => _counter ??= _ProfiledPromptCounter(original, this);

  void history({required bool windowed, required int pathNodes, required int bodyNodes, int? scanDepth}) {
    _history = {'windowed': windowed, 'pathNodes': pathNodes, 'bodyNodes': bodyNodes, 'scanDepth': ?scanDepth};
  }

  void finish(String kind) {
    mark('remainder');
    _watch.stop();
    final data = {
      'kind': kind,
      'elapsedMs': _watch.elapsedMicroseconds / 1000,
      'history': _history,
      'phasesMs': {for (final entry in _phases.entries) entry.key: entry.value / 1000},
      'workMs': {
        for (final entry in _work.entries)
          entry.key: {'total': entry.value.total / 1000, 'max': entry.value.longest / 1000, 'calls': entry.value.calls},
      },
      if (_elapsedSpans.isNotEmpty)
        'elapsedSpansMs': {
          for (final entry in _elapsedSpans.entries)
            entry.key: {
              'total': entry.value.total / 1000,
              'max': entry.value.longest / 1000,
              'calls': entry.value.calls,
            },
        },
    };
    stdout.writeln('DSH_TAVERN_PROFILE ${jsonEncode(data)}');
  }
}

class _ProfileWork {
  var total = 0;
  var longest = 0;
  var calls = 0;
  void add(int elapsed) {
    total += elapsed;
    if (elapsed > longest) longest = elapsed;
    calls++;
  }
}

class _ProfiledPromptCounter implements PromptTokenCounter {
  _ProfiledPromptCounter(this.original, this.profile);
  final PromptTokenCounter original;
  final _TurnProfile profile;

  @override
  String get name => original.name;
  @override
  bool get exact => original.exact;

  @override
  int countMessage(Map<String, Object?> message) {
    final start = profile.now;
    try {
      return original.countMessage(message);
    } finally {
      profile.record('token', start);
    }
  }

  @override
  int countText(String text) {
    final start = profile.now;
    try {
      return original.countText(text);
    } finally {
      profile.record('token', start);
    }
  }
}
