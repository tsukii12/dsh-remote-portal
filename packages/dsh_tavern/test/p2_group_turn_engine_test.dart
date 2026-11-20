import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show t24Preset;

typedef _Json = Map<String, Object?>;
typedef _Request = ({String method, Uri url, _Json body});

// These are new public group-API tests, not old-side probes. The production
// encoder, response decoder, engine, files and SQLite are used throughout.
// Only the HTTP peer, clock and random source are synthetic.
void main() {
  test('group calls use actor cards and all member books with one durable shared path', () async {
    final h = await _Harness.open();
    final host = await h.card('Host', description: 'HOST_NOT_AN_ACTOR');
    final a = await h.card('Alpha', description: 'DESC_A', book: 'WI_A', order: 100, replacement: 'A_SAVED');
    final b = await h.card('Beta', description: 'DESC_B', book: 'WI_B', order: 99, replacement: 'B_SAVED');
    final muted = await h.card('Muted', description: 'MUTED_NOT_AN_ACTOR', book: 'WI_M', order: 98);
    final chat = await h.engine.createGroupChat(
      [a, b, muted],
      hostCharacterId: host,
      activation: TavernGroupActivation.listOrder,
      addGreetings: false,
    );
    await h.engine.updateGroupMember(chat, a, modelRole: TavernGroupModelRole.main);
    await h.engine.updateGroupMember(chat, muted, muted: true);
    await h.engine.setPreset(_preset(controls: true));
    expect(await h.engine.path(chat), isEmpty);
    await h.reopen();
    expect((await h.engine.groupChat(chat))!.members.map((member) => member.characterId), [a, b, muted]);
    expect(h.requests, isEmpty);

    final wrongApi = await h.engine.send(chat, 'not inserted').toList();
    expect(wrongApi.whereType<TavernTurnDone>(), isEmpty);
    expect(wrongApi.whereType<TavernTurnFailed>().single.kind, TavernFailure.invalidParameters);
    expect(wrongApi.whereType<TavernTurnFailed>().single.detail, 'group_requires_sendGroup');
    expect(await h.engine.path(chat), isEmpty);
    final first = h.json('RAW');
    final second = h.json('RAW');
    final savedBeforeSecond = <(String, String, String?)>[];
    second.beforeResponse = () async {
      // A separate SQLite reader cannot see merely buffered A text. The
      // current B staging row may already exist with an empty body.
      final db = sqlite3.open('${h.root.path}/tavern.sqlite3');
      try {
        savedBeforeSecond.addAll(
          db
              .select(
                'SELECT role, text, speaker_character_id FROM nodes WHERE chat_id = ? AND text <> ? ORDER BY depth',
                [chat, ''],
              )
              .map((row) => (row['role']! as String, row['text']! as String, row['speaker_character_id'] as String?)),
        );
      } finally {
        db.close();
      }
    };
    stdout.writeln('P2_GROUP_TURN_READY');
    final events = await h.engine.sendGroup(chat, 'Q').toList();
    final expectedA = _body([
      {'role': 'system', 'content': 'WI_M\nWI_B\nWI_A'},
      {'role': 'system', 'content': 'MAIN Alpha'},
      {'role': 'system', 'content': 'DESC_A'},
      {'role': 'system', 'content': 'NEW Alpha, Beta, Muted'},
      {'role': 'user', 'content': 'Q'},
      {'role': 'system', 'content': 'NEXT Alpha;ALL Alpha, Beta, Muted;ACTIVE Alpha, Beta'},
    ]);
    final expectedB = _body([
      {'role': 'system', 'content': 'WI_M\nWI_B\nWI_A'},
      {'role': 'system', 'content': 'MAIN Beta'},
      {'role': 'system', 'content': 'DESC_B'},
      {'role': 'system', 'content': 'NEW Alpha, Beta, Muted'},
      {'role': 'user', 'content': 'Q'},
      {'role': 'assistant', 'content': 'Alpha: A_SAVED'},
      {'role': 'system', 'content': 'NEXT Beta;ALL Alpha, Beta, Muted;ACTIVE Alpha, Beta'},
    ]);
    // Two complete independently specified wire bodies, not marker-only checks.
    expect(h.requests.map((request) => request.body), [expectedA, expectedB]);
    expect((first.sends, second.sends, h.keyReads), (1, 1, 2));
    expect(savedBeforeSecond, [('user', 'Q', null), ('character', 'A_SAVED', a)]);
    expect(h.requests.map((request) => (request.method, request.url)), [
      for (var index = 0; index < 2; index++) ('POST', Uri.parse('https://p2-group.invalid/v1/chat/completions')),
    ]);
    final finished = events.whereType<TavernGroupFinished>().single;
    expect(finished.reason, TavernGroupEndReason.completed);
    expect(finished.failure, isNull);
    final done = _done(events);
    expect(done.map((row) => (row.speaker, row.speakerCharacterId, row.text)), [
      ('Alpha', a, 'A_SAVED'),
      ('Beta', b, 'B_SAVED'),
    ]);
    expect(events.whereType<TavernGroupMemberEvent>().map((event) => event.characterId).toSet(), {a, b});
    expect(finished.progress!.plannedCharacterIds, [a, b]);
    expect(finished.progress!.remainingCharacterIds, isEmpty);
    expect(finished.progress!.completedNodeIds, done.map((row) => row.nodeId));
    final speaking = events
        .whereType<TavernGroupProgressChanged>()
        .map((event) => event.progress)
        .where((progress) => progress.phase == TavernGroupPhase.speaking)
        .toList();
    expect(speaking.map((progress) => progress.speakerCharacterId), [a, b]);
    expect(speaking.map((progress) => progress.remainingCharacterIds), [
      [b],
      <String>[],
    ]);
    expect(speaking.every((progress) => progress.generationId != null && progress.generationId!.isNotEmpty), isTrue);
    expect(speaking.map((progress) => progress.generationId).toSet(), hasLength(2));
    final path = await h.engine.path(chat);
    expect(path.map((row) => (row.role, row.text, row.speakerCharacterId)), [
      (TavernRole.user, 'Q', null),
      (TavernRole.character, 'A_SAVED', a),
      (TavernRole.character, 'B_SAVED', b),
    ]);
    expect(path.map((row) => row.parentId), [null, path[0].nodeId, path[1].nodeId]);
    expect(finished.progress!.userNodeId, path[0].nodeId);
    final identity = path.map((row) => (row.nodeId, row.parentId, row.text, row.speakerCharacterId)).toList();
    for (var index = 0; index < done.length; index++) {
      final inspection = (await h.engine.inspectTurn(chat, nodeId: done[index].nodeId))!;
      expect(inspection.status, TavernInspectionStatus.completed);
      expect(inspection.prompt!.body, index == 0 ? expectedA : expectedB);
      final hits = _maps(inspection.worldInfo['activated']);
      expect(hits.map((hit) => hit['content']).toSet(), {'WI_A', 'WI_B', 'WI_M'});
    }
    await h.reopen();
    expect(
      (await h.engine.path(chat)).map((row) => (row.nodeId, row.parentId, row.text, row.speakerCharacterId)),
      identity,
    );
    expect(await h.engine.resumeGroupTurn(chat).toList(), isEmpty);
    expect(h.requests.map((request) => request.body), [expectedA, expectedB]);
    expect(h.keyReads, 2);
  });

  test('group streams detach and resume atomically while stop retains partial actor and skips the queue', () async {
    final h = await _Harness.open();
    await h.engine.setPreset(_preset(streaming: true));
    final a = await h.card('Same');
    final b = await h.card('Same');
    final c = await h.card('Third');
    final chat = await h.engine.createGroupChat(
      [a, b, c],
      activation: TavernGroupActivation.listOrder,
      addGreetings: false,
    );
    final first = h.stream();
    final second = h.stream();
    final initial = _Events(h.engine.sendGroup(chat, 'one user'));
    await initial.waitRequest(first);
    await first.listening.future;
    first.delta({'content': 'alpha ', 'reasoning_content': 'private A'});
    await initial.until((event) => _hasDelta(event, a, 'alpha '));
    final firstRound = initial.values.whereType<TavernGroupStarted>().single.progress.roundId;
    await initial.detach();

    final paused = _Events(h.engine.resumeGroupTurn(chat));
    final snap = await paused.until((event) => event is TavernGroupSnapshot) as TavernGroupSnapshot;
    expect(snap.progress.roundId, firstRound);
    expect(snap.progress.speakerCharacterId, a);
    expect(snap.progress.remainingCharacterIds, [b, c]);
    expect(snap.progress.nextCharacterId, b);
    expect(snap.progress.remainingCount, 2);
    expect((snap.message!.text, snap.message!.reasoning, snap.message!.speakerCharacterId), ('alpha ', 'private A', a));
    expect(h.requests, hasLength(1));
    paused.subscription.pause();

    final resumed = _Events(h.engine.resumeGroupTurn(chat));
    final duplicate = await h.engine.sendGroup(chat, 'must not insert').toList();
    expect(duplicate.whereType<TavernGroupFinished>().single.failure, TavernFailure.busy);
    expect(duplicate.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.failed);
    final oldSend = await h.engine.send(chat, 'also not inserted').toList();
    expect(oldSend.whereType<TavernTurnFailed>().single.kind, TavernFailure.busy);
    expect(h.requests, hasLength(1));
    first.finish();
    await resumed.waitRequest(second);
    await second.listening.future;
    expect(_done(resumed.values).single.speakerCharacterId, a);
    expect(_maps(h.requests[1].body['messages']), [
      {'role': 'user', 'content': 'one user'},
      {'role': 'assistant', 'content': 'Same: alpha '},
    ]);
    expect(jsonEncode(h.requests[1].body), isNot(contains('private A')));
    second.delta({'content': 'beta partial'});
    await resumed.until((event) => _hasDelta(event, b, 'beta partial'));
    final bSnapshot = _Events(h.engine.resumeGroupTurn(chat));
    final bSnap = await bSnapshot.until((event) => event is TavernGroupSnapshot) as TavernGroupSnapshot;
    expect(bSnap.progress.speakerCharacterId, b);
    expect(bSnap.progress.remainingCharacterIds, [c]);
    expect(bSnap.progress.completedNodeIds, [_done(resumed.values).single.nodeId]);
    expect((bSnap.message!.text, bSnap.message!.speakerCharacterId), ('beta partial', b));
    expect(bSnap.progress.generationId, isNot(snap.progress.generationId));
    h.engine.stop(chat);
    await resumed.done.future;
    await bSnapshot.done.future;
    final finish = resumed.values.whereType<TavernGroupFinished>().single;
    expect(
      (finish.reason, finish.failure, finish.attemptedCharacterId),
      (TavernGroupEndReason.cancelled, TavernFailure.cancelled, b),
    );
    expect((finish.partial!.text, finish.partial!.speakerCharacterId), ('beta partial', b));
    expect(finish.progress!.remainingCharacterIds, [c]);
    expect(finish.progress!.completedNodeIds, [_done(resumed.values).single.nodeId]);
    expect(
      resumed.values
          .whereType<TavernGroupMemberEvent>()
          .where((event) => event.event is TavernTurnFailed)
          .single
          .characterId,
      b,
    );
    expect(h.requests, hasLength(2));
    expect(h.keyReads, 2);
    final path = await h.engine.path(chat);
    expect(path.map((row) => (row.role, row.text, row.speakerCharacterId)), [
      (TavernRole.user, 'one user', null),
      (TavernRole.character, 'alpha ', a),
      (TavernRole.character, 'beta partial', b),
    ]);
    expect(path.map((row) => row.parentId), [null, path[0].nodeId, path[1].nodeId]);
    final identities = path.map((row) => row.nodeId).toList();
    // A paused observer must not hold close, persistence or a new engine open.
    await h.reopen();
    await paused.detach();
    expect((await h.engine.path(chat)).map((row) => row.nodeId), identities);
    expect((await h.engine.path(chat)).last.speakerCharacterId, b);
    expect(await h.engine.resumeGroupTurn(chat).toList(), isEmpty);
    expect(h.requests, hasLength(2));
    expect(first.sends, 1);
    expect(second.sends, 1);
  });

  test('manual list natural and pool select finite literal schedules without replaying random choices', () async {
    var draws = 0;
    final h = await _Harness.open(
      random: () {
        draws++;
        return 0.75;
      },
    );
    final a = await h.card('Alpha', talkativeness: 0);
    final b = await h.card('Beta', talkativeness: 0);
    final c = await h.card('Gamma', talkativeness: 0);
    final d = await h.card('Delta', talkativeness: 0);
    final chat = await h.engine.createGroupChat(
      [a, b, c, d],
      activation: TavernGroupActivation.manual,
      addGreetings: false,
    );
    expect((await h.engine.groupChat(chat))!.maxSpeakersPerTurn, 3);
    await h.engine.updateGroupMember(chat, d, muted: true);
    final noReply = await h.engine.sendGroup(chat, 'only the user').toList();
    expect(noReply.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.noSpeakers);
    expect(_done(noReply), isEmpty);
    expect((await h.engine.path(chat)).map((message) => message.text), ['only the user']);
    expect(h.requests, isEmpty);
    expect(h.keyReads, 0);
    expect(draws, 0);
    h.json('explicit muted member');
    final explicit = await h.engine.sendGroup(chat, '', speakerCharacterId: d).toList();
    expect(_done(explicit).single.speakerCharacterId, d);
    expect(draws, 0);
    await h.engine.updateGroupMember(chat, d, muted: false);
    await h.engine.updateGroupChat(chat, activation: TavernGroupActivation.listOrder);
    for (final input in ['list one', 'list two']) {
      h.json('a');
      h.json('b');
      h.json('c');
      final ordered = await h.engine.sendGroup(chat, input).toList();
      expect(_done(ordered).map((message) => message.speakerCharacterId), [a, b, c]);
      expect(ordered.whereType<TavernGroupFinished>().single.progress!.plannedCharacterIds, [a, b, c]);
    }
    expect(draws, 0, reason: 'LIST plus the cap starts from the roster head each time, without a rotating cursor.');

    final pool = await h.engine.createGroupChat(
      [a, b, c],
      activation: TavernGroupActivation.randomPool,
      addGreetings: false,
    );
    final pooled = <String?>[];
    for (final input in ['new user', '', '', '', 'new user again']) {
      h.json('pool reply');
      final one = await h.engine.sendGroup(pool, input).toList();
      pooled.add(_done(one).single.speakerCharacterId);
      expect(one.whereType<TavernGroupFinished>().single.progress!.plannedCharacterIds, hasLength(1));
    }
    expect(pooled, [c, b, a, c, c]);
    expect(draws, 5);

    final natural = await h.engine.createGroupChat(
      [a, b, c],
      activation: TavernGroupActivation.natural,
      maxSpeakersPerTurn: 1,
      addGreetings: false,
    );
    h.json('Alpha');
    final mentioned = await h.engine.sendGroup(natural, 'Beta Alpha').toList();
    expect(_done(mentioned).single.speakerCharacterId, b);
    expect(draws, 11, reason: 'All three shuffle and three threshold draws precede the project cap.');
    await h.engine.groupChat(natural);
    await h.engine.watchGroupChat(natural).first;
    await h.engine.resumeGroupTurn(natural).toList();
    expect(draws, 11);
    h.json('no matching name');
    final lastText = await h.engine.sendGroup(natural, '').toList();
    expect(_done(lastText).single.speakerCharacterId, a);
    expect(draws, 16, reason: 'The actual last Beta reply mentions Alpha; banned Beta skips its threshold draw.');

    final fallback = await h.engine.createGroupChat(
      [a],
      activation: TavernGroupActivation.natural,
      addGreetings: false,
    );
    for (final input in ['no matching name', '']) {
      h.json('no matching name');
      final chosen = await h.engine.sendGroup(fallback, input).toList();
      expect(_done(chosen).single.speakerCharacterId, a);
    }
    expect(draws, 21, reason: 'The fixed ST fallback may select the sole zero-talk, self-banned actor.');
    expect(h.requests, hasLength(16));
    expect(h.keyReads, 16);
  });

  test('director scheduling consumes durable proposals on a branch only after an actor is retained', () async {
    final h = await _Harness.open();
    final a = await h.card('Same', greeting: 'source greeting');
    final b = await h.card('Same');
    final muted = await h.card('Muted');
    final chat = await h.engine.createGroupChat([a, b, muted], activation: TavernGroupActivation.director);
    await h.engine.updateGroupMember(chat, muted, muted: true);
    final source = (await h.engine.path(chat)).single;
    final empty = await h.engine.sendGroup(chat, '').toList();
    expect(empty.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.noSpeakers);
    expect(h.requests, isEmpty);
    h.json(
      '',
      tools: [
        _directCall(
          events: [
            {
              'name': 'group.speaker',
              'data': jsonEncode({'characterId': 'unknown-character'}),
            },
            {
              'name': 'group.speaker',
              'data': jsonEncode({'characterId': muted}),
            },
            {
              'name': 'group.speaker',
              'data': jsonEncode({'characterId': b}),
            },
            {
              'name': 'group.speaker',
              'data': jsonEncode({'characterId': a}),
            },
            {'name': 'not-an-engine-command', 'data': 'must remain a proposal'},
          ],
        ),
      ],
      reason: 'tool_calls',
    );
    final proposal = await h.engine.runDirector(chat);
    expect(proposal.success, isTrue, reason: proposal.failure);
    final original = await h.engine.readDirectorEvents(chat);
    final originalIds = original.map((event) => event.id).toList();
    expect(original, hasLength(5));

    h.response({
      'error': {'message': 'fixture rejected'},
    }, status: 401);
    final rejected = await h.engine.sendGroup(chat, '').toList();
    expect(rejected.whereType<TavernGroupFinished>().single.failure, TavernFailure.badKey);
    expect(rejected.whereType<TavernGroupFinished>().single.attemptedCharacterId, b);
    expect((await h.engine.path(chat)).map((message) => message.nodeId), [source.nodeId]);
    expect(h.requests, hasLength(2));
    h.json('B on original branch');
    h.json('A on original branch');
    final accepted = await h.engine.sendGroup(chat, '').toList();
    expect(accepted.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.completed);
    expect(_done(accepted).map((message) => message.speakerCharacterId), [b, a]);
    final originalReplies = _done(accepted).map((message) => message.nodeId).toList();
    final consumed = await h.engine.sendGroup(chat, '').toList();
    expect(consumed.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.noSpeakers);
    expect(h.requests, hasLength(4));
    expect((await h.engine.readDirectorEvents(chat)).map((event) => event.id), originalIds);
    expect((await h.engine.readDirectorEvents(chat)).every((event) => event.status == 'pending'), isTrue);

    await h.reopen();
    expect(
      (await h.engine.sendGroup(chat, '').toList()).whereType<TavernGroupFinished>().single.reason,
      TavernGroupEndReason.noSpeakers,
    );
    await h.engine.selectNode(chat, source.nodeId);
    h.json('B on another branch');
    h.json('A on another branch');
    final another = await h.engine.sendGroup(chat, '').toList();
    expect(_done(another).map((message) => message.speakerCharacterId), [b, a]);
    expect(_done(another).map((message) => message.nodeId).toSet().intersection(originalReplies.toSet()), isEmpty);
    expect((await h.engine.tree(chat)).map((message) => message.nodeId), containsAll(originalReplies));
    expect((await h.engine.readDirectorEvents(chat)).map((event) => event.id), originalIds);
    expect(h.requests, hasLength(6));

    await h.engine.selectNode(chat, source.nodeId);
    await h.engine.edit(chat, source.nodeId, 'changed source fingerprint');
    final stale = await h.engine.sendGroup(chat, '').toList();
    expect(stale.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.noSpeakers);
    expect((await h.engine.readDirector(chat)).stale, isTrue);
    expect(h.requests, hasLength(6), reason: 'No implicit director rescue, stale reply or unrequested actor call.');
  });

  test('manual tree mutation drains the whole group before writing and permits the next explicit actor', () async {
    final h = await _Harness.open();
    await h.engine.setPreset(_preset(streaming: true));
    final a = await h.card('A');
    final b = await h.card('B');
    final c = await h.card('C');
    final chat = await h.engine.createGroupChat(
      [a, b, c],
      activation: TavernGroupActivation.listOrder,
      addGreetings: false,
    );
    final call = h.stream();
    final events = _Events(h.engine.sendGroup(chat, 'before mutation'));
    await events.waitRequest(call);
    await call.listening.future;
    call.delta({'content': 'retained partial'});
    await events.until((event) => _hasDelta(event, a, 'retained partial'));
    final narrated = await h.engine.narrate(chat, '  narrator after cancel  ', speaker: 'Narrator');
    await events.done.future;
    expect(events.values.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.cancelled);
    expect(h.requests, hasLength(1));
    expect(
      (narrated.role, narrated.text, narrated.speakerCharacterId),
      (TavernRole.narrator, 'narrator after cancel', null),
    );
    expect((await h.engine.path(chat)).map((message) => message.text), [
      'before mutation',
      'retained partial',
      'narrator after cancel',
    ]);
    await h.engine.setPreset(_preset());
    h.json('explicit B after mutation');
    final next = await h.engine.sendGroup(chat, '', speakerCharacterId: b).toList();
    expect(next.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.completed);
    expect(_done(next).single.speakerCharacterId, b);
    expect(_done(next).single.parentId, narrated.nodeId);
    expect(h.requests, hasLength(2));
    expect(h.keyReads, 2);
  });

  test('main and helper actor wire routes persist through explicit regeneration and continuation', () async {
    final h = await _Harness.open(deepseek: true, thinking: true);
    final a = await h.card('A');
    final b = await h.card('B');
    final chat = await h.engine.createGroupChat(
      [a, b],
      activation: TavernGroupActivation.listOrder,
      addGreetings: false,
    );
    h.json('main A');
    h.json('helper B');
    final events = await h.engine.sendGroup(chat, 'route').toList();
    expect(events.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.completed);
    final replies = _done(events);
    expect(replies.map((message) => message.speakerCharacterId), [a, b]);
    expect(h.requests.map((request) => request.body['model']), ['p2-group-model', 'deepseek-flash']);
    expect(h.requests.map((request) => request.body['thinking']), [
      {'type': 'enabled'},
      {'type': 'disabled'},
    ]);
    expect(h.requests.map((request) => request.url), [
      Uri.parse('https://p2-group.invalid/beta/chat/completions'),
      Uri.parse('https://p2-group.invalid/beta/chat/completions'),
    ]);
    for (final request in h.requests) {
      expect(request.body['temperature'], 0.4);
      expect(request.body['max_tokens'], 73);
      expect(request.body['stream'], isFalse);
    }
    expect(h.requests.first.body.containsKey('tools'), isFalse);
    expect(h.requests.first.body.containsKey('tool_choice'), isFalse);
    expect(_maps(h.requests[1].body['tools']).map((tool) => _map(tool['function'])['name']), ['roll']);
    expect(h.requests[1].body.containsKey('tool_choice'), isFalse);
    await h.engine.updateGroupMember(chat, b, muted: true);
    h.json('B regenerated');
    final regenerated = await h.engine.regenerate(chat, replies[1].nodeId).toList();
    expect(regenerated.whereType<TavernTurnFailed>(), isEmpty);
    final replacement = regenerated.whereType<TavernTurnDone>().single.message;
    expect((replacement.speakerCharacterId, replacement.parentId, replacement.siblingCount), (b, replies[0].nodeId, 2));
    expect(h.requests.last.body['model'], 'deepseek-flash');
    expect(h.requests.last.body['thinking'], {'type': 'disabled'});
    h.json(' continued');
    final continued = await h.engine.continueReply(chat, replacement.nodeId).toList();
    expect(continued.whereType<TavernTurnFailed>(), isEmpty);
    final continuedMessage = continued.whereType<TavernTurnDone>().single.message;
    expect(
      (continuedMessage.nodeId, continuedMessage.speakerCharacterId, continuedMessage.text),
      (replacement.nodeId, b, 'B regenerated continued'),
    );
    expect(_maps(h.requests.last.body['messages']).last['prefix'], isTrue);
    expect(h.requests.last.body['model'], 'deepseek-flash');
    await h.engine.removeGroupMember(chat, b);
    final removed = await h.engine.regenerate(chat, replacement.nodeId).toList();
    expect(removed.whereType<TavernTurnDone>(), isEmpty);
    expect(removed.whereType<TavernTurnFailed>().single.kind, TavernFailure.invalidParameters);
    expect(removed.whereType<TavernTurnFailed>().single.detail, 'group_actor_not_in_roster');
    expect(h.requests, hasLength(4));
    expect(h.keyReads, 4);
    expect((await h.engine.tree(chat)).where((node) => node.nodeId == replies[1].nodeId).single.speakerCharacterId, b);
  });

  test('host state is shared per actor while story and automatic director count one complete batch', () async {
    final h = await _Harness.open();
    final host = await h.card(
      'Host',
      extensions: {
        'dshgo': {
          'v': 1,
          'state': _counterState(),
          'story': {
            'acts': [
              {'id': 'waiting', 'title': 'HOST_STORY', 'when': false},
            ],
          },
        },
      },
    );
    final foreign = {
      'dshgo': {
        'v': 1,
        'state': _counterState(initial: 99, summary: 'ACTOR_SCHEMA_MUST_NOT_RUN'),
        'story': {
          'acts': [
            {'id': 'wrong', 'when': true},
          ],
        },
      },
    };
    final a = await h.card('A', extensions: foreign);
    final b = await h.card('B', extensions: foreign);
    final chat = await h.engine.createGroupChat(
      [a, b],
      hostCharacterId: host,
      activation: TavernGroupActivation.listOrder,
      addGreetings: false,
    );
    await h.engine.setSettings({
      'director': {'enabled': true, 'every': 1},
    }, chatId: chat);
    expect((await h.engine.readState(chat)).values, {'count': 0});
    h.json('A changes', tools: [_stateCall(10)], reason: 'tool_calls');
    final second = h.json('B changes', tools: [_stateCall(20)], reason: 'tool_calls');
    Object? beforeB;
    _Json? storyBeforeB;
    second.beforeResponse = () async {
      beforeB = (await h.engine.readState(chat)).values;
      storyBeforeB = (await h.engine.readDirector(chat)).story;
    };
    h.json('not chat text', tools: [_directCall()], reason: 'tool_calls');
    final events = await h.engine.sendGroup(chat, 'state round').toList();
    expect(events.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.completed);
    final director = await h.engine
        .watchDirector(chat)
        .firstWhere((snapshot) => snapshot.pendingJobs == 0 && snapshot.latestAttempt != null);
    expect(director.latestAttempt!.success, isTrue, reason: director.latestAttempt!.failure);
    expect(beforeB, {'count': 1});
    expect(storyBeforeB!['initialized'], isFalse);
    expect((await h.engine.readState(chat)).values, {'count': 2});
    expect(director.story!['currentActId'], 'waiting');
    expect(director.story!['actTurns'], 1);
    expect(director.latestSuccess!.automatic, isTrue);
    expect(director.latestSuccess!.sourceNodeId, _done(events).last.nodeId);
    expect(h.requests, hasLength(3));
    expect(h.keyReads, 3);
    expect(_text(h.requests[0].body), contains('HOST_COUNT=0'));
    expect(_text(h.requests[1].body), contains('HOST_COUNT=1'));
    expect(_text(h.requests[1].body), contains('A: A changes'));
    for (final request in h.requests.take(2)) {
      expect(_text(request.body), isNot(contains('ACTOR_SCHEMA_MUST_NOT_RUN')));
      expect(_maps(request.body['tools']).map((tool) => _map(tool['function'])['name']), ['update_state']);
    }
    final helper = h.requests[2].body;
    expect(_maps(helper['tools']).map((tool) => _map(tool['function'])['name']), ['direct']);
    expect(helper['stream'], isFalse);
    expect(helper['max_tokens'], 4096);
    final input = _map(jsonDecode(_maps(helper['messages']).last['content']! as String));
    expect(_map(input['card'])['name'], 'Host');
    final runs = await h.engine.readAgentRuns(chat, limit: 1000);
    expect(runs.where((run) => run.kind == 'story.rules'), hasLength(1));
    expect(runs.where((run) => run.kind == 'director.tick'), hasLength(1));
    final path = await h.engine.path(chat);
    expect(path.map((message) => (message.role, message.text, message.speakerCharacterId)), [
      (TavernRole.user, 'state round', null),
      (TavernRole.character, 'A changes', a),
      (TavernRole.character, 'B changes', b),
    ]);
    final savedDirector = director.latestSuccess!.id;
    await h.reopen();
    expect((await h.engine.readState(chat)).values, {'count': 2});
    final after = await h.engine.readDirector(chat);
    expect(after.story!['actTurns'], 1);
    expect(after.latestSuccess!.id, savedDirector);
    expect(h.requests, hasLength(3));

    // A successful child of a later failed batch keeps its legal state edit,
    // but must not advance the story or schedule another automatic helper.
    h.json('A retained', tools: [_stateCall(30)], reason: 'tool_calls');
    h.response({
      'error': {'message': 'fixture rejected'},
    }, status: 401);
    final partial = await h.engine.sendGroup(chat, 'failed batch').toList();
    expect(partial.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.failed);
    expect((await h.engine.readState(chat)).values, {'count': 3});
    final unchanged = await h.engine.readDirector(chat);
    expect(unchanged.story!['actTurns'], 1);
    expect(unchanged.latestSuccess!.id, savedDirector);
    expect(unchanged.pendingJobs, 0);
    final laterRuns = await h.engine.readAgentRuns(chat, limit: 1000);
    expect(laterRuns.where((run) => run.kind == 'story.rules'), hasLength(1));
    expect(laterRuns.where((run) => run.kind == 'director.tick'), hasLength(1));
    expect(h.requests, hasLength(5));
  });

  test('group preview binds a real host proposal locally before native continue adopts it independently', () async {
    final h = await _Harness.open();
    await h.engine.setPreset(ChatPreset({..._preset().raw, 'continue_prefill': false}));
    const fact = 'The host sealed the group alibi.';
    final host = await h.card(
      'Host',
      description: 'HOST_NOT_AN_ACTOR',
      extensions: {
        'dshgo': {
          'v': 1,
          'state': {
            'schema': {
              'type': 'object',
              'additionalProperties': false,
              'required': ['entity', 'private'],
              'properties': {
                'entity': {'type': 'string'},
                'private': {
                  'type': 'object',
                  'additionalProperties': false,
                  'required': ['fact'],
                  'x-dsh-hidden': true,
                  'x-dsh-by': ['rules', 'user'],
                  'properties': {
                    'fact': {
                      'type': ['string', 'null'],
                    },
                  },
                },
              },
            },
            'init': {
              'entity': 'group-entity',
              'private': {'fact': null},
            },
            'rules': <Object?>[],
            'summary': 'HOST_STATE_SCOPE',
          },
          'director': {
            'secretSlots': {
              'v': 1,
              'slots': [
                {
                  'id': 'alibi',
                  'path': '/private/fact',
                  'entityPath': '/entity',
                  'unbound': {'exists': true, 'value': null},
                  'bindWhen': true,
                  'release': {
                    'id': 'group-alibi',
                    'audience': 'currentCharacter',
                    'when': true,
                    'template': 'GROUP_RELEASE[{{fact}}]',
                  },
                },
              ],
            },
          },
        },
      },
    );
    final actor = await h.card(
      'Actor',
      description: 'ACTOR_BODY',
      extensions: {
        'dshgo': {'v': 1, 'state': _counterState(initial: 99, summary: 'ACTOR_SCHEMA_MUST_NOT_RUN')},
      },
    );
    final other = await h.card('Other');
    final chat = await h.engine.createGroupChat(
      [actor, other],
      hostCharacterId: host,
      activation: TavernGroupActivation.listOrder,
      addGreetings: false,
    );
    // Explicit actor selection permits a muted member. Capture the real
    // proposal after this edit so its group-member fingerprint stays valid.
    await h.engine.updateGroupMember(chat, actor, muted: true);
    await h.engine.setSettings({
      'director': {'enabled': true, 'secretsEnabled': true, 'every': 1},
    }, chatId: chat);
    h.json('ACTOR_SOURCE');
    h.json('', tools: [_directCall()], reason: 'tool_calls');
    final secret = h.json(
      '',
      reason: 'tool_calls',
      tools: [
        {
          'id': 'group-secret-proposal',
          'type': 'function',
          'function': {
            'name': 'propose_secrets',
            'arguments': jsonEncode({
              'notes': 'An actual group helper proposal',
              'facts': [
                {'slotId': 'alibi', 'value': fact},
              ],
            }),
          },
        },
      ],
    );
    final first = await h.engine.sendGroup(chat, '', speakerCharacterId: actor).toList();
    expect(first.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.completed);
    final source = _done(first).single;
    expect((source.speakerCharacterId, source.text), (actor, 'ACTOR_SOURCE'));
    final secretRequest = await secret.seen.future.timeout(const Duration(seconds: 10));
    await h.engine
        .watchDirector(chat)
        .firstWhere((view) => view.pendingJobs == 0 && !view.running)
        .timeout(const Duration(seconds: 10));
    final proposal = (await h.engine.readAgentRuns(
      chat,
      limit: 1000,
    )).singleWhere((run) => run.kind == 'director.secret_proposal');
    expect(proposal.result['success'], isTrue);
    expect(proposal.result['sourceNodeId'], source.nodeId);
    expect(proposal.result['characterId'], host);
    expect(_map(proposal.result['capability'])['characterId'], host);
    expect(_maps(_map(proposal.result['output'])['facts']).single['value'], fact);
    final input = _map(jsonDecode(_maps(secretRequest.body['messages']).last['content']! as String));
    expect(_map(input['card'])['name'], 'Host');
    expect(_maps(input['recent']).single['speakerCharacterId'], actor);
    await h.engine.setSettings({
      'director': {'enabled': true, 'secretsEnabled': true, 'every': 1000},
    }, chatId: chat);
    final draft = await h.engine.createAuthoringDraft([
      TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: host),
    ]);
    _Json databaseState() {
      final db = sqlite3.open('${h.root.path}/tavern.sqlite3');
      try {
        final result = <String, Object?>{};
        for (final table in db.select("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")) {
          final name = table['name']! as String;
          final quoted = name.replaceAll('"', '""');
          result[name] = [for (final row in db.select('SELECT * FROM "$quoted"')) Map<String, Object?>.from(row)];
        }
        return result;
      } finally {
        db.close();
      }
    }

    final before = databaseState();
    final calls = (h.requests.length, h.keyReads);
    Future<TavernAuthoringPromptPreview> preview(String kind) => h.engine
        .previewAuthoringPrompt(
          TavernAuthoringPromptRequest(
            requestId: 'group-local-bind-$kind',
            draftId: draft.id,
            draftRevision: draft.draftRevision,
            changeIds: const [],
            seed: 7,
            at: DateTime.utc(2026, 11, 12, 4),
            context: TavernAuthoringChatContext(
              chatId: chat,
              actorId: actor,
              generationType: kind,
              nodeId: kind == 'normal' ? null : source.nodeId,
            ),
          ),
        )
        .result;
    final normal = await preview('normal');
    final continuing = await preview('continue');
    for (final result in [normal, continuing]) {
      expect(result.status, TavernAuthoringPreviewStatus.complete, reason: '${result.issues}');
      final trace = result.secretTrace;
      expect(trace['scope'], 'preview');
      expect(trace['origin'], {'kind': 'chat', 'chatId': chat, 'nodeId': source.nodeId});
      expect(trace['adoptedLocally'], isTrue);
      expect(trace['attempted'], isFalse);
      expect(_maps(trace['changes']).map((change) => change['path']), ['/private/fact']);
      final release = _maps(trace['offered']).single;
      expect(release['characterId'], host);
      expect(trace['included'], [release['sourceId']]);
      expect(_text(result.assembly!.body), contains('GROUP_RELEASE[$fact]'));
      expect(_text(result.assembly!.body), contains('ACTOR_BODY'));
      expect(_text(result.assembly!.body), isNot(contains('ACTOR_SCHEMA_MUST_NOT_RUN')));
      expect(jsonEncode(trace), isNot(contains('bindReceiptId')));
    }
    // Regenerating this root uses null as parent, so the original anchor
    // gate rejects it; this does not claim to reach the physical-child gate.
    final regenerated = await preview('regenerate');
    expect(regenerated.status, TavernAuthoringPreviewStatus.complete);
    expect(regenerated.secretTrace['adoptedLocally'], isFalse);
    expect(regenerated.secretTrace['offered'], isEmpty);
    expect(regenerated.issues.map((issue) => issue.type), contains('secret_source_not_current_physical_leaf'));
    expect(databaseState(), before);
    expect((h.requests.length, h.keyReads), calls);
    expect(
      (await h.engine.readAgentRuns(chat, limit: 1000)).where((run) => run.kind == 'director.secret_bind'),
      isEmpty,
    );
    expect(_map((await h.engine.readState(chat)).values)['private'], {'fact': null});

    final native = h.json(' continued');
    native.beforeResponse = () async {
      // The real native B/audit must already be committed at provider entry.
      final bind = (await h.engine.readAgentRuns(
        chat,
        limit: 1000,
      )).singleWhere((run) => run.kind == 'director.secret_bind');
      expect(bind.result['committed'], isTrue);
      expect(bind.result['proposalRunId'], proposal.id);
      expect(bind.result['sourceFingerprint'], proposal.result['sourceFingerprint']);
      expect(bind.nodeId, source.nodeId);
      final binding = _maps(bind.result['bindings']).single;
      expect(binding['characterId'], host);
      expect(binding['boundNodeId'], source.nodeId);
      expect(_map((await h.engine.readState(chat)).values)['private'], {'fact': fact});
      final db = sqlite3.open('${h.root.path}/tavern.sqlite3');
      try {
        final row = db.select('SELECT text, speaker_character_id, extra FROM nodes WHERE id = ?', [
          source.nodeId,
        ]).single;
        expect((row['text'], row['speaker_character_id']), ('ACTOR_SOURCE', actor));
        final own = _map(_map(jsonDecode(row['extra']! as String))['dshgo']);
        expect(_map(own['group'])['actorCharacterId'], actor);
        expect(_map(own['secretBinding'])['runId'], bind.id);
      } finally {
        db.close();
      }
    };
    final finished = await h.engine.continueReply(chat, source.nodeId).toList();
    expect(finished.whereType<TavernTurnFailed>(), isEmpty);
    final reply = finished.whereType<TavernTurnDone>().single.message;
    expect((reply.nodeId, reply.speakerCharacterId, reply.text), (source.nodeId, actor, 'ACTOR_SOURCE continued'));
    expect((await native.seen.future).body, continuing.assembly!.body);
    expect(
      (await h.engine.readAgentRuns(chat, limit: 1000)).where((run) => run.kind == 'director.secret_bind'),
      hasLength(1),
    );
    expect(
      (await h.engine.groupChat(chat))!.members.singleWhere((member) => member.characterId == actor).muted,
      isTrue,
    );
  });

  test('a zero-output actor failure keeps the user and prior actor without retrying or starting another', () async {
    final h = await _Harness.open();
    final a = await h.card('A');
    final b = await h.card('B');
    final c = await h.card('C');
    final chat = await h.engine.createGroupChat(
      [a, b, c],
      activation: TavernGroupActivation.listOrder,
      addGreetings: false,
    );
    h.json('A durable');
    h.response({
      'error': {'message': 'bad fixture key'},
    }, status: 401);
    final events = await h.engine.sendGroup(chat, 'retain user').toList();
    final finish = events.whereType<TavernGroupFinished>().single;
    expect(
      (finish.reason, finish.failure, finish.attemptedCharacterId),
      (TavernGroupEndReason.failed, TavernFailure.badKey, b),
    );
    expect(finish.partial, isNull);
    expect(finish.progress!.remainingCharacterIds, [c]);
    expect(finish.progress!.completedNodeIds, [_done(events).single.nodeId]);
    expect(h.requests, hasLength(2));
    expect(h.keyReads, 2);
    final path = await h.engine.path(chat);
    expect(path.map((row) => (row.role, row.text, row.speakerCharacterId)), [
      (TavernRole.user, 'retain user', null),
      (TavernRole.character, 'A durable', a),
    ]);
    final tree = await h.engine.tree(chat);
    expect(tree.map((node) => node.nodeId), unorderedEquals(path.map((node) => node.nodeId)));
    await h.reopen();
    expect((await h.engine.path(chat)).map((row) => row.nodeId), path.map((row) => row.nodeId));
    expect(h.requests, hasLength(2));

    final empty = await h.engine.createGroupChat(
      [a, b],
      activation: TavernGroupActivation.listOrder,
      addGreetings: false,
    );
    h.response({
      'error': {'message': 'bad fixture key'},
    }, status: 401);
    final firstFailure = await h.engine.sendGroup(empty, 'first user retained').toList();
    final failed = firstFailure.whereType<TavernGroupFinished>().single;
    expect(failed.failure, TavernFailure.badKey);
    expect(failed.partial, isNull);
    expect(failed.progress!.completedNodeIds, isEmpty);
    expect(failed.progress!.remainingCharacterIds, [b]);
    expect((await h.engine.path(empty)).map((row) => (row.role, row.text)), [(TavernRole.user, 'first user retained')]);
    expect(h.requests, hasLength(3));
  });
}

bool _hasDelta(TavernGroupEvent event, String actor, String text) =>
    event is TavernGroupMemberEvent &&
    event.characterId == actor &&
    event.event is TavernTextDelta &&
    (event.event as TavernTextDelta).text == text;

String _text(_Json body) => _maps(body['messages']).map((message) => message['content']).whereType<String>().join('\n');

_Json _counterState({int initial = 0, String summary = 'HOST_COUNT={{state:/count}}'}) => {
  'schema': {
    'type': 'object',
    'additionalProperties': false,
    'required': ['count'],
    'properties': {
      'count': {'type': 'integer', 'minimum': 0, 'maximum': 100, 'default': 0, 'x-dsh-step': 1},
    },
  },
  'init': {'count': initial},
  'summary': summary,
  'depth': 1,
};

_Json _stateCall(int value) => {
  'id': 'state-$value',
  'type': 'function',
  'function': {
    'name': 'update_state',
    'arguments': jsonEncode({
      'ops': [
        {'op': 'set', 'path': '/count', 'value': value, 'why': 'per actor allowance'},
      ],
    }),
  },
};

_Json _directCall({List<_Json> events = const []}) => {
  'id': 'group-direct',
  'type': 'function',
  'function': {
    'name': 'direct',
    'arguments': jsonEncode({
      'notes': 'PRIVATE_DIRECTOR_NOT_CHAT',
      'beat': 'NEXT_BEAT',
      'prefetch': <Object?>[],
      'suggestions': [
        {'text': 'one', 'risk': ''},
        {'text': 'two', 'risk': ''},
        {'text': 'three', 'risk': ''},
      ],
      'events': events,
    }),
  },
};

class _Events {
  _Events(Stream<TavernGroupEvent> source) {
    subscription = source.listen(
      (event) {
        values.add(event);
        changes.add(event);
      },
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
        unawaited(changes.close());
      },
    );
    addTearDown(detach);
  }
  final values = <TavernGroupEvent>[];
  final changes = StreamController<TavernGroupEvent>.broadcast(sync: true);
  final done = Completer<void>();
  late final StreamSubscription<TavernGroupEvent> subscription;
  Future<TavernGroupEvent> until(bool Function(TavernGroupEvent) accept) {
    for (final event in values) {
      if (accept(event)) return Future.value(event);
    }
    return Future.any([
      changes.stream.firstWhere(accept),
      done.future.then<TavernGroupEvent>((_) => throw TestFailure('Group ended before expected event: $values')),
    ]);
  }

  Future<_Request> waitRequest(_Plan plan) => Future.any([
    plan.seen.future,
    done.future.then<_Request>((_) => throw TestFailure('Group ended before expected HTTP request: $values')),
  ]);
  Future<void> detach() async {
    await subscription.cancel();
    if (!changes.isClosed) await changes.close();
  }
}

List<TavernMessage> _done(Iterable<TavernGroupEvent> events) => [
  for (final event in events.whereType<TavernGroupMemberEvent>())
    if (event.event case TavernTurnDone(:final message)) message,
];

_Json _map(Object? value) => value! as _Json;
List<_Json> _maps(Object? value) => (value! as List<Object?>).cast<_Json>();

ChatPreset _preset({bool streaming = false, bool controls = false}) {
  final raw = t24Preset().raw;
  raw.addAll({
    'stream_openai': streaming,
    'openai_max_context': 8192,
    'openai_max_tokens': 73,
    'temperature': 0.4,
    'presence_penalty': 0.2,
    'frequency_penalty': 0.1,
    'top_p': 0.9,
    'seed': -1,
    'squash_system_messages': false,
    'new_group_chat_prompt': controls ? 'NEW {{group}}' : '',
    'group_nudge_prompt': controls ? 'NEXT {{char}};ALL {{group}};ACTIVE {{groupNotMuted}}' : '',
  });
  _maps(raw['prompts']).firstWhere((prompt) => prompt['identifier'] == 'main')['content'] = controls
      ? 'MAIN {{char}}'
      : '';
  return ChatPreset(raw);
}

_Json _body(List<_Json> messages) => {
  'messages': messages,
  'model': 'p2-group-model',
  'temperature': 0.4,
  'max_tokens': 73,
  'stream': false,
  'presence_penalty': 0.2,
  'frequency_penalty': 0.1,
  'top_p': 0.9,
};

_Json _completion(String text, {String reason = 'stop', List<_Json> tools = const []}) => {
  'choices': [
    {
      'index': 0,
      'message': {'role': 'assistant', 'content': text, if (tools.isNotEmpty) 'tool_calls': tools},
      'finish_reason': reason,
    },
  ],
};

class _Harness {
  _Harness(this.root, {required this.random});
  static Future<_Harness> open({bool deepseek = false, bool thinking = false, double Function()? random}) async {
    final root = await Directory.systemTemp.createTemp('dsh-p2-group-turn-');
    final h = _Harness(root, random: random ?? () => 0.25);
    addTearDown(h.dispose);
    h.config = TavernModelConfig(
      apiKey: () async {
        h.keyReads++;
        return 'p2-group-fixture-key';
      },
      baseUrl: 'https://p2-group.invalid/v1',
      model: 'p2-group-model',
      deepseek: deepseek,
      thinking: thinking,
    );
    h.model = TavernModelClient(
      clientFactory: () {
        final peer = _Peer(h);
        h.peers.add(peer);
        return peer;
      },
    );
    h.engine = await h._openEngine();
    h.isOpen = true;
    await h.engine.setPreset(_preset());
    await h.engine.setSettings({
      'userName': 'User',
      'macroEngine': 'modern',
      'globalRegexScripts': <Object?>[],
      'worldInfo': {
        'world_info_depth': 10,
        'world_info_budget': 80,
        'world_info_include_names': false,
        'world_info_recursive': false,
      },
    });
    return h;
  }

  final Directory root;
  final double Function() random;
  late TavernModelConfig config;
  late TavernModelClient model;
  late TavernEngine engine;
  final peers = <_Peer>[];
  final requests = <_Request>[];
  final pending = <_Plan>[];
  final allPlans = <_Plan>[];
  var keyReads = 0;
  var isOpen = false;

  Future<TavernEngine> _openEngine() => TavernEngine.openDirectory(
    root,
    config: config,
    modelClient: model,
    clock: () => DateTime.utc(2026, 11, 12, 4),
    random: random,
  );
  Future<void> reopen() async {
    await engine.close();
    isOpen = false;
    engine = await _openEngine();
    isOpen = true;
  }

  _Plan json(String text, {String reason = 'stop', List<_Json> tools = const []}) =>
      response(_completion(text, reason: reason, tools: tools));
  _Plan response(_Json body, {int status = 200}) {
    final plan = _Plan.json(body, status: status);
    pending.add(plan);
    allPlans.add(plan);
    return plan;
  }

  _Plan stream() {
    final plan = _Plan.stream();
    pending.add(plan);
    allPlans.add(plan);
    return plan;
  }

  Future<String> card(
    String name, {
    String description = '',
    String greeting = '',
    String? book,
    int order = 100,
    String? replacement,
    _Json extensions = const {},
    Object? talkativeness,
  }) async {
    final raw = {
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': name,
        'description': description,
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
        'talkativeness': ?talkativeness,
        'extensions': {
          ...extensions,
          if (replacement != null)
            'regex_scripts': [
              {
                'id': 'write-$name',
                'scriptName': 'actor $name',
                'findRegex': '/RAW/g',
                'replaceString': replacement,
                'placement': [2],
                'trimStrings': <String>[],
                'disabled': false,
                'markdownOnly': false,
                'promptOnly': false,
                'runOnEdit': false,
                'substituteRegex': 0,
              },
            ],
        },
        if (book != null)
          'character_book': {
            'name': 'same book label',
            'extensions': <String, Object?>{},
            'entries': [
              {
                'id': 0,
                'keys': <String>[],
                'secondary_keys': <String>[],
                'content': book,
                'enabled': true,
                'constant': true,
                'insertion_order': order,
                'position': 'before_char',
                'extensions': {'useProbability': false},
              },
            ],
          },
      },
    };
    return (await engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(raw))))).id;
  }

  Future<void> dispose() async {
    try {
      if (isOpen) await engine.close();
    } finally {
      for (final plan in allPlans) {
        await plan.dispose();
      }
      // Engine cancellation releases its tree without promising async* HTTP
      // drainage. The fixture owns these synthetic peers and waits for their
      // actual finally/close after it has released every response stream.
      await Future.wait([for (final peer in peers) peer.closedSignal.future]);
      if (await root.exists()) await root.delete(recursive: true);
    }
    expect(await root.exists(), isFalse);
    expect(peers.every((peer) => peer.closed), isTrue);
    stdout.writeln('P2_GROUP_TURN_CLEANUP');
  }
}

class _Plan {
  _Plan.json(this.jsonBody, {this.status = 200}) : source = null;
  _Plan.stream() : jsonBody = null, status = 200 {
    source = StreamController<List<int>>(
      sync: true,
      onListen: () {
        listening.complete();
      },
    );
  }
  final _Json? jsonBody;
  final int status;
  StreamController<List<int>>? source;
  final seen = Completer<_Request>();
  final listening = Completer<void>();
  Future<void> Function()? beforeResponse;
  var sends = 0;
  void delta(_Json delta) => source!.add(
    utf8.encode(
      'data: ${jsonEncode({
        'choices': [
          {'index': 0, 'delta': delta, 'finish_reason': null},
        ],
      })}\n\n',
    ),
  );
  void finish({String reason = 'stop'}) {
    source!.add(
      utf8.encode(
        'data: ${jsonEncode({
          'choices': [
            {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': reason},
          ],
        })}\n\ndata: [DONE]\n\n',
      ),
    );
    unawaited(source!.close());
  }

  Future<void> dispose() async {
    final stream = source;
    if (stream == null || stream.isClosed) return;
    if (listening.isCompleted) {
      await stream.close();
    } else {
      unawaited(stream.close());
    }
  }
}

class _Peer extends http.BaseClient {
  _Peer(this.h);
  final _Harness h;
  final closedSignal = Completer<void>();
  var closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = _map(jsonDecode(utf8.decode(await request.finalize().toBytes())));
    final captured = (method: request.method, url: request.url, body: body);
    h.requests.add(captured);
    if (h.pending.isEmpty) throw StateError('Unexpected additional group HTTP call.');
    final plan = h.pending.removeAt(0);
    plan.sends++;
    plan.seen.complete(captured);
    await plan.beforeResponse?.call();
    return http.StreamedResponse(
      plan.source?.stream ?? Stream.value(utf8.encode(jsonEncode(plan.jsonBody))),
      plan.status,
      headers: {'content-type': plan.source == null ? 'application/json' : 'text/event-stream'},
    );
  }

  @override
  void close() {
    closed = true;
    if (!closedSignal.isCompleted) closedSignal.complete();
  }
}
