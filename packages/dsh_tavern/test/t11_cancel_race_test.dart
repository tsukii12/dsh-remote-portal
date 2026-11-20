import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

// Offline recovery draft. This file has not been compiled, formatted, or run.
// The model stream is controlled; the facade and SQLite store are real.
// HTTP/SSE decoding is covered separately by t11_reasoning_gate_test.dart.
void main() {
  test('explicit stop and observer detachment apply terminal regex once despite a late producer end', () async {
    final h = await _open(thinking: true);
    addTearDown(h.dispose);
    final chatId = await _freshChat(h.engine);
    await h.engine.setSettings({
      'globalRegexScripts': [_script(2, 'bodyWrites'), _script(6, 'reasoningWrites')],
    });
    final events = <TavernEvent>[];
    final outputSeen = Completer<void>();
    var textSeen = false;
    var reasoningSeen = false;
    final subscription = h.engine.send(chatId, 'QUESTION').listen((event) {
      events.add(event);
      if (event is TavernTextDelta) {
        textSeen = true;
      }
      if (event is TavernReasoningDelta) {
        reasoningSeen = true;
      }
      if (textSeen && reasoningSeen && !outputSeen.isCompleted) {
        outputSeen.complete();
      }
    });
    await h.model.listening.future;
    h.model.add(const ModelReasoning('THOUGHT'));
    h.model.add(const ModelText('BODY'));
    await outputSeen.future;
    expect(events.whereType<TavernTextDelta>().map((event) => event.text).join(), 'BODY');
    expect(events.whereType<TavernReasoningDelta>().map((event) => event.text).join(), 'THOUGHT');
    expect(_terminals(events), isEmpty);

    // T24 observer cancellation only detaches. Explicitly stop the turn to
    // retain this original cancellation/late-producer race regression.
    h.engine.stop(chatId);
    // Do not await this cancellation before offering the late end: both
    // completion paths must be ready before yielding to a microtask.
    final consumerCancellation = subscription.cancel();
    final producerClose = h.model.endAfterConsumerCancellation();
    expect(h.model.lateEndSawCancellation, isTrue);
    expect(h.model.finishedEventsAdded, 1);
    // lateEndHadListener is recorded, not asserted. A correct implementation
    // may already have detached its upstream subscription at this point.
    await consumerCancellation;
    await h.engine.close(); // An independent lifecycle barrier, unlike stop().
    await producerClose; // This is the model source, not the cancelled facade controller.
    expect(h.model.sourceCancelCalls, 1);
    expect(_terminals(events).length, lessThanOrEqualTo(1));

    await h.reopenAfterClose();
    final path = await h.engine.path(chatId);
    expect(path.map((message) => message.text), ['G', 'QUESTION', '1|BODY']);
    expect(path.last.reasoning, '1|THOUGHT');
    expect(h.engine.variables(chatId)['bodyWrites'], 1);
    expect(h.engine.variables(chatId)['reasoningWrites'], 1);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('explicit stop after only disabled fresh reasoning rolls back rather than retaining a partial reply', () async {
    final h = await _open(thinking: false);
    addTearDown(h.dispose);
    final chatId = await _freshChat(h.engine);
    await h.engine.setSettings({
      'globalRegexScripts': [_script(2, 'bodyWrites'), _script(6, 'reasoningWrites')],
    });
    final before = await h.engine.path(chatId);
    final beforeIds = before.map((message) => message.nodeId).toList();
    final beforeVariables = h.engine.variables(chatId);
    final events = <TavernEvent>[];
    final subscription = h.engine.send(chatId, 'ROLL_BACK_THIS_USER').listen(events.add);
    await h.model.listening.future;

    // A sync controller offers this delta to the current model listener
    // before add() returns. No facade event is needed as a progress signal.
    h.model.add(const ModelReasoning('IGNORED'));
    expect(h.model.reasoningEventsAdded, 1);
    h.engine.stop(chatId);
    final consumerCancellation = subscription.cancel();
    final producerClose = h.model.endAfterConsumerCancellation();
    expect(h.model.lateEndSawCancellation, isTrue);
    expect(h.model.finishedEventsAdded, 1);
    await consumerCancellation;
    await h.engine.close();
    await producerClose;
    expect(h.model.sourceCancelCalls, 1);
    expect(_terminals(events).length, lessThanOrEqualTo(1));

    await h.reopenAfterClose();
    final after = await h.engine.path(chatId);
    expect(after.map((message) => message.nodeId), beforeIds);
    expect(after.map((message) => message.text), before.map((message) => message.text));
    expect(h.engine.variables(chatId), beforeVariables);
    expect(h.engine.variables(chatId).containsKey('bodyWrites'), isFalse);
    expect(h.engine.variables(chatId).containsKey('reasoningWrites'), isFalse);
  }, timeout: const Timeout(Duration(seconds: 15)));
}

final _at = DateTime.utc(2026, 11, 10, 12);

Future<_Harness> _open({required bool thinking}) async {
  final directory = await Directory.systemTemp.createTemp('dsh-t11-cancel-race-');
  final model = _ControlledModel();
  final config = TavernModelConfig(
    apiKey: () async => 'fixture-key',
    model: 'fixture-model',
    deepseek: true,
    thinking: thinking,
  );
  final engine = await TavernEngine.openDirectory(
    directory,
    config: config,
    modelClient: model,
    clock: () => _at,
    random: () => 0.25,
  );
  final h = _Harness(directory, config, model, engine);
  await engine.setPreset(_preset());
  return h;
}

class _Harness {
  _Harness(this.directory, this.config, this.model, this.engine);
  final Directory directory;
  final TavernModelConfig config;
  final _ControlledModel model;
  TavernEngine engine;

  Future<void> reopenAfterClose() async {
    engine = await TavernEngine.openDirectory(
      directory,
      config: config,
      modelClient: model,
      clock: () => _at,
      random: () => 0.25,
    );
  }

  Future<void> dispose() async {
    await engine.close();
    await directory.delete(recursive: true);
  }
}

class _ControlledModel extends TavernModelClient {
  _ControlledModel() {
    _source = StreamController<ModelDelta>(
      sync: true,
      onListen: () => listening.complete(),
      onCancel: () {
        sourceCancelCalls++;
      },
    );
  }

  late final StreamController<ModelDelta> _source;
  final listening = Completer<void>();
  ModelCancellation? _cancellation;
  var calls = 0;
  var sourceCancelCalls = 0;
  var reasoningEventsAdded = 0;
  var finishedEventsAdded = 0;
  bool? lateEndSawCancellation;
  bool? lateEndHadListener;

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    if (calls++ != 0) {
      throw StateError('This fixture expects one generation only.');
    }
    _cancellation = cancellation;
    return _source.stream;
  }

  void add(ModelDelta delta) {
    if (delta is ModelReasoning) {
      reasoningEventsAdded++;
    }
    _source.add(delta);
  }

  Future<void> endAfterConsumerCancellation() {
    lateEndSawCancellation = _cancellation?.isCancelled;
    lateEndHadListener = _source.hasListener;
    if (lateEndSawCancellation != true) {
      throw StateError('The consumer cancellation did not set the model cancellation flag.');
    }
    finishedEventsAdded++;
    _source.add(const ModelFinished('stop'));
    return _source.close().then<void>((_) {});
  }
}

Future<String> _freshChat(TavernEngine engine) async {
  final card = await engine.importCard(_card());
  return engine.createChat(card.id);
}

Iterable<TavernEvent> _terminals(List<TavernEvent> events) =>
    events.where((event) => event is TavernTurnDone || event is TavernTurnFailed);

Map<String, Object?> _script(int placement, String variable) => {
  'id': variable,
  'scriptName': variable,
  'findRegex': r'^([\s\S]+)$',
  'replaceString': '{{incvar::$variable}}|\$1',
  'placement': [placement],
  'trimStrings': <String>[],
  'disabled': false,
  'markdownOnly': false,
  'promptOnly': false,
  'runOnEdit': false,
  'substituteRegex': 0,
  'minDepth': null,
  'maxDepth': null,
};

ChatPreset _preset() {
  const identifiers = [
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
      for (final id in identifiers)
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
          for (final id in identifiers) {'identifier': id, 'enabled': true},
        ],
      },
    ],
  });
}

Uint8List _card() => Uint8List.fromList(
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
      },
    }),
  ),
);
