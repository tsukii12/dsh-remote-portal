// When each conversation was created, for the drawer's 「创建时间」 order.
//
// `session/list` rows carry only the latest activity (`updatedAt`); the
// creation time lives in the log header, which only `session/follow` sends.
// The first log event carries the same moment, and `session/page` reads it
// without activating an agent: `throughSeq: 0` is the one-event page ending at
// seq 0. The answer never changes, so it is fetched once per conversation,
// only while that order is chosen, and kept per host.
//
// A fork copies its source's first events, so it sorts by its source's time.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connection_state.dart';
import 'hosts_state.dart';

/// Reads one conversation's creation time; null when it can't tell.
typedef SessionCreatedFetcher = Future<DateTime?> Function(String sessionId);

final sessionCreatedFetcherProvider = Provider<SessionCreatedFetcher?>((ref) {
  final conn = ref.watch(activeConnectionProvider).value;
  if (conn == null) return null;
  return (sessionId) async {
    final page = await conn.client.history(sessionId, throughSeq: 0, maxMessages: 1);
    for (final event in page.events) {
      if (event.seq == 0 && event.time.millisecondsSinceEpoch > 0) return event.time;
    }
    return null;
  };
});

/// Conversation id → creation time, for the active host.
class SessionCreatedController extends Notifier<Map<String, DateTime>> {
  String _key = '';
  bool _loaded = false;
  final Set<String> _asking = {};
  final Set<String> _failed = {};
  final List<String> _queue = [];
  int _workers = 0;
  Timer? _flush;

  static String keyFor(HostRef host) => 'drawer.created.${host.kind.name}.${host.id}';

  /// Reads in flight at once.
  static const parallel = 2;

  @override
  Map<String, DateTime> build() {
    final key = keyFor(ref.watch(activeHostProvider));
    ref.watch(sessionCreatedFetcherProvider);
    _key = key;
    _loaded = false;
    _asking.clear();
    _failed.clear();
    _queue.clear();
    ref.onDispose(() => _flush?.cancel());
    unawaited(_load(key));
    return const {};
  }

  Future<void> _load(String key) async {
    final stored = <String, DateTime>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      final map = raw == null ? null : jsonDecode(raw);
      if (map is Map) {
        for (final MapEntry(:key, :value) in map.entries) {
          if (key is String && value is int) stored[key] = DateTime.fromMillisecondsSinceEpoch(value);
        }
      }
    } catch (_) {
      // Unreadable: fetch again.
    }
    if (_key != key || !ref.mounted) return;
    _loaded = true;
    state = {...stored, ...state};
    _pump();
  }

  /// Fetches the creation time of each of [ids] not known yet.
  void ensure(Iterable<String> ids) {
    for (final id in ids) {
      if (state.containsKey(id) || _asking.contains(id) || _failed.contains(id)) continue;
      _asking.add(id);
      _queue.add(id);
    }
    _pump();
  }

  void _pump() {
    if (!_loaded) return;
    final fetch = ref.read(sessionCreatedFetcherProvider);
    if (fetch == null) return;
    final owner = ref;
    while (_workers < parallel && _queue.isNotEmpty) {
      final id = _queue.removeAt(0);
      if (state.containsKey(id)) {
        _asking.remove(id);
        continue;
      }
      _workers++;
      unawaited(() async {
        DateTime? at;
        try {
          at = await fetch(id);
        } catch (_) {
          at = null;
        }
        _workers--;
        if (!ref.mounted) return;
        // An earlier build only frees its slot: the current queue may use
        // a new client for the same host and must own its failures too.
        if (owner.mounted) {
          _asking.remove(id);
          if (at == null) {
            _failed.add(id);
          } else {
            state = {...state, id: at};
            _scheduleSave();
          }
        }
        _pump();
      }());
    }
  }

  void _scheduleSave() {
    _flush?.cancel();
    final key = _key;
    _flush = Timer(const Duration(milliseconds: 400), () async {
      final snapshot = {for (final MapEntry(:key, :value) in state.entries) key: value.millisecondsSinceEpoch};
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(key, jsonEncode(snapshot));
      } catch (_) {
        // Kept in memory for this run.
      }
    });
  }
}

final sessionCreatedProvider = NotifierProvider<SessionCreatedController, Map<String, DateTime>>(
  SessionCreatedController.new,
);
