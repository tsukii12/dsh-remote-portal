// When each part of a shared conversation appears in its replay. The web viewer
// (site/share/viewer.js, `timeline`) runs the same steps; the fixture in
// test/replay/fixtures/timeline.json keeps the two in step.
//
// The original times are kept where they are short and squeezed where they are
// long: what took a minute of waiting plays in about a second, a reply streams
// at a reading pace, tools run one after another as they did.

import 'dart:math' as math;

import '../../share_code/conversation_share.dart';

/// Pacing constants (milliseconds; mirrored in viewer.js).
abstract final class ReplayPace {
  /// Gaps up to this long play as they were; beyond it at [gapRate].
  static const gapKnee = 500.0;
  static const gapRate = 0.2;

  /// Longest gap inside a turn, and before a prompt or a turn (the person
  /// typing).
  static const maxGap = 1600.0;
  static const maxGapBeforePrompt = 900.0;

  /// Calls that overlapped (run in parallel) still appear one after another.
  static const minStagger = 120.0;
  static const maxStagger = 400.0;

  /// A reply's text: at most this fast and at least this slow
  /// (characters a second), and never longer than [maxStream].
  static const fastestCps = 500.0;
  static const slowestCps = 30.0;
  static const maxStream = 6000.0;
  static const minStream = 300.0;

  /// Assumed when the file has no stream time.
  static const assumedCps = 80.0;

  /// The thinking part of a reply.
  static const minThinking = 600.0;
  static const maxThinking = 2400.0;

  /// A tool's run: as it was up to [toolKnee], then at [toolRate], at
  /// least [minTool] (so its ring shows) and at most [maxTool].
  static const toolKnee = 300.0;
  static const toolRate = 0.15;
  static const minTool = 250.0;
  static const maxTool = 2500.0;
  static const assumedTool = 400.0;

  /// After a turn's last part, before it closes.
  static const turnTail = 150.0;
}

/// When one entry plays: it appears at [start]; a reply thinks until
/// [thinkEnd] and streams its text until [end]; a tool runs until [end].
class ReplayBeat {
  const ReplayBeat(this.start, this.end, [double? thinkEnd]) : thinkEnd = thinkEnd ?? start;

  final double start;
  final double thinkEnd;
  final double end;

  Map<String, double> toJson() => {'start': start, 'think': thinkEnd, 'end': end};
}

/// The replay schedule of a conversation.
class ReplayTimeline {
  ReplayTimeline._(this.beats, this.turnEnds, this.duration);

  factory ReplayTimeline.of(List<ConversationEntry> entries) {
    final beats = <ReplayBeat>[];
    var lastEndOrig = 0.0;
    var lastEndV = 0.0;
    var prevStartOrig = 0.0;
    var prevStartV = 0.0;
    for (final (i, entry) in entries.indexed) {
      final t = entry.t.toDouble();
      final (think, run) = _durations(entry);
      double start;
      if (i == 0) {
        start = 0;
      } else if (t >= lastEndOrig) {
        // A prompt (and the turn it opens) waited on the person.
        final cap = entry is UserEntry || entry is TurnEntry ? ReplayPace.maxGapBeforePrompt : ReplayPace.maxGap;
        start = lastEndV + _gap(t - lastEndOrig, cap);
      } else {
        // Overlaps something still running (parallel calls).
        final stagger = (t - prevStartOrig).clamp(ReplayPace.minStagger, ReplayPace.maxStagger);
        start = prevStartV + stagger;
      }
      start = math.max(start, prevStartV);
      final beat = ReplayBeat(start, start + think + run, start + think);
      beats.add(beat);
      prevStartOrig = t;
      prevStartV = start;
      // A turn's own span covers its parts: it doesn't push them back.
      if (entry is! TurnEntry) {
        lastEndOrig = math.max(lastEndOrig, t + _origRun(entry));
        lastEndV = math.max(lastEndV, beat.end);
      }
    }
    // Turns close after their last part.
    final turnEnds = <int, double>{};
    for (final (i, entry) in entries.indexed) {
      if (entry is! TurnEntry || entry.d == null) continue;
      final closeOrig = entry.t + entry.d!;
      var end = beats[i].start;
      for (var j = i + 1; j < entries.length && entries[j] is! TurnEntry; j++) {
        if (entries[j].t > closeOrig) break;
        end = math.max(end, beats[j].end);
      }
      turnEnds[i] = end + ReplayPace.turnTail;
    }
    var duration = 0.0;
    for (final b in beats) {
      duration = math.max(duration, b.end);
    }
    for (final end in turnEnds.values) {
      duration = math.max(duration, end);
    }
    return ReplayTimeline._(List.unmodifiable(beats), Map.unmodifiable(turnEnds), duration);
  }

  /// One per entry, in order; starts never go backwards.
  final List<ReplayBeat> beats;

  /// Entry index of a turn → when it closes; turns that were still running
  /// when exported never close.
  final Map<int, double> turnEnds;

  /// When the last thing ends.
  final double duration;

  /// How many entries have appeared at [at].
  int visibleAt(double at) {
    var lo = 0;
    var hi = beats.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (beats[mid].start <= at) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  Map<String, Object> toJson() => {
    'beats': [for (final b in beats) b.toJson()],
    'turnEnds': {for (final e in turnEnds.entries) '${e.key}': e.value},
    'duration': duration,
  };

  static double _gap(double gap, double cap) {
    if (gap <= 0) return 0;
    if (gap <= ReplayPace.gapKnee) return math.min(gap, cap);
    return math.min(cap, ReplayPace.gapKnee + (gap - ReplayPace.gapKnee) * ReplayPace.gapRate);
  }

  /// How long it originally ran (what later entries wait for).
  static double _origRun(ConversationEntry e) => switch (e) {
    ReplyEntry(:final d) || ToolEntry(:final d) => (d ?? 0).toDouble(),
    _ => 0,
  };

  /// (thinking, the rest) in replay time.
  static (double, double) _durations(ConversationEntry e) {
    switch (e) {
      case ReplyEntry(:final d, :final text, :final thinking):
        final textChars = text.runes.length.toDouble();
        final thinkChars = (thinking?.runes.length ?? 0).toDouble();
        final total = textChars + thinkChars;
        if (total == 0) return (0, 0);
        final orig = d?.toDouble() ?? total / ReplayPace.assumedCps * 1000;
        final thinkOrig = orig * thinkChars / total;
        final textOrig = orig - thinkOrig;
        final think = thinkChars == 0 ? 0.0 : thinkOrig.clamp(ReplayPace.minThinking, ReplayPace.maxThinking);
        if (textChars == 0) return (think, 0);
        final fastest = textChars / ReplayPace.fastestCps * 1000;
        final slowest = textChars / ReplayPace.slowestCps * 1000;
        final run = math.min(ReplayPace.maxStream, math.max(fastest, math.min(textOrig, slowest)));
        return (think, math.max(run, ReplayPace.minStream));
      case ToolEntry(:final d):
        if (d == null) return (0, ReplayPace.assumedTool);
        final run = d <= ReplayPace.toolKnee
            ? d.toDouble()
            : ReplayPace.toolKnee + (d - ReplayPace.toolKnee) * ReplayPace.toolRate;
        return (0, run.clamp(ReplayPace.minTool, ReplayPace.maxTool));
      default:
        return (0, 0);
    }
  }
}
