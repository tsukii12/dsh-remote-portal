// The pet's mood reducer (docs/design/pets.md §4). A pure function from the
// app's signals (what runs where, what waits on the person, how turns ended,
// the last touch) to what the pet shows. The chat page's pet layer and the
// overlay both draw its result. States, priorities and timings follow Clawd on
// Desk (error 8 > notification 7 > sweeping 6 > attention 5 > carrying =
// juggling 4 > working 3 > thinking 2 > idle 1 > sleeping 0; `minDisplay` /
// `autoReturn`). Turn ends are debounced: a goal's next round starting at once
// is not a finish.
//
// | 宠物状态 | 信号 | 类型 |
// |---|---|---|
// | idle | nothing in scope runs | level |
// | thinking | waiting for the model, reasoning, retrying | level |
// | working | a tool runs or the reply streams; tier = running conversations on every host (1–3) | level |
// | juggling | subagents run; tier = running subagents (1 / 2+) | level |
// | sweeping | compacting (autoReturn caps it) | level |
// | notification | an approval or a question waits — until handled | level |
// | attention | a turn finished, and no new round started within 1.5 s | one-off |
// | error | a turn failed (an engine restart is not one) | one-off |
// | carrying | reserved: a file upload / import | level |
// | sleeping | idle and untouched for sleepAfter | level |
// | waking | touched or spoken to while asleep | one-off, wakeMs |
//
// Stopping keeps the state it had; a stopped turn goes quietly back to idle.
//
// Scope: standing on the run strip the pet speaks for the conversation on
// screen ([PetScope.focus], like the strip it replaces the whale tail of);
// on the composer and in the overlay it speaks for everything
// ([PetScope.global]). Tiers always count globally. Bubbles and the most
// relevant conversation are global only.

import 'package:flutter/foundation.dart';

import '../state/hosts_state.dart';
import 'pet_pack.dart';
import 'pet_state.dart';

/// Whose state the pet shows.
enum PetScope {
  /// Every conversation on every host: the highest priority wins.
  global,

  /// The conversation on screen only.
  focus,
}

/// What the conversation on screen is doing (from `runActivityOf`).
enum PetActivity {
  /// Not running.
  none,

  /// Waiting for the first token, reasoning, retrying.
  thinking,

  /// A tool runs or the reply streams.
  working,

  /// An approval or a question waits on the person.
  waiting,

  /// Being stopped: keeps whatever it showed.
  stopping,
}

/// A running conversation (or subagent) on some host.
@immutable
class PetRun {
  const PetRun(this.host, this.sessionId, {this.subagent = false, String? root, this.since, this.title})
    : root = root ?? sessionId;

  final HostRef host;
  final String sessionId;
  final bool subagent;

  /// The top-level conversation (itself unless a subagent).
  final String root;

  /// When it was last seen starting (the most recently active one wins).
  final DateTime? since;

  /// The top-level conversation's title, unmasked; null until the host listed it.
  final String? title;

  @override
  bool operator ==(Object other) =>
      other is PetRun &&
      other.host == host &&
      other.sessionId == sessionId &&
      other.subagent == subagent &&
      other.root == root &&
      other.since == since &&
      other.title == title;

  @override
  int get hashCode => Object.hash(host, sessionId, subagent, root, since, title);
}

/// Something waiting on the person: an approval or a question.
@immutable
class PetPending {
  const PetPending({required this.host, required this.sessionId, required this.key, this.question = false});

  final HostRef host;

  /// The top-level conversation.
  final String sessionId;

  /// The request's identity (its eventId).
  final String key;
  final bool question;

  String get id => '${host.kind.name}:${host.id}|$sessionId|$key';

  PetTarget get target => PetTarget(host, sessionId);

  @override
  bool operator ==(Object other) =>
      other is PetPending &&
      other.host == host &&
      other.sessionId == sessionId &&
      other.key == key &&
      other.question == question;

  @override
  int get hashCode => Object.hash(host, sessionId, key, question);
}

/// The conversation the chat page shows.
@immutable
class PetFocus {
  const PetFocus({
    required this.host,
    required this.sessionId,
    this.title,
    this.activity = PetActivity.none,
    this.compacting = false,
    this.waitingKey,
    this.waitingQuestion = false,
  });

  final HostRef host;
  final String sessionId;

  /// The current chat state's title, before notification masking.
  final String? title;
  final PetActivity activity;
  final bool compacting;

  /// The open approval (or question) card's eventId, if one waits.
  final String? waitingKey;
  final bool waitingQuestion;

  bool get running => activity != PetActivity.none;

  PetTarget get target => PetTarget(host, sessionId);

  bool isOf(HostRef h, String id) => h == host && id == sessionId;

  @override
  bool operator ==(Object other) =>
      other is PetFocus &&
      other.host == host &&
      other.sessionId == sessionId &&
      other.title == title &&
      other.activity == activity &&
      other.compacting == compacting &&
      other.waitingKey == waitingKey &&
      other.waitingQuestion == waitingQuestion;

  @override
  int get hashCode => Object.hash(host, sessionId, title, activity, compacting, waitingKey, waitingQuestion);
}

/// The level signals at one moment.
@immutable
class PetSignals {
  const PetSignals({
    this.focus,
    this.viewed = false,
    this.runs = const [],
    this.pending = const [],
    required this.lastInteraction,
    this.carrying = false,
    this.quiet = false,
  });

  final PetFocus? focus;

  /// The person is looking at [focus] (the app and the chat are on screen).
  final bool viewed;

  /// Every running conversation and subagent on every connected host.
  final List<PetRun> runs;

  /// Everything waiting on the person, by top-level conversation.
  final List<PetPending> pending;

  /// The last touch anywhere on the chat page.
  final DateTime lastInteraction;

  /// Reserved: a file is being uploaded or imported.
  final bool carrying;

  /// 安静模式: no bubbles.
  final bool quiet;

  int get subRuns => runs.where((r) => r.subagent).length;

  /// Running top-level conversations, the focus counted once.
  int get topRuns {
    final focus = this.focus;
    final listed = runs.where((r) => !r.subagent).length;
    if (focus == null || !focus.running) return listed;
    final has = runs.any((r) => !r.subagent && focus.isOf(r.host, r.sessionId));
    return has ? listed : listed + 1;
  }

  /// Whether [sessionId] on [host] runs (a new round started).
  bool runsNow(HostRef host, String sessionId) =>
      (focus?.isOf(host, sessionId) ?? false) && focus!.running ||
      runs.any((r) => !r.subagent && r.host == host && r.sessionId == sessionId);
}

/// An edge from the alerts: a turn ended, or a request arrived.
enum PetEventKind { done, failed, stopped, approval, question }

@immutable
class PetEvent {
  const PetEvent({
    required this.kind,
    required this.host,
    required this.sessionId,
    required this.key,
    required this.at,
    this.title,
    this.bubble = false,
    this.ask,
    this.preview,
  });

  final PetEventKind kind;
  final HostRef host;

  /// The top-level conversation.
  final String sessionId;

  /// `turn`, or the request's eventId.
  final String key;
  final String? title;
  final DateTime at;

  /// May raise a bubble: the alert went to the pet or to the system (not the
  /// conversation on screen, not switched off in 通知).
  final bool bubble;

  /// A request the bubble shows and may answer (approval, question).
  final PetAsk? ask;

  /// 问一句's reply, for its done bubble.
  final String? preview;

  PetTarget get target => PetTarget(host, sessionId);

  PetBubbleKind? get bubbleKind => switch (kind) {
    PetEventKind.done => PetBubbleKind.done,
    PetEventKind.failed => PetBubbleKind.failed,
    PetEventKind.approval => PetBubbleKind.approval,
    PetEventKind.question => PetBubbleKind.question,
    PetEventKind.stopped => null,
  };
}

/// The reducer's clock settings: the pack's, over Clawd's defaults.
@immutable
class PetTimings {
  const PetTimings({
    this.minDisplay = defaultMinDisplay,
    this.autoReturn = defaultAutoReturn,
    this.sleepAfter = const Duration(seconds: 60),
    this.wake = const Duration(milliseconds: 1500),
  });

  factory PetTimings.of(PetPack? pack) {
    if (pack == null) return const PetTimings();
    return PetTimings(
      minDisplay: {...defaultMinDisplay, ...pack.minDisplay},
      // notification waits until handled (§4.2): no fold-back for it.
      autoReturn: {...defaultAutoReturn, ...pack.autoReturn}..remove('notification'),
      sleepAfter: pack.sleepAfter,
      wake: Duration(milliseconds: pack.wakeDuration),
    );
  }

  /// Clawd on Desk's defaults (Deepy's theme.json), ms.
  static const defaultMinDisplay = {
    'attention': 5200,
    'error': 4800,
    'sweeping': 5600,
    'notification': 3200,
    'carrying': 3200,
    'working': 1000,
    'thinking': 1000,
  };
  static const defaultAutoReturn = {'attention': 5200, 'error': 4800, 'sweeping': 300000, 'carrying': 3200};

  /// A finished turn waits this long for a next round before it celebrates.
  static const doneHold = Duration(milliseconds: 1500);

  /// A lower tier must hold this long before the tier steps down.
  static const tierHold = Duration(seconds: 5);

  /// Alerts within this long of a bubble merge into it.
  static const mergeWindow = Duration(seconds: 2);

  /// A queued bubble older than this is dropped instead of shown.
  static const queueFor = Duration(seconds: 10);

  /// A bubble with a request to answer, or 问一句's reply to read, stays this
  /// long (an answered request goes at once: it is stale).
  static const readFor = Duration(seconds: 30);

  final Map<String, int> minDisplay;
  final Map<String, int> autoReturn;
  final Duration sleepAfter;
  final Duration wake;

  Duration minDisplayOf(PetStateName s) => Duration(milliseconds: minDisplay[s.name] ?? 0);
  Duration? autoReturnOf(PetStateName s) =>
      autoReturn[s.name] == null ? null : Duration(milliseconds: autoReturn[s.name]!);

  @override
  bool operator ==(Object other) =>
      other is PetTimings &&
      mapEquals(other.minDisplay, minDisplay) &&
      mapEquals(other.autoReturn, autoReturn) &&
      other.sleepAfter == sleepAfter &&
      other.wake == wake;

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(minDisplay.entries.map((e) => '${e.key}=${e.value}')),
    Object.hashAllUnordered(autoReturn.entries.map((e) => '${e.key}=${e.value}')),
    sleepAfter,
    wake,
  );
}

/// Clawd on Desk's state priority: a higher one takes over at once, a lower
/// one waits for the current state's minDisplay.
int petPriority(PetStateName s) => switch (s) {
  PetStateName.error => 8,
  PetStateName.notification => 7,
  PetStateName.sweeping => 6,
  PetStateName.attention => 5,
  PetStateName.carrying || PetStateName.juggling => 4,
  PetStateName.working => 3,
  PetStateName.thinking => 2,
  PetStateName.idle || PetStateName.waking => 1,
  PetStateName.sleeping => 0,
};

bool _busy(PetStateName s) => s == PetStateName.thinking || s == PetStateName.working || s == PetStateName.juggling;

/// A brief state after an event (attention, error).
@immutable
class PetFlash {
  const PetFlash(this.state, this.until, this.target);

  final PetStateName state;
  final DateTime until;
  final PetTarget target;
}

/// A turn end or failure not yet looked at.
@immutable
class PetUnseen {
  const PetUnseen(this.kind, this.at);

  final PetBubbleKind kind;
  final DateTime at;
}

/// The reducer's state: what shows, since when, and what it waits for.
@immutable
class PetMood {
  const PetMood({
    required this.shown,
    required this.since,
    this.tier = 0,
    this.lowerTier,
    this.lowerSince,
    this.flash,
    this.held = const [],
    this.bubble,
    this.bubbleAt,
    this.merged = const {},
    this.queued,
    this.queuedAt,
    this.unseen = const {},
    this.pendingSince = const {},
    this.compactSince,
    this.lastBusy,
    this.wakingUntil,
    this.next,
  });

  /// The first mood: idle, now.
  factory PetMood.initial(DateTime now) => PetMood(shown: PetStateName.idle, since: now, lastBusy: now);

  final PetStateName shown;
  final DateTime since;
  final int tier;

  /// A lower tier of [shown] waiting out [PetTimings.tierHold], since when.
  final int? lowerTier;
  final DateTime? lowerSince;
  final PetFlash? flash;

  /// Finished turns waiting [PetTimings.doneHold] for a next round.
  final List<PetEvent> held;
  final PetBubble? bubble;

  /// When [bubble] went up, and the conversations merged into it.
  final DateTime? bubbleAt;
  final Set<PetTarget> merged;

  /// The one bubble waiting its turn.
  final PetBubble? queued;
  final DateTime? queuedAt;
  final Map<PetTarget, PetUnseen> unseen;

  /// Waiting requests by [PetPending.id] → first seen.
  final Map<String, DateTime> pendingSince;

  /// When the current compaction started (sweeping folds back after autoReturn).
  final DateTime? compactSince;

  /// The last time the target was something other than idle.
  final DateTime? lastBusy;
  final DateTime? wakingUntil;

  /// Run the reducer again at this time (a timer runs out); null: only on a
  /// new signal.
  final DateTime? next;

  PetMood copyWith({PetBubble? bubble, bool clearBubble = false}) => PetMood(
    shown: shown,
    since: since,
    tier: tier,
    lowerTier: lowerTier,
    lowerSince: lowerSince,
    flash: flash,
    held: held,
    bubble: clearBubble ? null : (bubble ?? this.bubble),
    bubbleAt: clearBubble ? null : bubbleAt,
    merged: clearBubble ? const {} : merged,
    queued: queued,
    queuedAt: queuedAt,
    unseen: unseen,
    pendingSince: pendingSince,
    compactSince: compactSince,
    lastBusy: lastBusy,
    wakingUntil: wakingUntil,
    next: next,
  );
}

/// Reduces [signals] (and the [events] since the last call) at [now].
PetMood reducePetMood(
  PetMood prev,
  PetSignals signals,
  DateTime now, {
  List<PetEvent> events = const [],
  PetTimings timings = const PetTimings(),
  PetScope scope = PetScope.global,
}) {
  final wake = <DateTime>[];
  void at(DateTime? t) {
    if (t != null && t.isAfter(now)) wake.add(t);
  }

  final focus = signals.focus;
  final global = scope == PetScope.global;
  bool inScope(HostRef host, String sessionId) => global || (focus?.isOf(host, sessionId) ?? false);
  bool viewing(HostRef host, String sessionId) => signals.viewed && (focus?.isOf(host, sessionId) ?? false);

  var flash = prev.flash != null && prev.flash!.until.isAfter(now) ? prev.flash : null;
  var bubble = prev.bubble;
  var bubbleAt = prev.bubbleAt;
  var merged = prev.merged;
  var queued = prev.queued;
  var queuedAt = prev.queuedAt;
  final unseen = {...prev.unseen};
  final held = [...prev.held];

  void flashOf(PetStateName state, PetTarget target) {
    if (!inScope(target.host, target.sessionId)) return;
    // A success never hides a failure that is still showing.
    if (flash != null && petPriority(flash!.state) > petPriority(state)) return;
    final hold = timings.autoReturnOf(state) ?? timings.minDisplayOf(state);
    flash = PetFlash(state, now.add(hold), target);
  }

  void offer(PetEvent e) {
    final kind = e.bubbleKind;
    if (!global || !e.bubble || kind == null) return;
    PetBubble make() => PetBubble(
      id: '${e.host.kind.name}:${e.host.id}|${e.sessionId}|${e.key}|${e.at.microsecondsSinceEpoch}',
      kind: kind,
      title: e.title,
      target: e.target,
      until: now.add(e.ask != null || e.preview != null ? PetTimings.readFor : kind.shownFor),
      ask: e.ask,
      preview: e.preview,
    );
    final current = bubble != null && bubble!.until.isAfter(now) ? bubble : null;
    if (current == null) {
      bubble = make();
      bubbleAt = now;
      merged = {e.target};
    } else if (current.kind == kind && now.difference(bubbleAt ?? now) < PetTimings.mergeWindow) {
      // Several in a row: one bubble, 「3 个对话做完了」.
      if (!merged.contains(e.target)) {
        merged = {...merged, e.target};
        bubble = current.copyWith(count: merged.length, until: now.add(kind.shownFor));
      }
    } else if (kind.rank >= current.kind.rank) {
      if (kind.rank > current.kind.rank) {
        queued = current;
        queuedAt = now;
      }
      bubble = make();
      bubbleAt = now;
      merged = {e.target};
    } else {
      queued = make();
      queuedAt = now;
    }
  }

  // ── Events ───────────────────────────────────────────────────────────────
  for (final e in events) {
    switch (e.kind) {
      case PetEventKind.done:
        held.add(e);
      case PetEventKind.failed:
        flashOf(PetStateName.error, e.target);
        if (!viewing(e.host, e.sessionId)) unseen[e.target] = PetUnseen(PetBubbleKind.failed, now);
        offer(e);
      case PetEventKind.approval || PetEventKind.question:
        offer(e);
      case PetEventKind.stopped:
        // Quietly back to idle: no celebration, no error.
        held.removeWhere((h) => h.host == e.host && h.sessionId == e.sessionId);
    }
  }

  // A finish counts once no new round started within doneHold.
  for (final h in [...held]) {
    if (signals.runsNow(h.host, h.sessionId)) {
      held.remove(h);
      continue;
    }
    final ripe = h.at.add(PetTimings.doneHold);
    if (ripe.isAfter(now)) {
      at(ripe);
      continue;
    }
    held.remove(h);
    flashOf(PetStateName.attention, h.target);
    if (!viewing(h.host, h.sessionId)) unseen[h.target] = PetUnseen(PetBubbleKind.done, now);
    offer(h);
  }

  // ── Bubbles ──────────────────────────────────────────────────────────────
  final pendingIds = {for (final p in signals.pending) p.id};
  bool stale(PetBubble b) {
    if (!b.kind.waits) return false;
    final prefix = '${b.target.host.kind.name}:${b.target.host.id}|${b.target.sessionId}|';
    // Answered (here or elsewhere): it waited before and waits no more.
    return prev.pendingSince.keys.any((id) => id.startsWith(prefix)) && !pendingIds.any((id) => id.startsWith(prefix));
  }

  if (bubble != null && (!bubble!.until.isAfter(now) || stale(bubble!))) {
    bubble = null;
    bubbleAt = null;
    merged = const {};
  }
  if (queued != null && (stale(queued!) || now.difference(queuedAt ?? now) > PetTimings.queueFor)) {
    queued = null;
    queuedAt = null;
  }
  if (bubble == null && queued != null) {
    final q = queued!;
    bubble = q.copyWith(until: now.add(q.ask != null || q.preview != null ? PetTimings.readFor : q.kind.shownFor));
    bubbleAt = now;
    merged = {queued!.target};
    queued = null;
    queuedAt = null;
  }
  if (signals.quiet) {
    bubble = null;
    bubbleAt = null;
    merged = const {};
    queued = null;
    queuedAt = null;
  }
  at(bubble?.until);
  at(queuedAt?.add(PetTimings.queueFor));
  at(flash?.until);

  // Looked at: no longer unseen.
  if (signals.viewed && focus != null) unseen.remove(focus.target);

  // ── Levels ───────────────────────────────────────────────────────────────
  final pendingSince = <String, DateTime>{for (final id in pendingIds) id: prev.pendingSince[id] ?? now};
  final compactSince = focus?.compacting ?? false ? (prev.compactSince ?? now) : null;

  final candidates = <(PetStateName, int)>[];
  if (flash?.state == PetStateName.error) candidates.add((PetStateName.error, 0));
  if (signals.pending.any((p) => inScope(p.host, p.sessionId))) candidates.add((PetStateName.notification, 0));
  if (compactSince != null) {
    final fold = timings.autoReturnOf(PetStateName.sweeping);
    final end = fold == null ? null : compactSince.add(fold);
    at(end);
    if (end == null || end.isAfter(now)) candidates.add((PetStateName.sweeping, 0));
  }
  if (flash?.state == PetStateName.attention) candidates.add((PetStateName.attention, 0));
  if (signals.carrying) candidates.add((PetStateName.carrying, 0));
  final subs = global
      ? signals.subRuns
      : signals.runs
            .where((r) => r.subagent && focus != null && r.host == focus.host && r.root == focus.sessionId)
            .length;
  if (subs > 0) candidates.add((PetStateName.juggling, signals.subRuns.clamp(1, 2)));
  final activity = focus?.activity ?? PetActivity.none;
  final others = global ? signals.topRuns - (focus != null && focus.running ? 1 : 0) : 0;
  final workingTier = signals.topRuns.clamp(1, 3);
  if (activity == PetActivity.working || others > 0) {
    candidates.add((PetStateName.working, workingTier));
  } else if (activity == PetActivity.thinking) {
    candidates.add((PetStateName.thinking, 0));
  } else if (activity == PetActivity.stopping) {
    // Stopping keeps what it showed.
    candidates.add(_busy(prev.shown) ? (prev.shown, prev.tier) : (PetStateName.thinking, 0));
  }
  candidates.sort((a, b) => petPriority(b.$1).compareTo(petPriority(a.$1)));
  var (target, targetTier) = candidates.firstOrNull ?? (PetStateName.idle, 0);

  // ── Sleep and waking ─────────────────────────────────────────────────────
  var lastBusy = prev.lastBusy ?? prev.since;
  if (target != PetStateName.idle) lastBusy = now;
  final touched = signals.lastInteraction.isAfter(lastBusy) ? signals.lastInteraction : lastBusy;
  if (target == PetStateName.idle) {
    final sleepAt = touched.add(timings.sleepAfter);
    if (!sleepAt.isAfter(now)) {
      target = PetStateName.sleeping;
    } else {
      at(sleepAt);
    }
  }
  var wakingUntil = prev.wakingUntil;
  if (prev.shown == PetStateName.sleeping && target != PetStateName.sleeping) wakingUntil = now.add(timings.wake);
  if (target == PetStateName.sleeping || (wakingUntil != null && !wakingUntil.isAfter(now))) wakingUntil = null;

  PetMood settle(PetStateName state, int tier, {int? lowerTier, DateTime? lowerSince, bool hold = false}) {
    final same = state == prev.shown;
    return PetMood(
      shown: state,
      since: same ? prev.since : now,
      tier: tier,
      lowerTier: lowerTier,
      lowerSince: lowerSince,
      flash: flash,
      held: held,
      bubble: bubble,
      bubbleAt: bubbleAt,
      merged: merged,
      queued: queued,
      queuedAt: queuedAt,
      unseen: unseen,
      pendingSince: pendingSince,
      compactSince: compactSince,
      lastBusy: lastBusy,
      wakingUntil: wakingUntil,
      next: wake.isEmpty ? null : wake.reduce((a, b) => a.isBefore(b) ? a : b),
    );
  }

  if (wakingUntil != null) {
    // Errors and waiting requests don't wait for the yawn.
    if (petPriority(target) < petPriority(PetStateName.notification)) {
      at(wakingUntil);
      return settle(PetStateName.waking, 0);
    }
    wakingUntil = null;
  }

  // ── Holding ──────────────────────────────────────────────────────────────
  final shown = prev.shown == PetStateName.waking ? PetStateName.idle : prev.shown;
  if (target == shown) {
    if (targetTier >= prev.tier) return settle(target, targetTier);
    // A lower tier steps down only after holding tierHold.
    final since = prev.lowerTier == targetTier ? prev.lowerSince ?? now : now;
    final end = since.add(PetTimings.tierHold);
    if (end.isAfter(now)) {
      at(end);
      return settle(shown, prev.tier, lowerTier: targetTier, lowerSince: since);
    }
    return settle(target, targetTier);
  }
  if (petPriority(target) <= petPriority(shown) && prev.shown != PetStateName.waking) {
    // The shown state stays at least its minDisplay.
    final end = prev.since.add(timings.minDisplayOf(shown));
    if (end.isAfter(now)) {
      at(end);
      return settle(shown, prev.tier);
    }
  }
  return settle(target, targetTier);
}

/// The most relevant conversation (docs/design/pets.md §2.7): waiting on the
/// person (the longest), failed unseen, finished unseen, running (the most
/// recently started), the one last looked at.
PetTarget? petTarget(PetMood mood, PetSignals signals) {
  PetPending? longest;
  DateTime? first;
  for (final p in signals.pending) {
    final since = mood.pendingSince[p.id];
    if (longest == null || (since != null && (first == null || since.isBefore(first)))) {
      longest = p;
      first = since;
    }
  }
  if (longest != null) return longest.target;
  for (final kind in [PetBubbleKind.failed, PetBubbleKind.done]) {
    MapEntry<PetTarget, PetUnseen>? latest;
    for (final e in mood.unseen.entries) {
      if (e.value.kind == kind && (latest == null || e.value.at.isAfter(latest.value.at))) latest = e;
    }
    if (latest != null) return latest.key;
  }
  final focus = signals.focus;
  PetRun? recent;
  for (final r in signals.runs) {
    if (r.subagent) continue;
    if (recent == null || (r.since != null && (recent.since == null || r.since!.isAfter(recent.since!)))) recent = r;
  }
  if (recent != null) return PetTarget(recent.host, recent.sessionId);
  if (focus != null && focus.running) return focus.target;
  return focus?.target;
}

/// Something runs, waits on the person, or a bubble is up.
bool petActive(PetMood mood, PetSignals signals) =>
    signals.runs.isNotEmpty || (signals.focus?.running ?? false) || signals.pending.isNotEmpty || mood.bubble != null;
