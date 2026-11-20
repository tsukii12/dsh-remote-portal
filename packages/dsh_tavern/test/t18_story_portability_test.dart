import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

typedef _Json = Map<String, Object?>;

const _runtimeKey = 'dshgoStoryRuntime';

_Json _map(Object? value) => value! as _Json;

Future<T24Harness> _open() async {
  final h = await T24Harness.open(thinking: false);
  addTearDown(h.dispose);
  await h.engine.setSettings({
    'director': {'enabled': true, 'every': 1000},
  });
  return h;
}

Future<({String character, String chat})> _storyChat(T24Harness h) async {
  final raw = _map(jsonDecode(utf8.decode(t24Card())));
  _map(raw['data'])['extensions'] = {
    'dshgo': {
      'v': 1,
      'story': {
        'outline': 'Private portable story',
        'acts': [
          {'id': 'waiting', 'title': 'Waiting', 'goal': 'Keep the branch ledger', 'when': false, 'maxTurns': 1000},
        ],
        'endings': [
          {'id': 'arrival', 'title': 'Arrival recorded', 'when': true},
        ],
      },
    },
  };
  final character = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(raw))));
  return (character: character.id, chat: await h.engine.createChat(character.id));
}

Future<TavernMessage> _complete(T24Harness h, Stream<TavernEvent> source, String text) async {
  final call = h.model.prepare();
  final events = T24Events(source);
  await Future.any<void>([
    call.listening.future,
    events.done.future.then<void>((_) {
      throw TestFailure('Turn ended before model input: ${events.values}');
    }),
  ]);
  call.add(ModelText(text));
  await call.finish();
  await events.done.future;
  expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
  return events.values.whereType<TavernTurnDone>().single.message;
}

Future<TavernMessage> _reply(T24Harness h, String chat, String text) => _complete(h, h.engine.send(chat, ''), text);

Future<_Json> _story(TavernEngine engine, String chat) async => (await engine.readDirector(chat)).story!;

Future<_Json> _saved(TavernEngine engine, String chat) async {
  final files = await engine.exportChat(chat);
  final document = StChatDocument.decode(files.first.fileName, files.first.bytes);
  final saved = _map(_map(_map(document.messages.last['extra'])['dshgo'])['tavernState']);
  // The document is deeply read-only; mutation fixtures need detached JSON.
  return _map(jsonDecode(jsonEncode(saved)));
}

T _db<T>(T24Harness h, T Function(Database) action) {
  final db = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    return action(db);
  } finally {
    db.close();
  }
}

Future<void> _replaceSaved(T24Harness h, String chat, _Json saved) async {
  final leaf = (await h.engine.path(chat)).last.nodeId;
  _db(h, (db) {
    final extra = _map(
      jsonDecode(db.select('SELECT extra FROM nodes WHERE id = ?', [leaf]).single['extra']! as String),
    );
    final own = extra['dshgo'];
    extra['dshgo'] = {if (own is _Json) ...own, 'tavernState': saved};
    db.execute('UPDATE nodes SET extra = ? WHERE id = ?', [jsonEncode(extra), leaf]);
  });
}

Future<_Json> _own(T24Harness h, String chat) async {
  final leaf = (await h.engine.path(chat)).last.nodeId;
  return _db(h, (db) {
    final extra = _map(
      jsonDecode(db.select('SELECT extra FROM nodes WHERE id = ?', [leaf]).single['extra']! as String),
    );
    final own = extra['dshgo'];
    return own == null ? <String, Object?>{} : _map(own);
  });
}

Future<List<TavernAgentRun>> _runs(TavernEngine engine, String chat) async =>
    (await engine.readAgentRuns(chat, limit: 1000)).where((run) => run.kind == 'story.rules').toList();

_Json _runValues(TavernAgentRun run) => {'id': run.id, 'nodeId': run.nodeId, 'result': run.result};

Future<String> _importSaved(T24Harness h, String character, _Json saved) async {
  const name = 'story-state.jsonl';
  final document = StChatDocument(
    fileName: name,
    header: {
      'user_name': 'User',
      'character_name': 'Guide',
      'chat_metadata': {
        'variables': {'local': 'kept'},
      },
    },
    messages: [
      {
        'name': 'Guide',
        'is_user': false,
        'is_system': false,
        'mes': 'imported story',
        'send_date': T24Harness.at.toIso8601String(),
        if (saved.containsKey('messageVariables')) 'variables': [saved['messageVariables']],
        'extra': {
          'dshgo': {'tavernState': saved},
        },
      },
    ],
  );
  return (await h.engine.importChats(character, [
    TavernChatFile(fileName: name, bytes: document.encode()),
  ])).chatIds.single;
}

void main() {
  test('JSONL preserves each swipe story ledger and own audit without fabricating full agent history', () async {
    final h = await _open();
    final created = await _storyChat(h);
    final initial = await _saved(h.engine, created.chat);
    initial['vendorState'] = {
      'opaque': [false, null, 'kept'],
    };
    initial['messageVariables'] = {
      'stat_data': {
        'external': [7, null],
      },
    };
    await _replaceSaved(h, created.chat, initial);
    final first = await _reply(h, created.chat, 'branch A');
    final firstStory = await _story(h.engine, created.chat);
    final alternative = await _complete(h, h.engine.regenerate(created.chat, first.nodeId), 'branch B');
    await _complete(h, h.engine.continueReply(created.chat, alternative.nodeId), ' continued');
    final selected = await _story(h.engine, created.chat);
    final selectedSaved = await _saved(h.engine, created.chat);
    expect(selected['actTurns'], 2);
    expect(selected['unlockedEndings'], ['arrival']);
    expect(selected['effects'], isEmpty);
    expect(await _runs(h.engine, created.chat), hasLength(3));

    final files = await h.engine.exportChat(created.chat);
    final imported = (await h.engine.importChats(created.character, files)).chatIds.single;
    final copy = await _story(h.engine, imported);
    expect(copy['actTurns'], 2);
    expect(copy['unlockedEndings'], selected['unlockedEndings']);
    expect(copy['changes'], selected['changes']);
    expect(copy['effects'], selected['effects']);
    expect((await _saved(h.engine, imported))[_runtimeKey], selectedSaved[_runtimeKey]);
    expect((await _saved(h.engine, imported))['vendorState'], initial['vendorState']);
    expect(_map((await _saved(h.engine, imported))['messageVariables'])['stat_data'], {
      'external': [7, null],
    });
    expect(await h.engine.readAgentRuns(imported), isEmpty);

    final importedLeaf = (await h.engine.path(imported)).last;
    expect(importedLeaf.siblingCount, 2);
    await h.engine.selectSibling(imported, importedLeaf.nodeId, 0);
    final restoredFirst = await _story(h.engine, imported);
    expect(restoredFirst['actTurns'], 1);
    expect(restoredFirst['changes'], firstStory['changes']);
    expect(restoredFirst['effects'], firstStory['effects']);
    expect(restoredFirst['unlockedEndings'], ['arrival']);
    final firstCopy = (await h.engine.path(imported)).last;
    await _complete(h, h.engine.continueReply(imported, firstCopy.nodeId), ' imported continuation');
    final afterContinue = await _story(h.engine, imported);
    expect(afterContinue['actTurns'], 2);
    expect(afterContinue['effects'], isEmpty);
    expect(await _runs(h.engine, imported), hasLength(1));
    await h.reopen();
    expect(await _story(h.engine, imported), afterContinue);
    expect(await _runs(h.engine, imported), hasLength(1));
    expect(h.model.generated, 4);
  });

  test(
    'full backup restores both branch ledgers full audit rows and incompatible runtime without executing them',
    () async {
      final h = await _open();
      final work = await Directory.systemTemp.createTemp('dsh-t18-story-backup-');
      TavernEngine? restored;
      addTearDown(() async {
        await restored?.close();
        await work.delete(recursive: true);
      });
      final created = await _storyChat(h);
      final first = await _reply(h, created.chat, 'first branch');
      final firstView = await _story(h.engine, created.chat);
      final alternative = await _complete(h, h.engine.regenerate(created.chat, first.nodeId), 'second branch');
      await _complete(h, h.engine.continueReply(created.chat, alternative.nodeId), ' continued');
      final view = await _story(h.engine, created.chat);
      final saved = await _saved(h.engine, created.chat);
      final runs = await _runs(h.engine, created.chat);
      expect(runs, hasLength(3));
      final badSaved = _map(jsonDecode(jsonEncode(saved)));
      badSaved[_runtimeKey] = {
        ..._map(badSaved[_runtimeKey]),
        'version': 99,
        'vendor': {'preserve': true},
      };
      final badChat = await _importSaved(h, created.character, badSaved);
      final badView = await _story(h.engine, badChat);
      expect(badView['valid'], isFalse);

      final archive = File('${work.path}/story.zip');
      await h.engine.backup(archive.path);
      final target = Directory('${work.path}/restored');
      await restoreTavernDirectory(archive.path, target.path);
      final engine = restored = await TavernEngine.openDirectory(target);
      expect(await _story(engine, created.chat), view);
      expect((await _saved(engine, created.chat))[_runtimeKey], saved[_runtimeKey]);
      expect((await _runs(engine, created.chat)).map(_runValues).toList(), runs.map(_runValues).toList());
      expect(await _story(engine, badChat), badView);
      expect((await _saved(engine, badChat))[_runtimeKey], badSaved[_runtimeKey]);
      expect(await _runs(engine, badChat), isEmpty);
      await engine.selectSibling(created.chat, alternative.nodeId, 0);
      expect(await _story(engine, created.chat), firstView);
      expect((await engine.path(created.chat)).last.nodeId, first.nodeId);
      expect(h.model.generated, 3);
    },
  );

  test(
    'deleting one ancestor preserves descendant story state and retains the deleted node audit without an anchor',
    () async {
      final h = await _open();
      final created = await _storyChat(h);
      final first = await _reply(h, created.chat, 'ancestor');
      final second = await _reply(h, created.chat, 'descendant');
      await _complete(h, h.engine.continueReply(created.chat, second.nodeId), ' continuation');
      final before = await _story(h.engine, created.chat);
      final saved = await _saved(h.engine, created.chat);
      final own = await _own(h, created.chat);
      final deletedRun = (await _runs(h.engine, created.chat)).singleWhere((run) => run.nodeId == first.nodeId);
      expect(before['actTurns'], 3);
      await h.engine.deleteMessage(created.chat, first.nodeId);
      final path = await h.engine.path(created.chat);
      expect(path.map((node) => node.nodeId), isNot(contains(first.nodeId)));
      expect(path.last.nodeId, second.nodeId);
      expect(await _story(h.engine, created.chat), before);
      expect((await _saved(h.engine, created.chat))[_runtimeKey], saved[_runtimeKey]);
      expect((await _own(h, created.chat))['storyInvocation'], own['storyInvocation']);
      final retained = (await _runs(h.engine, created.chat)).singleWhere((run) => run.id == deletedRun.id);
      expect(retained.nodeId, isNull);
      expect(retained.result, deletedRun.result);
      await _complete(h, h.engine.continueReply(created.chat, second.nodeId), ' after reparent');
      final after = await _story(h.engine, created.chat);
      expect(after['actTurns'], 4);
      expect(after['unlockedEndings'], ['arrival']);
      expect(after['effects'], isEmpty);
      await h.reopen();
      expect(await _story(h.engine, created.chat), after);
    },
  );

  test('undoing a subtree deletion restores the exact selected story snapshot and does not replay endings', () async {
    final h = await _open();
    final created = await _storyChat(h);
    final first = await _reply(h, created.chat, 'ancestor');
    final second = await _reply(h, created.chat, 'descendant');
    final before = await _story(h.engine, created.chat);
    final saved = await _saved(h.engine, created.chat);
    final own = await _own(h, created.chat);
    final runs = (await _runs(h.engine, created.chat)).map(_runValues).toList();
    final token = await h.engine.deleteFrom(created.chat, first.nodeId);
    final previous = await _story(h.engine, created.chat);
    expect(previous['initialized'], isFalse);
    expect(previous['actTurns'], 0);
    expect(previous['unlockedEndings'], isEmpty);
    expect(h.model.generated, 2);
    expect(await h.engine.undoDeleteFrom(created.chat, token), isTrue);
    expect((await h.engine.path(created.chat)).last.nodeId, second.nodeId);
    expect(await _story(h.engine, created.chat), before);
    expect((await _saved(h.engine, created.chat))[_runtimeKey], saved[_runtimeKey]);
    expect((await _own(h, created.chat))['storyInvocation'], own['storyInvocation']);
    expect((await _runs(h.engine, created.chat)).map(_runValues).toList(), runs);
    await _complete(h, h.engine.continueReply(created.chat, second.nodeId), ' restored continuation');
    final after = await _story(h.engine, created.chat);
    expect(after['actTurns'], 3);
    expect(after['effects'], isEmpty);
    expect(after['unlockedEndings'], ['arrival']);
    expect(h.model.generated, 3);
  });

  test(
    'portable story overrides a different physical snapshot and manual children inherit state without own audit',
    () async {
      final h = await _open();
      final created = await _storyChat(h);
      final first = await _reply(h, created.chat, 'first');
      final saved = await _saved(h.engine, created.chat);
      final physical = _db(
        h,
        (db) => [
          for (final row in db.select('SELECT * FROM node_states WHERE node_id = ?', [first.nodeId]))
            Map<String, Object?>.from(row),
        ],
      );
      saved[_runtimeKey] = {
        ..._map(saved[_runtimeKey]),
        'actTurns': 40,
        'vendor': {
          'keep': [null, false],
        },
      };
      await _replaceSaved(h, created.chat, saved);
      expect(
        _db(
          h,
          (db) => [
            for (final row in db.select('SELECT * FROM node_states WHERE node_id = ?', [first.nodeId]))
              Map<String, Object?>.from(row),
          ],
        ),
        physical,
      );
      expect((await _story(h.engine, created.chat))['actTurns'], 40);
      await h.engine.narrate(created.chat, 'a manual interlude');
      final manual = await _story(h.engine, created.chat);
      expect(manual['actTurns'], 40);
      expect(manual['changes'], isEmpty);
      expect(manual['effects'], isEmpty);
      expect((await _own(h, created.chat)).containsKey('storyInvocation'), isFalse);
      await _reply(h, created.chat, 'after the interlude');
      final after = await _story(h.engine, created.chat);
      expect(after['actTurns'], 41);
      expect(after['unlockedEndings'], ['arrival']);
      expect(after['effects'], isEmpty);
      expect(_map((await _saved(h.engine, created.chat))[_runtimeKey])['vendor'], {
        'keep': [null, false],
      });
      await h.reopen();
      expect(await _story(h.engine, created.chat), after);
      expect(h.model.generated, 2);
    },
  );

  for (final kind in ['explicit-null', 'future-version', 'incompatible-definition']) {
    test('JSONL keeps $kind story runtime through reading generation export and reopening', () async {
      final h = await _open();
      final created = await _storyChat(h);
      await _reply(h, created.chat, 'source');
      final saved = await _saved(h.engine, created.chat);
      final oldRuntime = _map(saved[_runtimeKey]);
      saved[_runtimeKey] = switch (kind) {
        'explicit-null' => null,
        'future-version' => {
          ...oldRuntime,
          'version': 99,
          'vendor': {'opaque': true},
        },
        _ => {
          ...oldRuntime,
          'definitionFingerprint': 'another-story',
          'vendor': {'opaque': true},
        },
      };
      saved['vendorState'] = {
        'keep': [false, null],
      };
      saved['messageVariables'] = {
        'stat_data': {'opaque': 7},
      };
      final originalRuntime = jsonEncode(saved[_runtimeKey]);
      final imported = await _importSaved(h, created.character, saved);
      final before = await _story(h.engine, imported);
      expect(before['initialized'], isTrue);
      expect(before['valid'], isFalse);
      expect(before['issues'], isNotEmpty);
      expect(jsonEncode((await _saved(h.engine, imported))[_runtimeKey]), originalRuntime);
      expect(await _runs(h.engine, imported), isEmpty);
      expect(h.model.generated, 1);
      await _reply(h, imported, 'the body can still be generated');
      final after = await _story(h.engine, imported);
      expect(after['valid'], isFalse);
      expect(after['changes'], isEmpty);
      expect(after['effects'], isEmpty);
      final afterSaved = await _saved(h.engine, imported);
      expect(jsonEncode(afterSaved[_runtimeKey]), originalRuntime);
      expect(afterSaved['vendorState'], saved['vendorState']);
      expect(_map(afterSaved['messageVariables'])['stat_data'], {'opaque': 7});
      final rejected = (await _runs(h.engine, imported)).single;
      expect(rejected.result['committed'], isFalse);
      expect(rejected.result['countTurn'], isFalse);
      expect(rejected.result['effects'], isEmpty);
      final files = await h.engine.exportChat(imported);
      final copied = (await h.engine.importChats(created.character, files)).chatIds.single;
      expect(jsonEncode((await _saved(h.engine, copied))[_runtimeKey]), originalRuntime);
      expect((await _story(h.engine, copied))['valid'], isFalse);
      expect(await _runs(h.engine, copied), isEmpty);
      await h.reopen();
      expect(jsonEncode((await _saved(h.engine, copied))[_runtimeKey]), originalRuntime);
      expect((await _story(h.engine, copied))['valid'], isFalse);
      expect(h.model.generated, 2);
    });
  }
}
