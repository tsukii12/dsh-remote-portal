import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:mirrors';
import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';
import 'support/transcript_full_build_oracle.dart' as oracle;

// Test-only reflection compares public data/getters in two independent libraries.
// It performs no event folding and cannot substitute for either implementation.
Object? norm(dynamic v) {
  if (v == null || v is String || v is num || v is bool) return v;
  if (v is Enum) return v.name;
  if (v is DateTime) return v.microsecondsSinceEpoch;
  if (v is Duration) return v.inMicroseconds;
  if (v is Map) return {for (final e in v.entries) e.key.toString(): norm(e.value)};
  if (v is Iterable) return v.map(norm).toList();
  final m = reflect(v);
  final out = <String, Object?>{'class': MirrorSystem.getName(m.type.simpleName)};
  for (ClassMirror? t = m.type; t != null && t.reflectedType != Object; t = t.superclass) {
    for (final d in t.declarations.values) {
      if (d.isPrivate) continue;
      if (d is VariableMirror && !d.isStatic || d is MethodMirror && d.isGetter && !d.isStatic) {
        out[MirrorSystem.getName(d.simpleName)] = norm(m.getField(d.simpleName).reflectee);
      }
    }
  }
  return out;
}

Object? observe(dynamic t) => norm({
  'items': t.items,
  'running': t.running,
  'turns': t.turns,
  'todos': t.todos,
  'goal': t.goal,
  'title': t.title,
  'cursor': t.cursor,
  'oldest': t.oldestSeq,
  'newest': t.newestSeq,
  'hasMore': t.hasMoreHistory,
  'approvals': t.pendingApprovals,
  'questions': t.pendingQuestions,
  'inbox': t.inbox,
  'header': t.header,
  'connection': t.connectionState,
});

class Diff {
  Diff({bool synthetic = false})
    : a = ChatTranscript(showSyntheticUserMessages: synthetic),
      b = oracle.ChatTranscript(showSyntheticUserMessages: synthetic);
  final ChatTranscript a;
  final oracle.ChatTranscript b;
  var prefix = 0;
  void check() {
    expect(observe(a), observe(b), reason: 'prefix $prefix');
    expect(observe(a), observe(b), reason: 'cached prefix $prefix');
  }

  void apply(DshEvent Function() make) {
    expect(a.apply(make()), b.apply(make()));
    prefix++;
    check();
  }

  void wire(Map<String, Object?> frame, {bool resync = false}) =>
      apply(() => parseFollowFrame('s', jsonDecode(jsonEncode(frame)), isResync: resync));
  void history(List<Map<String, Object?>> events, bool hasMore) {
    HistoryPage page() =>
        HistoryPage(events.map((e) => SessionLogEvent.fromJson(jsonDecode(jsonEncode(e)))).toList(), hasMore);
    a.prependHistory(page());
    b.prependHistory(page());
    prefix++;
    check();
  }
}

Map<String, Object?> ev(int n, String type, Map<String, Object?> data) => {
  'type': 'event',
  'event': {'seq': n, 'time': 1000 + n, 'type': type, 'data': data},
};
Map<String, Object?> call(int n, String id) =>
    ev(n, 'tool/call', {'turn': n ~/ 10, 'step': 1, 'callId': id, 'name': 'name-$id', 'arguments': '{"n":$n}'});
Map<String, Object?> result(int n, String id, {bool error = false}) => ev(n, 'tool/result', {
  'turn': 2,
  'step': 1,
  'message': {
    'id': 'r$n',
    'role': 'tool',
    'toolCallId': id,
    'isError': error,
    'content': [
      {'type': 'text', 'text': 'r$n'},
    ],
  },
  'meta': {'n': n},
});
Map<String, Object?> end(int n, {String kind = 'completed'}) => ev(n, 'turn/end', {
  'turn': n ~/ 10,
  'reason': {'kind': kind},
});
Map<String, Object?> user(int n) => ev(n, 'user/message', {
  'id': 'u$n',
  'role': 'user',
  'source': {'kind': 'user', 'rpcId': 'req$n'},
  'content': [
    {'type': 'text', 'text': 'hello$n'},
    {
      'type': 'image',
      'attachment': {'attachmentId': 'i$n', 'mediaType': 'image/png'},
    },
    {
      'type': 'file',
      'attachment': {'attachmentId': 'f$n', 'name': 'file'},
    },
  ],
});
Map<String, Object?> assistant(int n, int step, {String? tool, String? phase}) => ev(n, 'assistant/message', {
  'turn': 1,
  'step': step,
  'message': {
    'id': 'a$n',
    'role': 'assistant',
    'source': {
      'kind': 'model',
      'model': 'one',
      if (phase != null)
        'replayState': {
          'response': {
            'kind': 'pi-ai',
            'version': 2,
            'api': 'openai-codex-responses',
            'provider': 'openai-codex',
            'model': 'one',
            'stopReason': 'stop',
          },
          'blocks': [
            {
              'type': 'text',
              'textSignature': jsonEncode({'v': 1, 'id': 'msg-$n', 'phase': phase}),
            },
            if (tool != null) {'type': 'tool-call'},
          ],
        },
    },
    'content': [
      {'type': 'text', 'text': 'answer$n'},
      if (tool != null) {'type': 'tool-call', 'id': tool, 'name': 'first-$tool', 'arguments': '{}'},
    ],
  },
  'usage': {'inputTokens': n, 'outputTokens': 3},
});
Map<String, Object?> snapshot(List<Map<String, Object?>> frames, {int cursor = 100}) => {
  'type': 'snapshot',
  'header': {'id': 's', 'version': 4, 'createdAt': 1000},
  'cursor': cursor,
  'records': frames,
  'hasMore': true,
  'projections': {'asOfSeq': cursor, 'values': {}},
  'assistantStream': {'revision': 0},
};

void main() {
  final fixtures =
      Directory('test/fixtures').listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in fixtures) {
    final name = file.uri.pathSegments.last;
    test('oracle fixture prefixes: $name', () {
      final p = Diff();
      final endpoints = <String, String>{};
      var count = 0;
      var snapshots = 0;
      void follow(Map<String, Object?> frame) {
        final resync = frame['type'] == 'snapshot' && snapshots++ > 0;
        p.wire(frame, resync: resync);
      }

      for (final line in file.readAsLinesSync().where((s) => s.trim().isNotEmpty)) {
        final raw = jsonDecode(line) as Map<String, dynamic>;
        count++;
        if (name == 'workspace_follow.jsonl') {
          expect(WorkspaceUpdate.fromJson(raw), isA<WorkspaceUpdate>());
          continue;
        }
        // Session-control projections are not DshEvents and never enter ChatTranscript.
        if (name == 'control_reply_ok.jsonl') {
          expect(raw['type'], anyOf('baseline', 'projection'));
          continue;
        }
        if (name == 'mux_raw_approval.jsonl') {
          final f = raw['frame'] as Map<String, dynamic>;
          if (raw['dir'] == 'out') {
            if (f['type'] == 'open') endpoints[f['streamId'] as String] = f['endpoint'] as String;
            continue;
          }
          expect(f['type'], 'item');
          switch (endpoints[f['streamId']]) {
            case r'$events':
              p.apply(() => HostEvent.fromFrame(jsonDecode(jsonEncode(f['value']))));
            case 'session/follow':
              follow(Map<String, Object?>.from(f['value'] as Map));
            default:
              fail('unclassified mux endpoint');
          }
        } else if (name.startsWith('events_')) {
          p.apply(() => HostEvent.fromFrame(jsonDecode(jsonEncode(raw))));
        } else {
          expect(name.startsWith('follow_'), isTrue, reason: 'unclassified $name');
          follow(raw);
        }
      }
      expect(count, greaterThan(0));
      p.check();
    });
  }
  for (final seed in [7, 42, 20261101]) {
    test('oracle random prefixes seed=$seed', () {
      final r = Random(seed);
      final p = Diff(synthetic: seed.isOdd);
      final history = <Map<String, Object?>>[];
      final approvalIds = <String>{};
      for (var i = 0; i < 320; i++) {
        final n = r.nextInt(5) == 0 && i > 0 ? r.nextInt(i) : i;
        final id = 'c${r.nextInt(12)}';
        final frame = switch (r.nextInt(12)) {
          0 => user(n),
          1 => assistant(n, r.nextInt(6), tool: id),
          2 => call(n, id),
          3 => result(n, id, error: r.nextBool()),
          4 => end(n, kind: ['completed', 'aborted', 'blocked'][r.nextInt(3)]),
          5 => ev(n, 'turn/start', {'turn': r.nextInt(5)}),
          6 => ev(n, 'approval/asked', {'id': 'p${r.nextInt(8)}', 'callId': id, 'toolName': 'tool'}),
          7 => ev(n, 'approval/decided', {
            'id': 'p${r.nextInt(8)}',
            'outcome': ['allowed-once', 'rejected'][r.nextInt(2)],
          }),
          8 => ev(n, 'todo/write', {
            'todos': [
              {'content': 'task$n', 'status': 'pending'},
            ],
          }),
          9 => ev(n, 'llm/retry', {'turn': 1, 'step': 1, 'retry': 2, 'maxRetries': 3}),
          10 => ev(n, 'session/title', {'title': 'title$n'}),
          _ => ev(n, 'future/unknown', {'value': n}),
        };
        final parsed = parseFollowFrame('s', frame);
        if (parsed is ApprovalAskedEvent) {
          expect(parsed.approvalId, isNotEmpty);
          approvalIds.add(parsed.approvalId);
        }
        if (parsed is ApprovalDecidedEvent) {
          expect(parsed.approvalId, isNotEmpty);
          approvalIds.add(parsed.approvalId);
        }
        p.wire(frame);
        history.add(frame['event'] as Map<String, Object?>);
        if (i % 23 == 0) p.apply(() => SessionStatusEvent('s', i.isEven));
        if (i % 31 == 0) {
          p.apply(
            () => ApprovalRequestedEvent(
              ApprovalRequest(eventId: 'live${i % 2}', sessionId: 's', toolName: 'tool', callId: id),
            ),
          );
        }
        if (i % 37 == 0) p.apply(() => const HostRequestCancelledEvent('live0'));
        if (i % 53 == 0) p.history(history.take(3).toList(), i.isEven);
        if (i % 79 == 0) p.wire(snapshot([frame], cursor: i - 10), resync: true);
        if (i == 160) p.wire(snapshot([], cursor: -1));
      }
      expect(approvalIds.length, greaterThan(1));
    });
  }
  test('final-answer flags agree with full rebuilds after append, resync and history', () {
    final p = Diff();
    p.wire(assistant(1, 1, phase: 'commentary'));
    p.wire(assistant(2, 2, phase: 'final_answer'));
    p.wire(assistant(3, 3, phase: 'final_answer'));
    p.wire(assistant(4, 4));
    expect(p.a.items.whereType<AssistantChatItem>().map((a) => a.isFinalAnswer), [false, true, true, false]);
    p.wire(snapshot([assistant(3, 3, phase: 'final_answer')], cursor: 3), resync: true);
    p.history([assistant(0, 0, phase: 'final_answer')['event'] as Map<String, Object?>], false);
    expect(p.a.items.whereType<AssistantChatItem>().map((a) => a.isFinalAnswer), [true, false, true, true, false]);
    p.wire(assistant(2, 2, phase: 'commentary'));
    expect(p.a.items.whereType<AssistantChatItem>().map((a) => a.isFinalAnswer), [true, false, false, true, false]);
  });
  test('late cross-turn result and approval precedence preserve first-seen fields', () {
    final p = Diff();
    for (final f in [
      result(0, 'first'),
      call(1, 'first'),
      call(2, 'old'),
      end(3),
      end(4),
      ev(5, 'turn/start', {'turn': 8}),
      result(6, 'old'),
    ]) {
      p.wire(f);
    }
    for (final id in ['earlier', 'later']) {
      p.apply(
        () => ApprovalRequestedEvent(ApprovalRequest(eventId: id, sessionId: 's', toolName: 'tool', callId: 'old')),
      );
    }
    p.apply(() => const HostRequestCancelledEvent('later'));
    p.wire(ev(7, 'approval/asked', {'id': 'p', 'callId': 'old'}));
    p.wire(ev(8, 'approval/decided', {'id': 'p', 'outcome': 'rejected'}));
    p.wire(assistant(9, 1));
    p.wire(assistant(10, 1));
  });
  test('cursor is not append boundary; reset and history preserve override rules', () {
    final p = Diff();
    p.wire(user(100));
    p.wire(snapshot([user(1)], cursor: 1), resync: true);
    p.wire(user(50));
    p.wire(assistant(100, 2));
    p.apply(() => const SessionStatusEvent('s', false));
    p.wire(ev(0, 'turn/start', {'turn': 1}));
    p.history([end(2)['event'] as Map<String, Object?>], false);
    p.wire(snapshot([end(2)], cursor: 2));
  });
  test('returned lists and shared result aliases match the full rebuild', () {
    final p = Diff();
    p.wire(user(0));
    p.wire(call(1, 'c'));
    p.wire(result(2, 'c'));
    final oldA = p.a.items, oldB = p.b.items;
    oldA.removeLast();
    oldB.removeLast();
    p.check();
    p.wire(end(3));
    final beforeA = norm(oldA), beforeB = norm(oldB);
    p.wire(result(4, 'c', error: true));
    expect(norm(oldA), beforeA);
    expect(norm(oldB), beforeB);
    for (final dynamic t in [p.a, p.b]) {
      final dynamic item = (t.items as List).lastWhere((dynamic x) => x.runtimeType.toString() == 'ToolChatItem');
      item.resultParts[0] = const TextPart('mutated result');
      (t.events as Iterable).whereType<ToolResultEvent>().last.data['meta'] = {'replacement': true};
    }
    p.wire(end(5));
  });
  test('strict append prefixes retain long-lived cross-turn tool state', () {
    final p = Diff(synthetic: true);
    final r = Random(19);
    for (var n = 0; n < 500; n++) {
      final id = 'long-${r.nextInt(25)}';
      final frame = switch (r.nextInt(7)) {
        0 => user(n),
        1 => assistant(n, r.nextInt(8), tool: id),
        2 => call(n, id),
        3 => result(n, id, error: r.nextBool()),
        4 => end(n),
        5 => ev(n, 'approval/asked', {'id': 'approval-$id', 'callId': id}),
        _ => ev(n, 'approval/decided', {'id': 'approval-$id', 'outcome': 'rejected'}),
      };
      p.wire(frame);
    }
  });
  test('stream drafts and cached derived running retain original transitions', () {
    final p = Diff();
    p.wire(
      snapshot([
        ev(0, 'turn/start', {'turn': 1}),
      ], cursor: 0),
    );
    p.wire(ev(1, 'future/unknown', {}));
    for (final id in ['older', 'latest']) {
      p.apply(() => AssistantStreamStarted(id, 1, turn: 1, step: 1, startedAfterSeq: 1));
      p.apply(() => AssistantChunkEvent(id, 1, index: 0, time: DateTime(2026), chunk: const TextDeltaChunk(0, 'text')));
      p.apply(
        () => AssistantChunkEvent(id, 1, index: 0, time: DateTime(2026), chunk: const TextDeltaChunk(0, 'duplicate')),
      );
    }
    p.apply(() => const AssistantStreamEnded('latest', 2, index: 1, committed: true, committedSeq: 5));
    p.wire(assistant(5, 1));
    p.history([end(6)['event'] as Map<String, Object?>], false);
    p.apply(() => const SessionStatusEvent('s', false));
    p.wire(ev(2, 'turn/start', {'turn': 9}));
    p.wire(snapshot([end(6)], cursor: 6), resync: true);
  });
}
