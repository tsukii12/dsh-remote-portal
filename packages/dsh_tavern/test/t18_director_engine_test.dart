import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  _lifecycleTests();
  _failureTests();
  _httpTest();

  test('automatic directing is off by default and a card or string setting cannot enable it', () async {
    final h = await _Harness.open(cardDirector: {'enabled': true, 'every': 1});
    final before = await h.engine.watchDirector(h.chatId).first;
    expect(before.automaticEnabled, isFalse);
    expect(before.latestSuccess, isNull);
    await h.reply('first');
    await h.engine.setSettings({
      'director': {'enabled': 'true'},
    });
    await h.reply('second');
    final after = await h.engine.readDirector(h.chatId);
    expect(after.automaticEnabled, isFalse);
    expect(after.pendingJobs, 0);
    expect(after.latestAttempt, isNull);
    expect(h.model.helpers, isEmpty);
    expect(_runs(h, 'director.tick'), isEmpty);
  });

  test('one explicit invocation saves three suggestions and durable pending proposals without another round', () async {
    final h = await _Harness.open();
    final before = _chatRows(h);
    final active = await h.manual();
    active.call.add(const ModelText('helper text is not chat text'));
    active.call.add(const ModelReasoning('helper reasoning is not chat reasoning'));
    active.call.add(const ModelUsage(TavernUsage(promptTokens: 11, cacheHitTokens: 2, completionTokens: 4)));
    final output = _output('MANUAL', events: 2);
    await active.call.direct(output, reason: 'stop');
    final run = await active.result;
    expect(run.success, isTrue);
    expect(run.automatic, isFalse);
    expect(run.notesSpoiler, isTrue);
    expect(run.output, output);
    expect(run.suggestions, hasLength(3));
    expect(run.reportedUsage!.promptTokens, 11);
    expect(_chatRows(h), before);
    expect(h.model.helpers, hasLength(1));
    expect(h.model.mains, isEmpty);
    expect(_runs(h, 'director.tick'), isEmpty);
    final first = await h.engine.readDirectorEvents(h.chatId, limit: 1);
    final second = await h.engine.readDirectorEvents(h.chatId, beforeEventId: first.single.id);
    expect(first.single.available, isTrue);
    expect(first.single.name, 'MANUAL-event-1');
    expect(second.single.name, 'MANUAL-event-0');
    expect({first.single.id, second.single.id}, hasLength(2));
    expect(first.single.runId, run.id);
    expect(first.single.status, 'pending');
    expect(first.single.source, 'director');
    expect(first.single.sourceNodeId, (await h.engine.path(h.chatId)).single.nodeId);
    final snapshot = await h.engine.readDirector(h.chatId);
    expect(snapshot.automaticEnabled, isFalse);
    expect(snapshot.latestSuccess!.id, run.id);
    expect(snapshot.latestAttempt!.id, run.id);
    expect(snapshot.pendingJobs, 0);
    await h.reply('ordinary reply');
    expect(_text(h.model.mains.single), contains('MANUAL next beat'));
    expect(h.model.helpers, hasLength(1));
    await h.reopen();
    expect((await h.engine.readDirector(h.chatId)).latestSuccess!.id, run.id);
    expect((await h.engine.readDirectorEvents(h.chatId)).map((event) => event.id), [first.single.id, second.single.id]);
  });

  for (final deepseek in [true, false]) {
    test('helper configuration and body stay independent from the main preset for deepseek=$deepseek', () async {
      final h = await _Harness.open(deepseek: deepseek);
      await h.engine.setPreset(
        ChatPreset({
          ...t24Preset().raw,
          'temperature': 1.7,
          'top_p': 0.3,
          'presence_penalty': 0.8,
          'frequency_penalty': 0.9,
          'stop': ['MAIN_STOP'],
          'tool_choice': 'required',
          'assistant_prefill': 'MAIN_PREFIX',
          'extensions': {
            'dshgo': {
              'prefill': {'enabled': true, 'target': 'content'},
            },
          },
        }),
      );
      final active = await h.manual();
      final call = active.call;
      expect(call.config.thinking, isFalse);
      expect(call.config.model, deepseek ? 'deepseek-flash' : 'main-reasoner');
      expect(call.config.deepseek, deepseek);
      expect(call.config.baseUrl, h.config.baseUrl);
      expect(call.config.apiKey, same(h.config.apiKey));
      expect(call.body['stream'], isFalse);
      expect(call.body['max_tokens'], 4096);
      expect(call.body['tool_choice'], {
        'type': 'function',
        'function': {'name': 'direct'},
      });
      final function = _map(_maps(call.body['tools']).single['function']);
      expect(function['name'], 'direct');
      expect(function.containsKey('strict'), deepseek);
      if (deepseek) {
        expect(function['strict'], isTrue);
        expect(call.body['thinking'], {'type': 'disabled'});
      } else {
        expect(call.body.containsKey('thinking'), isFalse);
      }
      for (final key in ['temperature', 'top_p', 'presence_penalty', 'frequency_penalty', 'stop']) {
        expect(call.body.containsKey(key), isFalse, reason: key);
      }
      expect(_maps(call.body['messages']).map((message) => message['role']), ['system', 'user']);
      expect(_maps(call.body['messages']).any((message) => message.containsKey('prefix')), isFalse);
      expect(jsonEncode(call.body), isNot(contains('MAIN_PREFIX')));
      await call.direct(_output('CONFIG'));
      expect((await active.result).success, isTrue);
      expect(h.model.calls, hasLength(1));
    });
  }

  test('A helper can finish after B main completes and only C uses the newly published result', () async {
    final h = await _Harness.open();
    await h.engine.setSettings({
      'director': {'enabled': true, 'every': 2},
    });
    await h.reply('warmup');
    final a = await h.reply('A main');
    final helper = await h.model.next(helper: true);
    await helper.listening.future;
    final captured = _map(jsonDecode(_maps(helper.body['messages']).last['content']! as String));
    expect(_maps(captured['recent']).last['nodeId'], a.nodeId);
    final b = await h.start(h.engine.send(h.chatId, 'B question'));
    expect(_text(b.call), isNot(contains('A next beat')));
    b.call.add(const ModelText('B main'));
    await b.call.finish();
    await b.events.done.future;
    expect(b.events.values.whereType<TavernTurnDone>(), hasLength(1));
    expect((await h.engine.path(h.chatId)).last.text, 'B main');
    expect(helper.cancellation.isCancelled, isFalse);
    expect((await h.engine.readDirector(h.chatId)).pendingJobs, 1);
    final published = _idle(h);
    await helper.direct(_output('A'));
    final snapshot = await published;
    expect(snapshot.latestSuccess!.sourceNodeId, a.nodeId);
    expect(snapshot.latestSuccess!.notes, 'A private notes');
    expect(snapshot.stale, isFalse);
    final bNode = b.events.values.whereType<TavernTurnDone>().single.message.nodeId;
    final savedB = (await h.engine.inspectTurn(h.chatId, nodeId: bNode))!;
    expect(savedB.director, isEmpty);
    expect(savedB.prompt!.body, b.call.body);
    final c = await h.start(h.engine.send(h.chatId, 'C question'));
    expect(_text(c.call), contains('A next beat'));
    c.call.add(const ModelText('C main'));
    await c.call.finish('length');
    await c.events.done.future;
    expect(h.model.helpers, hasLength(1));
    expect((await h.engine.inspectTurn(h.chatId))!.director['runId'], snapshot.latestSuccess!.id);
  });

  test('every counts committed invocations across reopening and continuing the same node', () async {
    final h = await _Harness.open(cardDirector: {'every': 2});
    await h.engine.setSettings({
      'director': {'enabled': true},
    });
    final first = await h.reply('first');
    expect(h.model.helpers, isEmpty);
    await h.reopen();
    final continued = await h.start(h.engine.continueReply(h.chatId, first.nodeId));
    continued.call.add(const ModelText(' continued'));
    await continued.call.finish('tool_calls');
    await continued.events.done.future;
    expect(continued.events.values.whereType<TavernTurnDone>().single.message.nodeId, first.nodeId);
    final helper = await h.model.next(helper: true);
    await helper.listening.future;
    final idle = _idle(h);
    await helper.direct(_output('EVERY'));
    expect((await idle).latestSuccess!.automatic, isTrue);
    await h.direct('EXPLICIT');
    await h.engine.sendOnly(h.chatId, 'stored without a model');
    await h.engine.narrate(h.chatId, 'narrator without a model');
    final impersonated = await h.start(h.engine.impersonate(h.chatId));
    impersonated.call.add(const ModelText('suggested user line'));
    await impersonated.call.finish();
    await impersonated.events.done.future;
    expect(_runs(h, 'director.tick'), hasLength(2));
    final regenerated = await h.start(h.engine.regenerate(h.chatId, first.nodeId));
    regenerated.call.add(const ModelText('alternative'));
    await regenerated.call.finish();
    await regenerated.events.done.future;
    expect(regenerated.events.values.whereType<TavernTurnDone>(), hasLength(1));
    final ticks = _runs(h, 'director.tick');
    expect(ticks.map((row) => _map(jsonDecode(row['result_json']! as String))['count']), [1, 2, 3]);
    expect(ticks.map((row) => _map(jsonDecode(row['result_json']! as String))['every']), [2, 2, 2]);
    expect(ticks[0]['node_id'], ticks[1]['node_id']);
    expect(h.model.helpers, hasLength(2));
    expect((await h.engine.readDirector(h.chatId)).pendingJobs, 0);
  });

  test('an explicit null every diagnoses invalid settings and falls back to one before the card value', () async {
    final h = await _Harness.open(cardDirector: {'every': 100});
    await h.engine.setSettings({
      'director': {'enabled': true, 'every': null},
    });
    await h.reply('counted');
    final helper = await h.model.next(helper: true);
    await helper.listening.future;
    final idle = _idle(h);
    await helper.direct(_output('NULL_EVERY'));
    final result = (await idle).latestSuccess!;
    expect(result.issues.map((issue) => issue['code']), contains('invalid_director_every'));
    final tick = _map(jsonDecode(_runs(h, 'director.tick').single['result_json']! as String));
    expect(tick['every'], 1);
    expect(tick['issue'], 'invalid_director_every');
  });

  for (final reason in <String?>[null, 'length', 'content_filter']) {
    test('a committed main terminal $reason does not count or schedule an automatic director', () async {
      final h = await _Harness.open();
      await h.engine.setSettings({
        'director': {'enabled': true},
      });
      await h.reply('saved main text', reason: reason);
      expect(_runs(h, 'director.tick'), isEmpty);
      expect(h.model.helpers, isEmpty);
      expect((await h.engine.readDirector(h.chatId)).pendingJobs, 0);
    });
  }

  for (final cancelled in [false, true]) {
    test('a failed main does not count or schedule a director with cancelled=$cancelled', () async {
      final h = await _Harness.open();
      await h.engine.setSettings({
        'director': {'enabled': true},
      });
      final active = await h.start(h.engine.send(h.chatId, 'question'));
      if (cancelled) {
        h.engine.stop(h.chatId);
      } else {
        active.call.fail(TavernFailure.network, 'provider-private-detail');
      }
      await active.call.close();
      await active.events.done.future;
      expect(active.events.values.whereType<TavernTurnDone>(), isEmpty);
      expect(
        active.events.values.whereType<TavernTurnFailed>().single.kind,
        cancelled ? TavernFailure.cancelled : TavernFailure.network,
      );
      expect(_runs(h, 'director.tick'), isEmpty);
      expect(h.model.helpers, isEmpty);
    });
  }

  for (final chatOverride in [false, true]) {
    test(
      'automatic admission rechecks current effective enablement after global disable with chat override=$chatOverride',
      () async {
        final h = await _Harness.open();
        await h.engine.setSettings({
          'director': {'enabled': true},
        });
        if (chatOverride) {
          await h.engine.setSettings({
            'director': {'enabled': true},
          }, chatId: h.chatId);
        }
        final main = await h.start(h.engine.send(h.chatId, 'held main'));
        await h.engine.setSettings({
          'director': {'enabled': false},
        });
        expect(main.call.cancellation.isCancelled, isFalse);
        main.call.add(const ModelText('committed after the setting changed'));
        await main.call.finish();
        await main.events.done.future;
        expect(main.events.values.whereType<TavernTurnDone>(), hasLength(1));
        if (chatOverride) {
          final helper = await h.model.next(helper: true);
          await helper.listening.future;
          final idle = _idle(h);
          await helper.direct(_output('OVERRIDE'));
          expect((await idle).automaticEnabled, isTrue);
          expect(_runs(h, 'director.tick'), hasLength(1));
        } else {
          expect(_runs(h, 'director.tick'), isEmpty);
          expect(h.model.helpers, isEmpty);
          expect((await h.engine.readDirector(h.chatId)).automaticEnabled, isFalse);
        }
      },
    );
  }
}

// Lifecycle cases are registered separately from protocol cases so none of the
// cancellation fixtures needs a real model, a timer sleep or a production hook.
void _lifecycleTests() {
  test('duplicate manual requests share one accepted job and one published result', () async {
    final h = await _Harness.open();
    final active = await h.manual();
    final duplicate = h.engine.runDirector(h.chatId);
    expect((await h.engine.readDirector(h.chatId)).pendingJobs, 1);
    await active.call.direct(_output('DEDUP', events: 1));
    expect((await duplicate).id, (await active.result).id);
    expect(h.model.helpers, hasLength(1));
    expect(_runs(h, 'director.success'), hasLength(1));
    expect((await h.engine.readDirectorEvents(h.chatId)), hasLength(1));
  });

  test('manual requests reject an active main or mutation without cancelling either owner', () async {
    final h = await _Harness.open();
    final main = await h.start(h.engine.send(h.chatId, 'held main'));
    await expectLater(h.engine.runDirector(h.chatId).timeout(const Duration(seconds: 10)), throwsA(_busy));
    expect(main.call.cancellation.isCancelled, isFalse);
    expect(h.model.helpers, isEmpty);
    main.call.add(const ModelText('completed main'));
    await main.call.finish();
    await main.events.done.future;
    expect(main.events.values.whereType<TavernTurnDone>(), hasLength(1));
    final nodeId = (await h.engine.path(h.chatId)).first.nodeId;
    final mutation = h.engine.setHidden(h.chatId, nodeId, true);
    await expectLater(h.engine.runDirector(h.chatId).timeout(const Duration(seconds: 10)), throwsA(_busy));
    await mutation;
    expect((await h.engine.path(h.chatId)).first.hidden, isTrue);
    expect(h.model.helpers, isEmpty);
    expect(_runs(h, 'director.failure'), isEmpty);
    expect((await h.direct('AFTER_BUSY')).success, isTrue);
  });

  test('the thirty third automatic job is rejected while main commits and the first thirty two remain owned', () async {
    final h = await _Harness.open();
    await h.engine.setSettings({
      'director': {'enabled': true},
    });
    await h.reply('main 0');
    final first = await h.model.next(helper: true);
    await first.listening.future;
    for (var index = 1; index < 33; index++) {
      await h.reply('main $index');
    }
    final snapshot = await h.engine.readDirector(h.chatId);
    expect(snapshot.pendingJobs, 32);
    expect(snapshot.latestAttempt!.success, isFalse);
    expect(snapshot.latestAttempt!.failure, 'director_queue_full');
    expect(h.model.helpers, hasLength(1));
    expect(_runs(h, 'director.tick'), hasLength(33));
    expect((await h.engine.path(h.chatId)).last.text, 'main 32');
    await h.engine.setSettings({
      'director': {'enabled': false},
    });
    expect(first.cancellation.isCancelled, isTrue);
    expect((await h.engine.readDirector(h.chatId)).pendingJobs, 0);
    expect(h.model.helpers, hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'disabling automatic work cancels active and queued auto jobs while preserving a queued manual and old success',
    () async {
      final h = await _Harness.open();
      final old = await h.direct('OLD');
      await h.engine.setSettings({
        'director': {'enabled': true},
      });
      await h.reply('A');
      final automatic = await h.model.next(helper: true);
      await automatic.listening.future;
      await h.reply('B');
      await h.reply('C');
      final manual = h.engine.runDirector(h.chatId);
      expect((await h.engine.readDirector(h.chatId)).pendingJobs, 4);
      await h.engine.setSettings({
        'director': {'enabled': false},
      });
      final manualCall = await h.model.next(helper: true);
      await manualCall.listening.future;
      expect(automatic.cancellation.isCancelled, isTrue);
      expect(manualCall.cancellation.isCancelled, isFalse);
      final waiting = await h.engine.readDirector(h.chatId);
      expect(waiting.automaticEnabled, isFalse);
      expect(waiting.pendingJobs, 1);
      expect(waiting.latestSuccess!.id, old.id);
      expect(h.model.helpers, hasLength(3));
      await manualCall.direct(_output('MANUAL_AFTER_DISABLE'));
      final completed = await manual;
      expect(completed.success, isTrue);
      expect(completed.automatic, isFalse);
      expect((await h.engine.readDirector(h.chatId)).latestSuccess!.id, completed.id);
      expect((await h.engine.readDirector(h.chatId)).pendingJobs, 0);
    },
  );

  test(
    'ordinary queued jobs keep every captured source and read preceding notes only when reaching the lane head',
    () async {
      final h = await _Harness.open();
      await h.engine.setSettings({
        'director': {'enabled': true},
      });
      final a = await h.reply('source A');
      var call = await h.model.next(helper: true);
      await call.listening.future;
      final b = await h.reply('source B');
      final c = await h.reply('source C');
      expect((await h.engine.readDirector(h.chatId)).pendingJobs, 3);
      expect(h.model.helpers, hasLength(1));
      final nodes = [a.nodeId, b.nodeId, c.nodeId];
      for (var index = 0; index < nodes.length; index++) {
        final input = _map(jsonDecode(_maps(call.body['messages']).last['content']! as String));
        expect(_maps(input['recent']).last['nodeId'], nodes[index]);
        expect(input['previousNotes'], index == 0 ? '' : 'FIFO_${index - 1} private notes');
        final published = h.engine
            .watchDirector(h.chatId)
            .firstWhere((snapshot) => snapshot.latestSuccess?.beat == 'FIFO_$index next beat');
        await call.direct(_output('FIFO_$index'));
        expect((await published).latestSuccess!.sourceNodeId, nodes[index]);
        if (index + 1 < nodes.length) {
          call = await h.model.next(helper: true);
          await call.listening.future;
        }
      }
      expect(_runs(h, 'director.success').map((row) => row['node_id']), nodes);
      expect(h.model.helpers, hasLength(3));
      expect((await h.engine.readDirector(h.chatId)).pendingJobs, 0);
    },
  );

  test('closing several synchronously queued jobs before startup does not dereference a cleared lane', () async {
    final h = await _Harness.open();
    final results = <Future<TavernDirectorRun>>[];
    for (var index = 0; index < 3; index++) {
      h.engine.configure(
        TavernModelConfig(
          apiKey: h.config.apiKey,
          baseUrl: 'https://fixture-$index.invalid/v1',
          model: 'main-reasoner',
          deepseek: true,
        ),
      );
      results.add(h.engine.runDirector(h.chatId));
    }
    await h.engine.close().timeout(const Duration(seconds: 10));
    final cancelled = await Future.wait(results);
    expect(cancelled, hasLength(3));
    expect(cancelled.every((run) => !run.success), isTrue);
    expect(cancelled.map((run) => run.id).toSet(), hasLength(3));
    expect(h.model.helpers, isEmpty);
    expect(_runs(h, 'director.success'), isEmpty);
  });

  test('cancelling a director watcher does not cancel or hide the independently published helper', () async {
    final h = await _Harness.open();
    final seen = <TavernDirectorSnapshot>[];
    final initial = Completer<void>();
    final observer = h.engine.watchDirector(h.chatId).listen((snapshot) {
      seen.add(snapshot);
      if (!initial.isCompleted) {
        initial.complete();
      }
    });
    addTearDown(observer.cancel);
    await initial.future;
    expect(seen.single.pendingJobs, 0);
    final started = h.engine.watchDirector(h.chatId).firstWhere((snapshot) => snapshot.running);
    final active = await h.manual();
    expect((await started).pendingJobs, 1);
    await observer.cancel();
    expect(active.call.cancellation.isCancelled, isFalse);
    final completed = _idle(h);
    await active.call.direct(_output('WATCHED'));
    final run = await active.result;
    expect((await completed).latestSuccess!.id, run.id);
    expect((await h.engine.watchDirector(h.chatId).first).latestSuccess!.id, run.id);
  });

  for (final racingDone in [false, true]) {
    test('close does not await a stubborn subscription or paused watcher with racing onDone=$racingDone', () async {
      final h = await _Harness.open();
      h.model.stubbornHelpers = true;
      final active = await h.manual();
      final observer = h.engine.watchDirector(h.chatId).listen((_) {});
      observer.pause();
      active.call.add(
        ModelToolFragment(
          index: 0,
          id: 'pending',
          type: 'function',
          name: 'direct',
          arguments: jsonEncode(_output('TOO_LATE', events: 1)),
        ),
      );
      active.call.add(const ModelFinished('tool_calls'));
      try {
        // A finish delta alone is insufficient: onDone has not arrived. Close
        // wins this race and the intentionally uncompleted cancel Future is not
        // needed for engine closure or for its own run Future to settle.
        final closing = h.engine.close();
        if (racingDone) {
          await active.call.close();
        }
        await closing.timeout(const Duration(seconds: 10));
        expect((await active.result).success, isFalse);
        expect(active.call.cancellation.isCancelled, isTrue);
        expect(active.call.cancelCalls, greaterThan(0));
        expect(active.call.cancelGate.isCompleted, isFalse);
        final before = _runs(h, 'director.failure');
        expect(_runs(h, 'director.success'), isEmpty);
        expect(_runs(h, 'director.event'), isEmpty);
        // The fake still delivers these callbacks after cancel; no closed SQL
        // handle or successful result may be reached from this stale receiver.
        if (!racingDone) {
          active.call.add(const ModelUsage(TavernUsage(promptTokens: 999)));
          await active.call.close();
        }
        expect(_runs(h, 'director.failure'), before);
        expect(_runs(h, 'director.success'), isEmpty);
      } finally {
        active.call.releaseCancel();
        observer.resume();
        await observer.cancel();
        await active.call.close();
      }
    });
  }

  for (final wholeCharacter in [false, true]) {
    test(
      'deleting the ${wholeCharacter ? 'character' : 'chat'} drains a stubborn helper and late callbacks cannot recreate its rows',
      () async {
        final h = await _Harness.open();
        final unrelated = await h.engine.importCard(t24Card(greeting: 'another character'));
        final otherChat = await h.engine.createChat(unrelated.id);
        h.model.stubbornHelpers = true;
        final active = await h.manual();
        try {
          if (wholeCharacter) {
            await h.engine.deleteCharacter(h.characterId).timeout(const Duration(seconds: 10));
          } else {
            await h.engine.deleteChat(h.chatId).timeout(const Duration(seconds: 10));
          }
          expect((await active.result).success, isFalse);
          expect(active.call.cancellation.isCancelled, isTrue);
          expect(active.call.cancelGate.isCompleted, isFalse);
          final before = _db(
            h,
            (db) => {
              for (final table in ['chats', 'nodes', 'agent_runs'])
                table: [
                  for (final row in db.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row),
                ],
            },
          );
          await active.call.direct(_output('AFTER_DELETE', events: 2));
          expect(
            _db(
              h,
              (db) => {
                for (final table in ['chats', 'nodes', 'agent_runs'])
                  table: [
                    for (final row in db.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row),
                  ],
              },
            ),
            before,
          );
          expect(_db(h, (db) => db.select('SELECT id FROM chats WHERE id = ?', [h.chatId])), isEmpty);
          expect(_db(h, (db) => db.select('SELECT id FROM agent_runs WHERE chat_id = ?', [h.chatId])), isEmpty);
          expect((await h.engine.path(otherChat)).single.text, 'another character');
          expect(_db(h, (db) => db.select('PRAGMA foreign_key_check')), isEmpty);
        } finally {
          active.call.releaseCancel();
          await active.call.close();
        }
      },
    );
  }

  test(
    'backup rejects both a synchronously accepted and active helper without cancelling it or creating an archive',
    () async {
      final container = await Directory.systemTemp.createTemp('dsh-t18-backup-admission-');
      addTearDown(() => container.delete(recursive: true));
      final h = await _Harness.open(parent: container);
      final destination = File('${h.root.path}-backup.zip');
      addTearDown(() async {
        if (await destination.exists()) {
          await destination.delete();
        }
      });
      final before = (await container.list().map((entity) => entity.path).toList())..sort();
      final result = h.engine.runDirector(h.chatId);
      await expectLater(h.engine.backup(destination.path), throwsA(_busy));
      expect(await destination.exists(), isFalse);
      expect((await container.list().map((entity) => entity.path).toList())..sort(), before);
      final call = await h.model.next(helper: true);
      await call.listening.future;
      await expectLater(h.engine.backup(destination.path), throwsA(_busy));
      expect(call.cancellation.isCancelled, isFalse);
      expect(await destination.exists(), isFalse);
      expect((await container.list().map((entity) => entity.path).toList())..sort(), before);
      expect((await h.engine.readDirector(h.chatId)).pendingJobs, 1);
      await call.direct(_output('BEFORE_BACKUP'));
      expect((await result).success, isTrue);
      await h.engine.backup(destination.path);
      expect(await destination.length(), greaterThan(0));
    },
  );
}

void _failureTests() {
  for (final failure in [
    'network',
    'no_call',
    'invalid_arguments',
    'two_calls',
    'null_finish',
    'length',
    'content_filter',
    'fragment_after_finish',
  ]) {
    test(
      'a helper failure $failure preserves the previous success and pending events without a second round',
      () async {
        final h = await _Harness.open();
        final old = await h.direct('PREVIOUS', events: 1);
        final oldEvents = await h.engine.readDirectorEvents(h.chatId);
        final chatBefore = _chatRows(h);
        final active = await h.manual();
        active.call.add(const ModelUsage(TavernUsage(promptTokens: 8, completionTokens: 3)));
        if (failure == 'network') {
          active.call.fail(TavernFailure.network, 'PRIVATE_PROVIDER_INPUT_SENTINEL');
          await active.call.close();
        } else {
          if (failure != 'no_call') {
            active.call.add(
              ModelToolFragment(
                index: 0,
                id: 'candidate',
                type: 'function',
                name: 'direct',
                arguments: failure == 'invalid_arguments' ? '{broken' : jsonEncode(_output('REJECTED', events: 2)),
              ),
            );
          }
          if (failure == 'two_calls') {
            active.call.add(
              ModelToolFragment(
                index: 1,
                id: 'extra',
                type: 'function',
                name: 'direct',
                arguments: jsonEncode(_output('ALSO_REJECTED')),
              ),
            );
          }
          if (failure == 'fragment_after_finish') {
            active.call.add(const ModelFinished('tool_calls'));
            active.call.add(ModelToolFragment(index: 0, arguments: ' '));
            await active.call.close();
          } else {
            await active.call.finish(
              failure == 'null_finish'
                  ? null
                  : failure == 'length' || failure == 'content_filter'
                  ? failure
                  : 'tool_calls',
            );
          }
        }
        final rejected = await active.result;
        expect(rejected.success, isFalse);
        expect(rejected.output, isNull);
        expect(rejected.failure, isNot(contains('PRIVATE_PROVIDER_INPUT_SENTINEL')));
        expect(rejected.reportedUsage!.promptTokens, 8);
        final snapshot = await h.engine.readDirector(h.chatId);
        expect(snapshot.latestAttempt!.id, rejected.id);
        expect(snapshot.latestAttempt!.success, isFalse);
        expect(snapshot.latestSuccess!.id, old.id);
        expect(snapshot.pendingJobs, 0);
        expect(
          (await h.engine.readDirectorEvents(h.chatId)).map((event) => event.id),
          oldEvents.map((event) => event.id),
        );
        expect(_chatRows(h), chatBefore);
        expect(h.model.helpers, hasLength(2));
        expect(h.model.mains, isEmpty);
        expect(_runs(h, 'director.success'), hasLength(1));
        expect(_runs(h, 'director.failure'), hasLength(1));
        expect(jsonEncode(_runs(h, 'director.failure')), isNot(contains('PRIVATE_PROVIDER_INPUT_SENTINEL')));
      },
    );
  }

  test(
    'an actual second-event INSERT failure publishes no partial success and preserves the old durable result',
    () async {
      final h = await _Harness.open();
      final old = await h.direct('OLD_SQL', events: 1);
      final beforeSuccess = _runs(h, 'director.success');
      final beforeEvents = _runs(h, 'director.event');
      final beforeChat = _chatRows(h);
      _db(
        h,
        (db) => db.execute(
          "CREATE TRIGGER reject_second_director_proposal BEFORE INSERT ON agent_runs "
          r"WHEN NEW.kind = 'director.event' AND json_extract(NEW.result_json, '$.name') = 'NEW_SQL-event-1' "
          "BEGIN SELECT RAISE(ABORT, 'fixture_director_event'); END",
        ),
      );
      try {
        final active = await h.manual();
        await active.call.direct(_output('NEW_SQL', events: 2));
        final failed = await active.result;
        expect(failed.success, isFalse);
        expect(failed.output, isNull);
        expect(failed.failure, 'director_write_failed');
        expect(failed.issues.map((issue) => issue['code']), contains('director_result_not_persisted'));
        expect(_runs(h, 'director.success'), beforeSuccess);
        expect(_runs(h, 'director.event'), beforeEvents);
        expect(_runs(h, 'director.failure'), isEmpty);
        expect(_chatRows(h), beforeChat);
        final snapshot = await h.engine.readDirector(h.chatId);
        expect(snapshot.latestSuccess!.id, old.id);
        expect(snapshot.latestAttempt!.id, failed.id);
        expect(snapshot.latestAttempt!.success, isFalse);
        expect(snapshot.pendingJobs, 0);
      } finally {
        _db(h, (db) => db.execute('DROP TRIGGER reject_second_director_proposal'));
      }
      final retry = await h.direct('RETRY_SQL', events: 2);
      expect(_runs(h, 'director.success'), hasLength(2));
      expect(_runs(h, 'director.event'), hasLength(3));
      await h.reopen();
      final reopened = await h.engine.readDirector(h.chatId);
      expect(reopened.latestSuccess!.id, retry.id);
      expect(reopened.latestAttempt!.id, retry.id);
      expect((await h.engine.readDirectorEvents(h.chatId)), hasLength(3));
    },
  );

  test(
    'a failed global settings write still cancels now-disabled automatic jobs and returns the original file error',
    () async {
      final h = await _Harness.open();
      await h.engine.setSettings({
        'director': {'enabled': true},
      });
      await h.reply('automatic A');
      final active = await h.model.next(helper: true);
      await active.listening.future;
      await h.reply('automatic B');
      expect((await h.engine.readDirector(h.chatId)).pendingJobs, 2);
      final settings = File('${h.root.path}/settings.json');
      final before = await settings.readAsBytes();
      final blocker = await Directory('${settings.path}.writing').create();
      try {
        await expectLater(
          h.engine.setSettings({
            'director': {'enabled': false},
          }),
          throwsA(isA<FileSystemException>()),
        );
        expect(_map((await h.engine.readSettings())['director'])['enabled'], isFalse);
        expect(active.cancellation.isCancelled, isTrue);
        expect((await h.engine.readDirector(h.chatId)).pendingJobs, 0);
        expect(h.model.helpers, hasLength(1));
        expect(await settings.readAsBytes(), before);
      } finally {
        await blocker.delete();
      }
    },
  );

  test(
    'a throwing public clock at helper completion falls back to its captured timestamp and releases ownership',
    () async {
      final h = await _Harness.open();
      final active = await h.manual();
      h.throwClock = true;
      try {
        await active.call.direct(_output('CLOCK'));
        final result = await active.result.timeout(const Duration(seconds: 10));
        expect(result.success, isTrue);
        expect(result.startedAt, h.now);
        expect(result.finishedAt, h.now);
        expect(result.issues.map((issue) => issue['code']), contains('director_clock_unavailable'));
        await h.engine.close().timeout(const Duration(seconds: 10));
        expect(_runs(h, 'director.success'), hasLength(1));
      } finally {
        h.throwClock = false;
      }
    },
  );
}

void _httpTest() {
  test('the public helper sends one actual nonstream DeepSeek direct request to a loopback server', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t18-director-http-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <Map<String, Object?>>[];
    final paths = <String>[];
    final methods = <String>[];
    final authorizations = <String?>[];
    final errors = <Object>[];
    final pending = <Future<void>>[];
    final subscription = server.listen(
      (request) {
        pending.add(() async {
          try {
            methods.add(request.method);
            paths.add(request.uri.path);
            authorizations.add(request.headers.value(HttpHeaders.authorizationHeader));
            bodies.add(_map(jsonDecode(await utf8.decoder.bind(request).join())));
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'role': 'assistant',
                      'content': 'not a chat reply',
                      'tool_calls': [
                        {
                          'id': 'wire-direct',
                          'type': 'function',
                          'function': {'name': 'direct', 'arguments': jsonEncode(_output('WIRE', events: 1))},
                        },
                      ],
                    },
                    'finish_reason': 'tool_calls',
                  },
                ],
                'usage': {'prompt_tokens': 11, 'prompt_cache_hit_tokens': 2, 'completion_tokens': 4},
              }),
            );
            await request.response.close();
          } catch (error) {
            errors.add(error);
            request.response.statusCode = 500;
            await request.response.close();
          }
        }());
      },
      onError: (Object error) {
        errors.add(error);
      },
    );
    TavernEngine? engine;
    try {
      final opened = await TavernEngine.openDirectory(
        root,
        config: TavernModelConfig(
          apiKey: () async => 'loopback-only',
          baseUrl: 'http://${server.address.address}:${server.port}/v1',
          model: 'main-thinking-model',
          deepseek: true,
          thinking: true,
        ),
        modelClient: TavernModelClient(idleTimeout: const Duration(seconds: 10)),
        clock: () => DateTime.utc(2026, 11, 10, 16),
        random: () => 0.25,
      );
      engine = opened;
      await opened.setPreset(t24Preset());
      final character = await opened.importCard(t24Card());
      final chatId = await opened.createChat(character.id);
      final original = await opened.path(chatId);
      final result = await opened.runDirector(chatId);
      expect(result.success, isTrue);
      expect(result.output, _output('WIRE', events: 1));
      expect(result.reportedUsage!.promptTokens, 11);
      expect(result.reportedUsage!.cacheHitTokens, 2);
      expect(result.reportedUsage!.completionTokens, 4);
      expect(bodies, hasLength(1));
      expect(methods, ['POST']);
      expect(paths, ['/beta/chat/completions']);
      expect(authorizations, ['Bearer loopback-only']);
      final body = bodies.single;
      expect(body['model'], 'deepseek-flash');
      expect(body['stream'], isFalse);
      expect(body['thinking'], {'type': 'disabled'});
      expect(body['max_tokens'], 4096);
      expect(body['tool_choice'], {
        'type': 'function',
        'function': {'name': 'direct'},
      });
      final function = _map(_maps(body['tools']).single['function']);
      expect(function['name'], 'direct');
      expect(function['strict'], isTrue);
      expect(_map(function['parameters'])['additionalProperties'], isFalse);
      expect(_maps(body['messages']).map((message) => message['role']), ['system', 'user']);
      expect((await opened.path(chatId)).map((message) => message.text), original.map((message) => message.text));
      expect((await opened.readDirector(chatId)).latestSuccess!.id, result.id);
      expect((await opened.readDirectorEvents(chatId)).single.runId, result.id);
      expect(bodies, hasLength(1));
    } finally {
      await engine?.close();
      await server.close(force: true);
      await subscription.cancel();
      await Future.wait(pending);
      await root.delete(recursive: true);
    }
    expect(errors, isEmpty);
  });
}

final _busy = isA<TavernModelException>().having((error) => error.kind, 'kind', TavernFailure.busy);
Map<String, Object?> _map(Object? value) => value! as Map<String, Object?>;
List<Map<String, Object?>> _maps(Object? value) => (value! as List<Object?>).map(_map).toList();
String _text(_Call call) => _maps(call.body['messages']).map((message) => message['content']).join('\n');
Future<TavernDirectorSnapshot> _idle(_Harness h) =>
    h.engine.watchDirector(h.chatId).firstWhere((snapshot) => snapshot.pendingJobs == 0);

Map<String, Object?> _output(String label, {int events = 0}) => {
  'notes': '$label private notes',
  'beat': '$label next beat',
  'prefetch': <Object?>[],
  'suggestions': [
    for (var index = 0; index < 3; index++) {'text': '$label option $index', 'risk': 'risk $index'},
  ],
  'events': [
    for (var index = 0; index < events; index++) {'name': '$label-event-$index', 'data': 'proposal $index'},
  ],
};

T _db<T>(_Harness h, T Function(Database database) action) {
  final database = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    return action(database);
  } finally {
    database.close();
  }
}

List<Map<String, Object?>> _runs(_Harness h, String kind) => _db(
  h,
  (db) => [
    for (final row in db.select('SELECT * FROM agent_runs WHERE kind = ? ORDER BY rowid', [kind]))
      Map<String, Object?>.from(row),
  ],
);

Map<String, Object?> _chatRows(_Harness h) => _db(
  h,
  (db) => {
    for (final table in ['chats', 'nodes', 'node_states'])
      table: [for (final row in db.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row)],
  },
);

class _Harness {
  _Harness(this.root, this.config);
  final Directory root;
  final TavernModelConfig config;
  final model = _Model();
  late TavernEngine engine;
  late String characterId;
  late String chatId;
  var throwClock = false;
  final now = DateTime.utc(2026, 11, 10, 16);

  DateTime clock() {
    if (throwClock) {
      throw StateError('CLOCK_PRIVATE_SENTINEL');
    }
    return now;
  }

  static Future<_Harness> open({bool deepseek = true, Map<String, Object?>? cardDirector, Directory? parent}) async {
    final root = await (parent ?? Directory.systemTemp).createTemp('dsh-t18-director-engine-');
    final h = _Harness(
      root,
      TavernModelConfig(
        apiKey: () async => 'fixture-only',
        baseUrl: 'https://fixture.invalid/v1',
        model: 'main-reasoner',
        deepseek: deepseek,
        thinking: true,
      ),
    );
    h.engine = await TavernEngine.openDirectory(
      root,
      config: h.config,
      modelClient: h.model,
      clock: h.clock,
      random: () => 0.25,
    );
    addTearDown(h.dispose);
    await h.engine.setPreset(t24Preset());
    final raw = _map(jsonDecode(utf8.decode(t24Card())));
    if (cardDirector != null) {
      _map(raw['data'])['extensions'] = {
        'dshgo': {'director': cardDirector},
      };
    }
    final card = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(raw))));
    h.characterId = card.id;
    h.chatId = await h.engine.createChat(card.id);
    return h;
  }

  Future<({_Call call, T24Events events})> start(Stream<TavernEvent> stream) async {
    final events = T24Events(stream);
    final call = await Future.any<_Call>([
      model.next(helper: false),
      events.done.future.then<_Call>((_) {
        throw TestFailure('Main ended before model input: ${events.values}');
      }),
    ]);
    await call.listening.future;
    return (call: call, events: events);
  }

  Future<TavernMessage> reply(String text, {String? reason = 'stop', String input = 'question'}) async {
    final active = await start(engine.send(chatId, input));
    active.call.add(ModelText(text));
    await active.call.finish(reason);
    await active.events.done.future;
    expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
    return active.events.values.whereType<TavernTurnDone>().single.message;
  }

  Future<({_Call call, Future<TavernDirectorRun> result})> manual({String? chat}) async {
    final result = engine.runDirector(chat ?? chatId);
    final call = await Future.any<_Call>([
      model.next(helper: true),
      result.then<_Call>((run) {
        throw TestFailure('Director ended before model input: ${run.failure}');
      }),
    ]);
    await call.listening.future;
    return (call: call, result: result);
  }

  Future<TavernDirectorRun> direct(String label, {int events = 0}) async {
    final active = await manual();
    await active.call.direct(_output(label, events: events));
    final result = await active.result;
    expect(result.success, isTrue);
    return result;
  }

  Future<void> reopen() async {
    await engine.close();
    engine = await TavernEngine.openDirectory(
      root,
      config: config,
      modelClient: model,
      clock: clock,
      random: () => 0.25,
    );
  }

  Future<void> dispose() async {
    throwClock = false;
    model.stubbornHelpers = false;
    for (final call in model.calls) {
      call.releaseCancel();
      unawaited(call.close());
    }
    try {
      await engine.close();
    } finally {
      for (final call in model.calls) {
        call.releaseCancel();
        await call.close();
      }
      await root.delete(recursive: true);
    }
  }
}

class _Model extends TavernModelClient {
  final calls = <_Call>[];
  final _ready = {false: Queue<_Call>(), true: Queue<_Call>()};
  final _waiting = {false: Queue<Completer<_Call>>(), true: Queue<Completer<_Call>>()};
  var stubbornHelpers = false;
  List<_Call> get helpers => calls.where((call) => call.helper).toList();
  List<_Call> get mains => calls.where((call) => !call.helper).toList();

  Future<_Call> next({required bool helper}) {
    if (_ready[helper]!.isNotEmpty) {
      return Future.value(_ready[helper]!.removeFirst());
    }
    final ready = Completer<_Call>();
    _waiting[helper]!.add(ready);
    return ready.future;
  }

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    final helper = (body['tools'] as List<Object?>? ?? const []).any(
      (tool) => _map(_map(tool)['function'])['name'] == 'direct',
    );
    final call = _Call(config, _map(jsonDecode(jsonEncode(body))), cancellation, helper, helper && stubbornHelpers);
    calls.add(call);
    if (_waiting[helper]!.isNotEmpty) {
      _waiting[helper]!.removeFirst().complete(call);
    } else {
      _ready[helper]!.add(call);
    }
    return call.stream;
  }
}

class _Call {
  _Call(this.config, this.body, this.cancellation, this.helper, this.stubborn) {
    _source = StreamController<ModelDelta>(sync: true, onListen: listening.complete);
  }
  final TavernModelConfig config;
  final Map<String, Object?> body;
  final ModelCancellation cancellation;
  final bool helper;
  final bool stubborn;
  final listening = Completer<void>();
  final cancelGate = Completer<void>();
  late final StreamController<ModelDelta> _source;
  var cancelCalls = 0;
  Stream<ModelDelta> get stream => stubborn ? _StubbornStream(this) : _source.stream;

  void add(ModelDelta delta) {
    _source.add(delta);
  }

  void fail(TavernFailure kind, String detail) {
    _source.addError(TavernModelException(kind, detail), StackTrace.current);
  }

  Future<void> finish([String? reason = 'stop']) {
    add(ModelFinished(reason));
    return close();
  }

  Future<void> direct(Map<String, Object?> output, {String? reason = 'tool_calls'}) {
    add(
      ModelToolFragment(index: 0, id: 'direct-result', type: 'function', name: 'direct', arguments: jsonEncode(output)),
    );
    return finish(reason);
  }

  Future<void> close() => _source.close();
  void releaseCancel() {
    if (!cancelGate.isCompleted) {
      cancelGate.complete();
    }
  }
}

// The inner subscription stays alive after cancel(), and its cancellation
// Future waits for a test-owned gate. Late callbacks deliberately still fire.
class _StubbornStream extends Stream<ModelDelta> {
  _StubbornStream(this.call);
  final _Call call;
  @override
  StreamSubscription<ModelDelta> listen(
    void Function(ModelDelta)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _StubbornSubscription(
    call,
    call._source.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError),
  );
}

class _StubbornSubscription implements StreamSubscription<ModelDelta> {
  _StubbornSubscription(this.call, this.inner);
  final _Call call;
  final StreamSubscription<ModelDelta> inner;
  @override
  Future<void> cancel() {
    call.cancelCalls++;
    return call.cancelGate.future;
  }

  @override
  void onData(void Function(ModelDelta)? handleData) => inner.onData(handleData);
  @override
  void onError(Function? handleError) => inner.onError(handleError);
  @override
  void onDone(void Function()? handleDone) => inner.onDone(handleDone);
  @override
  void pause([Future<void>? resumeSignal]) => inner.pause(resumeSignal);
  @override
  void resume() => inner.resume();
  @override
  bool get isPaused => inner.isPaused;
  @override
  Future<E> asFuture<E>([E? futureValue]) => inner.asFuture<E>(futureValue);
}
