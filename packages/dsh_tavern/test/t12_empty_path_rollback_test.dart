import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// Every empty selection below is created through public facade operations.
// SQLite is read only to compare surviving raw rows and remembered edges;
// this file neither writes selection columns nor calls a new store helper.
void main() {
  // Keep this exact name unique: the owner can reverse only the product
  // patch and run this facade case as the old-implementation negative control.
  test('empty failed send restores an explicit empty selection with retained roots', () async {
    final h = await _open();
    final retained = await _emptySelection(h);
    final active = await _start(h, h.engine.send(h.chatId, '{{setvar::temporary::1}}Q'));
    final inFlight = await h.engine.path(h.chatId);
    expect(inFlight.map((message) => message.role), [TavernRole.user, TavernRole.character]);
    expect(inFlight.first.text, 'Q');
    expect(inFlight.any((message) => message.nodeId == retained.root), isFalse);
    expect(h.engine.variables(h.chatId), {'temporary': '1'});
    active.call.fail(TavernFailure.network, 'no output after the new input and reply were stored');
    final failed = await _failed(active.events);
    expect(failed.kind, TavernFailure.network);
    expect(failed.partial, isNull);
    expect(active.events.values.whereType<TavernTurnStarted>(), hasLength(1));
    await _expectEmpty(h, retained);
    final files = await h.engine.exportChat(h.chatId);
    expect(StChatDocument.decode(files.first.fileName, files.first.bytes).messages, isEmpty);
    await h.reopen();
    await _expectEmpty(h, retained);
    await h.engine.selectNode(h.chatId, retained.root);
    expect((await h.engine.path(h.chatId)).single.nodeId, retained.root);
    expect(h.engine.variables(h.chatId), {'marker': 'A'});
    expect(await h.engine.readVariables(h.chatId), {'marker': 'A'});
  });

  test('stopping an empty-input send restores empty selection without a temporary user node', () async {
    final h = await _open();
    final retained = await _emptySelection(h);
    final active = await _start(h, h.engine.send(h.chatId, ''));
    final inFlight = await h.engine.path(h.chatId);
    expect(inFlight, hasLength(1));
    expect(inFlight.single.role, TavernRole.character);
    expect(inFlight.single.nodeId, isNot(retained.root));
    h.engine.stop(h.chatId);
    final failed = await _failed(active.events);
    expect(failed.kind, TavernFailure.cancelled);
    expect(failed.partial, isNull);
    expect(active.call.cancellation!.isCancelled, isTrue);
    await _expectEmpty(h, retained);
    await h.reopen();
    await _expectEmpty(h, retained);
  });

  test('an inactive continuation failure restores empty selection and its remembered descendants', () async {
    final h = await _open();
    final retained = await _emptySelection(h, descendants: true);
    final active = await _start(h, h.engine.continueReply(h.chatId, retained.target));
    final inFlight = await h.engine.path(h.chatId);
    expect(inFlight.map((message) => message.nodeId), retained.path.take(3));
    expect(inFlight.last.nodeId, retained.target);
    expect(h.engine.variables(h.chatId), {'marker': 'middle'});
    expect((await h.engine.tree(h.chatId)).map((node) => node.nodeId), retained.path);
    active.call.fail(TavernFailure.network, 'inactive continuation without any new output');
    final failed = await _failed(active.events);
    expect(failed.kind, TavernFailure.network);
    // A failed continuation returns its original target, even with no new
    // output. Its non-null partial is not evidence of a newly committed path.
    expect(failed.partial!.nodeId, retained.target);
    expect(failed.partial!.text, 'A1');
    // Restoring the continuation writes the old body once. Body revisions
    // remain monotonic even when the restored bytes equal the original.
    final targetRow = (retained.payload['nodes']! as List<Map<String, Object?>>).singleWhere(
      (node) => node['id'] == retained.target,
    );
    targetRow['content_version'] = (targetRow['content_version']! as int) + 1;
    await _expectEmpty(h, retained);
    await h.reopen();
    await _expectEmpty(h, retained);
    await h.engine.selectSibling(h.chatId, retained.root, 0);
    expect((await h.engine.path(h.chatId)).map((message) => message.nodeId), retained.path);
    expect(h.engine.variables(h.chatId), {'marker': 'tail'});
    expect(await h.engine.readVariables(h.chatId), {'marker': 'tail'});
    expect((await h.engine.tree(h.chatId)).singleWhere((node) => node.nodeId == retained.target).branchName, 'KEPT-A1');
    expect(_payload(h), retained.payload);
  });

  test('inactive regeneration preparation failure restores empty selection before a reply exists', () async {
    final h = await _open();
    final retained = await _emptySelection(h, descendants: true);
    await h.engine.setPreset(_overflowPreset(), chatId: h.chatId);
    final generated = h.model.generated;
    // No prepared provider call: preparation must fail before generate, after
    // recording the inactive prefix's remembered selection for rollback.
    final events = T24Events(h.engine.regenerate(h.chatId, retained.target));
    final failed = await _failed(events);
    expect(failed.kind, TavernFailure.contextTooLong);
    expect(failed.partial, isNull);
    expect(events.values.whereType<TavernTurnStarted>(), isEmpty);
    expect(h.model.generated, generated);
    await _expectEmpty(h, retained);
    await h.reopen();
    await _expectEmpty(h, retained);
    await h.engine.selectSibling(h.chatId, retained.root, 0);
    expect((await h.engine.path(h.chatId)).map((message) => message.nodeId), retained.path);
    expect(h.engine.variables(h.chatId), {'marker': 'tail'});
    expect(await h.engine.readVariables(h.chatId), {'marker': 'tail'});
    expect(_payload(h), retained.payload);
  });

  for (final partial in [false, true]) {
    test(
      '${partial ? 'partial output' : 'successful output'} from empty selection keeps its newly committed path',
      () async {
        final h = await _open();
        final retained = await _emptySelection(h);
        final active = await _start(h, h.engine.send(h.chatId, '{{setvar::marker::NEW}}Q'));
        final inFlight = await h.engine.path(h.chatId);
        expect(inFlight.map((message) => message.role), [TavernRole.user, TavernRole.character]);
        final replyId = inFlight.last.nodeId;
        active.call.add(const ModelText('KEPT-OUTPUT'));
        final TavernMessage reply;
        if (partial) {
          active.call.fail(TavernFailure.network, 'real text arrived before transport failure');
          final failed = await _failed(active.events);
          expect(failed.kind, TavernFailure.network);
          reply = failed.partial!;
        } else {
          await active.call.finish();
          reply = await _succeeded(active.events);
        }
        expect(reply.nodeId, replyId);
        expect(reply.text, 'KEPT-OUTPUT');
        expect(active.events.values.whereType<TavernTextDelta>().map((event) => event.text).join(), 'KEPT-OUTPUT');
        expect(
          (await h.engine.path(h.chatId)).map((message) => message.nodeId),
          inFlight.map((message) => message.nodeId),
        );
        expect(h.engine.variables(h.chatId), {'marker': 'NEW'});
        expect(await h.engine.readVariables(h.chatId), {'marker': 'NEW'});
        expect(
          (await h.engine.tree(h.chatId)).singleWhere((node) => node.nodeId == retained.root).isCurrentPath,
          isFalse,
        );
        expect(_payload(h, ids: retained.path.toSet()), retained.payload);
        await h.reopen();
        expect(
          (await h.engine.path(h.chatId)).map((message) => message.nodeId),
          inFlight.map((message) => message.nodeId),
        );
        expect(h.engine.variables(h.chatId), {'marker': 'NEW'});
        expect(await h.engine.readVariables(h.chatId), {'marker': 'NEW'});
        expect(_payload(h, ids: retained.path.toSet()), retained.payload);
      },
    );
  }

  test('a chat without retained roots still rolls back an empty send and accepts a later reply', () async {
    final h = await _open();
    final greeting = (await h.engine.path(h.chatId)).single;
    await h.engine.deleteMessage(h.chatId, greeting.nodeId);
    expect(await h.engine.path(h.chatId), isEmpty);
    expect(await h.engine.tree(h.chatId), isEmpty);
    final active = await _start(h, h.engine.send(h.chatId, ''));
    expect((await h.engine.path(h.chatId)).single.role, TavernRole.character);
    active.call.fail(TavernFailure.network, 'truly empty chat control');
    final failed = await _failed(active.events);
    expect(failed.kind, TavernFailure.network);
    expect(failed.partial, isNull);
    expect(await h.engine.path(h.chatId), isEmpty);
    expect(await h.engine.tree(h.chatId), isEmpty);
    expect(h.engine.variables(h.chatId), isEmpty);
    expect(await h.engine.readVariables(h.chatId), isEmpty);
    await h.reopen();
    expect(await h.engine.path(h.chatId), isEmpty);
    expect(await h.engine.tree(h.chatId), isEmpty);
    final retry = await _success(h, h.engine.send(h.chatId, ''), 'first real reply');
    expect((await h.engine.path(h.chatId)).single.nodeId, retry.nodeId);
    expect((await h.engine.tree(h.chatId)).single.isCurrentPath, isTrue);
    expect(h.engine.variables(h.chatId), isEmpty);
    expect(await h.engine.readVariables(h.chatId), isEmpty);
  });
}

const _deadline = Duration(seconds: 10);
typedef _Active = ({T24Call call, T24Events events});
typedef _Retained = ({String root, String target, List<String> path, Map<String, Object?> payload});

Future<T24Harness> _open() async {
  final h = await T24Harness.open(thinking: false);
  addTearDown(h.dispose);
  return h;
}

Future<_Active> _start(T24Harness h, Stream<TavernEvent> source) async {
  final call = h.model.prepare();
  final events = T24Events(source);
  await Future.any<void>([
    call.listening.future,
    events.done.future.then<void>((_) {
      throw TestFailure('The turn ended before provider subscription: ${events.values}');
    }),
  ]).timeout(_deadline);
  return (call: call, events: events);
}

Future<TavernMessage> _succeeded(T24Events events) async {
  await events.done.future.timeout(_deadline);
  expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
  return events.values.whereType<TavernTurnDone>().single.message;
}

Future<TavernTurnFailed> _failed(T24Events events) async {
  await events.done.future.timeout(_deadline);
  expect(events.values.whereType<TavernTurnDone>(), isEmpty);
  return events.values.whereType<TavernTurnFailed>().single;
}

Future<TavernMessage> _success(T24Harness h, Stream<TavernEvent> source, String text) async {
  final active = await _start(h, source);
  active.call.add(ModelText(text));
  await active.call.finish();
  return _succeeded(active.events);
}

Future<_Retained> _emptySelection(T24Harness h, {bool descendants = false}) async {
  final root = (await h.engine.path(h.chatId)).single.nodeId;
  expect((await h.engine.setStateValue(h.chatId, '/marker', 'A')).applied, isTrue);
  var target = root;
  if (descendants) {
    target = (await _success(h, h.engine.send(h.chatId, '{{setvar::marker::middle}}U1'), 'A1')).nodeId;
    await _success(h, h.engine.send(h.chatId, '{{setvar::marker::tail}}U2'), 'A2');
    await h.engine.nameBranch(h.chatId, target, 'KEPT-A1');
  }
  final remembered = (await h.engine.path(h.chatId)).map((message) => message.nodeId).toList();
  final otherRoot = await _success(h, h.engine.regenerate(h.chatId, root), 'temporary root B');
  expect((await h.engine.path(h.chatId)).single.nodeId, otherRoot.nodeId);
  await h.engine.deleteMessage(h.chatId, otherRoot.nodeId);
  final retained = (root: root, target: target, path: remembered, payload: _payload(h));
  await _expectEmpty(h, retained);
  return retained;
}

Future<void> _expectEmpty(T24Harness h, _Retained retained) async {
  // On the unpatched product, the core regression fails here because deleting
  // this attempt's temporary root activates the retained root as a fallback.
  expect(await h.engine.path(h.chatId), isEmpty);
  final tree = await h.engine.tree(h.chatId);
  expect(tree.map((node) => node.nodeId), retained.path);
  expect(tree.every((node) => !node.isCurrentPath), isTrue);
  expect(h.engine.variables(h.chatId), isEmpty);
  expect(await h.engine.readVariables(h.chatId), isEmpty);
  expect(_payload(h), retained.payload);
}

Map<String, Object?> _payload(T24Harness h, {Set<String>? ids}) {
  final database = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    return {
      'nodes': [
        for (final row in database.select('SELECT * FROM nodes WHERE chat_id = ? ORDER BY seq', [h.chatId]))
          if (ids == null || ids.contains(row['id'])) Map<String, Object?>.from(row),
      ],
      'states': [
        for (final row in database.select(
          '''SELECT s.* FROM node_states s JOIN nodes n ON n.id = s.node_id
            WHERE n.chat_id = ? ORDER BY n.seq''',
          [h.chatId],
        ))
          if (ids == null || ids.contains(row['node_id'])) Map<String, Object?>.from(row),
      ],
    };
  } finally {
    database.close();
  }
}

ChatPreset _overflowPreset() {
  final raw = t24Preset().raw;
  final prompts = (raw['prompts']! as List<Object?>).cast<Map<String, Object?>>();
  return ChatPreset({
    ...raw,
    'openai_max_context': 3,
    'openai_max_tokens': 0,
    'prompts': [
      for (final entry in prompts)
        if (entry['identifier'] == 'main')
          {...entry, 'content': List.filled(100, 'mandatory system content').join(' ')}
        else
          entry,
    ],
  });
}
