// State behind the native automation-task editor: the phone's time zone, the
// Host's workspaces, a new conversation to receive a task, the creation
// request (the Host has no create Remote — like the official 「新建」, the
// task is made by the model's `schedule_create` in its conversation) and
// 「立即运行」.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../runtime/runtime_state.dart';
import 'time_zones.dart';
import 'connection_state.dart';
import 'sessions_state.dart';
import 'settings_state.dart';

/// The phone's IANA time zone (the default for new rules).
final deviceTimeZoneProvider = FutureProvider<String>((ref) => detectDeviceTimeZone());

/// Workspaces of the active host (`workspace/follow` baseline); empty when
/// the Host has none or doesn't answer in time.
final hostWorkspacesProvider = FutureProvider.autoDispose<List<Workspace>>((ref) async {
  final client = ref.watch(activeConnectionProvider).value?.client;
  if (client == null) return const [];
  // A one-shot read still owns its subscription after timeout or editor disposal.
  final first = StreamIterator(client.watchWorkspaces().where((u) => u is WorkspaceBaseline));
  ref.onDispose(() => unawaited(first.cancel()));
  try {
    if (!await first.moveNext().timeout(const Duration(seconds: 6))) return const [];
    return (first.current as WorkspaceBaseline).workspaces;
  } on Object {
    return const [];
  } finally {
    await first.cancel();
  }
});

/// Where a new task's conversation is created and with which model.
class ConversationPlan {
  const ConversationPlan({this.workspaceId, this.model});

  /// Null: the app's default folder for new conversations.
  final String? workspaceId;

  /// Null: the Host default.
  final ModelSelection? model;
}

/// Opens a new conversation like the new-chat button does (same folder and
/// permission rule), in [plan]'s workspace, with its model.
Future<String> startConversation(WidgetRef ref, ConversationPlan plan) async {
  final conn = ref.read(activeConnectionProvider).value;
  if (conn == null) throw const DshClosedException('not connected');
  final String id;
  if (plan.workspaceId == null) {
    id = await ref.read(sessionsProvider.notifier).create();
  } else {
    id = (await conn.client.createSession(workspaceId: plan.workspaceId)).sessionId;
    final safeMode = ref.read(localRuntimeProvider).status.inSafeMode;
    if (conn.isLocal && !safeMode && ref.read(settingsProvider).autoApproveCommands) {
      try {
        await conn.client.setPermissionPreset(id, 'danger-full-access');
      } on Object {
        // Keep the default preset if the command is unavailable.
      }
    }
    unawaited(ref.read(sessionsProvider.notifier).refresh());
  }
  if (plan.model case final model?) {
    await conn.client.setModel(
      id,
      provider: model.provider,
      model: model.model,
      reasoningEffort: model.reasoningEffort,
    );
  }
  return id;
}

/// The message that asks the conversation's model to create the task: one
/// `schedule_create` call with exactly these arguments.
String scheduleCreateRequest({
  required String title,
  required String prompt,
  required ScheduleTiming timing,
  required String rule,
}) {
  final args = const JsonEncoder.withIndent('  ')
      .convert(scheduleCreateArguments(title: title, prompt: prompt, timing: timing));
  return appL10n.stateScheduleCreatePrompt(title, rule, args);
}

/// Why a creation request didn't produce a task (short, shown as is).
class ScheduleCreateFailure implements Exception {
  const ScheduleCreateFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Sends [request] into [sessionId] and waits until the Host catalog holds
/// a new task of that conversation (preferring one titled [title]). Fails
/// when the turn ends or errors without one, or after [timeout].
Future<ScheduleTask> requestSchedule(
  DshClient client, {
  required String sessionId,
  required String title,
  required String request,
  String? timeZone,
  Duration timeout = const Duration(minutes: 2),
  Duration poll = const Duration(seconds: 4),
  Duration settle = const Duration(seconds: 2),
}) async {
  final known = {for (final t in await client.scheduleCatalog()) t.id};
  final done = Completer<ScheduleTask>();
  // Host events can fail before prompt's RPC returns. Observe that interval;
  // the await below still returns the task or throws the same failure.
  done.future.ignore();
  var running = false;
  Timer? idle;

  void fail(String message) {
    if (!done.isCompleted) done.completeError(ScheduleCreateFailure(message));
  }

  Future<void> check() async {
    if (done.isCompleted) return;
    try {
      final fresh = [
        for (final t in await client.scheduleCatalog())
          if (t.sessionId == sessionId && !known.contains(t.id)) t,
      ];
      final match = fresh.where((t) => t.title == title).firstOrNull ?? fresh.firstOrNull;
      if (match != null && !done.isCompleted) done.complete(match);
    } on Object {
      // A failed read is retried by the next event or poll.
    }
  }

  final events = client.hostEvents.listen((event) {
    switch (event) {
      case UnknownHostEvent(event: 'schedule/changed'):
        unawaited(check());
      case SessionStatusEvent(sessionId: final id, running: true) when id == sessionId:
        running = true;
        idle?.cancel();
      case SessionStatusEvent(sessionId: final id, running: false) when id == sessionId && running:
        idle?.cancel();
        idle = Timer(settle, () async {
          await check();
          fail(appL10n.stateScheduleNotCreated);
        });
      case SessionErrorEvent(sessionId: final id) when id == sessionId:
        fail(appL10n.stateScheduleChatFailed);
      default:
        break;
    }
  });
  final timer = Timer.periodic(poll, (_) => unawaited(check()));
  try {
    await client.prompt(sessionId, request, timeZone: timeZone);
    return await done.future.timeout(
      timeout,
      onTimeout: () => throw ScheduleCreateFailure(appL10n.stateScheduleResultPending),
    );
  } finally {
    timer.cancel();
    idle?.cancel();
    unawaited(events.cancel());
  }
}

/// 「立即运行」: uses the Host target-aware run API on 0.2.2; legacy Hosts
/// retain the queued conversation prompt behavior.
Future<void> runScheduleNow(DshClient client, ScheduleTask task, {String? timeZone}) =>
    client.runScheduledTask(task, timeZone: timeZone);
