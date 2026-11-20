// The automation tasks of the conversation on screen, for the chat header's
// clock. Like the official session header (`dsh-client-ui-schedule`), it
// reads the conversation's own `schedule/list` rather than the Host-wide
// catalog, and reads again on `schedule/changed` and on every new ready
// generation (the official source follows `connection/reset`).

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';
import 'sessions_state.dart';

/// The wall clock the schedule surfaces read (tests pin it).
final scheduleClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// [tasks] by next run, soonest first; overdue ones therefore lead (the
/// official `orderScheduleRecords`). Ties keep the Host's order.
List<ScheduleTask> soonestFirst(Iterable<ScheduleTask> tasks) {
  final indexed = tasks.indexed.toList();
  indexed.sort((a, b) {
    final at = a.$2.scheduledAt;
    final bt = b.$2.scheduledAt;
    final byTime = switch ((at, bt)) {
      (null, null) => 0,
      (null, _) => 1,
      (_, null) => -1,
      (final x?, final y?) => x.compareTo(y),
    };
    return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
  });
  return [for (final (_, task) in indexed) task];
}

/// [sessionId]'s active automation tasks, soonest first.
///
/// Null while there is no connection, and until the Host is ready: its ready
/// event runs this again, so a reconnect also refreshes it. A failed read is
/// not retried behind the user's back; it surfaces as an error that still
/// carries the last tasks, and the next `schedule/changed` or reconnect reads
/// again.
final sessionSchedulesProvider = FutureProvider.autoDispose.family<List<ScheduleTask>?, String>((ref, sessionId) async {
  final client = ref.watch(activeConnectionProvider).value?.client;
  if (client == null) return null;
  final events = client.hostEvents.listen((event) {
    if (event is HostReadyEvent || (event is UnknownHostEvent && event.event == 'schedule/changed')) {
      ref.invalidateSelf();
    }
  });
  ref.onDispose(() => unawaited(events.cancel()));
  if (client.mux.state != DshConnectionState.connected) return null;
  return soonestFirst(await client.sessionSchedules(sessionId));
}, retry: (_, _) => null);

/// What the header's clock shows for the conversation on screen.
@immutable
class HeaderSchedules {
  const HeaderSchedules({this.sessionId, this.tasks = const [], this.failed = false});

  /// The conversation on screen; null on a new chat.
  final String? sessionId;

  /// Its active tasks, soonest first; while a refresh fails, the last ones
  /// read.
  final List<ScheduleTask> tasks;

  /// The latest read failed.
  final bool failed;

  /// Whether the header shows the clock: only once tasks are known, so it
  /// never appears and vanishes around the first read.
  bool get shown => sessionId != null && tasks.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is HeaderSchedules &&
      other.sessionId == sessionId &&
      other.failed == failed &&
      listEquals(other.tasks, tasks);

  @override
  int get hashCode => Object.hash(sessionId, failed, Object.hashAll(tasks));
}

/// [HeaderSchedules] of the current conversation.
final headerSchedulesProvider = Provider.autoDispose<HeaderSchedules>((ref) {
  final sessionId = ref.watch(currentSessionProvider);
  if (sessionId == null) return const HeaderSchedules();
  final read = ref.watch(sessionSchedulesProvider(sessionId));
  return HeaderSchedules(sessionId: sessionId, tasks: read.value ?? const [], failed: read.hasError);
});
