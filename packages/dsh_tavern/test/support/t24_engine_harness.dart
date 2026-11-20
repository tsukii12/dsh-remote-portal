import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';

/// Real engine/files/SQLite; only model events, clock and random are synthetic.
class T24Harness {
  T24Harness._(this.root, this.model, this.config, this.engine, this.characterId, this.chatId);

  static Future<T24Harness> open({bool thinking = true}) async {
    final root = await Directory.systemTemp.createTemp('dsh-t24-engine-');
    final model = T24Model();
    final config = TavernModelConfig(
      apiKey: () async => 'fixture-key',
      model: 'fixture-model',
      deepseek: true,
      thinking: thinking,
    );
    final engine = await TavernEngine.openDirectory(
      root,
      config: config,
      modelClient: model,
      clock: () => at,
      random: () => 0.25,
    );
    await engine.setPreset(t24Preset());
    final character = await engine.importCard(t24Card());
    final chatId = await engine.createChat(character.id);
    return T24Harness._(root, model, config, engine, character.id, chatId);
  }

  static final at = DateTime.utc(2026, 11, 10, 12);
  final Directory root;
  final T24Model model;
  final TavernModelConfig config;
  TavernEngine engine;
  final String characterId;
  final String chatId;

  Future<void> reopen() async {
    await engine.close();
    engine = await TavernEngine.openDirectory(
      root,
      config: config,
      modelClient: model,
      clock: () => at,
      random: () => 0.25,
    );
  }

  Future<TavernMessage> reply(String text, {TavernUsage? usage, String? chatId}) async {
    final call = model.prepare();
    final events = T24Events(engine.send(chatId ?? this.chatId, 'question'));
    await call.listening.future;
    call.add(ModelText(text));
    if (usage != null) call.add(ModelUsage(usage));
    await call.finish();
    await events.done.future;
    return events.values.whereType<TavernTurnDone>().single.message;
  }

  Future<void> dispose() async {
    await engine.close();
    for (final call in model.allCalls) {
      if (call.cancellation != null) {
        await call.close();
      } else {
        unawaited(call.close());
      }
    }
    if (await root.exists()) await root.delete(recursive: true);
  }
}

class T24Model extends TavernModelClient {
  final _pending = <T24Call>[];
  final allCalls = <T24Call>[];
  var generated = 0;

  T24Call prepare() {
    final call = T24Call();
    _pending.add(call);
    allCalls.add(call);
    return call;
  }

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    generated++;
    if (_pending.isEmpty) throw StateError('Unexpected model call.');
    final call = _pending.removeAt(0);
    call.cancellation = cancellation;
    call.body = body;
    return call._source.stream;
  }
}

class T24Call {
  T24Call() {
    _source = StreamController<ModelDelta>(
      sync: true,
      onListen: () {
        listening.complete();
      },
      onCancel: () {
        sourceCancelCalls++;
      },
    );
  }

  late final StreamController<ModelDelta> _source;
  final listening = Completer<void>();
  ModelCancellation? cancellation;
  Map<String, Object?>? body;
  var sourceCancelCalls = 0;

  void add(ModelDelta event) {
    _source.add(event);
  }

  void fail(TavernFailure kind, String detail) {
    _source.addError(TavernModelException(kind, detail), StackTrace.current);
  }

  Future<void> finish([String reason = 'stop']) {
    add(ModelFinished(reason));
    return close();
  }

  Future<void> close() => _source.close();
}

class T24Events {
  T24Events(Stream<TavernEvent> stream) {
    subscription = stream.listen(
      values.add,
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
  }

  final values = <TavernEvent>[];
  final done = Completer<void>();
  late final StreamSubscription<TavernEvent> subscription;
  Future<void> detach() => subscription.cancel();
}

Future<void> t24Pump() => Future<void>.delayed(Duration.zero);

ChatPreset t24Preset() {
  const ids = [
    'worldInfoBefore',
    'main',
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
    'continue_postfix': '',
    'new_chat_prompt': '',
    'new_group_chat_prompt': '',
    'new_example_chat_prompt': '',
    'continue_nudge_prompt': '',
    'group_nudge_prompt': '',
    'send_if_empty': '',
    'wi_format': '{0}',
    'personality_format': '{0}',
    'scenario_format': '{0}',
    'prompts': [
      for (final id in ids)
        {
          'identifier': id,
          'name': id,
          'role': 'system',
          'system_prompt': id == 'main' || id == 'jailbreak',
          'marker': id != 'main' && id != 'jailbreak',
          'content': '',
        },
    ],
    'prompt_order': [
      {
        'character_id': 100001,
        'order': [
          for (final id in ids) {'identifier': id, 'enabled': true},
        ],
      },
    ],
  });
}

Uint8List t24Card({String greeting = 'G'}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': 'Guide',
        'description': '',
        'personality': '',
        'scenario': '',
        'first_mes': greeting,
        'mes_example': '',
        'creator_notes': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'alternate_greetings': <String>[],
        'tags': <String>[],
        'creator': '',
        'character_version': '',
        'extensions': <String, Object?>{},
      },
    }),
  ),
);
