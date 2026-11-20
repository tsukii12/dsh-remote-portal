import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('path batches actual reports and preserves zero distinctly from absence after reopen', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    await h.reply(
      'one',
      usage: const TavernUsage(promptTokens: 11, cacheHitTokens: 7, completionTokens: 5, model: 'reported-model'),
    );
    await h.reply('two');
    await h.reply('three', usage: const TavernUsage());
    await h.reopen();
    final path = await h.engine.path(h.chatId);
    final replies = path.where((m) => m.role == TavernRole.character).toList();
    expect(replies.map((m) => m.text), ['G', 'one', 'two', 'three']);
    expect(replies[0].reportedUsage, isNull);
    expect(replies[1].reportedUsage!.promptTokens, 11);
    expect(replies[1].reportedUsage!.cacheHitTokens, 7);
    expect(replies[1].reportedUsage!.completionTokens, 5);
    expect(replies[1].reportedUsage!.model, 'reported-model');
    expect(replies[2].reportedUsage, isNull);
    expect(replies[3].reportedUsage, isNotNull);
    expect(replies[3].reportedUsage!.promptTokens, 0);
    expect(replies[3].reportedUsage!.cacheHitTokens, 0);
    expect(replies[3].reportedUsage!.completionTokens, 0);
    expect(path.where((m) => m.role == TavernRole.user).every((m) => m.reportedUsage == null), isTrue);
  });

  test('continuation without new usage cannot borrow the older call report', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final original = await h.reply('OLD', usage: const TavernUsage(promptTokens: 91, completionTokens: 6));
    final call = h.model.prepare();
    final events = T24Events(h.engine.continueReply(h.chatId, original.nodeId));
    await call.listening.future;
    expect((await h.engine.path(h.chatId)).last.reportedUsage, isNull);
    call.add(const ModelText('+NEW'));
    await call.finish();
    await events.done.future;
    final done = events.values.whereType<TavernTurnDone>().single.message;
    expect(done.usage!.promptTokens, 91); // The legacy node field is unchanged.
    expect(done.reportedUsage, isNull);
    expect((await h.engine.inspectTurn(h.chatId, nodeId: original.nodeId))!.reportedUsage, isNull);
    await h.reopen();
    final stored = (await h.engine.path(h.chatId)).last;
    expect(stored.text, 'OLD+NEW');
    expect(stored.usage!.promptTokens, 91);
    expect(stored.reportedUsage, isNull);
  });

  test('live path and reconnect snapshot use current report before terminal storage', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final original = await h.reply('OLD', usage: const TavernUsage(promptTokens: 90));
    final call = h.model.prepare();
    final events = T24Events(h.engine.continueReply(h.chatId, original.nodeId));
    await call.listening.future;
    call.add(const ModelUsage(TavernUsage(promptTokens: 13, cacheHitTokens: 4, completionTokens: 2)));
    final path = await h.engine.path(h.chatId);
    expect(path.last.reportedUsage!.promptTokens, 13);
    expect(path.last.reportedUsage!.cacheHitTokens, 4);
    final resumed = T24Events(h.engine.resumeTurn(h.chatId));
    call.add(const ModelText('+NEW'));
    await call.finish();
    await Future.wait([events.done.future, resumed.done.future]);
    expect((resumed.values.first as TavernTurnSnapshot).message!.reportedUsage!.promptTokens, 13);
    expect(events.values.whereType<TavernTurnDone>().single.message.reportedUsage!.completionTokens, 2);
  });

  test('failure with partial output preserves the usage actually received by that call', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final call = h.model.prepare();
    final events = T24Events(h.engine.send(h.chatId, 'question'));
    await call.listening.future;
    call.add(const ModelText('partial'));
    call.add(const ModelUsage(TavernUsage(promptTokens: 17, cacheHitTokens: 8, completionTokens: 3)));
    call.fail(TavernFailure.network, 'fixture offline');
    await events.done.future;
    final failure = events.values.whereType<TavernTurnFailed>().single;
    expect(failure.partial!.reportedUsage!.cacheHitTokens, 8);
    expect((await h.engine.path(h.chatId)).last.reportedUsage!.promptTokens, 17);
    await h.reopen();
    expect((await h.engine.path(h.chatId)).last.reportedUsage!.completionTokens, 3);
  });

  test('usage-only completion keeps a real all-zero report on the empty reply', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final call = h.model.prepare();
    final events = T24Events(h.engine.send(h.chatId, 'question'));
    await call.listening.future;
    call.add(const ModelUsage(TavernUsage()));
    await call.finish();
    await events.done.future;
    final reply = events.values.whereType<TavernTurnDone>().single.message;
    expect(reply.text, '');
    expect(reply.reportedUsage, isNotNull);
    expect(reply.reportedUsage!.completionTokens, 0);
    expect((await h.engine.path(h.chatId)).last.reportedUsage, isNotNull);
  });

  test('empty failed continuation restores the original node report and separate failed inspection', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final original = await h.reply('OLD', usage: const TavernUsage(promptTokens: 31));
    final call = h.model.prepare();
    final events = T24Events(h.engine.continueReply(h.chatId, original.nodeId));
    await call.listening.future;
    expect((await h.engine.path(h.chatId)).last.reportedUsage, isNull);
    call.fail(TavernFailure.network, 'nothing received');
    await events.done.future;
    expect(events.values.whereType<TavernTurnFailed>().single.partial!.reportedUsage!.promptTokens, 31);
    expect((await h.engine.path(h.chatId)).last.reportedUsage!.promptTokens, 31);
    final failed = (await h.engine.inspectTurn(h.chatId))!;
    expect(failed.nodeId, isNull);
    expect(failed.reportedUsage, isNull);
    expect(failed.status, TavernInspectionStatus.failed);
    final originalInspection = (await h.engine.inspectTurn(h.chatId, nodeId: original.nodeId))!;
    expect(originalInspection.status, TavernInspectionStatus.completed);
    expect(originalInspection.reportedUsage!.promptTokens, 31);
    await h.reopen();
    expect((await h.engine.inspectTurn(h.chatId))!.toJson(), failed.toJson());
    expect((await h.engine.inspectTurn(h.chatId, nodeId: original.nodeId))!.toJson(), originalInspection.toJson());
    expect((await h.engine.path(h.chatId)).last.reportedUsage!.promptTokens, 31);
  });

  test('path does not reconstruct the large inspection to read a compact persisted report', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final reply = await h.reply('answer', usage: const TavernUsage(promptTokens: 41, cacheHitTokens: 9));
    // Deliberately corrupt only the heavyweight inspection prompt, after a
    // real terminal write populated the compact report. No report is faked.
    final db = sqlite3.open('${h.root.path}/tavern.sqlite3');
    try {
      db.execute(
        r'''UPDATE nodes SET extra = json_set(extra,
        '$.dshgo.inspection.prompt', 'not an inspection prompt') WHERE id = ?''',
        [reply.nodeId],
      );
    } finally {
      db.close();
    }
    final path = await h.engine.path(h.chatId);
    expect(path.last.reportedUsage!.promptTokens, 41);
    expect(path.last.reportedUsage!.cacheHitTokens, 9);
    await expectLater(h.engine.inspectTurn(h.chatId, nodeId: reply.nodeId), throwsFormatException);
  });
}
