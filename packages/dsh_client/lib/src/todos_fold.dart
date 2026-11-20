/// The `todos` projection (`@deepseek-ai/dsh-tool-todo`) over a follow
/// window.
library;

import 'models.dart';

/// The session's current todo list, folded the way the Host folds its
/// `todos` projection: each `todo/write` replaces the list, the next
/// `turn/start` clears it, `turn/end` keeps the list just finished.
///
/// Starts from the snapshot's `todos` value (as of
/// [SessionProjections.asOfSeq]) and applies only the events after it; when
/// the snapshot carries no `todos` key (an older Host) the whole loaded log is
/// folded. Null when there is no current list.
List<TodoItem>? foldTodos(SessionProjections projections, Iterable<SessionLogEvent> events) {
  final seeded = projections.has('todos');
  var current = seeded ? projections.todos : null;
  final after = seeded ? projections.asOfSeq : -1;
  for (final event in events) {
    if (event.seq <= after) continue;
    switch (event) {
      case TodoWriteEvent(:final todos):
        current = todos;
      case TurnStartedEvent():
        current = null;
      default:
        break;
    }
  }
  return current;
}
