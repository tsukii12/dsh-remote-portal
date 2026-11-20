import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late TavernEngine engine;
  late _Model model;
  Future<TavernEngine> open() => TavernEngine.openDirectory(
    directory,
    config: TavernModelConfig(apiKey: () async => 'fixture-only', model: 'fixture'),
    modelClient: model,
    clock: () => _at,
    random: () => 0.25,
  );
  Future<(String, String)> chat([Map<String, Object?> fields = const {}]) async {
    final card = await engine.importCard(_card(fields));
    return (card.id, await engine.createChat(card.id));
  }

  Future<void> installTrigger(String sql) async {
    await engine.close();
    final database = sqlite3.open('${directory.path}/tavern.sqlite3');
    try {
      database.execute(sql);
    } finally {
      database.close();
    }
    engine = await open();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dsh-inspection-');
    model = _Model();
    engine = await open();
  });
  tearDown(() async {
    await engine.close();
    model.dispose();
    await directory.delete(recursive: true);
  });

  test('actual assembly, WI reasons and reported usage survive reopen', () async {
    final (cardId, chatId) = await chat({
      'description': '卡片{{incvar::seen}}',
      'character_book': {
        'name': '灯塔书',
        'entries': [
          {
            'id': 7,
            'keys': ['灯塔'],
            'content': '世界书信息',
            'enabled': true,
            'insertion_order': 100,
            'position': 'before_char',
            'extensions': {},
          },
        ],
      },
    });
    await engine.setSettings({
      'authorNote': {'content': '作者注释', 'placement': 'beforeMain'},
    }, chatId: chatId);
    model.reply(
      '回答',
      usage: const TavernUsage(promptTokens: 80, cacheHitTokens: 60, completionTokens: 8, model: 'fixture'),
    );
    final done = _done(await engine.send(chatId, '看看灯塔🐋').toList());
    final facade = engine as Tavern;
    final inspection = (await facade.inspectTurn(chatId, nodeId: done.nodeId))!;
    expect(inspection.status, TavernInspectionStatus.completed);
    expect(inspection.prompt!.body, model.bodies.single);
    expect(inspection.tokenCountLabel, '估算');
    expect(inspection.reportedUsage!.cacheHitTokens, 60);
    final sources = inspection.prompt!.afterPostProcessing.expand((segment) => segment.sources).toList();
    expect(sources.map((source) => source.kind), containsAll(['preset', 'card', 'worldInfo', 'authorNote', 'history']));
    final hits = (inspection.worldInfo['activated']! as List<Object?>).cast<Map<String, Object?>>();
    expect(hits.single['uid'], '7');
    expect(hits.single['reason'], 'keywords');
    expect(hits.single['primaryKey'], '灯塔');
    final beforeVariables = engine.variables(chatId);
    final snapshot = jsonEncode(inspection.toJson());
    await engine.inspectTurn(chatId);
    await engine.inspectTurn(chatId, nodeId: done.nodeId);
    expect(engine.variables(chatId), beforeVariables);
    await engine.updateCharacterFields(cardId, {'description': '改后的卡片'});
    expect(jsonEncode((await engine.inspectTurn(chatId, nodeId: done.nodeId))!.toJson()), snapshot);
    await engine.close();
    engine = await open();
    expect(jsonEncode((await engine.inspectTurn(chatId, nodeId: done.nodeId))!.toJson()), snapshot);
    expect((await engine.inspectTurn(chatId))!.nodeId, done.nodeId);
  });

  test('branch inspection stays attached to its node, deletion does not redirect it', () async {
    final (_, chatId) = await chat();
    model.reply('A', usage: const TavernUsage(promptTokens: 11));
    final first = _done(await engine.send(chatId, '第一问').toList());
    final original = jsonEncode((await engine.inspectTurn(chatId, nodeId: first.nodeId))!.toJson());
    model.reply('B', usage: const TavernUsage(promptTokens: 22));
    final sibling = _done(await engine.regenerate(chatId, first.nodeId).toList());
    await engine.selectSibling(chatId, sibling.nodeId, 0);
    expect((await engine.path(chatId)).last.nodeId, first.nodeId);
    expect((await engine.inspectTurn(chatId))!.nodeId, sibling.nodeId);
    expect(jsonEncode((await engine.inspectTurn(chatId, nodeId: first.nodeId))!.toJson()), original);
    await engine.deleteFrom(chatId, sibling.nodeId);
    expect(await engine.inspectTurn(chatId, nodeId: sibling.nodeId), isNull);
    expect(await engine.inspectTurn(chatId), isNull);
    expect(jsonEncode((await engine.inspectTurn(chatId, nodeId: first.nodeId))!.toJson()), original);
  });
  test('successful empty completion still persists its terminal inspection', () async {
    final (_, chatId) = await chat();
    model.reply('');
    final done = _done(await engine.send(chatId, '问').toList());
    expect(done.text, isEmpty);
    final saved = (await engine.inspectTurn(chatId, nodeId: done.nodeId))!;
    expect(saved.status, TavernInspectionStatus.completed);
    expect(saved.finishedAt, _at);
    expect(saved.reportedUsage, isNull);
    await engine.close();
    engine = await open();
    expect((await engine.inspectTurn(chatId))!.status, TavernInspectionStatus.completed);
  });

  test('continuation inspection never inherits the old response usage', () async {
    final (_, chatId) = await chat();
    model.reply('原文', usage: const TavernUsage(promptTokens: 17, cacheHitTokens: 13));
    final first = _done(await engine.send(chatId, '问').toList());
    final original = (await engine.inspectTurn(chatId, nodeId: first.nodeId))!;
    model.reply('续文');
    _done(await engine.continueReply(chatId, first.nodeId).toList());
    final continued = (await engine.inspectTurn(chatId, nodeId: first.nodeId))!;
    expect(continued.generationType, 'continue');
    expect(continued.reportedUsage, isNull);
    expect(original.reportedUsage!.promptTokens, 17);
    model.reply('再续', usage: const TavernUsage());
    _done(await engine.continueReply(chatId, first.nodeId).toList());
    final zero = (await engine.inspectTurn(chatId, nodeId: first.nodeId))!;
    expect(zero.reportedUsage, isNotNull);
    expect(zero.reportedUsage!.promptTokens, 0);
  });

  test('empty failed continuation preserves node evidence and records the failed attempt', () async {
    final (_, chatId) = await chat();
    model.reply('原文', usage: const TavernUsage(promptTokens: 12));
    final first = _done(await engine.send(chatId, '问').toList());
    final original = jsonEncode((await engine.inspectTurn(chatId, nodeId: first.nodeId))!.toJson());
    model.fail(TavernFailure.network);
    final failed = (await engine.continueReply(chatId, first.nodeId).toList()).whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.network);
    final latest = (await engine.inspectTurn(chatId))!;
    expect(latest.status, TavernInspectionStatus.failed);
    expect(latest.failure, TavernFailure.network);
    expect(latest.nodeId, isNull);
    expect(latest.prompt, isNotNull);
    expect(latest.reportedUsage, isNull);
    expect(jsonEncode((await engine.inspectTurn(chatId, nodeId: first.nodeId))!.toJson()), original);
    await engine.close();
    engine = await open();
    expect((await engine.inspectTurn(chatId))!.failure, TavernFailure.network);
    expect(jsonEncode((await engine.inspectTurn(chatId, nodeId: first.nodeId))!.toJson()), original);
  });

  test('impersonation retains a latest snapshot without adding a stored node', () async {
    final (_, chatId) = await chat();
    final before = (await engine.path(chatId)).map((message) => message.nodeId).toList();
    model.reply('代写内容', usage: const TavernUsage(promptTokens: 20));
    final done = _done(await engine.impersonate(chatId).toList());
    expect((await engine.path(chatId)).map((message) => message.nodeId), before);
    final inspection = (await engine.inspectTurn(chatId))!;
    expect(inspection.generationType, 'impersonate');
    expect(inspection.nodeId, isNull);
    expect(inspection.reportedUsage!.promptTokens, 20);
    expect(await engine.inspectTurn(chatId, nodeId: done.nodeId), isNull);
    await engine.close();
    engine = await open();
    expect((await engine.inspectTurn(chatId))!.generationType, 'impersonate');
  });

  test('deleting ephemeral context removes its snapshot across reopen', () async {
    final (_, chatId) = await chat();
    final context = (await engine.path(chatId)).single.nodeId;
    model.reply('临时代写');
    _done(await engine.impersonate(chatId).toList());
    expect((await engine.inspectTurn(chatId))!.contextNodeId, context);
    await engine.close();
    engine = await open();
    await engine.deleteFrom(chatId, context);
    expect(await engine.inspectTurn(chatId), isNull);
    await engine.close();
    engine = await open();
    expect(await engine.inspectTurn(chatId), isNull);
  });

  test('failed send anchors to existing context, not its rolled-back user node', () async {
    final (_, chatId) = await chat();
    final context = (await engine.path(chatId)).single.nodeId;
    model.fail(TavernFailure.noKey);
    final events = await engine.send(chatId, '应回到输入框').toList();
    expect(events.whereType<TavernTurnFailed>().single.partial, isNull);
    expect((await engine.path(chatId)).single.nodeId, context);
    final latest = (await engine.inspectTurn(chatId))!;
    expect(latest.contextNodeId, context);
    expect(latest.nodeId, isNull);
    expect(latest.prompt, isNotNull);
    expect(latest.failure, TavernFailure.noKey);
    await engine.close();
    engine = await open();
    expect((await engine.inspectTurn(chatId))!.failure, TavernFailure.noKey);
    await engine.deleteFrom(chatId, context);
    expect(await engine.inspectTurn(chatId), isNull);
  });

  test('a global-file failure after successful empty rollback never returns its deleted reply', () async {
    final (_, chatId) = await chat();
    final before = (await engine.path(chatId)).map((message) => message.nodeId).toList();
    await Directory('${directory.path}/settings.json.writing').create();
    model.fail(TavernFailure.network);
    final failed = (await engine.send(chatId, '{{setglobalvar::audit::1}}问').toList())
        .whereType<TavernTurnFailed>()
        .single;
    expect(failed.kind, TavernFailure.server);
    expect(failed.detail, startsWith('turn_storage_failure'));
    expect(failed.partial, isNull);
    expect((await engine.path(chatId)).map((message) => message.nodeId), before);
    final latest = (await engine.inspectTurn(chatId))!;
    expect(latest.failure, TavernFailure.server);
    expect(latest.nodeId, isNull);
    expect(latest.prompt, isNotNull);
    await engine.close();
    engine = await open();
    expect((await engine.inspectTurn(chatId))!.failure, TavernFailure.server);
    expect((await engine.path(chatId)).map((message) => message.nodeId), before);
  });

  test('failure before assembly does not present the previous successful prompt', () async {
    final (_, chatId) = await chat();
    model.reply('旧回答', usage: const TavernUsage(promptTokens: 10));
    final first = _done(await engine.send(chatId, '问').toList());
    await engine.putLorebook('budget-proof', {
      'entries': {
        '4': {'uid': 4, 'constant': true, 'ignoreBudget': true, 'content': '已实际算出的命中', 'position': 0},
      },
    });
    await engine.bindLorebooks(['budget-proof'], chatId: chatId);
    await engine.setPreset(
      ChatPreset({...ChatPreset.stDefault().raw, 'openai_max_context': 1, 'openai_max_tokens': 1}),
      chatId: chatId,
    );
    final failure = (await engine.send(chatId, '太长').toList()).whereType<TavernTurnFailed>().single;
    expect(failure.kind, TavernFailure.contextTooLong);
    expect(model.bodies, hasLength(1));
    final inspection = (await engine.inspectTurn(chatId))!;
    expect(inspection.prompt, isNull);
    expect(inspection.reportedUsage, isNull);
    expect(inspection.failure, TavernFailure.contextTooLong);
    final hits = (inspection.worldInfo['activated']! as List<Object?>).cast<Map<String, Object?>>();
    expect(hits.single['bookId'], 'budget-proof');
    expect((await engine.inspectTurn(chatId, nodeId: first.nodeId))!.reportedUsage!.promptTokens, 10);
  });
  test('streaming usage and cancellation remain attached to the partial node', () async {
    final (_, chatId) = await chat();
    final held = model.hold();
    final running = engine.send(chatId, '问').toList();
    await held.connected;
    held.stream.add(const ModelText('部分正文'));
    held.stream.add(const ModelUsage(TavernUsage(promptTokens: 9, cacheHitTokens: 7)));
    await Future<void>.delayed(Duration.zero);
    final active = (await engine.inspectTurn(chatId))!;
    expect(active.status, TavernInspectionStatus.ready);
    expect(active.reportedUsage!.cacheHitTokens, 7);
    engine.stop(chatId);
    final failed = (await running).whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.cancelled);
    final saved = (await engine.inspectTurn(chatId, nodeId: failed.partial!.nodeId))!;
    expect(saved.status, TavernInspectionStatus.failed);
    expect(saved.failure, TavernFailure.cancelled);
    expect(saved.reportedUsage!.cacheHitTokens, 7);
    await engine.close();
    engine = await open();
    expect((await engine.inspectTurn(chatId))!.nodeId, failed.partial!.nodeId);
  });

  test('busy rejection and cross-chat lookup do not replace an active inspection', () async {
    final (_, chatId) = await chat();
    final (_, otherId) = await chat();
    final held = model.hold();
    final running = engine.send(chatId, '正在生成').toList();
    await held.connected;
    final active = (await engine.inspectTurn(chatId))!;
    final before = jsonEncode(active.toJson());
    final rejected = (await engine.send(chatId, '重复请求').toList()).whereType<TavernTurnFailed>().single;
    expect(rejected.kind, TavernFailure.busy);
    expect(jsonEncode((await engine.inspectTurn(chatId))!.toJson()), before);
    expect(await engine.inspectTurn(otherId, nodeId: active.nodeId), isNull);
    expect(await engine.inspectTurn('missing-chat'), isNull);
    held.stream.add(const ModelText('回答'));
    held.stream.add(const ModelFinished('stop'));
    _done(await running);
  });

  test('reasoning-only and usage-only failures retain their own evidence', () async {
    engine.configure(TavernModelConfig(apiKey: () async => 'fixture-only', model: 'fixture', thinking: true));
    for (final deltas in <List<ModelDelta>>[
      [const ModelReasoning('只有思考')],
      [const ModelUsage(TavernUsage())],
    ]) {
      final (_, chatId) = await chat();
      model.partial(deltas);
      final failed = (await engine.send(chatId, '问').toList()).whereType<TavernTurnFailed>().single;
      expect(failed.kind, TavernFailure.network);
      expect(failed.partial, isNotNull);
      final saved = (await engine.inspectTurn(chatId, nodeId: failed.partial!.nodeId))!;
      expect(saved.status, TavernInspectionStatus.failed);
      expect(saved.reportedUsage != null, deltas.single is ModelUsage);
      if (deltas.single is ModelReasoning) expect(failed.partial!.reasoning, '只有思考');
    }
  });

  test('memory entries retain their own source and admission reason', () async {
    final (_, chatId) = await chat();
    await engine.putLorebook('memory', {
      'entries': {
        '0': {'uid': 0, 'constant': true, 'content': '记忆信息', 'order': 100, 'position': 1},
      },
    });
    await engine.bindLorebooks(['memory'], source: WorldInfoSource.memory, chatId: chatId);
    model.reply('回答');
    _done(await engine.send(chatId, '问').toList());
    final inspection = (await engine.inspectTurn(chatId))!;
    final hit = (inspection.worldInfo['activated']! as List<Object?>).single! as Map<String, Object?>;
    expect(hit['bookId'], 'memory');
    expect(hit['source'], 'memory');
    expect(hit['reason'], 'constant');
    final source = inspection.prompt!.afterPostProcessing
        .expand((message) => message.sources)
        .firstWhere((source) => source.id == 'memory:0');
    expect(source.details['source'], 'memory');
  });

  test('reply creation failure rolls back prepared input before starting the model', () async {
    final (_, chatId) = await chat();
    final before = (await engine.path(chatId)).map((message) => message.nodeId).toList();
    // T23 keeps ready inspection in memory. Inject at the actual reply
    // creation boundary so the preparation rollback contract stays tested.
    await installTrigger('''CREATE TRIGGER reject_ready_reply BEFORE INSERT ON nodes
      WHEN NEW.role = 'character' AND NEW.text = ''
      BEGIN SELECT RAISE(ABORT, 'fixture_ready_reply'); END''');
    final events = await engine.send(chatId, '用户行也应回滚').toList();
    expect(events.whereType<TavernTurnStarted>(), isEmpty);
    final failed = events.whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.server);
    expect(failed.partial, isNull);
    expect(model.bodies, isEmpty);
    expect((await engine.path(chatId)).map((message) => message.nodeId), before);
    final latest = (await engine.inspectTurn(chatId))!;
    expect(latest.status, TavernInspectionStatus.failed);
    expect(latest.nodeId, isNull);
    expect(latest.prompt, isNotNull);
    await engine.close();
    engine = await open();
    expect((await engine.inspectTurn(chatId))!.status, TavernInspectionStatus.failed);
  });

  test('terminal metadata failure never leaves a falsely completed node', () async {
    final (_, chatId) = await chat();
    await installTrigger('''CREATE TRIGGER reject_completed_inspection BEFORE UPDATE OF metadata ON chats
      WHEN EXISTS (SELECT 1 FROM nodes
        WHERE id = json_extract(NEW.metadata, '\$.dshgo.latestInspection.nodeId')
        AND json_extract(extra, '\$.dshgo.inspection.status') = 'completed')
      BEGIN SELECT RAISE(ABORT, 'fixture_completed'); END''');
    model.reply('已经成功保存的正文', usage: const TavernUsage(promptTokens: 9));
    final events = await engine.send(chatId, '问').toList();
    expect(events.whereType<TavernTurnDone>(), isEmpty);
    final failed = events.whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.server);
    expect(failed.partial!.text, '已经成功保存的正文');
    final saved = (await engine.inspectTurn(chatId, nodeId: failed.partial!.nodeId))!;
    expect(saved.status, TavernInspectionStatus.failed);
    expect(saved.failure, TavernFailure.server);
    expect(saved.reportedUsage!.promptTokens, 9);
    await engine.close();
    engine = await open();
    expect((await engine.inspectTurn(chatId))!.status, TavernInspectionStatus.failed);
  });

  test('inspection updates preserve continuation state across sibling selection and reopen', () async {
    final (_, chatId) = await chat({'description': '状态{{incvar::stateCount}}'});
    model.reply('A');
    final first = _done(await engine.send(chatId, '问').toList());
    final before = engine.variables(chatId);
    model.reply('B');
    final sibling = _done(await engine.regenerate(chatId, first.nodeId).toList());
    model.reply('续A');
    _done(await engine.continueReply(chatId, first.nodeId).toList());
    final continued = engine.variables(chatId);
    expect(continued, isNot(before));
    await engine.selectSibling(chatId, sibling.nodeId, 1);
    await engine.selectSibling(chatId, sibling.nodeId, 0);
    expect(engine.variables(chatId), continued);
    await engine.close();
    engine = await open();
    expect(engine.variables(chatId), continued);
    expect((await engine.inspectTurn(chatId, nodeId: first.nodeId))!.generationType, 'continue');
  });

  test('deleting a newer memory-only failure also clears an older disk latest', () async {
    final (_, chatId) = await chat();
    model.reply('A');
    final first = _done(await engine.send(chatId, '问').toList());
    model.reply('B');
    final sibling = _done(await engine.regenerate(chatId, first.nodeId).toList());
    await installTrigger('''CREATE TRIGGER reject_a_inspection BEFORE UPDATE OF metadata ON chats
      WHEN json_extract(NEW.metadata, '\$.dshgo.latestInspection.nodeId') = '${first.nodeId}'
        OR json_extract(NEW.metadata, '\$.dshgo.latestInspection.snapshot.contextNodeId') = '${first.nodeId}'
      BEGIN SELECT RAISE(ABORT, 'fixture_a_snapshot'); END''');
    final failed = (await engine.continueReply(chatId, first.nodeId).toList()).whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.server);
    final latest = (await engine.inspectTurn(chatId))!;
    expect(latest.status, TavernInspectionStatus.failed);
    expect(latest.nodeId, isNull);
    expect(latest.contextNodeId, first.nodeId);
    expect((await engine.inspectTurn(chatId, nodeId: sibling.nodeId))!.status, TavernInspectionStatus.completed);
    await engine.deleteFrom(chatId, first.nodeId);
    expect(await engine.inspectTurn(chatId), isNull);
    expect((await engine.path(chatId)).last.nodeId, sibling.nodeId);
    await engine.close();
    engine = await open();
    expect(await engine.inspectTurn(chatId), isNull);
    expect((await engine.inspectTurn(chatId, nodeId: sibling.nodeId))!.status, TavernInspectionStatus.completed);
  });

  test('failed latest cleanup rolls back deletion before publishing a cache tombstone', () async {
    final (_, chatId) = await chat();
    model.reply('保留我');
    final done = _done(await engine.send(chatId, '问').toList());
    await installTrigger('''CREATE TRIGGER reject_latest_clear BEFORE UPDATE OF metadata ON chats
      WHEN json_extract(OLD.metadata, '\$.dshgo.latestInspection') IS NOT NULL
        AND json_extract(NEW.metadata, '\$.dshgo.latestInspection') IS NULL
      BEGIN SELECT RAISE(ABORT, 'fixture_latest_clear'); END''');
    final before = jsonEncode((await engine.inspectTurn(chatId))!.toJson());
    await expectLater(engine.deleteFrom(chatId, done.nodeId), throwsA(isA<SqliteException>()));
    expect((await engine.path(chatId)).last.nodeId, done.nodeId);
    expect(jsonEncode((await engine.inspectTurn(chatId))!.toJson()), before);
    await engine.close();
    engine = await open();
    expect(jsonEncode((await engine.inspectTurn(chatId))!.toJson()), before);
  });

  test('persisting inspection preserves unrelated node extra and chat metadata', () async {
    final (_, chatId) = await chat();
    model.reply('原文');
    final first = _done(await engine.send(chatId, '问').toList());
    await engine.close();
    final databasePath = '${directory.path}/tavern.sqlite3';
    var store = ChatStore.open(databasePath);
    final node = store.node(chatId, first.nodeId);
    store.updateMessage(
      chatId,
      first.nodeId,
      extra: {
        ...node.extra,
        'foreign': {'keep': '🐋'},
        'dshgo': {
          ...(node.extra['dshgo']! as Map<String, Object?>),
          'futureFlag': {'enabled': true},
        },
      },
    );
    final oldChat = store.chat(chatId);
    store.updateChat(
      chatId,
      metadata: {
        ...oldChat.metadata,
        'foreign': [1, 2, 3],
        'dshgo': {...(oldChat.metadata['dshgo']! as Map<String, Object?>), 'futureFlag': 'keep'},
      },
    );
    await store.close();
    engine = await open();
    model.reply('续文');
    _done(await engine.continueReply(chatId, first.nodeId).toList());
    await engine.close();
    store = ChatStore.open(databasePath);
    try {
      final extra = store.node(chatId, first.nodeId).extra;
      expect(extra['foreign'], {'keep': '🐋'});
      expect((extra['dshgo']! as Map<String, Object?>)['futureFlag'], {'enabled': true});
      final metadata = store.chat(chatId).metadata;
      expect(metadata['foreign'], [1, 2, 3]);
      expect((metadata['dshgo']! as Map<String, Object?>)['futureFlag'], 'keep');
    } finally {
      await store.close();
    }
  });
}

final _at = DateTime.utc(2026, 11, 10, 3);
Uint8List _card(Map<String, Object?> fields) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': '鲸',
        'first_mes': '开场',
        'description': '',
        'personality': '',
        'scenario': '',
        'mes_example': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'creator_notes': '',
        'alternate_greetings': [],
        'tags': [],
        'extensions': {},
        ...fields,
      },
    }),
  ),
);
TavernMessage _done(List<TavernEvent> events) {
  expect(events.whereType<TavernTurnFailed>(), isEmpty);
  return events.whereType<TavernTurnDone>().single.message;
}

// This suite substitutes model deltas, not HTTP; T4/T8 exercise the transport.
class _Model extends TavernModelClient {
  final plans = Queue<Stream<ModelDelta> Function()>();
  final bodies = <Map<String, Object?>>[];
  final pending = <StreamController<ModelDelta>>[];
  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    bodies.add(jsonDecode(jsonEncode(body)) as Map<String, Object?>);
    if (plans.isEmpty) throw StateError('Unexpected model call in inspection test.');
    return plans.removeFirst()();
  }

  void reply(String text, {TavernUsage? usage}) => plans.add(
    () => Stream.fromIterable([ModelText(text), if (usage != null) ModelUsage(usage), const ModelFinished('stop')]),
  );
  void fail(TavernFailure kind) => plans.add(() => Stream.error(TavernModelException(kind, 'fixture_error')));
  void partial(List<ModelDelta> deltas) => plans.add(() async* {
    for (final delta in deltas) {
      yield delta;
    }
    throw const TavernModelException(TavernFailure.network, 'fixture_partial_error');
  });
  ({StreamController<ModelDelta> stream, Future<void> connected}) hold() {
    final connected = Completer<void>();
    final stream = StreamController<ModelDelta>(onListen: connected.complete);
    pending.add(stream);
    plans.add(() => stream.stream);
    return (stream: stream, connected: connected.future);
  }

  void dispose() {
    for (final stream in pending) {
      if (!stream.isClosed) unawaited(stream.close());
    }
  }
}
