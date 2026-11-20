import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// Public facade, files and SQLite. SQL below only reads physical bytes;
// branches and empty selections are created through public operations.
void main() {
  // Keep this name unique for the owner's old-product negative control.
  test('JSONL field-leading BOM survives facade import read edit and export', () async {
    final h = await _open();
    final file = _file('field-bom.jsonl', [_row(_body, speaker: _speaker, reasoning: _reasoning)], fileBom: true);
    expect(file.bytes.take(3), [0xef, 0xbb, 0xbf]);
    final decoded = StChatDocument.decode(file.fileName, file.bytes);
    expect(decoded.messages.single['mes'], _body);
    expect(decoded.messages.single['name'], _speaker);
    expect(_map(decoded.messages.single['extra'])['reasoning'], _reasoning);

    final imported = await h.engine.importChats(h.characterId, [file]);
    expect(imported.chatIds, hasLength(1));
    final chat = imported.chatIds.single;
    final path = await h.engine.path(chat);
    expect(path, hasLength(1));
    final id = path.single.nodeId;
    final before = _storedBytes(h, id);
    expect(before['text_type'], 'text');
    expect(before['text_bytes'], utf8.encode(_body));
    // On the old product, every setup assertion above passes. This is the
    // first failing assertion: actual code points lack the initial U+FEFF.
    expect(
      path.single.text.runes.toList(),
      _body.runes.toList(),
      reason: 'A field-leading U+FEFF is message data, not a JSONL file BOM.',
    );
    _expectChannels(path.single, _body, _reasoning);
    expect(path.single.speaker, _speaker);
    expect(before['speaker_bytes'], utf8.encode(_speaker));
    expect(before['reasoning_bytes'], utf8.encode(_reasoning));

    // These edits change only metadata/visibility. They must not rewrite a
    // shorter decoded body or alter the original TEXT storage representation.
    await h.engine.nameBranch(chat, id, 'kept branch');
    await h.engine.setHidden(chat, id, true);
    expect((await h.engine.path(chat)).single.hidden, isTrue);
    await h.engine.setHidden(chat, id, false);
    expect(_storedBytes(h, id), before);
    final edited = (await h.engine.path(chat)).single;
    _expectChannels(edited, _body, _reasoning);
    expect(edited.speaker, _speaker);

    final files = await h.engine.exportChat(chat);
    final exported = StChatDocument.decode(files.first.fileName, files.first.bytes);
    expect(files.first.bytes.first, 0x7b, reason: 'Canonical JSONL has no file-leading BOM.');
    expect(exported.header['unknown_header'], _unknown);
    _expectRow(exported.messages.single, _body, _reasoning, speaker: _speaker);
    expect(exported.messages.single['unknown_message'], _unknown);
    expect(_map(exported.messages.single['extra'])['foreign'], _unknown);
    expect(_map(_map(exported.messages.single['extra'])['dshgo'])['branchName'], 'kept branch');
    expect(exported.messages.single['is_system'], isFalse);
    expect(h.model.generated, 0);

    await h.reopen();
    final reopened = (await h.engine.path(chat)).single;
    _expectChannels(reopened, _body, _reasoning);
    expect(reopened.speaker, _speaker);
    expect(_storedBytes(h, id), before);
    final again = (await h.engine.importChats(h.characterId, await h.engine.exportChat(chat))).chatIds.single;
    final restored = (await h.engine.path(again)).single;
    _expectChannels(restored, _body, _reasoning);
    expect(restored.speaker, _speaker);
    _expectRow(await _exportedRow(h, again, restored.nodeId), _body, _reasoning, speaker: _speaker);
  });

  test('BOM bodies survive a real retained branch and empty selected path JSONL round trip', () async {
    final h = await _open();
    final chat = (await h.engine.importChats(h.characterId, [
      _file('retained-bom.jsonl', [_row(_body, reasoning: _reasoning)]),
    ])).chatIds.single;
    final root = (await h.engine.path(chat)).single.nodeId;
    const input = '\uFEFF分支问题🐋';
    const answer = '\uFEFF分支回答🌊';
    final branch = await _start(h, h.engine.send(chat, input));
    final leaf = await _complete(branch, text: answer);
    expect((await h.engine.path(chat)).map((message) => message.text), [_body, input, answer]);
    await h.engine.nameBranch(chat, leaf.nodeId, 'retained tail');

    final other = await _start(h, h.engine.regenerate(chat, root));
    final otherRoot = await _complete(other, text: 'other root');
    expect(otherRoot.parentId, isNull);
    await h.engine.deleteMessage(chat, otherRoot.nodeId);
    expect(await h.engine.path(chat), isEmpty);
    final retained = await h.engine.tree(chat);
    expect(retained, hasLength(3));
    expect(retained.every((node) => !node.isCurrentPath), isTrue);

    final files = await h.engine.exportChat(chat);
    final documents = [for (final file in files) StChatDocument.decode(file.fileName, file.bytes)];
    expect(documents.first.messages, isEmpty);
    expect(
      documents.any(
        (document) => document.messages.map((row) => row['mes']).join('|') == [_body, input, answer].join('|'),
      ),
      isTrue,
    );
    _expectRow(await _exportedRow(h, chat, root), _body, _reasoning);
    final restoredChat = (await h.engine.importChats(h.characterId, files)).chatIds.single;
    expect(await h.engine.path(restoredChat), isEmpty);
    final nodes = await h.engine.tree(restoredChat);
    expect(nodes.map((node) => node.preview), unorderedEquals([_body, input, answer]));
    final restoredLeaf = nodes.singleWhere((node) => node.preview == answer).nodeId;
    await h.reopen();
    expect(await h.engine.path(chat), isEmpty);
    expect(await h.engine.path(restoredChat), isEmpty);
    await h.engine.selectNode(restoredChat, restoredLeaf);
    final restoredPath = await h.engine.path(restoredChat);
    expect(restoredPath.map((message) => message.text), [_body, input, answer]);
    expect(restoredPath.first.reasoning, _reasoning);
    expect(
      (await h.engine.tree(restoredChat)).singleWhere((node) => node.nodeId == restoredLeaf).branchName,
      'retained tail',
    );
  });

  test('continuation and editing retain BOM prefixes and reasoning through SQL writeback and reopening', () async {
    final h = await _open();
    const body = '\uFEFF原正文🐋';
    const reasoning = '\uFEFF原思考🌊';
    final chat = (await h.engine.importChats(h.characterId, [
      _file('continue-bom.jsonl', [_row(body, reasoning: reasoning)]),
    ])).chatIds.single;
    final id = (await h.engine.path(chat)).single.nodeId;
    final active = await _start(h, h.engine.continueReply(chat, id));
    _expectChannels(await _live(h, chat), body, reasoning);
    _expectChannels(active.events.values.whereType<TavernTurnStarted>().single.message, body, reasoning);
    const tail = '\uFEFF续正文';
    const thoughtTail = '\uFEFF续思考';
    active.call.add(const ModelText(tail));
    active.call.add(const ModelReasoning(thoughtTail));
    _expectChannels(await _live(h, chat), '$body$tail', '$reasoning$thoughtTail');
    await active.call.finish();
    await active.events.done.future;
    expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
    _expectChannels(
      active.events.values.whereType<TavernTurnDone>().single.message,
      '$body$tail',
      '$reasoning$thoughtTail',
    );
    _expectRow(await _exportedRow(h, chat, id), '$body$tail', '$reasoning$thoughtTail');
    await h.reopen();
    _expectChannels((await h.engine.path(chat)).single, '$body$tail', '$reasoning$thoughtTail');

    const replacement = '\uFEFF\uFEFF改正文\u0001内\uFEFF文';
    await h.engine.edit(chat, id, replacement);
    _expectChannels((await h.engine.path(chat)).single, replacement, '$reasoning$thoughtTail');
    expect(_storedBytes(h, id)['text_bytes'], utf8.encode(replacement));
    expect(_storedBytes(h, id)['reasoning_bytes'], utf8.encode('$reasoning$thoughtTail'));
    // An empty failed continuation restores originalTarget through a real
    // UPDATE. Its non-null partial is the old message, not new model output.
    final failedTurn = await _start(h, h.engine.continueReply(chat, id));
    failedTurn.call.fail(TavernFailure.network, 'no new continuation output');
    await failedTurn.events.done.future;
    final failure = failedTurn.events.values.whereType<TavernTurnFailed>().single;
    expect(failure.kind, TavernFailure.network);
    _expectChannels(failure.partial!, replacement, '$reasoning$thoughtTail');
    expect(failedTurn.events.values.whereType<TavernTurnDone>(), isEmpty);
    await h.reopen();
    _expectChannels((await h.engine.path(chat)).single, replacement, '$reasoning$thoughtTail');
    _expectRow(await _exportedRow(h, chat, id), replacement, '$reasoning$thoughtTail');
  });

  test(
    'live BOM channels survive the real checkpoint shadow and cancelled terminal persistence',
    () => _withTimers((timers) async {
      final h = await _open();
      final active = await _start(h, h.engine.send(h.chatId, 'stream question'));
      const body = '\uFEFF流正文🐋';
      const reasoning = '\uFEFF流思考🌊';
      active.call.add(const ModelText(body));
      active.call.add(const ModelReasoning(reasoning));
      // The sync model has updated both buffers, but send and resumeTurn use
      // separate async observers. Drain queued deltas before reading their list.
      await t24Pump();
      final live = await _live(h, h.chatId);
      _expectChannels(live, body, reasoning);
      expect(active.events.values.whereType<TavernTextDelta>().map((event) => event.text).join(), body);
      expect(active.events.values.whereType<TavernReasoningDelta>().map((event) => event.text).join(), reasoning);
      final before = _storedBytes(h, live.nodeId);
      expect(before['text_bytes'], isEmpty);
      expect(before['stream_text_bytes'], isNull);
      expect(timers, hasLength(1));
      expect(timers.single.period, const Duration(milliseconds: 500));
      timers.single.fire();
      final checkpoint = _storedBytes(h, live.nodeId);
      expect(checkpoint['text_bytes'], isEmpty);
      expect(checkpoint['stream_text_bytes'], utf8.encode(body));
      expect(checkpoint['stream_reasoning_bytes'], utf8.encode(reasoning));
      _expectChannels((await h.engine.path(h.chatId)).last, body, reasoning);
      _expectRow(await _exportedRow(h, h.chatId, live.nodeId), body, reasoning);

      active.call.add(const ModelText('\uFEFF尾'));
      active.call.add(const ModelReasoning('\uFEFF思尾'));
      h.engine.stop(h.chatId);
      await active.events.done.future;
      final failure = active.events.values.whereType<TavernTurnFailed>().single;
      expect(failure.kind, TavernFailure.cancelled);
      expect(active.events.values.whereType<TavernTurnDone>(), isEmpty);
      _expectChannels(failure.partial!, '$body\uFEFF尾', '$reasoning\uFEFF思尾');
      expect(timers.single.isActive, isFalse);
      final terminal = _storedBytes(h, live.nodeId);
      expect(terminal['text_bytes'], utf8.encode('$body\uFEFF尾'));
      expect(terminal['reasoning_bytes'], utf8.encode('$reasoning\uFEFF思尾'));
      expect(terminal['stream_text_bytes'], isNull);
      expect(terminal['stream_reasoning_bytes'], isNull);
      await h.reopen();
      _expectChannels((await h.engine.path(h.chatId)).last, '$body\uFEFF尾', '$reasoning\uFEFF思尾');
      _expectRow(await _exportedRow(h, h.chatId, live.nodeId), '$body\uFEFF尾', '$reasoning\uFEFF思尾');
    }),
    timeout: const Timeout(Duration(seconds: 15)),
  );
}

const _body = '\uFEFF正文鲸🐋\r\n内\uFEFF部';
const _speaker = '\uFEFF讲述者🌊';
const _reasoning = '\uFEFF思考鲸🐋\r\n内\uFEFF部';
const _unknown = <String, Object?>{
  'text': '\uFEFF未知🐋',
  'list': <Object?>[null, true, '\uFEFF'],
};

Future<T24Harness> _open() async {
  final h = await T24Harness.open();
  addTearDown(h.dispose);
  return h;
}

Map<String, Object?> _row(String text, {String speaker = 'Guide', String? reasoning}) => {
  'name': speaker,
  'is_user': false,
  'is_system': false,
  'send_date': T24Harness.at.toIso8601String(),
  'mes': text,
  'unknown_message': _unknown,
  'extra': <String, Object?>{'foreign': _unknown, 'reasoning': ?reasoning},
};

TavernChatFile _file(String name, List<Map<String, Object?>> messages, {bool fileBom = false}) {
  final framed = [
    jsonEncode(<String, Object?>{'chat_metadata': <String, Object?>{}, 'unknown_header': _unknown}),
    for (final message in messages) jsonEncode(message),
  ].join('\r\n');
  return TavernChatFile(
    fileName: name,
    bytes: Uint8List.fromList([
      if (fileBom) ...[0xef, 0xbb, 0xbf],
      ...utf8.encode('$framed\r\n'),
    ]),
  );
}

typedef _Active = ({T24Call call, T24Events events});

Future<_Active> _start(T24Harness h, Stream<TavernEvent> stream) async {
  final call = h.model.prepare();
  final events = T24Events(stream);
  await Future.any<void>([
    call.listening.future,
    events.done.future.then<void>((_) {
      throw TestFailure('The turn ended before the controlled provider was listened to.');
    }),
  ]);
  return (call: call, events: events);
}

Future<TavernMessage> _complete(_Active active, {required String text}) async {
  active.call.add(ModelText(text));
  await active.call.finish();
  await active.events.done.future;
  expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
  return active.events.values.whereType<TavernTurnDone>().single.message;
}

Future<TavernMessage> _live(T24Harness h, String chat) async {
  final event = await h.engine.resumeTurn(chat).first;
  expect(event, isA<TavernTurnSnapshot>());
  final message = (event as TavernTurnSnapshot).message;
  expect(message, isNotNull);
  return message!;
}

void _expectChannels(TavernMessage message, String text, String? reasoning) {
  expect(message.text.runes.toList(), text.runes.toList());
  expect(message.reasoning, reasoning);
}

Map<String, Object?> _map(Object? value) => value is Map<String, Object?> ? value : <String, Object?>{};

void _expectRow(Map<String, Object?> row, String text, String? reasoning, {String speaker = 'Guide'}) {
  expect(row['mes'], text);
  expect(row['name'], speaker);
  expect(row['swipes'], [text]);
  final extra = _map(row['extra']);
  expect(extra['reasoning'], reasoning);
  expect(_map(_map(extra['dshgo'])['chatJsonl'])['text'], text);
  final infos = row['swipe_info']! as List<Object?>;
  expect(_map(_map(infos.single)['extra'])['reasoning'], reasoning);
}

Future<Map<String, Object?>> _exportedRow(T24Harness h, String chat, String nodeId) async {
  for (final file in await h.engine.exportChat(chat)) {
    for (final row in StChatDocument.decode(file.fileName, file.bytes).messages) {
      if (_map(_map(_map(row['extra'])['dshgo'])['chatJsonl'])['nodeId'] == nodeId) return row;
    }
  }
  throw TestFailure('Export did not contain node $nodeId.');
}

Map<String, Object?> _storedBytes(T24Harness h, String nodeId) {
  final db = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    return Map<String, Object?>.from(
      db
          .select(
            '''SELECT typeof(text) AS text_type,
      CAST(text AS BLOB) AS text_bytes, CAST(reasoning AS BLOB) AS reasoning_bytes,
      CAST(speaker AS BLOB) AS speaker_bytes, CAST(stream_text AS BLOB) AS stream_text_bytes,
      CAST(stream_reasoning AS BLOB) AS stream_reasoning_bytes FROM nodes WHERE id = ?''',
            [nodeId],
          )
          .single,
    );
  } finally {
    db.close();
  }
}

// Same real Timer.periodic interception as t23_stream_engine_test: fire the
// engine's checkpoint callback, without sleeping or a public product hook.
Future<void> _withTimers(Future<void> Function(List<_ManualTimer>) body) {
  final timers = <_ManualTimer>[];
  return runZoned(
    () => body(timers),
    zoneSpecification: ZoneSpecification(
      createPeriodicTimer: (self, parent, zone, period, callback) {
        final timer = _ManualTimer(period, callback);
        timers.add(timer);
        return timer;
      },
    ),
  );
}

class _ManualTimer implements Timer {
  _ManualTimer(this.period, this.callback);
  final Duration period;
  final void Function(Timer) callback;
  var _active = true;
  var _tick = 0;
  @override
  bool get isActive => _active;
  @override
  int get tick => _tick;
  @override
  void cancel() {
    _active = false;
  }

  void fire() {
    if (!_active) return;
    _tick++;
    callback(this);
  }
}
