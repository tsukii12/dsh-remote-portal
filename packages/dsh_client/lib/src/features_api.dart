/// Official surfaces the app mirrors natively: automation tasks
/// (`schedule/*`), background jobs (`job/*`), skills (`skills/list`), agent
/// presets (`agentPresets/*`) and settings namespaces (`settings/*`).
///
/// Verified against DSH 0.2.1-rc.2 (`@deepseek-ai/dsh-schedule`,
/// `dsh-api-job-controller`, `dsh-jobs`, `dsh-api-session-controller`,
/// `dsh-agent-preset-registry`, `dsh-api-settings-controller` typings, and a
/// throwaway `dsh web`).
library;

import 'dart:async';

import 'errors.dart';
import 'json.dart';
import 'session_api.dart';

// -----------------------------------------------------------------------------
// Automation tasks (schedule)
// -----------------------------------------------------------------------------

/// One `schedule/catalog` entry: a stored reminder plus where it lives.
///
/// Supports legacy session-owned records and 0.2.2 target-based Host tasks.
class ScheduleTask {
  const ScheduleTask({
    required this.id,
    required this.sessionId,
    required this.kind,
    required this.title,
    required this.prompt,
    required this.active,
    required this.record,
    this.scheduledAt,
    this.afterSeconds,
    this.everySeconds,
    this.time,
    this.timeZone,
    this.weekdays = const [],
    this.expression,
    this.lastDeliveredAt,
    this.target,
    this.involvedSessionIds = const [],
    this.status,
    this.updatedAt,
  });

  /// Null when the entry has no identity or supported destination.
  static ScheduleTask? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    final id = asString(map['id']);
    final target = asMap(map['target']);
    final targetKind = asString(target?['kind']);
    if (target != null && !const {'session', 'new_once', 'new'}.contains(targetKind)) return null;
    final sessionId = target == null
        ? asString(map['sessionId'])
        : targetKind == 'session'
        ? asString(target['sessionId'])
        : null;
    if (id == null || id.isEmpty || (target == null && sessionId == null)) return null;
    final prompt = asString(map['prompt']) ?? '';
    final title = asString(map['title'])?.trim();
    final last = asMap(map['lastDelivery']);
    // `update` compares against the stored record: keep it without the
    // catalog's own fields.
    final record = Map<String, Object?>.of(map)
      ..remove('sessionId')
      ..remove('status')
      ..remove('lastDelivery');
    return ScheduleTask(
      id: id,
      sessionId: sessionId,
      kind: asString(map['kind']) ?? 'at',
      // Records saved before titles existed fall back to the prompt's first line.
      title: title == null || title.isEmpty ? prompt.split('\n').first.trim() : title,
      prompt: prompt,
      active: target == null ? map['status'] != 'inactive' : map['status'] == 'active',
      target: target == null ? null : Map.unmodifiable(target),
      involvedSessionIds: [for (final id in asListOrEmpty(map['involvedSessionIds'])) ?asString(id)],
      status: asString(map['status']),
      updatedAt: asString(map['updatedAt']),
      record: Map.unmodifiable(record),
      scheduledAt: DateTime.tryParse(asString(map['scheduledAt']) ?? ''),
      afterSeconds: asInt(map['afterSeconds']),
      everySeconds: asInt(map['everySeconds']),
      time: asString(map['time']),
      timeZone: asString(map['timeZone']),
      weekdays: [for (final d in asListOrEmpty(map['weekdays'])) ?asInt(d)],
      expression: asString(map['expression']),
      lastDeliveredAt: DateTime.tryParse(asString(last?['deliveredAt']) ?? ''),
    );
  }

  final String id;

  /// Existing delivery session; null for `new` and the uncreated `new_once` target.
  final String? sessionId;
  final Map<String, Object?>? target;
  final List<String> involvedSessionIds;
  final String? status;
  final String? updatedAt;

  /// Wire evidence from the Host's catalog, independent of release strings.
  bool get usesTargetProtocol => target != null;

  /// `after`, `at`, `every`, `daily`, `weekly` or `cron`.
  final String kind;
  final String title;
  final String prompt;

  /// `status: active`; inactive tasks (one-shots already delivered) stay
  /// listed until deleted.
  final bool active;

  /// Next target time (UTC on the wire).
  final DateTime? scheduledAt;
  final int? afterSeconds;
  final int? everySeconds;

  /// `HH:MM[:SS[.mmm]]` in [timeZone] (daily / weekly).
  final String? time;
  final String? timeZone;

  /// ISO weekdays, 1 = Monday (weekly).
  final List<int> weekdays;

  /// Five-field cron expression in [timeZone].
  final String? expression;
  final DateTime? lastDeliveredAt;

  /// The stored record as returned (for `schedule/update`'s `expected`).
  final Map<String, Object?> record;

  bool get recurring => const {'every', 'daily', 'weekly', 'cron', 'rrule'}.contains(kind);
}

/// One delivered run (`schedule/history` record).
class ScheduleRun {
  const ScheduleRun({required this.scheduledAt, required this.deliveredAt, this.prompt, this.targetSessionId});

  final DateTime? scheduledAt;
  final DateTime? deliveredAt;

  /// Actual destination of this run; absent on legacy receipts.
  final String? targetSessionId;

  /// The prompt as delivered; absent on receipts older than prompt capture.
  final String? prompt;
}

/// A page of `schedule/history`, newest first.
class ScheduleHistory {
  const ScheduleHistory({
    this.runs = const [],
    this.nextBefore,
    this.pruned = false,
    this.retentionDays,
    this.retentionRecords,
    this.missing,
  });

  final List<ScheduleRun> runs;

  /// Cursor for the next (older) page; null on the last page.
  final String? nextBefore;

  /// Older runs were removed by the Host's retention policy.
  final bool pruned;
  final int? retentionDays;
  final int? retentionRecords;

  /// `schedule_not_found` / `delivery_cursor_not_found`; null on success.
  final String? missing;
}

/// Result of `schedule/update`: [code] says why nothing changed.
class ScheduleUpdate {
  const ScheduleUpdate({required this.updated, this.task, this.code, this.message});

  final bool updated;
  final ScheduleTask? task;

  /// `schedule_not_found`, `schedule_ended`, `schedule_conflict` or a tool
  /// error code (`invalid_prompt`…).
  final String? code;
  final String? message;
}

// -----------------------------------------------------------------------------
// Background jobs
// -----------------------------------------------------------------------------

/// `JobView` (`dsh-jobs`): one background process of a session.
class JobInfo {
  const JobInfo({
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
    this.progress,
    this.detail,
    this.startedAt,
    this.finishedAt,
    this.outputBytes = 0,
  });

  static JobInfo? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map?['id']);
    if (map == null || id == null) return null;
    return JobInfo(
      id: id,
      kind: asString(map['kind']) ?? 'bash',
      label: asString(map['label']) ?? id,
      status: asString(map['status']) ?? 'running',
      progress: asString(map['progress']),
      detail: asString(map['detail']),
      startedAt: asEpochMs(map['startedAt']),
      finishedAt: asEpochMs(map['finishedAt']),
      outputBytes: asInt(asMap(map['output'])?['total']) ?? 0,
    );
  }

  final String id;
  final String kind;

  /// Usually the command line.
  final String label;

  /// `running`, `stopping`, `completed`, `killed` or `failed`.
  final String status;
  final String? progress;
  final String? detail;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final int outputBytes;

  bool get live => status == 'running' || status == 'stopping';
}

/// One `job/follow` frame.
sealed class JobFrame {
  const JobFrame();

  static JobFrame? fromJson(Object? json) {
    final map = asMap(json);
    switch (asString(map?['type'])) {
      case 'opened':
        final job = JobInfo.fromJson(map!['job']);
        return job == null ? null : JobOpened(job);
      case 'output':
        return JobOutput([
          for (final c in asListOrEmpty(map!['chunks']))
            if (asMap(c) case final chunk?)
              JobChunk(
                text: asString(chunk['text']) ?? '',
                channel: asString(chunk['channel']),
                gapBefore: chunk['gapBefore'] == true,
              ),
        ], lossy: map['lossy'] == true);
      case 'status':
        final job = JobInfo.fromJson(map!['job']);
        return job == null ? null : JobStatusChanged(job);
    }
    return null;
  }
}

final class JobOpened extends JobFrame {
  const JobOpened(this.job);
  final JobInfo job;
}

final class JobOutput extends JobFrame {
  const JobOutput(this.chunks, {this.lossy = false});
  final List<JobChunk> chunks;

  /// Output was dropped before these chunks (cap or slow reader).
  final bool lossy;
}

/// The job finished; the stream ends after this frame.
final class JobStatusChanged extends JobFrame {
  const JobStatusChanged(this.job);
  final JobInfo job;
}

class JobChunk {
  const JobChunk({required this.text, this.channel, this.gapBefore = false});
  final String text;

  /// `stdout`, `stderr` or `log`.
  final String? channel;

  /// Earlier output was trimmed before this chunk.
  final bool gapBefore;
}

// -----------------------------------------------------------------------------
// Skills, agent presets, settings
// -----------------------------------------------------------------------------

/// A user-invocable skill (`skills/list`).
class SkillInfo {
  const SkillInfo({
    required this.name,
    required this.description,
    this.whenToUse,
    this.path,
    this.modelInvocable = true,
  });

  final String name;
  final String description;
  final String? whenToUse;

  /// Its `SKILL.md`, when the Host reports one.
  final String? path;

  /// False for `disable-model-invocation: true`: only `/name` loads it.
  final bool modelInvocable;
}

/// One `agentPresets/list` row.
class AgentPresetInfo {
  const AgentPresetInfo({
    required this.id,
    this.isDefault = false,
    this.name,
    this.description,
    this.broken,
    this.order,
  });

  final String id;

  /// The Host's default for new sessions (after `selectedDefault`).
  final bool isDefault;
  final String? name;
  final String? description;

  /// Why the preset failed to load; it cannot be selected then.
  final String? broken;
  final int? order;
}

/// `agentPresets/read`: the preset's YAML document.
class AgentPresetDocument {
  const AgentPresetDocument({required this.id, required this.content, this.name, this.description});

  final String id;
  final String content;
  final String? name;
  final String? description;
}

/// One namespace of `settings/describe` (a `SettingsNamespaceView`).
class SettingsSection {
  const SettingsSection({
    required this.ns,
    required this.value,
    required this.revision,
    this.writable = true,
    this.user,
    this.base,
  });

  /// Reads one namespace view; [writable] comes from the describe envelope.
  factory SettingsSection.fromView(String ns, Object? view, {bool writable = true}) {
    final map = asMapOrEmpty(view);
    return SettingsSection(
      ns: ns,
      value: asMapOrEmpty(map['value']),
      revision: asInt(map['revision']) ?? 0,
      writable: writable,
      user: asMap(map['user']),
      base: asMap(map['base']),
    );
  }

  final String ns;

  /// Resolved value: schema defaults, then the composition base, then the
  /// user layer (secrets redacted).
  final Map<String, Object?> value;
  final int revision;

  /// The settings document accepts writes (false under a read-only profile).
  final bool writable;

  /// The raw user layer, when one exists: a field here is user-owned.
  final Map<String, Object?>? user;

  /// The composition base (profile `cordis.patch.yml`, overlays) with
  /// defaults resolved: a field here comes back after the user removes it.
  final Map<String, Object?>? base;
}

/// One path-addressed edit of `settings/mutate` (`SettingsPathOpView`): `set`
/// writes [value] at [path], creating intermediate objects; `unset` removes it.
class SettingsOp {
  const SettingsOp.set(this.path, this.value) : op = 'set';
  const SettingsOp.unset(this.path) : op = 'unset', value = null;

  final String op;
  final List<String> path;
  final Object? value;

  Map<String, Object?> toJson() => {'op': op, 'path': path, if (op == 'set') 'value': value};
}

extension FeaturesApi on DshClient {
  // ── schedule ─────────────────────────────────────────────────────────────

  /// `schedule/catalog`: every stored task on this Host, active and inactive.
  Future<List<ScheduleTask>> scheduleCatalog() async => [
    for (final entry in asListOrEmpty(await rpc.call('schedule/catalog'))) ?ScheduleTask.fromJson(entry),
  ];

  /// `schedule/history`: delivered runs of [task], newest first, [limit]
  /// (1-100) per page; pass the previous page's `nextBefore` as [before].
  Future<ScheduleHistory> scheduleHistory(ScheduleTask task, {int limit = 20, String? before}) async {
    final value = asMapOrEmpty(
      await rpc.call('schedule/history', {
        'request': {
          if (!task.usesTargetProtocol) 'sessionId': task.sessionId,
          'id': task.id,
          'limit': limit,
          'before': ?before,
        },
      }),
    );
    final code = asString(value['code']);
    if (code != null) return ScheduleHistory(missing: code);
    final retention = asMap(value['retention']);
    return ScheduleHistory(
      runs: [
        for (final r in asListOrEmpty(value['records']))
          if (asMap(r) case final run?)
            ScheduleRun(
              scheduledAt: DateTime.tryParse(asString(run['scheduledAt']) ?? ''),
              deliveredAt: DateTime.tryParse(asString(run['deliveredAt']) ?? ''),
              prompt: asString(run['prompt']),
              targetSessionId: asString(run['targetSessionId']),
            ),
      ],
      nextBefore: asString(value['nextBefore']),
      pruned: value['earlierRecordsPruned'] == true,
      retentionDays: asInt(retention?['days']),
      retentionRecords: asInt(retention?['records']),
    );
  }

  /// `schedule/update` with the task's stored record as `expected`
  /// (compare-and-set): renames and/or rewrites the prompt.
  Future<ScheduleUpdate> updateSchedule(ScheduleTask task, {String? title, String? prompt}) async {
    if (task.usesTargetProtocol) return updateTargetSchedule(task, {'title': ?title, 'prompt': ?prompt});
    final value = asMapOrEmpty(
      await rpc.call('schedule/update', {
        'request': {
          'sessionId': task.sessionId,
          'id': task.id,
          'expected': task.record,
          'title': ?title,
          'prompt': ?prompt,
        },
      }),
    );
    final record = asMap(value['record']);
    if (value['updated'] == true || (record != null && value['code'] == null)) {
      return ScheduleUpdate(
        updated: value['updated'] == true,
        task: record == null
            ? null
            : ScheduleTask.fromJson({
                ...record,
                'sessionId': task.sessionId,
                'status': task.active ? 'active' : 'inactive',
              }),
      );
    }
    return ScheduleUpdate(updated: false, code: asString(value['code']), message: asString(value['message']));
  }

  /// `schedule/delete` (hard delete, history included). False when the task
  /// was already gone.
  Future<bool> deleteSchedule(ScheduleTask task) async {
    if (task.usesTargetProtocol) {
      final value = asMapOrEmpty(
        await rpc.call('schedule/edit', {
          'request': {'id': task.id, 'action': 'delete', 'expectedUpdatedAt': task.updatedAt},
        }),
      );
      final code = asString(value['code']);
      if (code != null && code != 'schedule_not_found') throw DshRemoteException(code, code);
      return value['deleted'] == true;
    }
    final value = asMapOrEmpty(
      await rpc.call('schedule/delete', {
        'request': {'sessionId': task.sessionId, 'id': task.id},
      }),
    );
    return value['deleted'] == true;
  }

  /// Update one 0.2.2 task using its catalog revision; never replay a failed write.
  Future<ScheduleUpdate> updateTargetSchedule(ScheduleTask task, Map<String, Object?> patch) async {
    final value = asMapOrEmpty(
      await rpc.call('schedule/edit', {
        'request': {'id': task.id, 'action': 'update', 'patch': patch, 'expectedUpdatedAt': task.updatedAt},
      }),
    );
    final code = asString(value['code']);
    return ScheduleUpdate(
      updated: code == null && value['id'] == task.id,
      task: code == null ? ScheduleTask.fromJson(value) : null,
      code: code,
      message: asString(value['message']),
    );
  }

  /// Run through the Host's target semantics on 0.2.2; retain legacy queued prompts.
  Future<void> runScheduledTask(ScheduleTask task, {String? timeZone}) async {
    if (!task.usesTargetProtocol) {
      await prompt(task.sessionId!, task.prompt, mode: PromptMode.queue, timeZone: timeZone);
      return;
    }
    final value = asMapOrEmpty(
      await rpc.call('schedule/run', {
        'request': {'id': task.id},
      }),
    );
    final code = asString(value['code']);
    if (code != null) throw DshRemoteException(code, code);
  }

  // ── jobs ─────────────────────────────────────────────────────────────────

  /// `job/list`: the session's jobs, the whole set on every change. Jobs live
  /// in the Host process's memory: a restart forgets them.
  Stream<List<JobInfo>> watchJobs(String sessionId) => _items('job/list', {
    'request': {'sessionId': sessionId},
  }).map((item) => [for (final j in asListOrEmpty(asMap(item)?['jobs'])) ?JobInfo.fromJson(j)]);

  /// `job/follow`: `opened`, then output chunks from [from] (default: the
  /// earliest kept), then one `status` frame when the job ends.
  Stream<JobFrame> followJob(String sessionId, String jobId, {int? from}) => _items('job/follow', {
    'request': {'sessionId': sessionId, 'jobId': jobId, 'from': ?from},
  }).map(JobFrame.fromJson).where((f) => f != null).cast<JobFrame>();

  /// `job/kill`: true when a stop was requested, false when it had already
  /// finished. Throws `job/not-found` for an unknown job.
  Future<bool> killJob(String sessionId, String jobId) async {
    final value = asMapOrEmpty(
      await rpc.call('job/kill', {
        'request': {'sessionId': sessionId, 'jobId': jobId},
      }),
    );
    return value['outcome'] == 'requested';
  }

  // ── skills ───────────────────────────────────────────────────────────────

  /// `skills/list`: skills the user can invoke with `/name` in [sessionId]
  /// (project skills depend on the session's directory).
  Future<List<SkillInfo>> listSkills(String sessionId) async {
    final value = asMapOrEmpty(
      await rpc.call('skills/list', {
        'request': {'sessionId': sessionId},
      }),
    );
    return [
      for (final s in asListOrEmpty(value['skills']))
        if (asMap(s) case final skill? when asString(skill['name'])?.isNotEmpty ?? false)
          SkillInfo(
            name: asString(skill['name'])!,
            description: asString(skill['description']) ?? '',
            whenToUse: asString(skill['whenToUse']),
            path: asString(skill['path']),
            modelInvocable: skill['modelInvocable'] != false,
          ),
    ];
  }

  // ── agent presets ────────────────────────────────────────────────────────

  /// `agentPresets/list`, in the Host's order.
  Future<List<AgentPresetInfo>> listAgentPresets() async {
    final value = asMapOrEmpty(await rpc.call('agentPresets/list'));
    final presets = [
      for (final p in asListOrEmpty(value['presets']))
        if (asMap(p) case final preset? when asString(preset['id']) != null)
          AgentPresetInfo(
            id: asString(preset['id'])!,
            isDefault: preset['isDefault'] == true,
            name: asString(preset['name']),
            description: asString(preset['description']),
            broken: asString(preset['broken']),
            order: asInt(preset['order']),
          ),
    ];
    return presets;
  }

  /// `agentPresets/read`.
  Future<AgentPresetDocument> readAgentPreset(String id) async {
    final value = asMapOrEmpty(await rpc.call('agentPresets/read', {'agentPreset': id}));
    return AgentPresetDocument(
      id: asString(value['agentPreset']) ?? id,
      content: asString(value['content']) ?? '',
      name: asString(value['name']),
      description: asString(value['description']),
    );
  }

  /// Makes [id] the default for new sessions, as the official settings page
  /// does (`settings/update agent-preset-registry {selectedDefault}`).
  Future<void> setDefaultAgentPreset(String id) async {
    final section = await settingsSection('agent-preset-registry');
    await rpc.call('settings/update', {
      'ns': 'agent-preset-registry',
      'patch': {'selectedDefault': id},
      'expectedRevision': ?section?.revision,
    });
  }

  // ── settings ─────────────────────────────────────────────────────────────

  /// One namespace of `settings/describe`; null when the Host doesn't have it
  /// (its plugin is off).
  Future<SettingsSection?> settingsSection(String ns) async {
    final value = asMapOrEmpty(await rpc.call('settings/describe'));
    final writable = value['writable'] != false;
    for (final n in asListOrEmpty(value['namespaces'])) {
      final map = asMap(n);
      if (map == null || map['ns'] != ns) continue;
      return SettingsSection.fromView(ns, map, writable: writable);
    }
    return null;
  }

  /// `settings/mutate` with one `set` at [path]; returns the new section.
  Future<SettingsSection> setSetting(String ns, List<String> path, Object? value, {int? expectedRevision}) =>
      mutateSettings(ns, [SettingsOp.set(path, value)], expectedRevision: expectedRevision);

  /// `settings/mutate`: [ops] apply together or not at all. The Host validates
  /// the whole section against its schema and refuses a write a home patch or
  /// command-line overlay would override; a stale [expectedRevision] fails with
  /// `settings/conflict`. Returns the new section.
  Future<SettingsSection> mutateSettings(String ns, List<SettingsOp> ops, {int? expectedRevision}) async {
    final result = await rpc.call('settings/mutate', {
      'ns': ns,
      'ops': [for (final op in ops) op.toJson()],
      'expectedRevision': ?expectedRevision,
    });
    return SettingsSection.fromView(ns, result);
  }

  // ── plumbing ─────────────────────────────────────────────────────────────

  /// Items of one logical stream; cancelling the subscription cancels it.
  Stream<Object?> _items(String endpoint, Map<String, Object?> args) {
    late final StreamController<Object?> out;
    StreamSubscription<Object?>? sub;
    var cancelled = false;
    out = StreamController<Object?>(
      onListen: () async {
        try {
          await mux.ready();
          if (cancelled || out.isClosed) return;
          final stream = mux.open(endpoint, args);
          sub = stream.items.listen(out.add, onError: out.addError, onDone: out.close);
        } on Object catch (error) {
          if (!cancelled && !out.isClosed) out.addError(error);
          await out.close();
          return;
        }
      },
      onCancel: () async {
        cancelled = true;
        await sub?.cancel();
      },
    );
    return out.stream;
  }
}
