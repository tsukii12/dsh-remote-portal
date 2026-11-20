/// Conversation reminders on legacy and target-based Hosts. Catalog is read-only
/// and remains available on both versions; 0.2.2 list is a Host-wide paged API.
library;

import 'features_api.dart';
import 'session_api.dart';

extension SessionSchedulesApi on DshClient {
  Future<List<ScheduleTask>> sessionSchedules(String sessionId) async => [
    for (final task in await scheduleCatalog())
      if (task.active &&
          (task.usesTargetProtocol ? task.involvedSessionIds.contains(sessionId) : task.sessionId == sessionId))
        task,
  ];
}
