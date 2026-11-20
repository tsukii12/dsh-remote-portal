// The live activity (native: android/.../notify/LiveActivity.kt): one ongoing
// notification Android 16 promotes to a Live Update — the status bar chip, the
// top of the shade, the lock screen — and HyperOS, ColorOS and MagicOS draw in
// their islands.
//
// What it says is the pet's mood (pet_mood.dart) put into words, from the same
// reducer, so the island and the pet never disagree; it shows the pet's own
// picture for that state. Phone control is added natively and outranks this.
//
// | 宠物状态 | 实时活动 |
// |---|---|
// | thinking / working / juggling / sweeping | running: the clock in the chip |
// | notification | waiting: 「待确认」/「待回答」 |
// | attention | done: 「完成」 for the pet's moment, app in the background only |
// | error | failed: 「出错」, same |
// | anything else | running while something runs, else nothing |

import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';
import '../pets/pet_mood.dart';
import '../pets/pet_state.dart';
import 'chat_alerts.dart' show alertTitle;

enum LiveKind { running, waiting, done, failed }

/// What the live activity says. Equal values are not pushed again.
@immutable
class LiveActivity {
  const LiveActivity({
    required this.kind,
    required this.title,
    required this.text,
    required this.chip,
    required this.publicText,
    required this.mood,
    this.since,
    this.target,
    this.eventId,
  });

  final LiveKind kind;

  /// The conversation's title, masked.
  final String title;
  final String text;

  /// A word or two for the chip and the island.
  final String chip;

  /// The lock screen's line when it hides sensitive content.
  final String publicText;

  /// The pet state whose picture goes with it.
  final PetStateName mood;

  /// When the run started: the chip counts up from it.
  final DateTime? since;

  /// The conversation a tap opens.
  final PetTarget? target;

  /// The request it waits on.
  final String? eventId;

  Map<String, Object?> toMap() => {
    'kind': kind.name,
    'title': title,
    'text': text,
    'chip': chip,
    'publicText': publicText,
    'mood': mood.name,
    'sinceMs': ?since?.millisecondsSinceEpoch,
    if (target case final target?) ...target.toMap(),
    'eventId': ?eventId,
  };

  @override
  bool operator ==(Object other) =>
      other is LiveActivity &&
      other.kind == kind &&
      other.title == title &&
      other.text == text &&
      other.chip == chip &&
      other.publicText == publicText &&
      other.mood == mood &&
      other.since == since &&
      other.target == target &&
      other.eventId == eventId;

  @override
  int get hashCode => Object.hash(kind, title, text, chip, publicText, mood, since, target, eventId);

  @override
  String toString() => 'LiveActivity(${kind.name} "$title" · $text)';
}

/// What the live activity shows for [pet] (the global pet state); null: nothing.
///
/// [titles] holds the titles of conversations seen running (unmasked), so a
/// finished one keeps its name for its moment. [showDone] / [showFailed]
/// follow the 「一轮完成」 / 「出错或被停下」 notification switches.
LiveActivity? liveActivityOf({
  required PetState pet,
  required List<PetRun> runs,
  required List<PetPending> pending,
  PetFocus? focus,
  Map<PetTarget, String> titles = const {},
  bool showDone = true,
  bool showFailed = true,
}) {
  final l10n = appL10n;
  final roots = {for (final r in runs) PetTarget(r.host, r.root)};
  final running = roots.isNotEmpty;
  final target = pet.target ?? (running ? roots.first : null);
  if (target == null) return null;

  DateTime? started(PetTarget t) {
    DateTime? first;
    for (final r in runs) {
      final since = r.since;
      if (r.host != t.host || r.root != t.sessionId || since == null) continue;
      if (first == null || since.isBefore(first)) first = since;
    }
    return first;
  }

  // Its own title while it runs, else the one it last had.
  var title = titles[target];
  for (final r in runs) {
    final t = r.title;
    if (r.host == target.host && r.root == target.sessionId && t != null && t.trim().isNotEmpty) {
      title = t;
      break;
    }
  }
  // The open chat already follows title changes that an older list misses.
  final focusedTitle = focus?.title;
  if (focus?.target == target && focusedTitle != null && focusedTitle.trim().isNotEmpty) {
    title = focusedTitle;
  }

  // More conversations than the one it names: 「· 3 个对话在跑」.
  String counted(String line) => roots.length > 1 ? '$line · ${l10n.liveRunsCount(roots.length)}' : line;

  LiveActivity make(LiveKind kind, String text, String chip, String publicText, {String? eventId}) => LiveActivity(
    kind: kind,
    title: alertTitle(title),
    text: text,
    chip: chip,
    publicText: publicText,
    mood: pet.state,
    since: kind == LiveKind.running || kind == LiveKind.waiting ? started(target) : null,
    target: target,
    eventId: eventId,
  );

  LiveActivity? runningAs(PetStateName state) {
    if (!running) return null;
    final (text, chip) = switch (state) {
      PetStateName.working => (l10n.liveWorking, l10n.liveChipWorking),
      PetStateName.juggling => (l10n.liveJuggling, l10n.liveChipJuggling),
      PetStateName.sweeping => (l10n.liveSweeping, l10n.liveChipSweeping),
      _ => (l10n.liveThinking, l10n.liveChipThinking),
    };
    return make(LiveKind.running, counted(text), chip, l10n.livePublicRunning);
  }

  switch (pet.state) {
    case PetStateName.notification:
      final request = pending.where((p) => p.target == target).firstOrNull ?? pending.firstOrNull;
      final question = request?.question ?? false;
      return make(
        LiveKind.waiting,
        counted(question ? l10n.commonWaitingAnswer : l10n.commonWaitingApproval),
        question ? l10n.liveChipQuestion : l10n.liveChipApproval,
        l10n.livePublicWaiting,
        eventId: request?.key,
      );
    case PetStateName.attention when !pet.foreground && showDone:
      return make(LiveKind.done, l10n.statePetDone, l10n.liveChipDone, l10n.livePublicDone);
    case PetStateName.error when !pet.foreground && showFailed:
      return make(LiveKind.failed, l10n.statePetFailed, l10n.liveChipFailed, l10n.livePublicFailed);
    case PetStateName.thinking || PetStateName.working || PetStateName.juggling || PetStateName.sweeping:
      return runningAs(pet.state);
    default:
      return runningAs(PetStateName.thinking);
  }
}

/// Remembers titles from [runs] and then the current [focus], newest last,
/// keeping at most [max].
void learnLiveTitles(Map<PetTarget, String> titles, List<PetRun> runs, {PetFocus? focus, int max = 32}) {
  for (final r in runs) {
    final title = r.title;
    if (title == null || title.trim().isEmpty) continue;
    final key = PetTarget(r.host, r.root);
    titles.remove(key);
    titles[key] = title;
  }
  final focusedTitle = focus?.title;
  if (focus != null && focusedTitle != null && focusedTitle.trim().isNotEmpty) {
    titles.remove(focus.target);
    titles[focus.target] = focusedTitle;
  }
  while (titles.length > max) {
    titles.remove(titles.keys.first);
  }
}
