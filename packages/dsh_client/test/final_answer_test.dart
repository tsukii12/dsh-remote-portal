import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

const _text = {'type': 'text', 'text': 'answer'};
const _reasoning = {'type': 'reasoning', 'text': 'thinking'};
const _response = {
  'kind': 'pi-ai',
  'version': 2,
  'api': 'openai-codex-responses',
  'provider': 'openai-codex',
  'model': 'gpt-6.1-sol',
  'stopReason': 'stop',
};

String _signature(String phase) => jsonEncode({'v': 1, 'id': 'msg-test', 'phase': phase});

Map<String, Object?> _textReplay(String phase) => {'type': 'text', 'textSignature': _signature(phase)};

Map<String, Object?> _replay(List<Object?> blocks, {Object? response = _response}) => {
  'response': response,
  'blocks': blocks,
};

Map<String, Object?> _message({
  List<Map<String, Object?>> content = const [_text],
  Object? replayState,
  String role = 'assistant',
  String sourceKind = 'model',
}) => {
  'id': 'a-test',
  'role': role,
  'content': content,
  'source': {'kind': sourceKind, 'provider': 'openai-codex', 'model': 'gpt-6.1-sol', 'replayState': ?replayState},
};

Map<String, Object?> _event(int seq, String type, Map<String, Object?> data) => {
  'type': 'event',
  'event': {'seq': seq, 'time': 1000 + seq, 'type': type, 'data': data},
};

Map<String, Object?> _answer(int seq, int step, String? phase) => _event(seq, 'assistant/message', {
  'turn': 1,
  'step': step,
  'message': _message(
    content: [
      _reasoning,
      {'type': 'text', 'text': 'answer-$step'},
    ],
    replayState: phase == null
        ? null
        : _replay([
            {'type': 'reasoning'},
            _textReplay(phase),
          ]),
  ),
});

DshEvent _snapshot(List<Map<String, Object?>> frames, {bool resync = false}) => parseFollowFrame('s', {
  'type': 'snapshot',
  'header': {'id': 's', 'version': 4, 'createdAt': 1000},
  'cursor': (frames.last['event'] as Map)['seq'],
  'records': frames,
  'hasMore': false,
  'projections': {'asOfSeq': 100, 'values': {}},
  'assistantStream': {'revision': 0},
}, isResync: resync);

Object _observe(ChatTranscript transcript) => [
  for (final item in transcript.items.whereType<AssistantChatItem>())
    (item.seq, item.key, item.text, item.reasoning, item.isFinalAnswer, item.streaming, item.model),
];

void main() {
  group('Message.isFinalAnswer', () {
    test('reads the final phase from pi-ai v2 replay, not visible content', () {
      final message = Message.fromJson(_message(replayState: _replay([_textReplay('final_answer')])));
      expect(message.isFinalAnswer, isTrue);
      expect(message.text, 'answer');
      expect((message.raw['content'] as List).single, _text);
    });

    test('commentary, legacy and unrecognized phase locations stay unmarked', () {
      expect(Message.fromJson(_message(replayState: _replay([_textReplay('commentary')]))).isFinalAnswer, isFalse);
      expect(Message.fromJson(_message()).isFinalAnswer, isFalse);
      expect(
        Message.fromJson({
          ..._message(
            content: [
              {..._text, 'phase': 'final_answer'},
            ],
          ),
          'phase': 'final_answer',
          'channel': 'final',
        }).isFinalAnswer,
        isFalse,
      );
    });

    test('unknown or malformed replay envelopes are not trusted', () {
      final cases = <Object?>[
        null,
        'not-an-envelope',
        [],
        {},
        {'response': _response},
        {'response': _response, 'blocks': {}},
        _replay([_textReplay('final_answer')], response: null),
        _replay([_textReplay('final_answer')], response: 'pi-ai'),
        _replay([_textReplay('final_answer')], response: {..._response, 'kind': 'future-adapter'}),
        _replay([_textReplay('final_answer')], response: {..._response, 'version': 1}),
        _replay([_textReplay('final_answer')], response: {..._response, 'version': 3}),
        _replay([_textReplay('final_answer')], response: {..._response, 'version': '2'}),
        _replay([]),
        _replay([_textReplay('final_answer'), _textReplay('final_answer')]),
      ];
      for (final replay in cases) {
        expect(Message.fromJson(_message(replayState: replay)).isFinalAnswer, isFalse, reason: '$replay');
      }
    });

    test('malformed or unsupported signatures never become final answers', () {
      final signatures = <Object?>[
        null,
        1,
        {'v': 1, 'id': 'msg-test', 'phase': 'final_answer'},
        'not-json',
        '{',
        'null',
        '[]',
        '"final_answer"',
        '{"phase":"final_answer"}',
        '{"v":2,"id":"msg-test","phase":"final_answer"}',
        '{"v":"1","id":"msg-test","phase":"final_answer"}',
        '{"v":1,"phase":"final_answer"}',
        '{"v":1,"id":"","phase":"final_answer"}',
        '{"v":1,"id":42,"phase":"final_answer"}',
        '{"v":1,"id":"msg-test"}',
        '{"v":1,"id":"msg-test","phase":"future"}',
      ];
      for (final signature in signatures) {
        final message = Message.fromJson(
          _message(
            replayState: _replay([
              {'type': 'text', 'textSignature': signature},
            ]),
          ),
        );
        expect(message.isFinalAnswer, isFalse, reason: '$signature');
      }
      for (final block in <Object?>[
        null,
        'text',
        {},
        {'type': 'reasoning', 'textSignature': _signature('final_answer')},
      ]) {
        expect(Message.fromJson(_message(replayState: _replay([block]))).isFinalAnswer, isFalse);
      }
    });

    test('replay blocks use the content index, including reasoning blocks', () {
      final content = [_reasoning, _text];
      final correct = Message.fromJson(
        _message(
          content: content,
          replayState: _replay([
            {'type': 'reasoning'},
            _textReplay('final_answer'),
          ]),
        ),
      );
      expect(correct.isFinalAnswer, isTrue);
      for (final blocks in [
        [_textReplay('final_answer')],
        [
          _textReplay('final_answer'),
          {'type': 'reasoning'},
        ],
        [
          _textReplay('final_answer'),
          {'type': 'text'},
        ],
      ]) {
        expect(Message.fromJson(_message(content: content, replayState: _replay(blocks))).isFinalAnswer, isFalse);
      }
    });

    test('only nonempty assistant model text can be a final answer', () {
      for (final content in <List<Map<String, Object?>>>[
        [],
        [_reasoning],
        [
          {'type': 'tool-call', 'id': 'c', 'name': 'read', 'arguments': '{}'},
        ],
        [
          {'type': 'future', 'text': 'answer'},
        ],
        [
          {'type': 'text', 'text': ''},
        ],
        [
          {'type': 'text', 'text': ' \n\t'},
        ],
      ]) {
        final replay = _replay([for (final _ in content) _textReplay('final_answer')]);
        expect(Message.fromJson(_message(content: content, replayState: replay)).isFinalAnswer, isFalse);
      }
      final replay = _replay([_textReplay('final_answer')]);
      for (final role in ['user', 'tool', 'developer', 'unknown']) {
        expect(Message.fromJson(_message(role: role, replayState: replay)).isFinalAnswer, isFalse);
      }
      expect(Message.fromJson(_message(sourceKind: 'user', replayState: replay)).isFinalAnswer, isFalse);
    });

    test('any nonempty final block preserves the joined message', () {
      final content = [
        {'type': 'text', 'text': 'first'},
        _reasoning,
        {'type': 'text', 'text': 'second'},
        {'type': 'text', 'text': ' '},
      ];
      final blocks = [
        _textReplay('final_answer'),
        {'type': 'reasoning'},
        _textReplay('final_answer'),
        {'type': 'text'},
      ];
      final message = Message.fromJson(_message(content: content, replayState: _replay(blocks)));
      expect(message.isFinalAnswer, isTrue);
      expect(message.text, 'firstsecond ');
      expect(message.reasoning, 'thinking');
      for (final replacement in [
        _textReplay('commentary'),
        {'type': 'text'},
        {'type': 'text', 'textSignature': '{'},
      ]) {
        expect(
          Message.fromJson(
            _message(content: content, replayState: _replay([...blocks.take(2), replacement, blocks.last])),
          ).isFinalAnswer,
          isTrue,
        );
      }
      final mixed = Message.fromJson(
        _message(
          content: const [_text, _text],
          replayState: _replay([_textReplay('commentary'), _textReplay('final_answer')]),
        ),
      );
      expect(mixed.isFinalAnswer, isTrue);
      expect(mixed.text, 'answeranswer');
      final progress = Message.fromJson(
        _message(
          content: const [_text, _text],
          replayState: _replay([_textReplay('commentary'), _textReplay('commentary')]),
        ),
      );
      expect(progress.isFinalAnswer, isFalse);
    });
  });

  group('final-answer transcript projection', () {
    final frames = [
      _event(0, 'turn/start', {'turn': 1}),
      _answer(1, 24, 'commentary'),
      _answer(2, 25, 'final_answer'),
      for (final (seq, kind) in [(3, 'agent-message'), (4, 'subagent-settled')])
        _event(seq, 'user/message', {
          'id': 'u$seq',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'synthetic result'},
          ],
          'source': {'kind': kind},
        }),
      _answer(5, 26, 'final_answer'),
      _answer(6, 27, null),
      _event(7, 'turn/end', {
        'turn': 1,
        'reason': {'kind': 'completed'},
      }),
    ];

    test('incremental commits and a full snapshot retain both final answers', () {
      final incremental = ChatTranscript();
      for (final frame in frames) {
        incremental.apply(parseFollowFrame('s', frame));
        // Materialize every prefix to exercise the cached append-only fold.
        expect(incremental.items, same(incremental.items));
      }
      final snapshot = ChatTranscript()..apply(_snapshot(frames));
      expect(_observe(incremental), _observe(snapshot));
      final answers = incremental.items.whereType<AssistantChatItem>().toList();
      expect(answers.map((a) => a.isFinalAnswer), [false, true, true, false]);
      expect(answers.map((a) => a.text), ['answer-24', 'answer-25', 'answer-26', 'answer-27']);
      expect(answers.map((a) => a.key), ['m1.24', 'm1.25', 'm1.26', 'm1.27']);
      expect(answers.every((a) => a.reasoning == 'thinking'), isTrue);
      expect(incremental.items.whereType<UserChatItem>(), isEmpty);
      expect(incremental.running, isFalse);
    });

    test('resync, older history and replacement rebuild the final-answer flags', () {
      final transcript = ChatTranscript()..apply(_snapshot(frames.skip(5).toList()));
      transcript.items;
      transcript.prependHistory(
        HistoryPage(frames.take(5).map((f) => SessionLogEvent.fromJson(f['event'])).toList(), false),
      );
      final expected = ChatTranscript()..apply(_snapshot(frames));
      expect(_observe(transcript), _observe(expected));
      transcript.apply(_snapshot(frames.skip(5).toList(), resync: true));
      expect(_observe(transcript), _observe(expected));
      transcript.apply(parseFollowFrame('s', _answer(2, 25, 'commentary')));
      expect(transcript.items.whereType<AssistantChatItem>().map((a) => a.isFinalAnswer), [false, false, true, false]);
    });

    test('drafts and legacy constructors stay unmarked until the durable commit', () {
      const legacy = AssistantChatItem(id: 'legacy', text: 'answer', reasoning: '');
      expect(legacy.isFinalAnswer, isFalse);
      final transcript = ChatTranscript();
      transcript.apply(const AssistantStreamStarted('attempt', 1, turn: 1, step: 25, startedAfterSeq: 0));
      transcript.apply(
        AssistantChunkEvent('attempt', 2, index: 0, time: DateTime(2026), chunk: const TextDeltaChunk(0, 'draft')),
      );
      final draft = transcript.items.whereType<AssistantChatItem>().single;
      expect(draft.streaming, isTrue);
      expect(draft.isFinalAnswer, isFalse);
      transcript.apply(parseFollowFrame('s', _answer(2, 25, 'final_answer')));
      final committed = transcript.items.whereType<AssistantChatItem>().single;
      expect(committed.key, draft.key);
      expect(committed.streaming, isFalse);
      expect(committed.isFinalAnswer, isTrue);
    });
  });
}
