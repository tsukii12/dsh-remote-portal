/// 后台记录 (docs/design/roleplay-ui.md §8–§9): the engine's audit of a chat,
/// [TavernAgentRun] by kind. A kind is a string the engine may add to; one we
/// do not know keeps its own name and its raw record.
library;

import 'package:dsh_tavern/dsh_tavern.dart';

import 'tavern_state_hints.dart';

/// Who or what a run was, for its label and icon.
enum TavernRunFamily { user, model, rules, stopped, director, directorFailed, event, story, secret, other }

TavernRunFamily tavernRunFamily(String kind) => switch (kind) {
  'state.user' => TavernRunFamily.user,
  'state.tool' || 'state.tool_batch' => TavernRunFamily.model,
  'state.rules' => TavernRunFamily.rules,
  'state.terminal' => TavernRunFamily.stopped,
  'director.success' || 'director.tick' => TavernRunFamily.director,
  'director.failure' || 'director.secret_failure' => TavernRunFamily.directorFailed,
  'director.event' || 'director.event_apply' => TavernRunFamily.event,
  'story.rules' => TavernRunFamily.story,
  'director.secret_proposal' || 'director.secret_bind' => TavernRunFamily.secret,
  _ => TavernRunFamily.other,
};

/// The run went in: false only when the record says it was not kept.
bool tavernRunKept(TavernAgentRun run) => run.result['committed'] != false;

/// A JSON Pointer as a reader says it: `/stat_data/体力` → `stat_data › 体力`.
String tavernRunPath(String pointer) => pointer.isEmpty
    ? '/'
    : pointer.substring(1).split('/').map((step) => step.replaceAll('~1', '/').replaceAll('~0', '~')).join(' › ');

/// What a run changed, as 「where → what」 lines: your edit's own path and
/// value; otherwise the record's net changes (a removal as 「where → —」).
List<String> tavernRunChanges(TavernAgentRun run) {
  final result = run.result;
  if (result['path'] case final String path when run.kind == 'state.user') {
    return ['${tavernRunPath(path)} → ${tavernStateText(result['value'])}'];
  }
  return [
    if (result['changes'] case final List<Object?> changes)
      for (final change in changes)
        if (change case {'path': final String path})
          '${tavernRunPath(path)} → ${change['newExists'] == false ? '—' : tavernStateText(change['new'])}',
  ];
}

/// The first thing the record says went wrong, if it says one.
String? tavernRunIssue(TavernAgentRun run) {
  if (run.result['issues'] case final List<Object?> issues) {
    for (final issue in issues) {
      if (issue case {'message': final String message} when message.isNotEmpty) return message;
      if (issue case {'code': final String code} when code.isNotEmpty) return code;
    }
  }
  return null;
}
