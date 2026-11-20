import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 't24_engine_harness.dart';

/// Production facade, files and SQLite. Only provider responses and dice are
/// controlled; each test still enters through the public turn/tool APIs.
class Stage1Harness {
  Stage1Harness._(this.root, this.model, this.config, this.engine, this.characterId, this.chatId, this.dice);

  static Future<Stage1Harness> open({
    bool state = true,
    bool thinking = false,
    bool deepseek = true,
    int? step,
    bool rules = false,
    Map<String, Object?>? cardTools,
    Stage1Dice? dice,
  }) async {
    final root = await Directory.systemTemp.createTemp('dsh-stage1-');
    final model = T24Model();
    final source = dice ?? Stage1Dice();
    final config = TavernModelConfig(
      apiKey: () async => 'fixture-key',
      model: 'fixture-model',
      deepseek: deepseek,
      thinking: thinking,
    );
    TavernEngine? engine;
    try {
      engine = await TavernEngine.openDirectory(
        root,
        config: config,
        modelClient: model,
        clock: () => T24Harness.at,
        random: () => 0.25,
        rollRandom: source.draw,
      );
      final preset = t24Preset().raw;
      preset['openai_max_context'] = 16384;
      preset['continue_prefill'] = false;
      preset['continue_nudge_prompt'] = 'Continue.';
      await engine.setPreset(ChatPreset(preset));
      final card = jsonDecode(utf8.decode(t24Card())) as Map<String, Object?>;
      final data = card['data']! as Map<String, Object?>;
      data['extensions'] = {
        'dshgo': {
          'v': 1,
          'tools': ?cardTools,
          if (state)
            'state': {
              'schema': {
                'type': 'object',
                'additionalProperties': false,
                'required': ['n', 'ticks'],
                'properties': {
                  'n': {'type': 'integer', 'minimum': 0, 'maximum': 1000, 'default': 0, 'x-dsh-step': ?step},
                  'ticks': {
                    'type': 'integer',
                    'default': 0,
                    'x-dsh-by': ['rules', 'user'],
                  },
                },
              },
              'rules': [
                if (rules)
                  {
                    'id': 'tick',
                    'when': true,
                    'once': false,
                    'do': [
                      {
                        'type': 'state',
                        'ops': [
                          {'op': 'add', 'path': '/ticks', 'value': 1, 'why': 'one terminal pass'},
                        ],
                      },
                    ],
                  },
              ],
            },
        },
      };
      final character = await engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(card))));
      final chatId = await engine.createChat(character.id);
      final harness = Stage1Harness._(root, model, config, engine, character.id, chatId, source);
      addTearDown(harness.dispose);
      return harness;
    } catch (_) {
      await engine?.close();
      await root.delete(recursive: true);
      rethrow;
    }
  }

  final Directory root;
  final T24Model model;
  final TavernModelConfig config;
  TavernEngine engine;
  final String characterId, chatId;
  final Stage1Dice dice;

  Future<Stage1Active> start({String input = 'question', String? continueNode, String? regenerateNode}) async {
    final call = model.prepare();
    final stream = continueNode != null
        ? engine.continueReply(chatId, continueNode)
        : regenerateNode != null
        ? engine.regenerate(chatId, regenerateNode)
        : engine.send(chatId, input);
    final events = T24Events(stream);
    await listening(call, events);
    return Stage1Active(call, events);
  }

  static Future<void> listening(T24Call call, T24Events events) => Future.any<void>([
    call.listening.future,
    events.done.future.then<void>((_) {
      throw TestFailure(
        'Turn ended before the expected request: ${events.values.whereType<TavernTurnFailed>().map((e) => e.detail)}',
      );
    }),
  ]);

  Future<TavernToolTurnSnapshot> turn(T24Events events) async {
    final started = events.values.whereType<TavernTurnStarted>().single;
    expect(started.logicalTurnId, isNotNull);
    return (await engine.readToolTurn(started.logicalTurnId!))!;
  }

  Future<void> enableMemory({String mode = 'ask'}) async {
    await engine.setToolPolicy({
      'remember': {'allow': true, 'mode': mode},
    });
  }

  T database<T>(T Function(Database database) action) {
    final database = sqlite3.open('${root.path}/tavern.sqlite3');
    database.execute('PRAGMA foreign_keys = ON');
    try {
      return action(database);
    } finally {
      database.close();
    }
  }

  Future<void> reopen() async {
    await engine.close();
    engine = await TavernEngine.openDirectory(
      root,
      config: config,
      modelClient: model,
      clock: () => T24Harness.at,
      random: () => 0.25,
      rollRandom: dice.draw,
    );
  }

  Future<void> dispose() async {
    await engine.close();
    for (final call in model.allCalls) {
      if (call.cancellation == null) {
        unawaited(call.close());
      } else {
        await call.close();
      }
    }
    if (await root.exists()) await root.delete(recursive: true);
  }
}

class Stage1Dice {
  int calls = 0;
  int Function(int max) value = (_) => 0;
  int draw(int max) {
    calls++;
    return value(max);
  }
}

class Stage1Active {
  const Stage1Active(this.call, this.events);
  final T24Call call;
  final T24Events events;
}

class Stage1Call {
  Stage1Call(this.index, this.id, this.name, Map<String, Object?> parameters) : arguments = jsonEncode(parameters);
  Stage1Call.raw(this.index, this.id, this.name, this.arguments);
  final int index;
  final String id, name, arguments;
  ModelToolFragment get fragment =>
      ModelToolFragment(index: index, id: id, type: 'function', name: name, arguments: arguments);
  Map<String, Object?> get wire => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': arguments},
  };
}

Future<void> stage1Finish(
  T24Call call, {
  List<Stage1Call> tools = const [],
  String? content,
  String? reason = 'stop',
  bool snapshot = true,
  ModelUsageReport? usageReport,
  TavernUsage? usage,
}) async {
  if (content != null) call.add(ModelText(content));
  for (final tool in tools) {
    call.add(tool.fragment);
  }
  if (usage != null) call.add(ModelUsage(usage, report: usageReport));
  final message = <String, Object?>{
    'role': 'assistant',
    'content': content,
    if (tools.isNotEmpty) 'tool_calls': [for (final tool in tools) tool.wire],
  };
  call.add(
    ModelFinished(
      reason,
      assistantSnapshot: snapshot
          ? ModelAssistantSnapshot.fromCustomMessage(message, callIndexes: [for (final tool in tools) tool.index])
          : null,
      finalUsageReport: usageReport,
    ),
  );
  await call.close();
}

Map<String, Object?> stage1Set(int value) => {'op': 'set', 'path': '/n', 'value': value, 'why': 'fixture'};
Map<String, Object?> stage1Add(int value) => {'op': 'add', 'path': '/n', 'value': value, 'why': 'fixture'};
Map<String, Object?> stage1Map(Object? value) => value! as Map<String, Object?>;
List<Map<String, Object?>> stage1Rows(Object? value) =>
    value is List<Object?> ? [for (final item in value) stage1Map(item)] : [];

ModelUsageReport stage1Usage({required int index, required int prompt, required int completion, required int cache}) =>
    ModelUsageReport.fromJson({
      'version': 1,
      'origin': 'provider',
      'transport': 'custom',
      'observationIndex': index,
      'observationComplete': true,
      'rawPresent': true,
      'raw': {'prompt_tokens': prompt, 'completion_tokens': completion, 'prompt_cache_hit_tokens': cache},
      'fields': {
        for (final entry in {
          'prompt_tokens': prompt,
          'completion_tokens': completion,
          'cache_hit_tokens': cache,
        }.entries)
          entry.key: {
            'state': 'reported',
            'value': entry.value,
            'originalPresence': true,
            'sourcePath': entry.key == 'cache_hit_tokens' ? 'usage.prompt_cache_hit_tokens' : 'usage.${entry.key}',
          },
      },
    });
