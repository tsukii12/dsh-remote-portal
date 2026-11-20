import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_slash_test_support.dart';

// New public-contract tests. These use the real native round, not a private
// background child or synthetic ModelDelta, and are not recovered old tests.
void main() {
  test('trigger await false returns after actual admission and a held native hook rejects busy before key', () async {
    final h = await slashFixture(allowModel: true);
    final actor = await h.card('Native admission');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.engine.setPreset(scriptPreset(streaming: true));
    final entered = Completer<void>();
    final release = Completer<void>();
    final outcomes = <Future<Object>>[];
    _triggerCleanup(h, 'native-admission', outcomes, release: release);
    final host = SlashHost();
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'GENERATION_AFTER_COMMANDS') {
        if (!entered.isCompleted) {
          entered.complete();
        }
        await release.future;
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    final response = h.stream();
    final script = await h.bridge.triggerSlash(context.id, '/trigger await=false', executionId: 'native-admission');
    outcomes.add(_observedOutcome(script));
    final result = await script.result;
    expect(result.pipe, '');
    expect(result.completion, TavernSlashCompletion.completed);
    final accepted = _nativeEffects(result.effects, chat, 'single', [TavernSlashEffectState.accepted]);
    expect(accepted.single.committed, isFalse);
    expect(result.effects.committed, isFalse);
    final frozen = jsonEncode(result.effects.toJson());
    final terminal = await script.events.single;
    final native = ScriptEvents(h.engine.resumeTurn(chat));
    await native.until((event) => event is TavernTurnSnapshot);
    await _nativeBoundary(native, entered.future);
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();

    final busy = await h.bridge.triggerSlash(context.id, '/trigger await=false');
    final error = await slashFailure(busy);
    expect(error.code, TavernScriptErrorCode.busy);
    final rejected = await busy.events.single;
    expect(
      rejected.effects.entries.where(
        (entry) => entry.kind == TavernSlashEffectKind.nativeTurn && entry.state == TavernSlashEffectState.accepted,
      ),
      isEmpty,
    );
    h.expectNoGeneration();
    release.complete();
    // The Slash result is already final. Only the still-active native stream
    // may be used to wait for this original turn's HTTP and model completion.
    await native.waitRequest(response);
    await _nativeBoundary(native, response.listening.future);
    response.delta('ADMITTED ANSWER');
    response.finish();
    await native.done.future;
    expect(native.values.whereType<TavernTurnFailed>(), isEmpty);
    final done = native.values.whereType<TavernTurnDone>().single;
    final path = await h.engine.path(chat);
    expect(path, hasLength(1));
    expect(path.single.role, TavernRole.character);
    expect(path.single.text, 'ADMITTED ANSWER');
    expect(path.single.nodeId, done.message.nodeId);
    expect(jsonEncode(result.effects.toJson()), frozen);
    final later = await script.events.single;
    expect(jsonEncode(later.effects.toJson()), frozen);
    expect(later.lastSeq, terminal.lastSeq);
    expect(later.status, TavernSlashStatus.completed);
    expect(host.interactions, isEmpty);
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('trigger await true remains pending through the real saved MESSAGE_RECEIVED acknowledgement', () async {
    final h = await slashFixture(allowModel: true);
    final actor = await h.card('Native received');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.engine.setPreset(scriptPreset(streaming: true));
    final received = Completer<TavernScriptDispatch>();
    final release = Completer<void>();
    final outcomes = <Future<Object>>[];
    _triggerCleanup(h, 'native-received', outcomes, release: release);
    final host = SlashHost();
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'MESSAGE_RECEIVED') {
        final ref = request.nodeRef!;
        expect(
          h.inspect((db) => db.select('SELECT text FROM nodes WHERE id = ?', [ref.nodeId]).single['text']),
          'SAVED ANSWER',
        );
        if (!received.isCompleted) {
          received.complete(request);
        }
        await release.future;
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    final response = h.stream();
    final script = await h.bridge.triggerSlash(context.id, '/trigger await=true', executionId: 'native-received');
    var settled = false;
    outcomes.add(
      script.result.then<Object>(
        (value) {
          settled = true;
          return value;
        },
        onError: (Object error) {
          settled = true;
          return error;
        },
      ),
    );
    final slashEvents = ScriptEvents(script.events);
    await slashSignal(script, response.seen.future);
    await slashSignal(script, response.listening.future);
    final native = ScriptEvents(h.engine.resumeTurn(chat));
    await native.until((event) => event is TavernTurnSnapshot);
    response.delta('SAVED ANSWER');
    response.finish();
    final hook = await slashSignal(script, received.future);
    final heldPath = await h.engine.path(chat);
    expect(heldPath, hasLength(1));
    expect(heldPath.single.text, 'SAVED ANSWER');
    expect(heldPath.single.nodeId, hook.nodeRef!.nodeId);
    expect(native.values.whereType<TavernTurnDone>(), isEmpty);
    expect(settled, isFalse);
    expect(slashEvents.values.where((event) => event.status == TavernSlashStatus.completed), isEmpty);
    release.complete();
    final result = await script.result;
    await native.done.future;
    expect(result.pipe, '');
    expect(result.completion, TavernSlashCompletion.completed);
    final entries = _nativeEffects(result.effects, chat, 'single', [
      TavernSlashEffectState.accepted,
      TavernSlashEffectState.completed,
    ]);
    expect(entries.first.committed, isFalse);
    expect(entries.last.committed, isTrue);
    expect(result.effects.committed, isTrue);
    expect(entries.last.details['refs'], [
      {'chatId': chat, 'nodeId': hook.nodeRef!.nodeId},
    ]);
    expect(native.values.whereType<TavernTurnDone>().single.message.text, 'SAVED ANSWER');
    expect(native.values.whereType<TavernTurnFailed>(), isEmpty);
    expect(host.deliveries.where((request) => request.name == 'MESSAGE_RECEIVED'), hasLength(1));
    expect(host.interactions, isEmpty);
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('stopping a waiting trigger leaves its admitted group round and the same SSE request alive', () async {
    final h = await slashFixture(allowModel: true);
    final alpha = await h.card('Alpha');
    final beta = await h.card('Beta');
    final chat = await h.engine.createGroupChat(
      [alpha, beta],
      activation: TavernGroupActivation.manual,
      addGreetings: false,
    );
    final context = await h.context(chat, characterId: alpha);
    await h.engine.setPreset(scriptPreset(streaming: true));
    final outcomes = <Future<Object>>[];
    _triggerCleanup(h, 'native-group-stop', outcomes);
    final response = h.stream();
    final script = await h.bridge.triggerSlash(context.id, '/trigger await=true 1', executionId: 'native-group-stop');
    outcomes.add(_observedOutcome(script));
    await slashSignal(script, response.seen.future);
    await slashSignal(script, response.listening.future);
    final native = ScriptEvents(h.engine.resumeGroupTurn(chat));
    final snapshot = await native.until((event) => event is TavernGroupSnapshot) as TavernGroupSnapshot;
    expect(snapshot.progress.speakerCharacterId, beta);
    response.delta('PREFIX');
    final observed =
        await native.until((event) => event is TavernGroupMemberEvent && event.event is TavernTextDelta)
            as TavernGroupMemberEvent;
    expect(observed.characterId, beta);
    expect((observed.event as TavernTextDelta).text, 'PREFIX');
    expect(h.bridge.stopScript(script.id), isTrue);
    final error = await slashFailure(script);
    expect(error.code, TavernScriptErrorCode.cancelled);
    final terminal = await script.events.single;
    expect(terminal.status, TavernSlashStatus.cancelled);
    expect(terminal.partialGeneration, isNull);
    _nativeEffects(terminal.effects, chat, 'group', [TavernSlashEffectState.accepted]);
    final frozen = jsonEncode(terminal.effects.toJson());

    // No second send and no engine.stop: continue the very same encoded SSE.
    response.delta('-TAIL');
    response.finish();
    await native.done.future;
    expect(native.values.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.completed);
    final memberEvents = native.values.whereType<TavernGroupMemberEvent>();
    expect(memberEvents.where((event) => event.event is TavernTurnFailed), isEmpty);
    final done = memberEvents.where((event) => event.event is TavernTurnDone).single;
    expect(done.characterId, beta);
    expect((done.event as TavernTurnDone).message.text, 'PREFIX-TAIL');
    final path = await h.engine.path(chat);
    expect(path, hasLength(1));
    expect(path.single.role, TavernRole.character);
    expect(path.single.speakerCharacterId, beta);
    expect(path.single.text, 'PREFIX-TAIL');
    expect((await h.engine.groupChat(chat))!.members.map((member) => member.characterId), [alpha, beta]);
    final later = await script.events.single;
    expect(jsonEncode(later.effects.toJson()), frozen);
    expect(later.lastSeq, terminal.lastSeq);
    expect(later.status, TavernSlashStatus.cancelled);
    expect(later.partialGeneration, isNull);
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test(
    'trigger rejects numeric prefixes nonmembers and duplicate names but accepts a leading zero member index',
    () async {
      final h = await slashFixture(allowModel: true);
      final left = await h.card('Twin', description: 'LEFT CARD');
      final right = await h.card('Twin', description: 'RIGHT CARD');
      final outside = await h.card('Outside');
      expect(left, isNot(right));
      final chat = await h.engine.createGroupChat(
        [left, right],
        activation: TavernGroupActivation.manual,
        addGreetings: false,
      );
      final context = await h.context(chat, characterId: left);
      final roster = (await h.engine.groupChat(chat))!.members.map((member) => member.characterId).toList();
      expect(roster, [left, right]);
      expect(roster, isNot(contains(outside)));
      final cases = <String, TavernScriptErrorCode>{
        '1tail': TavernScriptErrorCode.notFound,
        'Outside': TavernScriptErrorCode.notFound,
        'Twin': TavernScriptErrorCode.ambiguousName,
      };
      for (final entry in cases.entries) {
        final script = await h.bridge.triggerSlash(context.id, '/trigger await=true ${entry.key}');
        final error = await slashFailure(script);
        expect(error.code, entry.value, reason: entry.key);
        final terminal = await script.events.single;
        expect(terminal.effects.entries.where((effect) => effect.kind == TavernSlashEffectKind.nativeTurn), isEmpty);
        expect(await h.engine.path(chat), isEmpty);
        h.expectNoGeneration();
      }
      final outcomes = <Future<Object>>[];
      _triggerCleanup(h, 'native-member-index', outcomes);
      h.reply('GROUP-OK');
      final script = await h.bridge.triggerSlash(
        context.id,
        '/trigger await=true 0001',
        executionId: 'native-member-index',
      );
      outcomes.add(_observedOutcome(script));
      final result = await script.result;
      expect(result.pipe, '');
      expect(result.completion, TavernSlashCompletion.completed);
      final path = await h.engine.path(chat);
      expect(path, hasLength(1));
      expect(path.single.role, TavernRole.character);
      expect(path.single.speakerCharacterId, right);
      expect(path.single.text, 'GROUP-OK');
      final entries = _nativeEffects(result.effects, chat, 'group', [
        TavernSlashEffectState.accepted,
        TavernSlashEffectState.completed,
      ]);
      expect(entries.first.committed, isFalse);
      expect(entries.last.committed, isTrue);
      expect(entries.last.details['refs'], [
        {'chatId': chat, 'nodeId': path.single.nodeId},
      ]);
      expect((await h.engine.groupChat(chat))!.members.map((member) => member.characterId), roster);
      expect(h.requests, hasLength(1));
      expect(h.keyReads, 1);
      stdout.writeln('P2_B3_TRIGGER_READY');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
}

Future<T> _nativeBoundary<T, E>(ScriptEvents<E> native, Future<T> signal) => Future.any([
  signal,
  native.done.future.then<T>((_) => throw TestFailure('Native stream ended before the expected boundary.')),
]);

Future<Object> _observedOutcome(TavernSlashExecution script) =>
    script.result.then<Object>((value) => value, onError: (Object error) => error);

void _triggerCleanup(ScriptFixture h, String id, List<Future<Object>> outcomes, {Completer<void>? release}) {
  addTearDown(() async {
    h.bridge.stopScript(id);
    if (release != null && !release.isCompleted) {
      release.complete();
    }
    for (final plan in h.plans) {
      await plan.dispose();
    }
    for (final outcome in outcomes) {
      await outcome;
    }
  });
}

List<TavernSlashEffect> _nativeEffects(
  TavernSlashEffects effects,
  String chat,
  String mode,
  List<TavernSlashEffectState> states,
) {
  final entries = effects.entries.where((entry) => entry.kind == TavernSlashEffectKind.nativeTurn).toList();
  expect(entries.map((entry) => entry.state), states);
  for (final entry in entries) {
    expect(entry.operation, 'trigger');
    expect(entry.stage, TavernSlashEffectStage.handler);
    expect(entry.target, {'chatId': chat, 'mode': mode});
  }
  expect(effects.entries.where((entry) => entry.kind == TavernSlashEffectKind.backgroundGeneration), isEmpty);
  return entries;
}
