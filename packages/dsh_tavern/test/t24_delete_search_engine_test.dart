import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('delete and undo restore node identities, branch variables, reports and export visibility together', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final old = await h.reply('old', usage: const TavernUsage(promptTokens: 7, cacheHitTokens: 3));
    await h.engine.edit(h.chatId, old.nodeId, '{{setvar::branch::old}}needle old');
    final tail = await h.reply('tail', usage: const TavernUsage(promptTokens: 11, completionTokens: 4));
    await h.engine.edit(h.chatId, tail.nodeId, '{{setvar::branch::tail}}needle tail');
    final before = await h.engine.path(h.chatId);
    expect(h.engine.variables(h.chatId)['branch'], 'tail');
    expect((await h.engine.inspectTurn(h.chatId))!.nodeId, tail.nodeId);

    final token = await h.engine.deleteFrom(h.chatId, old.nodeId);
    expect(token, isNotEmpty);
    expect(_ids(await h.engine.path(h.chatId)), _ids(before.take(2)));
    expect(h.engine.variables(h.chatId), isEmpty);
    expect(await h.engine.searchChat(h.chatId, 'needle'), isEmpty);
    expect(await h.engine.inspectTurn(h.chatId), isNull);
    expect(await h.engine.inspectTurn(h.chatId, nodeId: tail.nodeId), isNull);
    expect(await _exportText(h), isNot(contains('needle old')));
    _inspect(h, (db) {
      expect(db.select('SELECT id FROM nodes WHERE deleted_by = ?', [token]), hasLength(3));
      expect(db.select('SELECT text FROM nodes WHERE id = ?', [tail.nodeId]).single['text'], 'needle tail');
    });

    expect(await h.engine.undoDeleteFrom(h.chatId, token), isTrue);
    final restored = await h.engine.path(h.chatId);
    expect(_ids(restored), _ids(before));
    expect(restored.map((m) => m.text), before.map((m) => m.text));
    expect(restored.last.reportedUsage!.promptTokens, 11);
    expect(h.engine.variables(h.chatId)['branch'], 'tail');
    expect((await h.engine.inspectTurn(h.chatId, nodeId: tail.nodeId))!.reportedUsage!.completionTokens, 4);
    // Undo restores the node's evidence, not a new latest attempt.
    expect(await h.engine.inspectTurn(h.chatId), isNull);
    expect(await _exportText(h), contains('needle old'));
    expect(await h.engine.undoDeleteFrom(h.chatId, token), isFalse);
  });

  test('undo preserves new replies and variables while restoring the old branch for later selection', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final old = await h.reply('old branch');
    await h.engine.edit(h.chatId, old.nodeId, '{{setvar::branch::old}}old branch');
    final token = await h.engine.deleteFrom(h.chatId, old.nodeId);
    final fresh = await h.reply('new branch');
    await h.engine.edit(h.chatId, fresh.nodeId, '{{setvar::branch::new}}new branch');
    final current = await h.engine.path(h.chatId);
    expect(await h.engine.undoDeleteFrom(h.chatId, token), isTrue);
    expect(_ids(await h.engine.path(h.chatId)), _ids(current));
    expect(h.engine.variables(h.chatId)['branch'], 'new');
    expect((await h.engine.inspectTurn(h.chatId))!.nodeId, fresh.nodeId);
    final restoredOld = (await h.engine.searchChat(h.chatId, 'old branch')).single;
    expect(restoredOld.nodeId, old.nodeId);
    expect(restoredOld.siblingCount, 2);
    await h.engine.selectSibling(h.chatId, old.nodeId, 0);
    expect((await h.engine.path(h.chatId)).last.nodeId, old.nodeId);
    expect(h.engine.variables(h.chatId)['branch'], 'old');
    await h.engine.selectSibling(h.chatId, old.nodeId, 1);
    expect((await h.engine.path(h.chatId)).last.nodeId, fresh.nodeId);
    expect(h.engine.variables(h.chatId)['branch'], 'new');
  });

  test(
    'deleting an active detached subtree first finalizes cancellation and undo restores that partial reply',
    () async {
      final h = await T24Harness.open();
      addTearDown(h.dispose);
      final before = await h.engine.path(h.chatId);
      final call = h.model.prepare();
      final events = T24Events(h.engine.send(h.chatId, 'new question'));
      await call.listening.future;
      call.add(const ModelText('partial answer'));
      call.add(const ModelUsage(TavernUsage(promptTokens: 13, completionTokens: 2)));
      final active = await h.engine.path(h.chatId);
      final user = active[active.length - 2];
      final reply = active.last;
      await events.detach();
      expect(call.cancellation!.isCancelled, isFalse);

      final token = await h.engine.deleteFrom(h.chatId, user.nodeId);
      expect(call.cancellation!.isCancelled, isTrue);
      expect(_ids(await h.engine.path(h.chatId)), _ids(before));
      expect(await h.engine.resumeTurn(h.chatId).toList(), isEmpty);
      expect(await h.engine.undoDeleteFrom(h.chatId, token), isTrue);
      final restored = await h.engine.path(h.chatId);
      expect(restored.last.nodeId, reply.nodeId);
      expect(restored.last.text, 'partial answer');
      expect(restored.last.reportedUsage!.promptTokens, 13);
      final inspection = (await h.engine.inspectTurn(h.chatId, nodeId: reply.nodeId))!;
      expect(inspection.status, TavernInspectionStatus.failed);
      expect(inspection.failure, TavernFailure.cancelled);
      expect(inspection.reportedUsage!.completionTokens, 2);
      expect(await h.engine.inspectTurn(h.chatId), isNull);
    },
  );

  test('failure while restoring variables rolls the entire facade deletion back', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final reply = await h.reply('kept');
    await h.engine.edit(h.chatId, reply.nodeId, '{{setvar::branch::kept}}kept');
    final before = await h.engine.path(h.chatId);
    final variables = h.engine.variables(h.chatId);
    _inspect(
      h,
      (db) => db.execute('''CREATE TRIGGER reject_runtime BEFORE UPDATE OF variables ON chats
      BEGIN SELECT RAISE(ABORT, 'fixture_runtime'); END'''),
    );
    await expectLater(h.engine.deleteFrom(h.chatId, reply.nodeId), throwsA(isA<SqliteException>()));
    expect(_ids(await h.engine.path(h.chatId)), _ids(before));
    expect(h.engine.variables(h.chatId), variables);
    expect((await h.engine.inspectTurn(h.chatId))!.nodeId, reply.nodeId);
    _inspect(h, (db) {
      expect(db.select('SELECT * FROM deleted_subtrees'), isEmpty);
      expect(db.select('SELECT id FROM nodes WHERE deleted_by IS NOT NULL'), isEmpty);
      db.execute('DROP TRIGGER reject_runtime');
    });
    final token = await h.engine.deleteFrom(h.chatId, reply.nodeId);
    expect(await h.engine.undoDeleteFrom(h.chatId, token), isTrue);
  });

  test('failure while restoring variables rolls facade undo back and retains a usable token', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final reply = await h.reply('kept');
    await h.engine.edit(h.chatId, reply.nodeId, '{{setvar::branch::restored}}kept');
    final token = await h.engine.deleteFrom(h.chatId, reply.nodeId);
    final before = await h.engine.path(h.chatId);
    final variables = h.engine.variables(h.chatId);
    _inspect(
      h,
      (db) => db.execute('''CREATE TRIGGER reject_runtime BEFORE UPDATE OF variables ON chats
      BEGIN SELECT RAISE(ABORT, 'fixture_runtime'); END'''),
    );
    await expectLater(h.engine.undoDeleteFrom(h.chatId, token), throwsA(isA<SqliteException>()));
    expect(_ids(await h.engine.path(h.chatId)), _ids(before));
    expect(h.engine.variables(h.chatId), variables);
    expect(await h.engine.inspectTurn(h.chatId, nodeId: reply.nodeId), isNull);
    _inspect(h, (db) {
      expect(db.select('SELECT id FROM deleted_subtrees WHERE id = ?', [token]), hasLength(1));
      expect(db.select('SELECT deleted_by FROM nodes WHERE id = ?', [reply.nodeId]).single['deleted_by'], token);
      db.execute('DROP TRIGGER reject_runtime');
    });
    expect(await h.engine.undoDeleteFrom(h.chatId, token), isTrue);
    expect((await h.engine.path(h.chatId)).last.nodeId, reply.nodeId);
    expect(h.engine.variables(h.chatId)['branch'], 'restored');
  });

  test('the next engine open physically purges deleted nodes and invalidates their undo token', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final reply = await h.reply('purgedword', usage: const TavernUsage(promptTokens: 9));
    final token = await h.engine.deleteFrom(h.chatId, reply.nodeId);
    _inspect(h, (db) => expect(db.select('SELECT id FROM nodes WHERE id = ?', [reply.nodeId]), hasLength(1)));
    await h.reopen();
    expect(await h.engine.undoDeleteFrom(h.chatId, token), isFalse);
    expect(await h.engine.searchChat(h.chatId, 'purgedword'), isEmpty);
    expect(await h.engine.inspectTurn(h.chatId, nodeId: reply.nodeId), isNull);
    expect((await h.engine.path(h.chatId)).last.role, TavernRole.user);
    _inspect(h, (db) {
      expect(db.select('SELECT id FROM nodes WHERE id = ?', [reply.nodeId]), isEmpty);
      expect(db.select('SELECT * FROM deleted_subtrees'), isEmpty);
      expect(db.select('PRAGMA foreign_key_check'), isEmpty);
    });
  });

  test('search excludes a continuation before its first checkpoint and fills the limit from older matches', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final older = await h.reply('older needle', usage: const TavernUsage(promptTokens: 2));
    final original = await h.reply('original needle', usage: const TavernUsage(promptTokens: 91));
    final call = h.model.prepare();
    final events = T24Events(h.engine.continueReply(h.chatId, original.nodeId));
    await call.listening.future;
    // No body event yet: even a fired 500ms timer has nothing to checkpoint.
    _inspect(
      h,
      (db) => expect(
        db.select('SELECT stream_text FROM nodes WHERE id = ?', [original.nodeId]).single['stream_text'],
        isNull,
      ),
    );
    expect(await h.engine.searchChat(h.chatId, 'original needle'), isEmpty);
    final body = await h.engine.searchChat(h.chatId, 'needle', limit: 1);
    expect(_ids(body), [older.nodeId]);
    expect(body.single.reportedUsage!.promptTokens, 2);
    final speakers = await h.engine.searchChat(h.chatId, 'Guide', limit: 2);
    expect(speakers.map((m) => m.text), ['older needle', 'G']);
    expect(await h.engine.searchChat(h.chatId, 'needle', limit: 0), isEmpty);
    await expectLater(h.engine.searchChat(h.chatId, 'needle', limit: -1), throwsArgumentError);
    expect(call.cancellation!.isCancelled, isFalse);
    call.add(const ModelText('+new'));
    call.add(const ModelUsage(TavernUsage(promptTokens: 13, cacheHitTokens: 4)));
    await call.finish();
    await events.done.future;
    final finished = (await h.engine.searchChat(h.chatId, 'original needle+new')).single;
    expect(finished.nodeId, original.nodeId);
    expect(finished.reportedUsage!.promptTokens, 13);
  });

  test('speaker search cannot expose an active empty reply before any body checkpoint', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final greeting = (await h.engine.path(h.chatId)).single;
    final call = h.model.prepare();
    final events = T24Events(h.engine.send(h.chatId, 'question'));
    await call.listening.future;
    final active = (await h.engine.path(h.chatId)).last;
    expect(active.text, isEmpty);
    expect(_ids(await h.engine.searchChat(h.chatId, 'Guide', limit: 1)), [greeting.nodeId]);
    call.add(const ModelText('finished answer'));
    await call.finish();
    await events.done.future;
    expect(_ids(await h.engine.searchChat(h.chatId, 'Guide', limit: 1)), [active.nodeId]);
  });

  test(
    'facade search is literal, chat scoped, includes inactive hidden branches and carries compact reports',
    () async {
      final h = await T24Harness.open();
      addTearDown(h.dispose);
      const literal = '中文 needle 100%_done !marker path\\x a"b';
      final first = await h.reply(literal, usage: const TavernUsage(promptTokens: 17, cacheHitTokens: 5));
      final call = h.model.prepare();
      final events = T24Events(h.engine.regenerate(h.chatId, first.nodeId));
      await call.listening.future;
      call.add(const ModelText('中文 needle alternative'));
      await call.finish();
      await events.done.future;
      final otherBranch = events.values.whereType<TavernTurnDone>().single.message;
      await h.engine.setHidden(h.chatId, first.nodeId, true);
      final otherChat = await h.engine.createChat(h.characterId);
      await h.reply(literal, chatId: otherChat);
      final calls = h.model.generated;

      final results = await h.engine.searchChat(h.chatId, 'needle');
      expect(_ids(results), [otherBranch.nodeId, first.nodeId]);
      expect(results.last.hidden, isTrue);
      expect(results.last.reportedUsage!.promptTokens, 17);
      expect(results.last.reportedUsage!.cacheHitTokens, 5);
      for (final query in ['中', '%', '_', '!', 'path\\x', 'a"b']) {
        final matches = await h.engine.searchChat(h.chatId, query);
        expect(_ids(matches), query == '中' ? [otherBranch.nodeId, first.nodeId] : [first.nodeId], reason: query);
      }
      expect(await h.engine.searchChat(h.chatId, '" OR ('), isEmpty);
      expect(_ids(await h.engine.searchChat(h.chatId, 'needle', limit: 1)), [otherBranch.nodeId]);
      expect(await h.engine.searchChat(h.chatId, 'needle', limit: 0), isEmpty);
      await expectLater(h.engine.searchChat(h.chatId, 'needle', limit: -1), throwsArgumentError);
      await expectLater(h.engine.searchChat('missing-chat', 'needle'), throwsStateError);
      expect(h.model.generated, calls);
      expect((await h.engine.path(h.chatId)).last.nodeId, otherBranch.nodeId);
      final token = await h.engine.deleteFrom(h.chatId, first.nodeId);
      expect(_ids(await h.engine.searchChat(h.chatId, 'needle')), [otherBranch.nodeId]);
      expect(await h.engine.undoDeleteFrom(h.chatId, token), isTrue);
      expect(_ids(await h.engine.searchChat(h.chatId, 'needle')), [otherBranch.nodeId, first.nodeId]);
    },
  );
}

List<String> _ids(Iterable<TavernMessage> messages) => messages.map((message) => message.nodeId).toList();

Future<String> _exportText(T24Harness h) async =>
    (await h.engine.exportChat(h.chatId)).map((file) => utf8.decode(file.bytes)).join('\n');

T _inspect<T>(T24Harness h, T Function(Database database) operation) {
  final database = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    return operation(database);
  } finally {
    database.close();
  }
}
