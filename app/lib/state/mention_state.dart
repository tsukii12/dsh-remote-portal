// `@` references: where candidates come from, and the recently picked ones.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connection_state.dart';

/// Candidate lookups behind the `@` picker (a seam for tests).
abstract class MentionSource {
  /// `fileReferences/list` under [sessionId]'s cwd.
  Future<List<FileReferenceCandidate>> files(String sessionId, String query);

  /// `sessionReferenceResolver/candidates` for [sessionId].
  Future<List<SessionReferenceCandidate>> sessions(String sessionId, String query);

  /// `session/list` (subagents and archived included): parents, cwd and
  /// activity times for the rows.
  Future<List<SessionSummary>> allSessions();
}

class ClientMentionSource implements MentionSource {
  ClientMentionSource(this.client);
  final DshClient client;

  @override
  Future<List<FileReferenceCandidate>> files(String sessionId, String query) => client.fileReferences(sessionId, query);

  @override
  Future<List<SessionReferenceCandidate>> sessions(String sessionId, String query) =>
      client.sessionReferences(sessionId, query);

  @override
  Future<List<SessionSummary>> allSessions() => client.listSessions();
}

/// The active host's lookups; null while disconnected.
final mentionSourceProvider = Provider<MentionSource?>((ref) {
  final client = ref.watch(activeConnectionProvider).value?.client;
  if (client == null || !client.canListReferences) return null;
  return ClientMentionSource(client);
});

/// One picked reference, for the 「最近」 rows.
class MentionRecent {
  const MentionRecent({required this.key, required this.mention, this.cwd, this.sessionId});

  static MentionRecent? fromJson(Object? json) {
    if (json is! Map) return null;
    final key = json['key'];
    final mention = json['mention'];
    if (key is! String || mention is! String) return null;
    return MentionRecent(
      key: key,
      mention: mention,
      cwd: json['cwd'] as String?,
      sessionId: json['sessionId'] as String?,
    );
  }

  /// `f:<path>` for files and folders, `s:<sessionId>` for conversations.
  final String key;

  /// The prompt text that was inserted.
  final String mention;

  /// The workspace a file path is relative to.
  final String? cwd;

  /// The conversation it was picked in (a file) or the one it names.
  final String? sessionId;

  Map<String, Object?> toJson() => {'key': key, 'mention': mention, 'cwd': ?cwd, 'sessionId': ?sessionId};
}

/// Recently picked references, newest first; kept across launches when the
/// preferences store is there.
class MentionRecents {
  MentionRecents({this.persist = true}) {
    if (persist) unawaited(_load());
  }

  static const _key = 'mention_recents_v1';
  static const limit = 12;

  final bool persist;
  List<MentionRecent> _entries = const [];

  List<MentionRecent> get entries => _entries;

  /// Position in the list (0 = newest), or null.
  int? rank(String key) {
    final i = _entries.indexWhere((e) => e.key == key);
    return i < 0 ? null : i;
  }

  void record(MentionRecent entry) {
    _entries = [
      entry,
      for (final e in _entries)
        if (e.key != entry.key) e,
    ].take(limit).toList();
    if (persist) unawaited(_save());
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final loaded = [for (final e in decoded) ?MentionRecent.fromJson(e)];
      // Anything picked before the load finished stays on top.
      _entries = [
        ..._entries,
        for (final e in loaded)
          if (!_entries.any((x) => x.key == e.key)) e,
      ].take(limit).toList();
    } catch (_) {
      // No preferences backend (tests) or an unreadable value: start empty.
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode([for (final e in _entries) e.toJson()]));
    } catch (_) {}
  }
}

final mentionRecentsProvider = Provider<MentionRecents>((ref) => MentionRecents());
