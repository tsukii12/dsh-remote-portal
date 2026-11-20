// A synthetic two-turn session with realistic timing, in DSH 0.2 follow-frame
// shape (test/chat/fixtures/follow_run_info.jsonl): step markers, timed
// assistant streams (time to first token), a 48 s approval wait, todo writes,
// usage per request; turn 1 finished (seq 4–39), turn 2 still running a
// `flutter test` (dispatched at seq 60).

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_client/dsh_client.dart';

const runInfoFixture = 'test/chat/fixtures/follow_run_info.jsonl';

/// Last seq of the finished first turn.
const runInfoTurnOneEnd = 39;

/// Host epoch of the fixture (turn 1 starts here).
final runInfoT0 = DateTime.fromMillisecondsSinceEpoch(1792720800000);

/// Turn 2 starts 140 s later; its `flutter test` is dispatched 7.65 s in.
final runInfoTurnTwoStart = runInfoT0.add(const Duration(seconds: 140));
final runInfoTestDispatched = runInfoTurnTwoStart.add(const Duration(milliseconds: 7650));

ChatTranscript runInfoTranscript({int? throughSeq}) {
  final transcript = ChatTranscript();
  for (final line in File(runInfoFixture).readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final event = parseFollowFrame('s1', jsonDecode(line));
    if (throughSeq != null && event is SessionLogEvent) {
      if (event.seq > throughSeq) continue;
    }
    transcript.apply(event);
  }
  return transcript;
}

/// The chat state the controller would publish for the fixture.
ChatState runInfoState({bool finished = false}) {
  final t = runInfoTranscript(throughSeq: finished ? runInfoTurnOneEnd : null);
  return ChatState(
    items: t.items,
    running: t.running,
    title: t.title,
    loading: false,
    turns: t.turns,
    todos: t.todos,
    model: const ModelSelection(provider: 'deepseek-official', model: 'deepseek-flash', reasoningEffort: 'high'),
  );
}
