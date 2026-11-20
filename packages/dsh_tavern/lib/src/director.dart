import 'dart:convert';

import 'api.dart' show TavernUsage;

/// One completed helper attempt. Notes are private planning for the spoiler
/// panel; only beat and resolved prefetch references enter a main request.
class TavernDirectorRun {
  TavernDirectorRun({
    required this.id,
    required this.chatId,
    required this.sourceKind,
    this.sourceNodeId,
    required this.sourceFingerprint,
    required this.startedAt,
    required this.finishedAt,
    required this.success,
    required this.automatic,
    this.reportedUsage,
    this.failure,
    Map<String, Object?>? output,
    List<Map<String, Object?>> issues = const [],
  }) : _output = output == null ? null : jsonEncode(output),
       _issues = jsonEncode(issues);

  final String id;
  final String chatId;

  /// `node` retains the original id even after the audit FK becomes null.
  final String sourceKind;
  final String? sourceNodeId;
  final String sourceFingerprint;
  final DateTime startedAt;
  final DateTime finishedAt;
  final bool success;
  final bool automatic;
  final TavernUsage? reportedUsage;
  final String? failure;
  final String? _output;
  final String _issues;
  bool get notesSpoiler => true;
  Map<String, Object?>? get output => _output == null ? null : jsonDecode(_output) as Map<String, Object?>;
  List<Map<String, Object?>> get issues => [
    for (final item in jsonDecode(_issues) as List<Object?>) item as Map<String, Object?>,
  ];
  String? get notes => output?['notes'] as String?;
  String? get beat => output?['beat'] as String?;
  List<Map<String, Object?>> _rows(String key) => [
    for (final item in output?[key] as List<Object?>? ?? const []) item as Map<String, Object?>,
  ];
  List<Map<String, Object?>> get prefetch => _rows('prefetch');
  List<Map<String, Object?>> get suggestions => _rows('suggestions');

  /// These are the proposals from this run. Fixed-card execution receipts are
  /// branch-local in snapshot.eventRules; this raw proposal list is unchanged.
  /// Use readDirectorEvents to page through all successful runs' proposals.
  List<Map<String, Object?>> get events => _rows('events');
}

/// The current view. A failed latest attempt does not replace latestSuccess.
class TavernDirectorSnapshot {
  TavernDirectorSnapshot({
    required this.chatId,
    required this.automaticEnabled,
    required this.pendingJobs,
    required this.running,
    this.latestSuccess,
    this.latestAttempt,
    required this.stale,
    List<Map<String, Object?>> issues = const [],
    Map<String, Object?>? story,
    Map<String, Object?>? eventRules,
  }) : _issues = jsonEncode(issues),
       _story = story == null ? null : jsonEncode(story),
       _eventRules = eventRules == null ? null : jsonEncode(eventRules);
  final String chatId;

  /// False also when effective settings are unreadable, reported by
  /// director_settings_unavailable in [issues]. This conservative view does
  /// not change the saved automatic-execution setting.
  final bool automaticEnabled;

  /// Includes active/preparing jobs and cancelled local reads still draining,
  /// not only the waiting queue. Network cancellation does not wait for a
  /// deliberately uncooperative model subscription.
  final int pendingJobs;
  final bool running;
  final TavernDirectorRun? latestSuccess;
  final TavernDirectorRun? latestAttempt;
  final bool stale;
  final String _issues;
  final String? _story;
  final String? _eventRules;

  /// Saved story progress for the currently selected branch, with a read-only
  /// initial preview when no progress has been committed. Null for a card
  /// without a story, or when reading the view failed; the latter is reported
  /// by director_story_snapshot_unavailable in the top-level issues.
  /// Reading never advances acts or evaluates ending rules.
  /// This is separate from the latest helper attempt and can change on a
  /// normal main-turn commit even when the helper has not completed.
  Map<String, Object?>? get story => _story == null ? null : jsonDecode(_story) as Map<String, Object?>;

  /// Branch-local fixed-card event receipts, once/consumption ledger and
  /// pending literal prompts. Original proposals remain globally pending;
  /// reading this view never evaluates handlers or consumes their effects.
  /// Null means no definition/ledger, or an unreadable view reported by
  /// director_event_snapshot_unavailable in the top-level issues.
  Map<String, Object?>? get eventRules => _eventRules == null ? null : jsonDecode(_eventRules) as Map<String, Object?>;
  List<Map<String, Object?>> get issues => [
    for (final item in jsonDecode(_issues) as List<Object?>) item as Map<String, Object?>,
  ];
}

/// A durable director proposal. The engine owns its identity; names/data alone
/// do not authorize rules or IO. Its global pending status is separate from
/// each branch's fixed-card consumption ledger and execution receipts.
class TavernDirectorEvent {
  const TavernDirectorEvent({
    required this.id,
    required this.runId,
    required this.chatId,
    required this.name,
    required this.data,
    required this.createdAt,
    required this.sourceKind,
    this.sourceNodeId,
    required this.sourceFingerprint,
  }) : unavailableReason = null;

  /// Retains the saved id as a usable pagination cursor without inventing an
  /// empty proposal or hiding valid neighboring records. Original bytes stay
  /// on disk; unavailable fields are explicitly null.
  const TavernDirectorEvent.unavailable({required this.id, required this.chatId, required String reason})
    : unavailableReason = reason,
      runId = null,
      name = null,
      data = null,
      createdAt = null,
      sourceKind = null,
      sourceNodeId = null,
      sourceFingerprint = null;
  final String id;
  final String? runId;
  final String chatId;
  final String? name;
  final String? data;
  final DateTime? createdAt;
  final String? sourceKind;
  final String? sourceNodeId;
  final String? sourceFingerprint;
  final String? unavailableReason;
  bool get available => unavailableReason == null;
  String get status => available ? 'pending' : 'unavailable';
  String get source => 'director';
}
