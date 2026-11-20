import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

// Real facade, SQLite, prompt assembly, macros and regex execution. Only the
// model deltas, time and generation entropy are synthetic.
void main() {
  for (final mode in ['modern', 'legacy']) {
    test('$mode shared turn context sees the user appended after its first expansion', () async {
      final h = await _open(mode);
      await h.engine.setPreset(_preset(main: 'LAST={{lastMessage}}|USER={{lastUserMessage}}'));
      final chat = await h.chat();
      h.model.reply(['OK']);
      _done(await h.engine.send(chat, 'U={{lastMessage}}|LIMIT={{maxPrompt}}').toList());
      final path = await h.engine.path(chat);
      expect(path[1].text, 'U=G|LIMIT=3840');
      expect(_bodyText(h.model.bodies.single), contains('LAST=U=G|LIMIT=3840|USER=U=G|LIMIT=3840'));
    });

    test('$mode a cached first history item is refreshed after greeting expansion replaces it', () async {
      final h = await _open(mode);
      await h.engine.setPreset(_preset(main: 'FIRST={{lastCharMessage}}'));
      final chat = await h.imported(
        'GREET={{getvar::stage}}',
        metadata: {
          'variables': {'stage': 'old'},
        },
      );
      h.model.reply(['OK']);
      // lastCharMessage reads the original first node before history[0] is
      // replaced. Both dialects retain its inserted macro text in this call.
      _done(await h.engine.send(chat, '{{lastCharMessage}}{{setvar::stage::new}}').toList());
      expect((await h.engine.path(chat)).first.text, 'GREET=new');
      final body = _bodyText(h.model.bodies.single);
      expect(body, contains('FIRST=GREET=new'));
      expect(body, isNot(contains('FIRST=GREET={{getvar::stage}}')));
    });

    test('$mode writeback sees complete raw append and the replacement of a continued history item', () async {
      final h = await _open(mode);
      await h.engine.setPreset(_preset(main: 'BEFORE={{lastMessage}}', continuePostfix: '~'));
      final chat = await h.chat();
      await h.engine.setSettings({
        'globalRegexScripts': [_rule('writeback', r'^[\s\S]+$', 'WRITE={{lastMessage}}')],
      });
      h.model.reply(['RAW', '-A']);
      final firstEvents = await h.engine.send(chat, 'QUESTION').toList();
      final first = _done(firstEvents);
      expect(firstEvents.whereType<TavernTextDelta>().map((event) => event.text).join(), 'RAW-A');
      expect(first.text, 'WRITE=RAW-A');
      expect(_bodyText(h.model.bodies.first), contains('BEFORE=QUESTION'));

      h.model.reply(['RAW', '-B']);
      final continued = _done(await h.engine.continueReply(chat, first.nodeId).toList());
      expect(_bodyText(h.model.bodies.last), contains('BEFORE=WRITE=RAW-A'));
      expect(continued.nodeId, first.nodeId);
      expect(continued.text, 'WRITE=WRITE=RAW-A~RAW-B');
      expect((await h.engine.path(chat)).last.text, continued.text);
    });

    test('$mode late outlets stay live and separate field expansions keep fresh variables and random draws', () async {
      var draws = 0;
      final h = await _open(mode, random: () => draws++ == 0 ? 0.0 : 0.99);
      await h.engine.setPreset(
        _preset(
          main: 'P1={{description}}/{{random::low::high}}/OUT={{outlet::slot}}',
          probe: 'P2={{description}}/{{random::low::high}}',
        ),
      );
      final chat = await h.imported(
        'G',
        card: {'description': '<CHAR>{{incvar::field}}'},
        metadata: {
          'variables': {'field': 0},
        },
      );
      await h.engine.putLorebook('late-outlet', {
        'entries': <String, Object?>{
          '0': <String, Object?>{
            'uid': 0,
            'key': <String>[],
            'constant': true,
            'content': 'SLOT',
            'position': 7,
            'outletName': 'slot',
            'order': 100,
            'useProbability': false,
          },
        },
      });
      await h.engine.bindLorebooks(['late-outlet'], source: WorldInfoSource.global);
      h.model.reply(['OK']);
      // The context already exists while this outlet is empty. WI fills the
      // same map before the two independently expanded preset documents.
      _done(await h.engine.send(chat, '{{outlet::slot}}Q').toList());
      expect((await h.engine.path(chat))[1].text, 'Q');
      final body = _bodyText(h.model.bodies.single);
      final first = RegExp(r'P1=Guide(\d+)/low/OUT=SLOT').firstMatch(body);
      final second = RegExp(r'P2=Guide(\d+)/high').firstMatch(body);
      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(
        int.parse(second![1]!),
        greaterThan(int.parse(first![1]!)),
        reason: 'The raw description is evaluated again in the next expansion, not reused from the turn.',
      );
      expect(draws, 2);
    });

    test('$mode display uses copied state while an active turn retains its own history and variables', () async {
      final h = await _open(mode);
      final chat = await h.chat();
      await h.engine.setGlobalVariables({'baseline': 'kept'});
      await h.engine.setSettings({
        'globalRegexScripts': [
          _rule(
            'display',
            r'^DISPLAY$',
            '{{incvar::display}}/{{incglobalvar::display}}/{{lastMessage}}/{{random::one::two}}',
            markdownOnly: true,
          ),
          _rule('writeback', r'^RAW$', '{{getvar::display}}/{{getglobalvar::display}}/{{lastMessage}}'),
        ],
      });
      final held = h.model.hold(['RAW']);
      final running = h.engine.send(chat, '{{setvar::display::10}}{{setglobalvar::display::20}}Q').toList();
      await held.started.future;
      final reply = (await h.engine.path(chat)).last;
      final local = h.engine.variables(chat);
      final global = h.engine.globalVariables;
      final inspection = jsonEncode((await h.engine.inspectTurn(chat))!.toJson());
      final draws = h.randomCalls;

      final first = await h.engine.displayText(chat, nodeId: reply.nodeId, text: 'DISPLAY');
      final second = await h.engine.displayText(chat, nodeId: reply.nodeId, text: 'DISPLAY');
      expect(first.warnings, isEmpty);
      expect(first.text, anyOf('11/21/DISPLAY/one', '11/21/DISPLAY/two'));
      expect(second.text, first.text);
      expect(h.engine.variables(chat), local);
      expect(h.engine.globalVariables, global);
      expect(h.randomCalls, draws);
      expect(jsonEncode((await h.engine.inspectTurn(chat))!.toJson()), inspection);
      expect((await h.engine.path(chat)).last.text, '');

      held.release();
      expect(_done(await running).text, '10/20/RAW');
      expect(h.engine.variables(chat), local);
      expect(h.engine.globalVariables, global);
    });
  }
}

Future<_Harness> _open(String mode, {double Function()? random}) async {
  final directory = await Directory.systemTemp.createTemp('dsh-t23-macro-environment-');
  final h = _Harness(directory, random);
  h.engine = await TavernEngine.openDirectory(
    directory,
    config: TavernModelConfig(
      apiKey: () async => 'fixture-key',
      model: 'fixture-model',
      deepseek: true,
      thinking: true,
    ),
    modelClient: h.model,
    clock: () => _at,
    random: () {
      h.randomCalls++;
      return h.random?.call() ?? 0.25;
    },
  );
  addTearDown(() async {
    await h.engine.close();
    await directory.delete(recursive: true);
  });
  await h.engine.setSettings({'macroEngine': mode});
  await h.engine.setPreset(_preset());
  return h;
}

class _Harness {
  _Harness(this.directory, this.random);
  final Directory directory;
  final double Function()? random;
  final model = _Model();
  late TavernEngine engine;
  var randomCalls = 0;

  Future<String> chat() async => engine.createChat((await engine.importCard(_card())).id);

  Future<String> imported(
    String greeting, {
    Map<String, Object?> card = const {},
    Map<String, Object?> metadata = const {},
  }) async {
    final character = await engine.importCard(_card(card));
    final document = StChatDocument(
      fileName: 'macro-environment.jsonl',
      header: {'user_name': 'User', 'character_name': 'Guide', 'chat_metadata': metadata},
      messages: [
        <String, Object?>{
          'name': 'Guide',
          'is_user': false,
          'is_system': false,
          'send_date': _at.toIso8601String(),
          'mes': greeting,
        },
      ],
    );
    return (await engine.importChats(character.id, [
      TavernChatFile(fileName: document.fileName, bytes: document.encode()),
    ])).chatIds.single;
  }
}

class _Plan {
  _Plan(this.chunks, {bool held = false}) : gate = held ? Completer<void>() : null;
  final List<String> chunks;
  final started = Completer<void>();
  final Completer<void>? gate;
  void release() {
    final pending = gate;
    if (pending != null && !pending.isCompleted) pending.complete();
  }
}

class _Model extends TavernModelClient {
  final plans = Queue<_Plan>();
  final bodies = <Map<String, Object?>>[];

  void reply(List<String> chunks) => plans.add(_Plan(chunks));
  _Plan hold(List<String> chunks) {
    final plan = _Plan(chunks, held: true);
    plans.add(plan);
    return plan;
  }

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) async* {
    final plan = plans.removeFirst();
    bodies.add(jsonDecode(jsonEncode(body)) as Map<String, Object?>);
    plan.started.complete();
    final gate = plan.gate;
    if (gate != null) await cancellation.wait(gate.future);
    for (final chunk in plan.chunks) {
      cancellation.check();
      yield ModelText(chunk);
    }
    cancellation.check();
    yield const ModelFinished('stop');
  }
}

TavernMessage _done(List<TavernEvent> events) {
  expect(events.whereType<TavernTurnFailed>(), isEmpty);
  return events.whereType<TavernTurnDone>().single.message;
}

String _bodyText(Map<String, Object?> body) => (body['messages']! as List<Object?>)
    .cast<Map<String, Object?>>()
    .map((message) => message['content'] ?? '')
    .join('\n');

Map<String, Object?> _rule(String id, String find, String replacement, {bool markdownOnly = false}) => {
  'id': id,
  'scriptName': id,
  'findRegex': find,
  'replaceString': replacement,
  'placement': [2],
  'trimStrings': <String>[],
  'disabled': false,
  'markdownOnly': markdownOnly,
  'promptOnly': false,
  'runOnEdit': false,
  'substituteRegex': 0,
};

ChatPreset _preset({String main = '', String probe = '', String continuePostfix = ''}) {
  const identifiers = [
    'worldInfoBefore',
    'main',
    'probe',
    'worldInfoAfter',
    'charDescription',
    'charPersonality',
    'scenario',
    'personaDescription',
    'dialogueExamples',
    'chatHistory',
    'jailbreak',
  ];
  return ChatPreset({
    'openai_max_context': 4096,
    'openai_max_tokens': 256,
    'stream_openai': true,
    'names_behavior': 0,
    'continue_prefill': true,
    'continue_postfix': continuePostfix,
    'new_chat_prompt': '',
    'new_group_chat_prompt': '',
    'new_example_chat_prompt': '',
    'continue_nudge_prompt': '',
    'group_nudge_prompt': '',
    'impersonation_prompt': '',
    'send_if_empty': '',
    'wi_format': '{0}',
    'personality_format': '{0}',
    'scenario_format': '{0}',
    'prompts': <Object?>[
      for (final id in identifiers)
        <String, Object?>{
          'identifier': id,
          'name': id,
          'role': 'system',
          'system_prompt': id == 'main' || id == 'jailbreak',
          'marker': id != 'main' && id != 'jailbreak' && id != 'probe',
          'content': id == 'main'
              ? main
              : id == 'probe'
              ? probe
              : '',
        },
    ],
    'prompt_order': <Object?>[
      <String, Object?>{
        'character_id': 100001,
        'order': <Object?>[
          for (final id in identifiers) <String, Object?>{'identifier': id, 'enabled': true},
        ],
      },
    ],
  });
}

Uint8List _card([Map<String, Object?> fields = const {}]) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': <String, Object?>{
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

final _at = DateTime.utc(2026, 11, 10);
