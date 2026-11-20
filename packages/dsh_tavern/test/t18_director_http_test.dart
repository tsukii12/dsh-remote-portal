import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show t24Card, t24Preset;

typedef Json = Map<String, Object?>;
typedef _Request = ({Uri url, String method, Map<String, String> headers, Json body, String text});

const _key = 'wire-fixture-key';
const _privateInput = 'PRIVATE_HTTP_INPUT_SENTINEL';
final _at = DateTime.utc(2026, 11, 10, 12);

// Production TavernModelClient, HTTP request encoding, JSON response decoder,
// accumulator, coordinator and SQLite publication. MockClient replaces only
// the HTTP peer; no ModelDelta producer or real network account is involved.
void main() {
  test('DeepSeek HTTP uses the beta direct-only envelope and publishes one decoded result with usage', () async {
    final h = await _open();
    expect(h.config.thinking, isTrue);
    expect(h.config.model, isNot('deepseek-flash'));
    final before = (await h.engine.path(h.chatId)).map((node) => node.nodeId).toList();
    final output = _output(
      notes: '秘密：海🐋',
      events: [
        {'name': '灯光', 'data': '只是待处理提案'},
      ],
    );
    h.json(
      _completion(
        calls: [_call('wire-direct', output: output)],
        content: 'DISCARDED_HELPER_TEXT',
        reasoning: 'DISCARDED_HELPER_REASONING',
        usage: {'prompt_tokens': 120, 'prompt_cache_hit_tokens': 90, 'completion_tokens': 7},
        model: 'provider-reported-flash',
      ),
    );
    final run = await h.engine.runDirector(h.chatId);
    expect(run.success, isTrue, reason: run.failure);
    expect(run.output, output);
    expect(run.reportedUsage!.promptTokens, 120);
    expect(run.reportedUsage!.cacheHitTokens, 90);
    expect(run.reportedUsage!.completionTokens, 7);
    expect(run.reportedUsage!.model, 'provider-reported-flash');
    expect(h.requests, hasLength(1));
    expect(h.clients, 1);
    expect(h.keyReads, 1);
    final request = h.requests.single;
    expect(request.method, 'POST');
    expect(request.url, Uri.parse('https://deepseek-wire.invalid/beta/chat/completions'));
    expect(request.headers['authorization'], 'Bearer $_key');
    expect(request.headers['content-type'], contains('application/json'));
    _helperWire(request.body, deepseek: true, model: 'deepseek-flash');
    expect(
      request.body.keys,
      unorderedEquals(['messages', 'stream', 'max_tokens', 'thinking', 'tools', 'tool_choice', 'model']),
    );
    expect((await h.engine.path(h.chatId)).map((node) => node.nodeId), before);
    expect(await h.engine.inspectTurn(h.chatId), isNull);
    expect(_kindCount(h, 'director.success'), 1);
    expect(_kindCount(h, 'director.failure'), 0);
    final events = await h.engine.readDirectorEvents(h.chatId);
    expect(events, hasLength(1));
    expect(events.single.runId, run.id);
    expect(events.single.status, 'pending');
    expect(events.single.name, '灯光');
    final saved = _saved(h, run.id);
    expect(saved['usage'], isA<String>());
    expect(saved['result_json'], isNot(contains('DISCARDED_HELPER_TEXT')));
    expect(saved['result_json'], isNot(contains('DISCARDED_HELPER_REASONING')));
    await h.reopen();
    final snapshot = await h.engine.readDirector(h.chatId);
    expect(snapshot.latestSuccess!.id, run.id);
    expect(snapshot.latestSuccess!.output, output);
    expect(snapshot.latestSuccess!.reportedUsage!.cacheHitTokens, 90);
    expect(
      h.requests,
      hasLength(1),
      reason: 'Publishing and reopening do not produce a tool-result follow-up request.',
    );
  });

  test('generic HTTP retains the configured model and API prefix while omitting strict and thinking fields', () async {
    final h = await _open(deepseek: false);
    h.json(
      _completion(
        reason: 'stop',
        model: 'generic-reported',
        usage: {
          'prompt_tokens': 20,
          'prompt_tokens_details': {'cached_tokens': 12},
          'completion_tokens': 2,
        },
      ),
    );
    final run = await h.engine.runDirector(h.chatId);
    expect(run.success, isTrue, reason: run.failure);
    final request = h.requests.single;
    expect(request.url, Uri.parse('https://generic-wire.invalid/service/v1/chat/completions'));
    _helperWire(request.body, deepseek: false, model: 'generic-current-model');
    expect(request.body.keys, unorderedEquals(['messages', 'stream', 'max_tokens', 'tools', 'tool_choice', 'model']));
    expect(run.reportedUsage!.promptTokens, 20);
    expect(run.reportedUsage!.cacheHitTokens, 12);
    expect(run.reportedUsage!.completionTokens, 2);
    expect(run.reportedUsage!.model, 'generic-reported');
    expect(_kindCount(h, 'director.success'), 1);
    expect(h.requests, hasLength(1));
  });

  test('helper HTTP is independent of actual main sampling stops state tools and continuation prefix', () async {
    final h = await _open(thinking: false, stateful: true);
    final preset = t24Preset().raw;
    preset.addAll({
      'stream_openai': false,
      'openai_max_tokens': 73,
      'temperature': 0.77,
      'top_p': 0.42,
      'presence_penalty': 0.3,
      'frequency_penalty': 0.4,
      'continue_prefill': true,
      'continue_postfix': '',
    });
    await h.engine.setPreset(ChatPreset(preset));
    await h.engine.setSettings({
      'stops': ['MAIN_STOP_SENTINEL'],
    });
    h.json(_textCompletion('MAIN_RESPONSE'));
    final main = await h.engine.send(h.chatId, 'main question').toList();
    expect(main.whereType<TavernTurnFailed>(), isEmpty);
    final node = main.whereType<TavernTurnDone>().single.message;
    final mainBody = h.requests.single.body;
    expect(mainBody['temperature'], 0.77);
    expect(mainBody['top_p'], 0.42);
    expect(mainBody['presence_penalty'], 0.3);
    expect(mainBody['frequency_penalty'], 0.4);
    expect(mainBody['stop'], ['MAIN_STOP_SENTINEL']);
    expect(mainBody['max_tokens'], 73);
    expect(_rows(mainBody['tools']).map((tool) => _map(tool['function'])['name']), ['update_state', 'roll']);

    h.json(_textCompletion('_CONTINUED'));
    final continued = await h.engine.continueReply(h.chatId, node.nodeId).toList();
    expect(continued.whereType<TavernTurnFailed>(), isEmpty);
    expect(continued.whereType<TavernTurnDone>(), hasLength(1));
    final prefixBody = h.requests[1].body;
    expect(_rows(prefixBody['messages']).last['prefix'], isTrue);
    expect(_rows(prefixBody['messages']).last['content'], contains('MAIN_RESPONSE'));
    expect(prefixBody.containsKey('tools'), isFalse);

    h.json(_completion());
    final run = await h.engine.runDirector(h.chatId);
    expect(run.success, isTrue, reason: run.failure);
    final helper = h.requests.last.body;
    _helperWire(helper, deepseek: true, model: 'deepseek-flash');
    for (final field in [
      'stop',
      'temperature',
      'top_p',
      'presence_penalty',
      'frequency_penalty',
      'seed',
      'logprobs',
      'logit_bias',
      'response_format',
      'max_completion_tokens',
    ]) {
      expect(helper.containsKey(field), isFalse, reason: field);
    }
    expect(_rows(helper['tools']).map((tool) => _map(tool['function'])['name']), ['direct']);
    expect(
      _rows(helper['messages']).every(
        (message) =>
            !message.containsKey('prefix') &&
            !message.containsKey('reasoning_content') &&
            !message.containsKey('tool_calls') &&
            !message.containsKey('tool_call_id'),
      ),
      isTrue,
    );
    expect(h.requests, hasLength(3));
    expect(_kindCount(h, 'director.success'), 1);
  });

  test('two complete HTTP tool calls reject the entire attempt and preserve the prior success and events', () async {
    final h = await _open();
    final previous = await _baseline(h);
    h.json(
      _completion(
        calls: [
          _call(
            'first',
            output: _output(
              notes: 'MUST_NOT_PUBLISH_FIRST',
              events: [
                {'name': 'first', 'data': 'rejected'},
              ],
            ),
          ),
          _call('second', output: _output(notes: 'MUST_NOT_PUBLISH_SECOND')),
        ],
        usage: _failedUsage,
      ),
    );
    final failed = await h.engine.runDirector(h.chatId);
    await _preserved(h, previous, failed, failure: 'invalid_director_output', withUsage: true);
    expect(h.requests, hasLength(2));
  });

  test(
    'a complete HTTP envelope with half argument JSON retains reported usage but cannot publish a partial direct result',
    () async {
      final h = await _open();
      final previous = await _baseline(h);
      h.json(
        _completion(
          calls: [_call('half', arguments: '{"notes":"unfinished')],
          usage: _failedUsage,
        ),
      );
      final failed = await h.engine.runDirector(h.chatId);
      await _preserved(h, previous, failed, failure: 'invalid_director_output', withUsage: true);
      expect(
        h.requests,
        hasLength(2),
        reason: 'Accepted argument failure is not retried or repaired by another model call.',
      );
    },
  );

  test('a complete direct call with HTTP finish length stays failed and leaves the prior output intact', () async {
    final h = await _open();
    final previous = await _baseline(h);
    h.json(_completion(reason: 'length', usage: _failedUsage));
    final failed = await h.engine.runDirector(h.chatId);
    await _preserved(h, previous, failed, failure: 'invalid_director_output', withUsage: true);
    expect(h.requests, hasLength(2));
  });

  test('an HTTP completion without finish_reason is not promoted to a successful direct result', () async {
    final h = await _open();
    final previous = await _baseline(h);
    h.json(_completion(includeFinish: false, usage: _failedUsage));
    final failed = await h.engine.runDirector(h.chatId);
    await _preserved(h, previous, failed, failure: 'invalid_director_output', withUsage: true);
    expect(h.requests, hasLength(2));
  });

  test('HTTP error input echoes and credentials never enter the persisted director failure', () async {
    final h = await _open();
    final previous = await _baseline(h);
    h.responders.add((request) {
      final input = _input(_map(jsonDecode(request.body)));
      final secret = _map(input['card'])['description'];
      expect(secret, _privateInput);
      // Put reflected input first: the transport's bounded truncation alone
      // would retain it, so this checks the director's safe-detail boundary.
      return _jsonResponse({
        'error': {'message': '$secret ${request.body} $_key Bearer private-provider-token'},
      }, 400);
    });
    final failed = await h.engine.runDirector(h.chatId);
    await _preserved(h, previous, failed, failure: 'invalidParameters:director_model_failed');
    final raw = _saved(h, failed.id)['result_json']! as String;
    for (final text in [_privateInput, _key, 'private-provider-token', 'previousNotes', 'structured planning']) {
      expect(raw, isNot(contains(text)), reason: text);
      expect(failed.failure, isNot(contains(text)), reason: text);
    }
    await h.reopen();
    final snapshot = await h.engine.readDirector(h.chatId);
    expect(snapshot.latestSuccess!.id, previous.id);
    expect(snapshot.latestAttempt!.id, failed.id);
    expect(snapshot.latestAttempt!.failure, 'invalidParameters:director_model_failed');
    expect(h.requests, hasLength(2));
  });

  test('a provider error object in an accepted HTTP response is audited as a failure without JSON fallback', () async {
    final h = await _open();
    final previous = await _baseline(h);
    h.json({
      'error': {'message': 'PROVIDER_PRIVATE_ERROR $_privateInput', 'type': 'provider_failed'},
    });
    final failed = await h.engine.runDirector(h.chatId);
    await _preserved(h, previous, failed, failure: 'server:director_model_failed');
    expect(_saved(h, failed.id)['result_json'], isNot(contains('PROVIDER_PRIVATE_ERROR')));
    expect(h.requests, hasLength(2));
  });

  test('transport 5xx retries keep one prepared helper request and publish only one failed attempt', () async {
    final h = await _open();
    final previous = await _baseline(h);
    for (var attempt = 0; attempt < 3; attempt++) {
      h.json({
        'error': {'message': 'PRIVATE_503_RETRY_ECHO'},
      }, status: 503);
    }
    final failed = await h.engine.runDirector(h.chatId);
    await _preserved(h, previous, failed, failure: 'server:director_model_failed');
    expect(h.requests, hasLength(4));
    expect(h.requests.skip(1).map((request) => request.text).toSet(), hasLength(1));
    expect(h.keyReads, 2, reason: 'One key read per logical invocation, including the successful baseline.');
    expect(h.clients, 4);
    expect(_kindCount(h, 'director.failure'), 1);
    expect(_saved(h, failed.id)['result_json'], isNot(contains('PRIVATE_503_RETRY_ECHO')));
    // These three POSTs are the existing bounded transport retry policy,
    // not a second director/tool-result round and not three audit attempts.
  });
}

const _failedUsage = <String, Object?>{'prompt_tokens': 91, 'prompt_cache_hit_tokens': 5, 'completion_tokens': 13};

Json _map(Object? value) => value! as Json;
List<Json> _rows(Object? value) => (value! as List<Object?>).cast<Json>();
Json _input(Json request) => _map(jsonDecode(_rows(request['messages']).last['content']! as String));

Json _output({String notes = 'structured planning', List<Json> events = const []}) => {
  'notes': notes,
  'beat': '远处亮起一盏灯。',
  'prefetch': <Object?>[],
  'suggestions': [
    {'text': '观察灯光', 'risk': '可能暴露位置'},
    {'text': '原地等待', 'risk': ''},
    {'text': '询问同伴', 'risk': '需要时间'},
  ],
  'events': events,
};

Json _call(String id, {Json? output, String? arguments}) => {
  'id': id,
  'type': 'function',
  'function': {'name': 'direct', 'arguments': arguments ?? jsonEncode(output ?? _output())},
};

Json _completion({
  List<Json>? calls,
  String? reason = 'tool_calls',
  bool includeFinish = true,
  Json? usage,
  String model = 'wire-model',
  String? content,
  String? reasoning,
}) => {
  'id': 'completion-fixture',
  'model': model,
  'choices': [
    {
      'index': 0,
      'message': {
        'role': 'assistant',
        'content': content,
        'reasoning_content': ?reasoning,
        'tool_calls': calls ?? [_call('direct-call')],
      },
      if (includeFinish) 'finish_reason': reason,
    },
  ],
  'usage': ?usage,
};

Json _textCompletion(String text) => {
  'model': 'main-reported-model',
  'choices': [
    {
      'index': 0,
      'message': {'role': 'assistant', 'content': text},
      'finish_reason': 'stop',
    },
  ],
};

http.Response _jsonResponse(Json body, int status) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void _helperWire(Json body, {required bool deepseek, required String model}) {
  expect(body['model'], model);
  expect(body['stream'], isFalse);
  expect(body['max_tokens'], 4096);
  expect(body['tool_choice'], {
    'type': 'function',
    'function': {'name': 'direct'},
  });
  final messages = _rows(body['messages']);
  expect(messages.map((message) => message['role']), ['system', 'user']);
  final tools = _rows(body['tools']);
  expect(tools, hasLength(1));
  expect(tools.single['type'], 'function');
  final function = _map(tools.single['function']);
  expect(function['name'], 'direct');
  if (deepseek) {
    expect(body['thinking'], {'type': 'disabled'});
    expect(function['strict'], isTrue);
  } else {
    expect(body.containsKey('thinking'), isFalse);
    expect(function.containsKey('strict'), isFalse);
  }
  final parameters = _map(function['parameters']);
  expect(_map(parameters['properties']).keys, unorderedEquals(['notes', 'beat', 'prefetch', 'suggestions', 'events']));
  _closedObjects(parameters);
}

void _closedObjects(Json schema) {
  if (schema['type'] == 'object') {
    final properties = _map(schema['properties']);
    expect(schema['required'], unorderedEquals(properties.keys));
    expect(schema['additionalProperties'], isFalse);
    for (final child in properties.values) {
      _closedObjects(_map(child));
    }
  }
  if (schema['items'] case final Map<String, Object?> items) {
    _closedObjects(items);
  }
  if (schema['anyOf'] case final List<Object?> branches) {
    for (final branch in branches) {
      _closedObjects(_map(branch));
    }
  }
}

Future<TavernDirectorRun> _baseline(_Harness h) async {
  h.json(
    _completion(
      calls: [
        _call(
          'old-success',
          output: _output(
            notes: 'previous stable notes',
            events: [
              {'name': 'previous-event', 'data': 'keep the existing pending proposal'},
            ],
          ),
        ),
      ],
    ),
  );
  final run = await h.engine.runDirector(h.chatId);
  expect(run.success, isTrue, reason: run.failure);
  return run;
}

Future<void> _preserved(
  _Harness h,
  TavernDirectorRun previous,
  TavernDirectorRun failed, {
  required String failure,
  bool withUsage = false,
}) async {
  expect(failed.success, isFalse);
  expect(failed.failure, failure);
  expect(failed.output, isNull);
  if (withUsage) {
    expect(failed.reportedUsage!.promptTokens, 91);
    expect(failed.reportedUsage!.cacheHitTokens, 5);
    expect(failed.reportedUsage!.completionTokens, 13);
  } else {
    expect(failed.reportedUsage, isNull);
  }
  final snapshot = await h.engine.readDirector(h.chatId);
  expect(snapshot.latestSuccess!.id, previous.id);
  expect(snapshot.latestSuccess!.output, previous.output);
  expect(snapshot.latestAttempt!.id, failed.id);
  expect(snapshot.latestAttempt!.success, isFalse);
  expect(_kindCount(h, 'director.success'), 1);
  expect(_kindCount(h, 'director.failure'), 1);
  final proposal = (await h.engine.readDirectorEvents(h.chatId)).single;
  expect(proposal.runId, previous.id);
  expect(proposal.name, 'previous-event');
  final saved = _saved(h, failed.id);
  expect(saved['kind'], 'director.failure');
  expect(_map(jsonDecode(saved['result_json']! as String))['success'], isFalse);
  if (withUsage) {
    expect(_map(jsonDecode(saved['usage']! as String))['completionTokens'], 13);
  } else {
    expect(saved['usage'], isNull);
  }
  expect(h.responders, isEmpty);
}

Future<_Harness> _open({bool deepseek = true, bool thinking = true, bool stateful = false}) async {
  final directory = await Directory.systemTemp.createTemp('dsh-t18-director-http-');
  final h = _Harness(directory, deepseek: deepseek, thinking: thinking);
  await h.open();
  addTearDown(h.dispose);
  final preset = t24Preset().raw..['stream_openai'] = false;
  await h.engine.setPreset(ChatPreset(preset));
  final card = _map(jsonDecode(utf8.decode(t24Card())));
  final data = _map(card['data']);
  data['description'] = _privateInput;
  if (stateful) {
    data['extensions'] = {
      'dshgo': {
        'v': 1,
        'state': {
          'schema': {
            'type': 'object',
            'additionalProperties': false,
            'required': ['count'],
            'properties': {
              'count': {'type': 'integer', 'default': 0, 'minimum': 0, 'maximum': 9},
            },
          },
          'init': {'count': 0},
        },
      },
    };
  }
  final imported = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(card))));
  h.chatId = await h.engine.createChat(imported.id);
  return h;
}

class _Harness {
  _Harness(this.directory, {required this.deepseek, required this.thinking});
  final Directory directory;
  final bool deepseek;
  final bool thinking;
  late TavernEngine engine;
  late String chatId;
  int clients = 0;
  int keyReads = 0;
  final requests = <_Request>[];
  final responders = <http.Response Function(http.Request)>[];
  late final TavernModelConfig config = TavernModelConfig(
    apiKey: () async {
      keyReads++;
      return _key;
    },
    baseUrl: deepseek ? 'https://deepseek-wire.invalid/v1/' : 'https://generic-wire.invalid/service/v1/',
    model: deepseek ? 'caller-selected-main-model' : 'generic-current-model',
    deepseek: deepseek,
    thinking: thinking,
  );
  late final TavernModelClient model = TavernModelClient(
    clientFactory: () {
      clients++;
      return MockClient((request) async {
        requests.add((
          url: request.url,
          method: request.method,
          headers: {for (final entry in request.headers.entries) entry.key.toLowerCase(): entry.value},
          body: _map(jsonDecode(request.body)),
          text: request.body,
        ));
        if (responders.isEmpty) throw StateError('Unexpected additional HTTP request.');
        return responders.removeAt(0)(request);
      });
    },
  );

  void json(Json response, {int status = 200}) {
    final encoded = jsonEncode(response);
    responders.add(
      (_) => http.Response.bytes(
        utf8.encode(encoded),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
  }

  Future<void> open() async {
    engine = await TavernEngine.openDirectory(
      directory,
      config: config,
      modelClient: model,
      clock: () => _at,
      random: () => 0.25,
    );
  }

  Future<void> reopen() async {
    await engine.close();
    await open();
  }

  Future<void> dispose() async {
    await engine.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

T _db<T>(_Harness h, T Function(Database) action) {
  final db = sqlite3.open('${h.directory.path}/tavern.sqlite3');
  try {
    return action(db);
  } finally {
    db.close();
  }
}

int _kindCount(_Harness h, String kind) => _db(
  h,
  (db) =>
      db.select('SELECT COUNT(*) AS n FROM agent_runs WHERE chat_id = ? AND kind = ?', [h.chatId, kind]).single['n']!
          as int,
);

Json _saved(_Harness h, String id) => _db(
  h,
  (db) => Map<String, Object?>.from(
    db.select('SELECT id, kind, result_json, usage FROM agent_runs WHERE id = ? AND chat_id = ?', [
      id,
      h.chatId,
    ]).single,
  ),
);
