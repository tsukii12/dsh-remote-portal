import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:dsh_client/dsh_client.dart';

const seed = 20261101;
int sink = 0;
List<Map<String, Object?>> generateWire() {
  final rng = Random(seed);
  final rows = <Map<String, Object?>>[];
  void add(String type, Map<String, Object?> data) {
    rows.add({'seq': rows.length, 'time': 1793491200000 + rows.length * 7, 'type': type, 'data': data});
  }

  for (var turn = 1; turn <= 100; turn++) {
    add('turn/start', {'turn': turn});
    add('user/message', {
      'id': 'u$turn',
      'role': 'user',
      'source': {'kind': 'user', 'rpcId': 'r$turn'},
      'content': [
        {'type': 'text', 'text': 'Synthetic question $turn value ${rng.nextInt(100000)}'},
      ],
    });
    for (var step = 1; step <= 3; step++) {
      final count = step == 3 ? 4 : 7;
      add('step/start', {'turn': turn, 'step': step});
      final calls = [
        for (var i = 0; i < count; i++)
          {
            'type': 'tool-call',
            'id': 'c$turn.$step.$i',
            'name': 'fixture_tool_$i',
            'arguments': jsonEncode({'query': rng.nextInt(100000)}),
          },
      ];
      add('assistant/message', {
        'turn': turn,
        'step': step,
        'message': {
          'id': 'a$turn.$step',
          'role': 'assistant',
          'source': {'kind': 'model', 'model': 'fixture-model'},
          'content': [
            {'type': 'reasoning', 'text': 'reasoning $turn/$step'},
            {'type': 'text', 'text': 'Working $turn/$step'},
            ...calls,
          ],
        },
        'usage': {'inputTokens': 100, 'outputTokens': 20},
      });
      for (final c in calls) {
        add('tool/call', {
          'turn': turn,
          'step': step,
          'callId': c['id'],
          'name': c['name'],
          'arguments': c['arguments'],
        });
      }
      for (var i = 0; i < calls.length; i++) {
        final c = calls[i];
        if (turn % 5 == 0 && step == 1 && i == 0) {
          add('tool/progress', {'turn': turn, 'step': step, 'callId': c['id'], 'status': 'pending'});
          continue;
        }
        add('tool/result', {
          'turn': turn,
          'step': step,
          'message': {
            'id': 'result-${c['id']}',
            'role': 'tool',
            'toolCallId': c['id'],
            'isError': rng.nextInt(10) == 0,
            'source': {'kind': 'tool'},
            'content': [
              {'type': 'text', 'text': 'result ${rng.nextInt(1000000)}'},
            ],
          },
        });
      }
      if (step == 3) {
        add('todo/write', {
          'todos': [
            {'content': 'fixture task $turn', 'status': turn % 2 == 0 ? 'completed' : 'in_progress'},
          ],
        });
      } else {
        add('step/end', {'turn': turn, 'step': step});
      }
    }
    add('step/start', {'turn': turn, 'step': 4});
    add('assistant/message', {
      'turn': turn,
      'step': 4,
      'message': {
        'id': 'a$turn.4',
        'role': 'assistant',
        'source': {'kind': 'model', 'model': 'fixture-model'},
        'content': [
          {'type': 'text', 'text': 'Final answer $turn'},
        ],
      },
    });
    add('turn/end', {
      'turn': turn,
      'reason': {'kind': turn % 5 == 0 ? 'aborted' : 'completed'},
    });
  }
  if (rows.length != 5000) throw StateError('expected 5000, got ${rows.length}');
  return rows;
}

int readItems(ChatTranscript t) {
  final a = t.items;
  return a.length + (a.isEmpty ? 0 : a.last.key.length);
}

int readAll(ChatTranscript t) =>
    readItems(t) + t.turns.length + (t.todos?.length ?? 0) + (t.goal == null ? 0 : 1) + (t.running ? 1 : 0);
({int micros, int checksum}) run(List<SessionLogEvent> events, String mode) {
  final t = ChatTranscript();
  var sum = 0;
  if (mode.startsWith('cold_')) {
    for (final e in events) {
      t.apply(e);
    }
    final clock = Stopwatch()..start();
    sum = mode == 'cold_items' ? readItems(t) : readAll(t);
    clock.stop();
    sink ^= sum;
    return (micros: clock.elapsedMicroseconds, checksum: sum);
  }
  final clock = Stopwatch()..start();
  for (final e in events) {
    t.apply(e);
    sum += mode == 'append_items'
        ? readItems(t)
        : mode == 'append_all'
        ? readAll(t)
        : 0;
  }
  clock.stop();
  sink ^= sum;
  return (micros: clock.elapsedMicroseconds, checksum: sum);
}

void main(List<String> args) {
  final warmups = args.isEmpty ? 2 : int.parse(args[0]);
  final repeats = args.length < 2 ? 5 : int.parse(args[1]);
  final raw = generateWire();
  final events = raw.map(SessionLogEvent.fromJson).toList(growable: false);
  final distribution = <String, int>{};
  for (final e in events) {
    distribution.update(e.type, (v) => v + 1, ifAbsent: () => 1);
  }
  final summaries = <String, Object?>{};
  for (final mode in ['append_only', 'append_items', 'append_all', 'cold_items', 'cold_all']) {
    for (var i = 0; i < warmups; i++) {
      run(events, mode);
    }
    final samples = <int>[];
    final sums = <int>{};
    for (var i = 0; i < repeats; i++) {
      final r = run(events, mode);
      samples.add(r.micros);
      sums.add(r.checksum);
    }
    if (sums.length != 1) throw StateError('unstable output checksum $mode');
    final sorted = [...samples]..sort();
    final median = sorted[sorted.length ~/ 2];
    summaries[mode] = {'samples_us': samples, 'median_us': median, 'median_ms': median / 1000, 'checksum': sums.single};
    stdout.writeln(jsonEncode({'mode': mode, ...summaries[mode] as Map<String, Object?>}));
  }
  final t = ChatTranscript();
  for (final e in events) {
    t.apply(e);
  }
  final statuses = <String, int>{};
  for (final item in t.items.whereType<ToolChatItem>()) {
    statuses.update(item.status.name, (v) => v + 1, ifAbsent: () => 1);
  }
  stdout.writeln(
    jsonEncode({
      'benchmark': 'ChatTranscript5000',
      'version': 1,
      'seed': seed,
      'events': events.length,
      'turns': t.turns.length,
      'tools': t.items.whereType<ToolChatItem>().length,
      'final_items': t.items.length,
      'tool_statuses': statuses,
      'event_distribution': distribution,
      'warmups_per_mode': warmups,
      'repeats_per_mode': repeats,
      'units': 'microseconds',
      'dart': Platform.version,
      'sink': sink,
      'results': summaries,
    }),
  );
  if (args.length > 2) File(args[2]).writeAsStringSync('${raw.map(jsonEncode).join('\n')}\n');
}
