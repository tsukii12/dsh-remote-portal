import 'dart:convert';
import 'dart:io';
import 'package:dsh_client/dsh_client.dart';

// Public DTOs and ChatTranscript only. Measures this CPU slice, not UI frames,
// network latency, model speed, or Android performance. Fixture creation and
// initial folding are outside the measured interval.
SessionLogEvent event(int seq, String type, Map<String, Object?> data) =>
    SessionLogEvent.fromJson({'seq': seq, 'time': 1700000000000 + seq, 'type': type, 'data': data});

List<SessionLogEvent> history(int turns) {
  final out = <SessionLogEvent>[];
  var seq = 0;
  void add(String type, Map<String, Object?> data) => out.add(event(seq++, type, data));
  for (var turn = 1; turn <= turns; turn++) {
    add('user/message', {
      'id': 'u$turn',
      'role': 'user',
      'source': {'kind': 'user'},
      'content': [
        {'type': 'text', 'text': 'request $turn'},
      ],
    });
    add('turn/start', {'turn': turn});
    add('step/start', {'turn': turn, 'step': 1});
    add('assistant/message', {
      'turn': turn,
      'step': 1,
      'message': {
        'id': 'a$turn',
        'role': 'assistant',
        'source': {'kind': 'model', 'model': 'fixture'},
        'content': [
          {'type': 'text', 'text': 'response $turn'},
        ],
      },
    });
    add('step/end', {'turn': turn, 'step': 1});
    add('turn/end', {
      'turn': turn,
      'reason': {'kind': 'completed'},
    });
  }
  return out;
}

List<SessionLogEvent> steps(int start, int turn) {
  final out = <SessionLogEvent>[];
  var seq = start;
  void add(String type, Map<String, Object?> data) => out.add(event(seq++, type, data));
  for (var step = 1; step <= 20; step++) {
    final id = 'call-$turn-$step';
    add('step/start', {'turn': turn, 'step': step});
    add('assistant/message', {
      'turn': turn,
      'step': step,
      'message': {
        'id': 'a$turn-$step',
        'role': 'assistant',
        'source': {'kind': 'model', 'model': 'fixture'},
        'content': [
          {'type': 'tool-call', 'id': id, 'name': 'read_file', 'arguments': '{"path":"own.txt"}'},
        ],
      },
    });
    add('tool/call', {
      'turn': turn,
      'step': step,
      'callId': id,
      'name': 'read_file',
      'arguments': '{"path":"own.txt"}',
    });
    add('tool/result', {
      'turn': turn,
      'step': step,
      'message': {
        'id': 'r$id',
        'role': 'tool',
        'toolCallId': id,
        'content': [
          {'type': 'text', 'text': 'own content $step'},
        ],
      },
    });
    add('step/end', {'turn': turn, 'step': step});
  }
  return out;
}

int read(ChatTranscript transcript, bool publishGetters) {
  return transcript.turns.length;
}

void main(List<String> args) {
  final label = args.isEmpty ? 'unspecified' : args.single;
  final result = <Map<String, Object?>>[];
  var checksum = 0;
  for (final config in [(1, false), (100, false), (1000, false), (1000, true)]) {
    final (turns, interrupted) = config;
    final past = history(turns).where((e) => !interrupted || e.type != 'turn/end').toList();
    final nextSeq = turns * 6;
    final next = steps(nextSeq + 1, turns + 1);
    for (final publish in [false]) {
      for (final batch in [1, 5]) {
        final samples = <int>[];
        for (var iteration = -3; iteration < 10; iteration++) {
          final transcript = ChatTranscript();
          transcript.apply(
            SessionSnapshotEvent(
              sessionId: 'own',
              header: SessionHeader.fromJson({'id': 'own', 'version': 4, 'createdAt': 1700000000000}),
              cursor: past.length - 1,
              events: past,
              hasMore: false,
              projections: SessionProjections(past.length - 1, {
                'todos': null,
                'goal': {
                  'goal': {
                    'id': 'own-goal',
                    'revision': 1,
                    'objective': 'fixture',
                    'phase': 'active',
                    'maxGoalRounds': 10,
                  },
                  'roundsStarted': 1,
                  'createdAt': 1700000000000,
                  'updatedAt': 1700000000000,
                },
              }),
              assistantRevision: 0,
            ),
          );
          transcript.apply(event(nextSeq, 'turn/start', {'turn': turns + 1}));
          checksum += read(transcript, publish);
          final timer = Stopwatch()..start();
          for (var i = 0; i < next.length; i++) {
            transcript.apply(next[i]);
            if ((i + 1) % batch == 0) checksum += read(transcript, publish);
          }
          timer.stop();
          if (iteration >= 0) samples.add(timer.elapsedMicroseconds);
          if (transcript.todos != null ||
              transcript.goal?.roundsStarted != 1 ||
              transcript.newestSeq != next.last.seq) {
            throw StateError('incorrect public result');
          }
        }
        final sorted = [...samples]..sort();
        final row = <String, Object?>{
          'interruptedHistory': interrupted,
          'historicalTurns': turns,
          'historicalEvents': past.length,
          'appendedEvents': next.length,
          'readMode': 'turns-only',
          'eventsPerRead': batch,
          'samplesUs': samples,
          'medianUs': (sorted[4] + sorted[5]) / 2,
          'minUs': sorted.first,
          'maxUs': sorted.last,
        };
        result.add(row);
        stderr.writeln(jsonEncode(row));
      }
    }
  }
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'label': label,
      'warmupPerCase': 3,
      'samplesPerCase': 10,
      'scope': '100 appends plus selected public getters; excludes setup, HTTP, Flutter publish/widgets, ARM',
      'rows': result,
      'checksum': checksum,
    }),
  );
}
