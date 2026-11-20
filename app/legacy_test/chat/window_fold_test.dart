// Opening a conversation whose last turn is long: the follow snapshot is a
// window the Host cuts from the end. With the Host's default cap (50
// messages) the cut lands inside that turn, its `turn/start` is not loaded,
// there is no TurnTrace for it and it can neither fold nor carry a footnote.
// The chat asks for the official web window (at least 50 messages and
// two turns, capped at 500), so the cut lands on a turn start. The fake Host
// below pages exactly as DSH does (dsh-api-session-controller `paginate`).

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The session log: a short turn, then one with 60 tool steps (62 messages).
final _log = () {
  final log = <Map<String, Object?>>[];
  var time = DateTime(2026, 10, 25, 9).millisecondsSinceEpoch;
  void ev(String type, Map<String, Object?> data) =>
      log.add({'type': type, 'seq': log.length, 'time': time += 1000, 'data': data});
  void prompt(String text) => ev('user/message', {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
    ],
    'source': {'kind': 'user'},
  });
  void reply(int turn, int step, {String text = '', String? call}) {
    ev('assistant/message', {
      'turn': turn,
      'step': step,
      'message': {
        'role': 'assistant',
        'content': [
          if (call != null) ...[
            {'type': 'reasoning', 'text': '第 $step 步'},
            {
              'type': 'tool-call',
              'id': call,
              'name': 'bash',
              'arguments': jsonEncode({'command': call}),
            },
          ],
          if (text.isNotEmpty) {'type': 'text', 'text': text},
        ],
        'source': {'kind': 'llm', 'model': 'deepseek-flash'},
      },
    });
    if (call == null) return;
    ev('tool/call', {
      'turn': turn,
      'step': step,
      'callId': call,
      'name': 'bash',
      'arguments': jsonEncode({'command': call}),
    });
    ev('tool/result', {
      'turn': turn,
      'step': step,
      'message': {
        'role': 'tool',
        'toolCallId': call,
        'content': [
          {'type': 'text', 'text': 'ok'},
        ],
      },
    });
  }

  void end(int turn) => ev('turn/end', {
    'turn': turn,
    'reason': {'kind': 'completed'},
  });

  ev('turn/start', {'turn': 1});
  prompt('你好');
  reply(1, 1, text: '你好，有什么要做的？');
  end(1);
  ev('turn/start', {'turn': 2});
  prompt('把这个仓库的测试都跑一遍');
  for (var step = 1; step <= 60; step++) {
    reply(2, step, call: 'c$step');
  }
  reply(2, 61, text: '全部通过。');
  end(2);
  return log;
}();

final int _longTurnStart = _log.lastWhere((e) => e['type'] == 'turn/start')['seq']! as int;

/// The Host's window: walking back from the end, cut at a turn start once
/// [window] is met, or at the message that reaches [maxMessages] (its
/// default 50) first.
SessionSnapshotEvent _hostSnapshot(String sessionId, {required int? maxMessages, required TurnWindow? window}) {
  final cap = maxMessages ?? 50;
  var count = 0;
  var turns = 0;
  var cut = 0;
  for (var i = _log.length - 1; i >= 0; i--) {
    final type = _log[i]['type'];
    if (window != null && type == 'turn/start') {
      turns++;
      if (count >= window.minMessages && turns >= window.minTurns) {
        cut = i;
        break;
      }
    }
    if (type != 'user/message' && type != 'assistant/message') continue;
    if (++count >= cap) {
      cut = i;
      break;
    }
  }
  return SessionSnapshotEvent.fromJson(sessionId, {
    'cursor': _log.last['seq'],
    'hasMore': cut > 0,
    'records': [
      for (final event in _log.sublist(cut)) {'type': 'event', 'event': event},
    ],
  });
}

class _Mux extends DshMux {
  _Mux(super.carrier);
  final connection = StreamController<DshConnectionState>.broadcast();

  @override
  Stream<DshConnectionState> get states => connection.stream;
}

/// Answers `watch` with the Host's window for the options it was given.
class _Client extends DshClient {
  _Client() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));
  late final _mux = _Mux(carrier);
  final requested = <WatchOptions>[];

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) {
    requested.add(options);
    final stream = StreamController<DshEvent>()
      ..add(_hostSnapshot(sessionId, maxMessages: options.maxMessages, window: options.turnWindow));
    return stream.stream;
  }

  @override
  _Mux get mux => _mux;
}

void main() {
  test('the Host default (50 messages) cuts inside the long turn', () {
    final t = ChatTranscript()..apply(_hostSnapshot('s', maxMessages: null, window: const TurnWindow(50, 2)));
    expect(t.events.any((e) => e.seq == _longTurnStart), isFalse);
    expect(t.turns, isEmpty, reason: 'no turn/start, no trace');
    final rows = deriveRows(items: t.items, turns: t.turns, foldTurns: true);
    expect(rows.whereType<TurnProcessRow>(), isEmpty);
  });

  testWidgets('opening the conversation loads the turn start and folds it', (tester) async {
    final client = _Client();
    final container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(
          AsyncData(HostConnection(hostId: '', client: client, label: '本机', isLocal: true)),
        ),
      ],
    );
    final sub = container.listen(chatProvider('s'), (_, _) {});
    await tester.pump(const Duration(milliseconds: 40));

    expect(client.requested.single.maxMessages, 500);
    final state = sub.read();
    expect(state.loading, isFalse);
    final long = state.turns.singleWhere((t) => t.startSeq == _longTurnStart);
    expect(long.endReason?.isCompleted, isTrue);

    final rows = deriveRows(items: state.items, turns: state.turns, foldTurns: true);
    final fold = rows.whereType<TurnProcessRow>().singleWhere((row) => row.trace.startSeq == _longTurnStart);
    expect(fold.key, 'tp$_longTurnStart');
    expect(fold.toolCalls, 60);
    final answer = rows.whereType<AssistantRow>().last;
    expect(answer.item.text, '全部通过。');
    expect(answer.footnote, same(long));
    expect(rows.indexOf(answer), rows.indexOf(fold) + 1);

    sub.close();
    container.dispose();
  });
}
