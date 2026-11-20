import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';

/// The active host's client, or null while not connected.
DshClient? _client(Ref ref) => ref.watch(activeConnectionProvider).value?.client;

/// Re-runs [ref]'s provider when the Host emits one of [events].
void _refreshOn(Ref ref, DshClient client, Set<String> events) {
  final sub = client.hostEvents.listen((event) {
    if (event is HostReadyEvent || (event is UnknownHostEvent && events.contains(event.event))) {
      ref.invalidateSelf();
    }
  });
  ref.onDispose(() => unawaited(sub.cancel()));
}

// ── 自动化任务 ────────────────────────────────────────────────────────────────

/// Every automation task on the active host (`schedule/catalog`), refreshed
/// on `schedule/changed`. Null while not connected.
final schedulesProvider = FutureProvider.autoDispose<List<ScheduleTask>?>((ref) async {
  final client = _client(ref);
  if (client == null) return null;
  _refreshOn(ref, client, const {'schedule/changed'});
  final tasks = await client.scheduleCatalog();
  // Active first, then by next run; inactive ones by when they last ran.
  tasks.sort((a, b) {
    if (a.active != b.active) return a.active ? -1 : 1;
    final at = a.scheduledAt ?? DateTime(9999);
    final bt = b.scheduledAt ?? DateTime(9999);
    return a.active ? at.compareTo(bt) : bt.compareTo(at);
  });
  return tasks;
});

/// Delivered runs of one task, newest first (first page).
final scheduleHistoryProvider = FutureProvider.autoDispose.family<ScheduleHistory, ScheduleTask>((ref, task) async {
  final client = _client(ref);
  if (client == null) return const ScheduleHistory();
  return client.scheduleHistory(task);
});

// ── 后台任务 ──────────────────────────────────────────────────────────────────

/// A session's background jobs (`job/list`): the whole set on every change,
/// running ones first.
final jobsProvider = StreamProvider.autoDispose.family<List<JobInfo>, String>((ref, sessionId) {
  final client = _client(ref);
  if (client == null) return const Stream.empty();
  return client.watchJobs(sessionId).map((jobs) {
    final sorted = [...jobs]
      ..sort((a, b) {
        if (a.live != b.live) return a.live ? -1 : 1;
        final at = a.startedAt ?? DateTime(0);
        final bt = b.startedAt ?? DateTime(0);
        return bt.compareTo(at);
      });
    return sorted;
  });
});

// ── 技能 ──────────────────────────────────────────────────────────────────────

/// Skills the user can call with `/name` in [sessionId]; refreshed when a
/// plugin changes the command catalog.
final skillsProvider = FutureProvider.autoDispose.family<List<SkillInfo>?, String>((ref, sessionId) async {
  final client = _client(ref);
  if (client == null) return null;
  _refreshOn(ref, client, const {'commands/change', 'plugin-manager/changed'});
  final skills = await client.listSkills(sessionId);
  return skills..sort((a, b) => a.name.compareTo(b.name));
});

// ── Agent 预设 ────────────────────────────────────────────────────────────────

/// Agent presets in the Host's order; refreshed when the default changes.
final agentPresetsProvider = FutureProvider.autoDispose<List<AgentPresetInfo>?>((ref) async {
  final client = _client(ref);
  if (client == null) return null;
  _refreshOn(ref, client, const {'agent-preset/selected', 'settings/document-updated'});
  return client.listAgentPresets();
});

/// One preset's YAML.
final agentPresetDocumentProvider = FutureProvider.autoDispose.family<AgentPresetDocument, String>((ref, id) async {
  final client = _client(ref);
  if (client == null) throw const DshClosedException('not connected');
  return client.readAgentPreset(id);
});

// ── 权限预设 ──────────────────────────────────────────────────────────────────

/// One selectable permission preset.
class PermissionOption {
  const PermissionOption(this.value, this.name, [this.description]);
  final String value;
  final String name;
  final String? description;
}

/// What the 权限 page shows: the presets, the session's current one and
/// the default for new sessions.
class PermissionState {
  const PermissionState({
    required this.options,
    required this.hostDefault,
    this.defaultOptions,
    this.current,
    this.defaultRevision,
    this.invalidDefault = false,
  });

  final List<PermissionOption> options;
  final List<PermissionOption>? defaultOptions;
  final bool invalidDefault;

  /// Effective default for new sessions (`permission.defaultPreset`, else
  /// the catalog's default).
  final String hostDefault;

  /// The session's preset (`permissions` projection); `custom` when it was
  /// changed outside the presets. Null without a session.
  final String? current;

  /// Revision of the `permission` settings namespace (for the write);
  /// null when the namespace is missing (read-only default).
  final int? defaultRevision;
}

/// Permission presets for [sessionId] (null = new chat: no current value).
final permissionStateProvider = FutureProvider.autoDispose.family<PermissionState?, String?>((ref, sessionId) async {
  final client = _client(ref);
  if (client == null) return null;
  _refreshOn(ref, client, const {'permission-presets/catalog-changed', 'settings/document-updated'});
  final section = await client.settingsSection('permission').catchError((Object _) => null);
  final stored = section?.value['defaultPreset'];
  final catalog = await client.permissionPresets().catchError((Object error) {
    // Previous app versions offered the session-only Auto preset as a default.
    // Keep the explicit reset available when that makes the catalog fail.
    if (stored == 'auto' &&
        error is DshRemoteException &&
        error.message.contains('permission: unknown default preset')) {
      return (
        options: <({String value, String name, String? description})>[],
        defaultOptions: <({String value, String name, String? description})>[],
        defaultPreset: 'auto',
      );
    }
    throw error;
  });
  final projections = sessionId == null ? null : await client.projections(sessionId).catchError((Object _) => null);
  return PermissionState(
    options: [for (final o in catalog.options) PermissionOption(o.value, o.name, o.description)],
    defaultOptions: [for (final o in catalog.defaultOptions) PermissionOption(o.value, o.name, o.description)],
    hostDefault: stored is String ? stored : catalog.defaultPreset,
    current: projections?.permissionPreset,
    defaultRevision: section?.writable == true ? section?.revision : null,
    invalidDefault: stored == 'auto' && catalog.options.isEmpty,
  );
});
