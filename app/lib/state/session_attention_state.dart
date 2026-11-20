// Which conversations want the person's attention, for the drawer's markers
// and its 待确认 / 未读 filters:
//
// * pending — an approval, plan review or question waits on them. Source:
//   the mux's pending host requests (`approval/request` and
//   `user-questions/request` waterfalls the Host redelivers to every new
//   connection until answered), the same state the notifications use.
//   Subagent requests count for their top-level conversation, like the
//   official sidebar's `pendingInteraction` marker.
// * unread — a conversation moved on since the person last looked at it
//   (the official "未读完成提醒"). This phone remembers, per host, the
//   activity time it last saw of each conversation; everything already there
//   the first time counts as seen.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import 'connection_state.dart';
import 'hosts_state.dart';
import 'notify_state.dart' show viewedChatProvider;
import 'sessions_state.dart';

// ── Pending requests ─────────────────────────────────────────────────────────

/// What a conversation waits for, strongest first.
enum PendingKind {
  approval,
  plan,
  question;

  /// The row's marker text.
  String get label => switch (this) {
    approval => appL10n.stateCordisPending,
    plan => appL10n.statePlanPending,
    question => appL10n.stateQuestionPending,
  };
}

/// Where pending requests come from: `$events` and the requests the mux holds
/// for the current generation.
typedef PendingSource = ({Stream<HostEvent> events, List<HostEvent> Function() pending});

final pendingSourceProvider = Provider<PendingSource?>((ref) {
  final conn = ref.watch(activeConnectionProvider).value;
  if (conn == null) return null;
  return (events: conn.client.hostEvents, pending: () => conn.client.mux.pendingRequests);
});

/// How long a request has to stay open before it is marked, so one answered
/// at once (「本对话都允许」, another device) never flashes.
final pendingSettleProvider = Provider<Duration>((ref) => const Duration(milliseconds: 800));

/// Top-level conversation id → what it waits for.
class PendingInteractionsController extends Notifier<Map<String, PendingKind>> {
  final Set<String> _ripe = {};
  final Map<String, Timer> _timers = {};
  PendingSource? _source;

  @override
  Map<String, PendingKind> build() {
    final source = ref.watch(pendingSourceProvider);
    _source = source;
    _clearTimers();
    _ripe.clear();
    if (source == null) return const {};
    final sub = source.events.listen((event) {
      switch (event) {
        case ApprovalRequestedEvent() ||
            UserQuestionRequestedEvent() ||
            HostRequestCancelledEvent() ||
            HostReadyEvent() ||
            SessionRemovedEvent():
          _refresh();
        default:
          break;
      }
    }, onError: (Object _) {});
    // Subagent lineage arrives with the list.
    ref.listen(sessionsProvider, (_, _) => _refresh());
    ref.onDispose(() {
      unawaited(sub.cancel());
      _clearTimers();
    });
    return _compute();
  }

  void _clearTimers() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }

  void _refresh() {
    final next = _compute();
    if (!_sameMap(next, state)) state = next;
  }

  Map<String, PendingKind> _compute() {
    final source = _source;
    if (source == null) return const {};
    final settle = ref.read(pendingSettleProvider);
    final live = <String>{};
    final out = <String, PendingKind>{};
    for (final event in source.pending()) {
      final (String, String, PendingKind)? request = switch (event) {
        ApprovalRequestedEvent(:final request) => (request.eventId, request.sessionId, PendingKind.approval),
        UserQuestionRequestedEvent(:final request) => (
          request.eventId,
          request.sessionId,
          request.questions.any((q) => q.intent?['kind'] == 'plan-review') ? PendingKind.plan : PendingKind.question,
        ),
        _ => null,
      };
      if (request == null) continue;
      final (eventId, sessionId, kind) = request;
      live.add(eventId);
      if (settle > Duration.zero && !_ripe.contains(eventId)) {
        _timers.putIfAbsent(
          eventId,
          () => Timer(settle, () {
            _timers.remove(eventId);
            _ripe.add(eventId);
            _refresh();
          }),
        );
        continue;
      }
      final root = _rootOf(sessionId);
      final had = out[root];
      if (had == null || kind.index < had.index) out[root] = kind;
    }
    _ripe.retainAll(live);
    for (final id in [..._timers.keys]) {
      if (!live.contains(id)) _timers.remove(id)?.cancel();
    }
    return out;
  }

  /// The top-level conversation a (sub)agent belongs to.
  String _rootOf(String sessionId) {
    final all = {for (final s in ref.read(sessionsProvider.notifier).allSessions) s.sessionId: s};
    var id = sessionId;
    for (var depth = 0; depth < 8; depth++) {
      final info = all[id];
      final parent = info?.parentSessionId;
      if (info == null || !info.isSubagent || parent == null || parent.isEmpty) return id;
      id = parent;
    }
    return id;
  }

  static bool _sameMap(Map<String, PendingKind> a, Map<String, PendingKind> b) {
    if (a.length != b.length) return false;
    for (final MapEntry(:key, :value) in a.entries) {
      if (b[key] != value) return false;
    }
    return true;
  }
}

final pendingInteractionsProvider = NotifierProvider<PendingInteractionsController, Map<String, PendingKind>>(
  PendingInteractionsController.new,
);

// ── Unread ───────────────────────────────────────────────────────────────────

/// What this phone has seen of one host's conversations: the activity time
/// (host clock, ms) last seen of each, and the baseline for the rest.
class DrawerSeen {
  const DrawerSeen({this.loaded = false, this.baseline, this.seen = const {}});

  factory DrawerSeen.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    final seen = map['seen'];
    return DrawerSeen(
      loaded: true,
      baseline: map['baseline'] is int ? map['baseline'] as int : null,
      seen: {
        if (seen is Map)
          for (final MapEntry(:key, :value) in seen.entries)
            if (key is String && value is int) key: value,
      },
    );
  }

  final bool loaded;

  /// Everything at or before this counts as seen (set on first sight).
  final int? baseline;
  final Map<String, int> seen;

  Map<String, Object?> toJson() => {'baseline': ?baseline, 'seen': seen};

  int seenOf(String sessionId) => seen[sessionId] ?? baseline ?? 0;

  DrawerSeen copyWith({int? baseline, Map<String, int>? seen}) =>
      DrawerSeen(loaded: loaded, baseline: baseline ?? this.baseline, seen: seen ?? this.seen);
}

class DrawerSeenController extends Notifier<DrawerSeen> {
  String _key = '';

  static String keyFor(HostRef host) => 'drawer.seen.${host.kind.name}.${host.id}';

  @override
  DrawerSeen build() {
    final key = keyFor(ref.watch(activeHostProvider));
    _key = key;
    unawaited(_load(key));
    ref.listen(sessionsProvider, (_, _) {
      _seedBaseline();
      _markViewed();
    });
    ref.listen(viewedChatProvider, (_, _) => _markViewed());
    // Leaving a conversation: what it showed then is what was seen.
    ref.listen(currentSessionProvider, (previous, _) {
      if (previous != null) markSeen(previous);
    });
    return const DrawerSeen();
  }

  Future<void> _load(String key) async {
    DrawerSeen loaded;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      loaded = raw == null ? const DrawerSeen(loaded: true) : DrawerSeen.fromJson(jsonDecode(raw));
    } catch (_) {
      loaded = const DrawerSeen(loaded: true);
    }
    if (_key != key || !ref.mounted) return;
    // Marks made before the store answered win over it.
    state = loaded.copyWith(seen: {...loaded.seen, ...state.seen});
    _seedBaseline();
    _markViewed();
  }

  List<SessionSummary> get _sessions => ref.read(sessionsProvider).value ?? const [];

  void _seedBaseline() {
    if (!state.loaded || state.baseline != null) return;
    final sessions = _sessions;
    if (sessions.isEmpty) return;
    final newest = sessions.map((s) => s.updatedAt.millisecondsSinceEpoch).reduce(math.max);
    _save(state.copyWith(baseline: newest));
  }

  void _markViewed() {
    final viewed = ref.read(viewedChatProvider);
    if (viewed != null && viewed.host == ref.read(activeHostProvider)) markSeen(viewed.sessionId);
  }

  /// Records [sessionId]'s current activity time as seen.
  void markSeen(String sessionId) {
    SessionSummary? summary;
    for (final s in _sessions) {
      if (s.sessionId == sessionId) summary = s;
    }
    if (summary == null) return;
    final at = summary.updatedAt.millisecondsSinceEpoch;
    if ((state.seen[sessionId] ?? -1) >= at) return;
    _save(state.copyWith(seen: {...state.seen, sessionId: at}));
  }

  void _save(DrawerSeen next) {
    state = next;
    if (!next.loaded) return;
    final key = _key;
    // Only conversations still listed are worth remembering.
    final listed = {for (final s in _sessions) s.sessionId};
    final kept = listed.isEmpty
        ? next
        : next.copyWith(
            seen: {
              for (final MapEntry(:key, :value) in next.seen.entries)
                if (listed.contains(key)) key: value,
            },
          );
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(key, jsonEncode(kept.toJson()));
      } catch (_) {
        // Kept in memory for this run.
      }
    }());
  }
}

final drawerSeenProvider = NotifierProvider<DrawerSeenController, DrawerSeen>(DrawerSeenController.new);

/// Conversations that moved on since they were last seen: idle (a running
/// one shows its own dot) and not the one open now.
final unreadSessionIdsProvider = Provider<Set<String>>((ref) {
  final seen = ref.watch(drawerSeenProvider);
  if (!seen.loaded || seen.baseline == null) return const {};
  final sessions = ref.watch(sessionsProvider).value ?? const [];
  final current = ref.watch(currentSessionProvider);
  return {
    for (final s in sessions)
      if (!s.running && s.sessionId != current && s.updatedAt.millisecondsSinceEpoch > seen.seenOf(s.sessionId))
        s.sessionId,
  };
});
