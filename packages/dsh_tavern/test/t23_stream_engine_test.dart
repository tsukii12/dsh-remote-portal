import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// Model and periodic scheduling are controlled; facade, files and SQLite are
// real. These assert the requested interval and SQL operations, not speed.
void main() {
  late _Harness h;
  setUp(() async {
    h = await _Harness.open();
  });
  tearDown(() async {
    await h.close();
  });

  test(
    'a burst has no 16-chunk write and one 500ms checkpoint omits inspection and usage',
    () => _withTimers((timers) async {
      final held = h.model.hold();
      final running = h.engine.send(h.chat, 'question').toList();
      await held.connected;
      final active = (await h.engine.inspectTurn(h.chat))!;
      final id = active.nodeId!;
      for (var i = 0; i < 128; i++) {
        held.source.add(const ModelText('x'));
      }
      held.source.add(const ModelUsage(TavernUsage(promptTokens: 21, cacheHitTokens: 8)));
      await _settle();
      expect(timers, hasLength(1));
      expect(timers.single.period, const Duration(milliseconds: 500));
      expect(h.node(id)['text'], '');
      expect(h.node(id)['stream_text'], isNull);
      expect(h.events(id, 'body'), isEmpty);
      expect(h.events(id, 'text'), isEmpty);
      expect(h.events(id, 'extra'), isEmpty);
      expect((await h.engine.inspectTurn(h.chat, nodeId: id))!.reportedUsage!.promptTokens, 21);
      expect(_extra(h.node(id))['dshgo'], isNot(contains('inspection')));
      timers.single.fire();
      final checkpoint = (await h.engine.path(h.chat)).last;
      expect(checkpoint.text, List.filled(128, 'x').join());
      expect(checkpoint.usage, isNull);
      expect(h.events(id, 'body'), [1]);
      expect(h.events(id, 'extra'), isEmpty);
      expect(h.node(id)['usage'], isNull);
      held.source.add(const ModelText('tail'));
      held.source.add(const ModelFinished('stop'));
      final done = _done(await running);
      expect(done.text, '${List.filled(128, 'x').join()}tail');
      expect(done.usage!.cacheHitTokens, 8);
      expect(h.events(id, 'body'), [1]);
      expect(h.events(id, 'text'), [2]);
      expect(h.events(id, 'extra'), [2]);
      expect(h.node(id)['stream_text'], isNull);
      expect((await h.engine.inspectTurn(h.chat, nodeId: id))!.status, TavernInspectionStatus.completed);
      expect(timers.single.isActive, isFalse);
      h.integrity();
    }),
  );

  test(
    'a short reply commits its full tail without waiting for a periodic tick',
    () => _withTimers((timers) async {
      h.model.reply([const ModelText('short'), const ModelText(' tail'), const ModelFinished('length')]);
      final events = await h.engine.send(h.chat, 'question').toList();
      final done = events.whereType<TavernTurnDone>().single;
      expect(done.message.text, 'short tail');
      expect(done.finishReason, 'length');
      expect(h.events(done.message.nodeId, 'body'), isEmpty);
      expect(h.events(done.message.nodeId, 'text'), [2]);
      expect(h.events(done.message.nodeId, 'extra'), [2]);
      expect(timers.every((timer) => !timer.isActive), isTrue);
      h.integrity();
    }),
  );

  test(
    'terminal regex may clear the checkpoint and still runs only once after cancellation',
    () => _withTimers((timers) async {
      await h.engine.setSettings({
        'globalRegexScripts': [
          {
            'id': 'clear-body',
            'scriptName': 'clear-body',
            'findRegex': r'^[\s\S]+$',
            'replaceString': '{{setvar::terminalSeen::{{incvar::terminalCount}}}}',
            'placement': [2],
            'disabled': false,
            'markdownOnly': false,
            'promptOnly': false,
          },
        ],
      });
      final held = h.model.hold();
      final running = h.engine.send(h.chat, 'question').toList();
      await held.connected;
      final id = (await h.engine.inspectTurn(h.chat))!.nodeId!;
      held.source.add(const ModelText('draftword'));
      await _settle();
      timers.single.fire();
      expect((await h.engine.path(h.chat)).last.text, 'draftword');
      h.engine.stop(h.chat);
      final failed = (await running).whereType<TavernTurnFailed>().single;
      expect(failed.kind, TavernFailure.cancelled);
      expect(failed.partial!.text, '');
      expect(h.engine.variables(h.chat)['terminalCount'], 1);
      expect(h.events(id, 'body'), [1]);
      expect(h.events(id, 'text'), [2]);
      expect(h.events(id, 'extra'), [2]);
      expect(h.matches('draftword'), isEmpty);
      timers.single.fire();
      expect(h.events(id, 'text'), [2]);
      h.integrity();
    }),
  );

  test(
    'usage-only output has no body checkpoint and remains a failed partial',
    () => _withTimers((timers) async {
      final held = h.model.hold();
      final running = h.engine.send(h.chat, 'question').toList();
      await held.connected;
      final id = (await h.engine.inspectTurn(h.chat))!.nodeId!;
      held.source.add(const ModelUsage(TavernUsage(promptTokens: 9, completionTokens: 0)));
      await _settle();
      timers.single.fire();
      expect(h.events(id, 'body'), isEmpty);
      expect(h.node(id)['usage'], isNull);
      h.engine.stop(h.chat);
      final failed = (await running).whereType<TavernTurnFailed>().single;
      expect(failed.partial, isNotNull);
      expect(failed.partial!.usage!.promptTokens, 9);
      expect((await h.engine.inspectTurn(h.chat, nodeId: id))!.reportedUsage!.promptTokens, 9);
      expect(h.events(id, 'text'), [2]);
      expect(h.events(id, 'extra'), [2]);
    }),
  );

  test(
    'reasoning-only checkpoint keeps a null body marker distinct from an empty body',
    () => _withTimers((timers) async {
      final held = h.model.hold();
      final running = h.engine.send(h.chat, 'question').toList();
      await held.connected;
      final id = (await h.engine.inspectTurn(h.chat))!.nodeId!;
      held.source.add(const ModelReasoning('thought'));
      await _settle();
      timers.single.fire();
      expect(h.node(id)['stream_text'], '');
      expect(h.node(id)['stream_reasoning'], 'thought');
      expect((await h.engine.path(h.chat)).last.reasoning, 'thought');
      held.source.addError(const TavernModelException(TavernFailure.network, 'fixture_network'));
      final failed = (await running).whereType<TavernTurnFailed>().single;
      expect(failed.kind, TavernFailure.network);
      expect(failed.partial!.reasoning, 'thought');
      expect(h.events(id, 'body'), [1]);
      expect(h.events(id, 'text'), [2]);
      h.integrity();
    }),
  );

  test(
    'disabled fresh reasoning does not checkpoint and empty cancellation restores the path',
    () => _withTimers((timers) async {
      h.engine.configure(TavernModelConfig(apiKey: () async => 'fixture', model: 'fixture', deepseek: true));
      final before = (await h.engine.path(h.chat)).map((message) => message.nodeId).toList();
      final held = h.model.hold();
      final running = h.engine.send(h.chat, 'question').toList();
      await held.connected;
      final id = (await h.engine.inspectTurn(h.chat))!.nodeId!;
      held.source.add(const ModelReasoning('ignored'));
      await _settle();
      timers.single.fire();
      expect(h.events(id, 'body'), isEmpty);
      h.engine.stop(h.chat);
      final failed = (await running).whereType<TavernTurnFailed>().single;
      expect(failed.kind, TavernFailure.cancelled);
      expect(failed.partial, isNull);
      expect((await h.engine.path(h.chat)).map((message) => message.nodeId), before);
      expect((await h.engine.inspectTurn(h.chat))!.nodeId, isNull);
      expect(timers.single.isActive, isFalse);
    }),
  );

  test(
    'failed checkpoint still saves full received buffers as failed terminal evidence',
    () => _withTimers((timers) async {
      final held = h.model.hold();
      final running = h.engine.send(h.chat, 'question').toList();
      await held.connected;
      final id = (await h.engine.inspectTurn(h.chat))!.nodeId!;
      h.execute('''CREATE TRIGGER reject_checkpoint BEFORE UPDATE OF stream_text ON nodes
      WHEN NEW.stream_text IS NOT NULL BEGIN SELECT RAISE(ABORT, 'fixture_checkpoint'); END''');
      held.source.add(const ModelText('receivedword'));
      await _settle();
      timers.single.fire();
      final failed = (await running).whereType<TavernTurnFailed>().single;
      expect(failed.kind, TavernFailure.server);
      expect(failed.partial!.text, 'receivedword');
      expect(h.events(id, 'body'), isEmpty);
      expect(h.events(id, 'text'), [2]);
      expect(h.events(id, 'extra'), [2]);
      expect((await h.engine.inspectTurn(h.chat, nodeId: id))!.status, TavernInspectionStatus.failed);
      expect(h.matches('receivedword'), [id]);
      h.integrity();
    }),
  );

  test(
    'a rejected completed pointer rolls back the first final commit and saves failed evidence once',
    () => _withTimers((timers) async {
      h.execute(r'''CREATE TRIGGER reject_complete BEFORE UPDATE OF metadata ON chats
      WHEN EXISTS(SELECT 1 FROM nodes WHERE id = json_extract(NEW.metadata, '$.dshgo.latestInspection.nodeId')
        AND json_extract(extra, '$.dshgo.inspection.status') = 'completed')
      BEGIN SELECT RAISE(ABORT, 'fixture_complete'); END''');
      final held = h.model.hold();
      final running = h.engine.send(h.chat, 'question').toList();
      await held.connected;
      final id = (await h.engine.inspectTurn(h.chat))!.nodeId!;
      held.source.add(const ModelText('committedword'));
      await _settle();
      timers.single.fire();
      held.source.add(const ModelFinished('stop'));
      final events = await running;
      expect(events.whereType<TavernTurnDone>(), isEmpty);
      final failed = events.whereType<TavernTurnFailed>().single;
      expect(failed.partial!.text, 'committedword');
      expect(h.events(id, 'body'), [1]);
      expect(h.events(id, 'text'), [2]);
      expect(h.events(id, 'extra'), [2]);
      expect((await h.engine.inspectTurn(h.chat, nodeId: id))!.status, TavernInspectionStatus.failed);
      h.integrity();
    }),
  );

  test(
    'unwritable continuation returns its last checkpoint and reopen cannot reuse old completed evidence',
    () => _withTimers((timers) async {
      h.model.reply([
        const ModelText('oldword'),
        const ModelUsage(TavernUsage(promptTokens: 5)),
        const ModelFinished('stop'),
      ]);
      final original = _done(await h.engine.send(h.chat, 'question').toList());
      h.execute('DELETE FROM stream_audit');
      final held = h.model.hold();
      final running = h.engine.continueReply(h.chat, original.nodeId).toList();
      await held.connected;
      held.source.add(const ModelText(' savedtail'));
      await _settle();
      timers.last.fire();
      final saved = (await h.engine.path(h.chat)).last.text;
      h.execute('''CREATE TRIGGER reject_final_body BEFORE UPDATE OF text ON nodes
      WHEN NEW.id = '${original.nodeId}' BEGIN SELECT RAISE(ABORT, 'fixture_final_body'); END''');
      held.source.add(const ModelText(' unsavedtail'));
      held.source.add(const ModelFinished('stop'));
      final failed = (await running).whereType<TavernTurnFailed>().single;
      expect(failed.kind, TavernFailure.server);
      expect(failed.detail, startsWith('turn_storage_failure'));
      expect(failed.partial!.text, saved);
      expect(failed.partial!.usage, isNull);
      expect(await h.engine.inspectTurn(h.chat, nodeId: original.nodeId), isNull);
      expect((await h.engine.inspectTurn(h.chat))!.status, TavernInspectionStatus.failed);
      expect(h.node(original.nodeId)['stream_text'], saved);
      expect(h.node(original.nodeId)['text'], 'oldword');
      expect(h.events(original.nodeId, 'text'), isEmpty);
      h.execute('DROP TRIGGER reject_final_body');
      await h.reopen();
      expect((await h.engine.path(h.chat)).last.text, saved);
      expect((await h.engine.path(h.chat)).last.usage, isNull);
      expect(await h.engine.inspectTurn(h.chat, nodeId: original.nodeId), isNull);
      expect(await h.engine.inspectTurn(h.chat), isNull);
      expect(h.node(original.nodeId)['stream_text'], isNull);
      expect(h.events(original.nodeId, 'text'), [2]);
      h.integrity();
    }),
  );

  test(
    'global-file failure resolves before one failed terminal SQL snapshot',
    () => _withTimers((timers) async {
      final blocked = await Directory('${h.directory.path}/settings.json.writing').create();
      final held = h.model.hold();
      final running = h.engine.send(h.chat, '{{setglobalvar::audit::1}}question').toList();
      await held.connected;
      final id = (await h.engine.inspectTurn(h.chat))!.nodeId!;
      held.source.add(const ModelText('partialword'));
      await _settle();
      timers.single.fire();
      held.source.addError(const TavernModelException(TavernFailure.network, 'fixture_network'));
      final failed = (await running).whereType<TavernTurnFailed>().single;
      expect(failed.kind, TavernFailure.server);
      expect(failed.detail, startsWith('turn_storage_failure'));
      expect(failed.partial!.text, 'partialword');
      expect(h.events(id, 'body'), [1]);
      expect(h.events(id, 'text'), [2]);
      expect(h.events(id, 'extra'), [2]);
      final inspection = (await h.engine.inspectTurn(h.chat, nodeId: id))!;
      expect(inspection.status, TavernInspectionStatus.failed);
      expect(inspection.failure, TavernFailure.server);
      expect(inspection.detail, startsWith('turn_storage_failure'));
      await blocked.delete();
      await h.reopen();
      expect((await h.engine.inspectTurn(h.chat, nodeId: id))!.failure, TavernFailure.server);
      expect((await h.engine.path(h.chat)).last.text, 'partialword');
      h.integrity();
    }),
  );

  test(
    'editing an abandoned continuation cannot revive its earlier completed inspection or usage',
    () => _withTimers((timers) async {
      h.model.reply([
        const ModelText('oldword'),
        const ModelUsage(TavernUsage(promptTokens: 5)),
        const ModelFinished('stop'),
      ]);
      final original = _done(await h.engine.send(h.chat, 'question').toList());
      h.execute('DELETE FROM stream_audit');
      final held = h.model.hold();
      final running = h.engine.continueReply(h.chat, original.nodeId).toList();
      await held.connected;
      held.source.add(const ModelText(' savedtail'));
      await _settle();
      timers.last.fire();
      h.execute('''CREATE TRIGGER reject_final_body BEFORE UPDATE OF text ON nodes
      WHEN NEW.id = '${original.nodeId}' BEGIN SELECT RAISE(ABORT, 'fixture_final_body'); END''');
      held.source.add(const ModelFinished('stop'));
      expect((await running).whereType<TavernTurnFailed>().single.kind, TavernFailure.server);
      expect(await h.engine.inspectTurn(h.chat, nodeId: original.nodeId), isNull);
      h.execute('DROP TRIGGER reject_final_body');
      await h.engine.edit(h.chat, original.nodeId, 'editedword');
      final edited = (await h.engine.path(h.chat)).last;
      expect(edited.text, 'editedword');
      expect(edited.usage, isNull);
      expect(h.node(original.nodeId)['stream_text'], isNull);
      expect(await h.engine.inspectTurn(h.chat, nodeId: original.nodeId), isNull);
      expect(h.matches('oldword'), isEmpty);
      expect(h.matches('editedword'), [original.nodeId]);
      await h.reopen();
      expect(await h.engine.inspectTurn(h.chat, nodeId: original.nodeId), isNull);
      expect(await h.engine.inspectTurn(h.chat), isNull);
      expect((await h.engine.path(h.chat)).last.usage, isNull);
      h.integrity();
    }),
  );

  test(
    'parallel chats retain NORMAL checkpoints after one finishes and FULL ordinary writes',
    () => _withTimers((timers) async {
      final secondChat = await h.engine.createChat(h.cardId);
      final otherNode = (await h.engine.path(secondChat)).single;
      final first = h.model.hold();
      final firstRun = h.engine.send(h.chat, 'one').toList();
      await first.connected;
      final firstId = (await h.engine.inspectTurn(h.chat))!.nodeId!;
      final second = h.model.hold();
      final secondRun = h.engine.send(secondChat, 'two').toList();
      await second.connected;
      final secondId = (await h.engine.inspectTurn(secondChat))!.nodeId!;
      expect(timers, hasLength(2));
      first.source.add(const ModelText('firstword'));
      second.source.add(const ModelText('secondword'));
      await _settle();
      timers[0].fire();
      timers[1].fire();
      first.source.add(const ModelFinished('stop'));
      _done(await firstRun);
      final idleChat = await h.engine.createChat(h.cardId);
      final idleNode = (await h.engine.path(idleChat)).single;
      await h.engine.edit(idleChat, idleNode.nodeId, 'ordinaryedit');
      expect(h.events(idleNode.nodeId, 'text').last, 2);
      second.source.add(const ModelText(' tail'));
      await _settle();
      timers[1].fire();
      expect(h.events(firstId, 'body'), [1]);
      expect(h.events(firstId, 'text'), [2]);
      expect(h.events(secondId, 'body'), [1, 1]);
      h.engine.stop(secondChat);
      expect((await secondRun).whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
      expect(h.events(secondId, 'text'), [2]);
      expect((await h.engine.path(secondChat)).first.nodeId, otherNode.nodeId);
      expect(timers.every((timer) => !timer.isActive), isTrue);
      h.integrity();
    }),
  );

  test(
    'impersonation has no periodic database work and saves its terminal snapshot',
    () => _withTimers((timers) async {
      final before = (await h.engine.path(h.chat)).map((message) => message.nodeId).toList();
      h.execute('DELETE FROM stream_audit');
      final held = h.model.hold();
      final running = h.engine.impersonate(h.chat).toList();
      await held.connected;
      held.source.add(const ModelText('temporary'));
      await _settle();
      expect(timers, isEmpty);
      expect(h.rows('SELECT * FROM stream_audit'), isEmpty);
      expect(
        h.rows("SELECT json_extract(metadata, '\$.dshgo.latestInspection') AS latest FROM chats WHERE id = ?", [
          h.chat,
        ]).single['latest'],
        isNull,
      );
      held.source.add(const ModelFinished('stop'));
      expect(_done(await running).text, 'temporary');
      expect((await h.engine.path(h.chat)).map((message) => message.nodeId), before);
      expect((await h.engine.inspectTurn(h.chat))!.status, TavernInspectionStatus.completed);
      expect((await h.engine.inspectTurn(h.chat))!.generationType, 'impersonate');
    }),
  );

  test(
    'close cancels a paused consumer without abandoning its final checkpoint',
    () => _withTimers((timers) async {
      final held = h.model.hold();
      final events = <TavernEvent>[];
      final subscription = h.engine.send(h.chat, 'question').listen(events.add);
      await held.connected;
      final id = (await h.engine.inspectTurn(h.chat))!.nodeId!;
      held.source.add(const ModelText('closeword'));
      await _settle();
      timers.single.fire();
      subscription.pause();
      await h.engine.close().timeout(const Duration(seconds: 5));
      expect(timers.single.isActive, isFalse);
      expect(h.node(id)['text'], 'closeword');
      expect(h.node(id)['stream_text'], isNull);
      expect(h.events(id, 'text'), [2]);
      expect(
        (_extra(h.node(id))['dshgo']! as Map<String, Object?>)['inspection'],
        isA<Map<String, Object?>>().having((value) => value['status'], 'status', 'failed'),
      );
      await subscription.cancel();
    }),
  );
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);
TavernMessage _done(List<TavernEvent> events) => events.whereType<TavernTurnDone>().single.message;
Map<String, Object?> _extra(Map<String, Object?> row) => jsonDecode(row['extra']! as String) as Map<String, Object?>;

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

class _Harness {
  _Harness(this.directory, this.model);
  final Directory directory;
  final _Model model;
  late TavernEngine engine;
  late String cardId;
  late String chat;
  static Future<_Harness> open() async {
    final h = _Harness(await Directory.systemTemp.createTemp('dsh-t23-stream-engine-'), _Model());
    h.engine = await h._open();
    final card = await h.engine.importCard(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'spec': 'chara_card_v3',
            'spec_version': '3.0',
            'data': {'name': 'Whale', 'first_mes': 'greeting', 'description': '', 'extensions': {}},
          }),
        ),
      ),
    );
    h.cardId = card.id;
    h.chat = await h.engine.createChat(card.id);
    h.execute('''CREATE TABLE stream_audit(kind TEXT NOT NULL, node_id TEXT NOT NULL, sync INTEGER NOT NULL);
      CREATE TRIGGER audit_body AFTER UPDATE OF stream_text ON nodes WHEN NEW.stream_text IS NOT NULL BEGIN
        INSERT INTO stream_audit SELECT 'body', NEW.id, synchronous FROM pragma_synchronous;
      END;
      CREATE TRIGGER audit_text AFTER UPDATE OF text ON nodes BEGIN
        INSERT INTO stream_audit SELECT 'text', NEW.id, synchronous FROM pragma_synchronous;
      END;
      CREATE TRIGGER audit_extra AFTER UPDATE OF extra ON nodes BEGIN
        INSERT INTO stream_audit SELECT 'extra', NEW.id, synchronous FROM pragma_synchronous;
      END;''');
    return h;
  }

  Future<TavernEngine> _open() => TavernEngine.openDirectory(
    directory,
    config: TavernModelConfig(apiKey: () async => 'fixture', model: 'fixture', deepseek: false),
    modelClient: model,
    random: () => 0.25,
  );
  Future<void> reopen() async {
    await engine.close();
    engine = await _open();
  }

  List<Map<String, Object?>> rows(String sql, [List<Object?> parameters = const []]) {
    final database = sqlite3.open('${directory.path}/tavern.sqlite3');
    try {
      return [for (final row in database.select(sql, parameters)) Map<String, Object?>.from(row)];
    } finally {
      database.close();
    }
  }

  void execute(String sql) {
    final database = sqlite3.open('${directory.path}/tavern.sqlite3');
    try {
      database.execute(sql);
    } finally {
      database.close();
    }
  }

  Map<String, Object?> node(String id) => rows('SELECT * FROM nodes WHERE id = ?', [id]).single;
  List<int> events(String id, String kind) => [
    for (final row in rows('SELECT sync FROM stream_audit WHERE node_id = ? AND kind = ? ORDER BY rowid', [id, kind]))
      row['sync'] as int,
  ];
  List<String> matches(String word) => [
    for (final row in rows(
      'SELECT n.id FROM nodes_fts JOIN nodes n ON n.seq = nodes_fts.rowid WHERE nodes_fts MATCH ?',
      [word],
    ))
      row['id'] as String,
  ];
  void integrity() => execute("INSERT INTO nodes_fts(nodes_fts, rank) VALUES('integrity-check', 1)");
  Future<void> close() async {
    await engine.close();
    model.dispose();
    await directory.delete(recursive: true);
  }
}

class _Model extends TavernModelClient {
  final plans = Queue<Stream<ModelDelta> Function()>();
  final controllers = <StreamController<ModelDelta>>[];
  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    if (plans.isEmpty) throw StateError('Unexpected model call');
    return plans.removeFirst()();
  }

  void reply(List<ModelDelta> events) => plans.add(() => Stream.fromIterable(events));
  ({StreamController<ModelDelta> source, Future<void> connected}) hold() {
    final connected = Completer<void>();
    final source = StreamController<ModelDelta>(onListen: connected.complete);
    controllers.add(source);
    plans.add(() => source.stream);
    return (source: source, connected: connected.future);
  }

  void dispose() {
    for (final source in controllers) {
      if (!source.isClosed) unawaited(source.close());
    }
  }
}
