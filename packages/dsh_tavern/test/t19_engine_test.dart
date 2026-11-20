import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  for (final postfix in <Object?>[7, null]) {
    test('continue nudge uses the same coerced postfix $postfix as saved text', () async {
      final model = _Model();
      final h = await _open(model: model);
      await h.engine.setPreset(
        ChatPreset({
          ...ChatPreset.stDefault().raw,
          'continue_prefill': false,
          'continue_postfix': postfix,
          'continue_nudge_prompt': 'LAST={{lastChatMessage}}',
        }),
      );
      final chat = await h.chat();
      final greeting = (await h.engine.path(chat)).single;
      final done = (await h.engine.continueReply(chat, greeting.nodeId).toList()).whereType<TavernTurnDone>().single;
      expect(done.message.text, 'G${postfix}OK');
      expect(jsonEncode(model.bodies.single), contains('LAST=G$postfix'));
    });
  }
  for (final postfix in <Object?>[7, null]) {
    test('raw prefill keeps the original body and commits coerced postfix $postfix', () async {
      final model = _Model();
      final h = await _open(model: model);
      await h.engine.setPreset(
        ChatPreset({...ChatPreset.stDefault().raw, 'continue_prefill': true, 'continue_postfix': postfix}),
      );
      final chat = await h.chat();
      final greeting = (await h.engine.path(chat)).single;
      final done = (await h.engine.continueReply(chat, greeting.nodeId).toList()).whereType<TavernTurnDone>().single;
      expect(done.message.text, 'G${postfix}OK');
      final messages = model.bodies.single['messages']! as List<Object?>;
      expect((messages.last! as Map<String, Object?>)['content'], 'G');
      await h.reopen();
      expect((await h.engine.path(chat)).single.text, 'G${postfix}OK');
    });
  }
  for (final mode in ['modern', 'legacy']) {
    test('$mode budget macros accept numeric preset strings before assembly', () async {
      final model = _Model();
      final h = await _open(model: model);
      await h.engine.setSettings({'macroEngine': mode});
      await h.engine.setPreset(
        ChatPreset({
          ...ChatPreset.stDefault().raw,
          'openai_max_context': '2048',
          'openai_max_tokens': '64',
          'temperature': '0.7',
        }),
      );
      final chat = await h.chat();
      final events = await h.engine.send(chat, '{{maxPrompt}}/{{maxContext}}/{{maxResponse}}').toList();
      expect(events.whereType<TavernTurnDone>(), hasLength(1));
      expect((await h.engine.path(chat))[1].text, '1984/2048/64');
      expect(model.bodies.single['temperature'], 0.7);
    });
  }
  test('transport retries do not repeat macros or tree writes', () async {
    final bodies = <String>[];
    var attempts = 0;
    final transport = TavernModelClient(
      clientFactory: () => _Http((request) async {
        attempts++;
        bodies.add(utf8.decode(await request.finalize().toBytes()));
        if (attempts < 3) return http.StreamedResponse(Stream.value(utf8.encode('overloaded')), 503);
        return http.StreamedResponse(
          Stream.value(
            utf8.encode('data: {"choices":[{"delta":{"content":"OK"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n'),
          ),
          200,
        );
      }),
    );
    final h = await _open(model: transport);
    final card = await h.engine.importCard(_card({}));
    final chat = await h.engine.createChat(card.id);
    await h.engine.updateCharacterFields(card.id, {'description': '{{incvar::prepared}}'});
    final events = await h.engine.send(chat, '{{incvar::input}}Q').toList();
    expect(events.whereType<TavernTurnStarted>(), hasLength(1));
    expect(events.whereType<TavernTurnDone>().single.finishReason, 'stop');
    expect(attempts, 3);
    expect(bodies.toSet(), hasLength(1));
    expect(h.engine.variables(chat)['input'], 1);
    expect(h.engine.variables(chat)['prepared'], 1);
    expect((await h.engine.path(chat)).map((m) => m.text), ['G', '1Q', 'OK']);
    await h.reopen();
    expect(h.engine.variables(chat)['input'], 1);
    expect(h.engine.variables(chat)['prepared'], 1);
  });
  test('malformed existing lorebook is still invalidCard, not a missing skip', () async {
    final model = _Model();
    final h = await _open(model: model);
    final chat = await h.chat();
    final file = File('${h.directory.path}/lorebooks/broken.json');
    await file.parent.create(recursive: true);
    await file.writeAsString('{broken');
    await h.engine.bindLorebooks(['broken']);
    final failure = (await h.engine.send(chat, 'Q').toList()).whereType<TavernTurnFailed>().single;
    expect(failure.kind, TavernFailure.invalidCard);
    expect(model.bodies, isEmpty);
  });

  for (final reason in ['length', 'content_filter', 'future-provider-value', null]) {
    test('Done carries the unmodified finish reason $reason', () async {
      final h = await _open(model: _Model(reason: reason));
      final chat = await h.chat();
      final events = await h.engine.send(chat, 'Q').toList();
      expect(events.whereType<TavernTurnDone>().single.finishReason, reason);
      expect(events.whereType<TavernTurnFailed>(), isEmpty);
      expect(events.whereType<TavernTurnDone>().single.message.text, 'OK');
    });
  }

  for (final mode in ['regenerate', 'continue', 'impersonate']) {
    test('$mode forwards the finish reason too', () async {
      final h = await _open(model: _Model(reason: 'length'));
      final chat = await h.chat();
      final node = (await h.engine.path(chat)).single.nodeId;
      final stream = switch (mode) {
        'regenerate' => h.engine.regenerate(chat, node),
        'continue' => h.engine.continueReply(chat, node),
        _ => h.engine.impersonate(chat),
      };
      expect((await stream.toList()).whereType<TavernTurnDone>().single.finishReason, 'length');
    });
  }

  test('content_filter with no content still reports a completed filtered turn', () async {
    final h = await _open(
      model: _Model(reason: 'content_filter', text: ''),
    );
    final chat = await h.chat();
    final events = await h.engine.send(chat, 'Q').toList();
    final done = events.whereType<TavernTurnDone>().single;
    expect(done.finishReason, 'content_filter');
    expect(done.message.text, isEmpty);
    expect(events.whereType<TavernTurnFailed>(), isEmpty);
  });
  test('missing bound books are skipped and traced alongside working embedded WI', () async {
    final h = await _open();
    final chat = await h.chat({
      'character_book': {
        'entries': [
          {
            'id': 1,
            'keys': ['beacon'],
            'content': 'working-book',
            'enabled': true,
            'extensions': {},
          },
        ],
      },
    });
    await h.engine.bindLorebooks(['gone-global']);
    await h.engine.bindLorebooks(['gone-chat'], source: WorldInfoSource.chat, chatId: chat);
    final done = (await h.engine.send(chat, 'beacon').toList()).whereType<TavernTurnDone>().single;
    expect(done.message.text, 'OK');
    final expected = [
      {'bookId': 'gone-global', 'source': 'global', 'reason': 'missing'},
      {'bookId': 'gone-chat', 'source': 'chat', 'reason': 'missing'},
    ];
    final inspection = (await h.engine.inspectTurn(chat, nodeId: done.message.nodeId))!;
    expect(inspection.worldInfo['missing'], expected);
    expect((inspection.worldInfo['activated']! as List<Object?>), hasLength(1));
    expect((h.engine.inspect(chat)!.toJson()['worldInfo']! as Map<String, Object?>)['missing'], expected);
    await h.reopen();
    expect((await h.engine.inspectTurn(chat, nodeId: done.message.nodeId))!.worldInfo['missing'], expected);
    await h.engine.putLorebook('gone-global', {'entries': <String, Object?>{}});
    await h.engine.putLorebook('gone-chat', {'entries': <String, Object?>{}});
    await h.engine.send(chat, 'again').toList();
    expect((await h.engine.inspectTurn(chat))!.worldInfo.containsKey('missing'), isFalse);
  });

  test('a missing book stays diagnosed when the model subsequently fails', () async {
    final h = await _open(model: _Model(failure: const TavernModelException(TavernFailure.badKey, 'fixture')));
    final chat = await h.chat();
    await h.engine.bindLorebooks(['missing']);
    final failed = (await h.engine.send(chat, 'Q').toList()).whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.badKey);
    expect((await h.engine.inspectTurn(chat))!.worldInfo['missing'], [
      {'bookId': 'missing', 'source': 'global', 'reason': 'missing'},
    ]);
    expect((await h.engine.path(chat)).map((m) => m.text), ['G']);
  });
}

Future<_Harness> _open({TavernModelClient? model}) async {
  final directory = await Directory.systemTemp.createTemp('dsh-t19-engine-');
  final h = _Harness(directory, model ?? _Model());
  await h.open();
  addTearDown(() async {
    await h.engine.close();
    await directory.delete(recursive: true);
  });
  return h;
}

class _Harness {
  _Harness(this.directory, this.model);
  final Directory directory;
  final TavernModelClient model;
  late TavernEngine engine;
  Future<void> open() async {
    engine = await TavernEngine.openDirectory(
      directory,
      modelClient: model,
      config: TavernModelConfig(apiKey: () async => 'fixture-key'),
      clock: () => DateTime.utc(2026, 11, 10),
      random: () => 0.25,
    );
  }

  Future<void> reopen() async {
    await engine.close();
    await open();
  }

  Future<String> chat([Map<String, Object?> fields = const {}]) async {
    final card = await engine.importCard(_card(fields));
    return engine.createChat(card.id);
  }
}

class _Model extends TavernModelClient {
  _Model({this.reason = 'stop', this.failure, this.text = 'OK'});
  final String? reason;
  final TavernModelException? failure;
  final String text;
  final bodies = <Map<String, Object?>>[];
  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) async* {
    bodies.add(body);
    if (failure != null) throw failure!;
    if (text.isNotEmpty) yield ModelText(text);
    yield ModelFinished(reason);
  }
}

class _Http extends http.BaseClient {
  _Http(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => handler(request);
}

Uint8List _card(Map<String, Object?> fields) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': 'Guide',
        'description': '',
        'personality': '',
        'scenario': '',
        'first_mes': 'G',
        'mes_example': '',
        'creator_notes': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'alternate_greetings': <String>[],
        'tags': <String>[],
        'creator': '',
        'character_version': '',
        'extensions': <String, Object?>{},
        ...fields,
      },
    }),
  ),
);
