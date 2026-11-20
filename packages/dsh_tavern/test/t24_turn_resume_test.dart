import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('unlistened send is inert and reconnecting an idle chat is empty', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    h.engine.send(h.chatId, 'not admitted');
    expect(await h.engine.resumeTurn(h.chatId).toList(), isEmpty);
    expect(h.model.generated, 0);
    expect((await h.engine.path(h.chatId)).map((m) => m.text), ['G']);
  });

  test('reconnect during preparation gives null snapshot then started and terminal', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final call = h.model.prepare();
    final first = T24Events(h.engine.send(h.chatId, 'question'));
    final second = T24Events(h.engine.resumeTurn(h.chatId));
    await call.listening.future;
    call.add(const ModelText('answer'));
    await call.finish();
    await Future.wait([first.done.future, second.done.future]);
    final snapshot = second.values.first as TavernTurnSnapshot;
    expect(snapshot.chatId, h.chatId);
    expect(snapshot.generationType, 'normal');
    expect(snapshot.startedAt, T24Harness.at);
    expect(snapshot.message, isNull);
    expect(second.values.whereType<TavernTurnStarted>(), hasLength(1));
    expect(second.values.whereType<TavernTextDelta>().single.text, 'answer');
    expect(second.values.whereType<TavernTurnDone>().single.message.text, 'answer');
    expect(h.model.generated, 1);
  });

  test('detached page receives current full buffers before only future deltas', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final call = h.model.prepare();
    final first = T24Events(h.engine.send(h.chatId, 'question'));
    await call.listening.future;
    call.add(const ModelText('before'));
    call.add(const ModelReasoning('thought'));
    await t24Pump();
    await first.detach();
    expect(call.cancellation!.isCancelled, isFalse);
    expect(call.sourceCancelCalls, 0);
    call.add(const ModelText('-away'));
    call.add(const ModelReasoning('-away'));
    // The producer callbacks are synchronous; no 500ms checkpoint is needed.
    final second = T24Events(h.engine.resumeTurn(h.chatId));
    call.add(const ModelText('-after'));
    call.add(const ModelReasoning('-after'));
    await call.finish('length');
    await second.done.future;
    final snapshot = second.values.first as TavernTurnSnapshot;
    expect(snapshot.message!.text, 'before-away');
    expect(snapshot.message!.reasoning, 'thought-away');
    expect(second.values.whereType<TavernTurnStarted>(), isEmpty);
    expect(second.values.whereType<TavernTextDelta>().map((v) => v.text), ['-after']);
    expect(second.values.whereType<TavernReasoningDelta>().map((v) => v.text), ['-after']);
    final done = second.values.whereType<TavernTurnDone>().single;
    expect(done.message.text, 'before-away-after');
    expect(done.message.reasoning, 'thought-away-after');
    expect(done.finishReason, 'length');
    expect(h.model.generated, 1);
    expect((await h.engine.path(h.chatId)).last.text, done.message.text);
  });

  test('snapshot registration has no overlap with immediately following synchronous deltas', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final call = h.model.prepare();
    final first = T24Events(h.engine.send(h.chatId, 'question'));
    await call.listening.future;
    call.add(const ModelText('A'));
    await first.detach();
    final second = T24Events(h.engine.resumeTurn(h.chatId));
    for (var i = 0; i < 64; i++) {
      call.add(ModelText('$i,'));
    }
    await call.finish();
    await second.done.future;
    final snapshot = second.values.first as TavernTurnSnapshot;
    final combined = snapshot.message!.text + second.values.whereType<TavernTextDelta>().map((e) => e.text).join();
    expect(snapshot.message!.text, 'A');
    expect(second.values.whereType<TavernTextDelta>(), hasLength(64));
    expect(combined, second.values.whereType<TavernTurnDone>().single.message.text);
  });

  test('multiple observers detach independently and explicit stop ends remaining observer', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final call = h.model.prepare();
    final first = T24Events(h.engine.send(h.chatId, 'question'));
    await call.listening.future;
    call.add(const ModelText('A'));
    final second = T24Events(h.engine.resumeTurn(h.chatId));
    final third = T24Events(h.engine.resumeTurn(h.chatId));
    await first.detach();
    await second.detach();
    expect(call.cancellation!.isCancelled, isFalse);
    call.add(const ModelText('B'));
    h.engine.stop(h.chatId);
    await third.done.future;
    expect(call.cancellation!.isCancelled, isTrue);
    final failure = third.values.whereType<TavernTurnFailed>().single;
    expect(failure.kind, TavernFailure.cancelled);
    expect(failure.partial!.text, 'AB');
    expect(third.values.whereType<TavernTurnDone>(), isEmpty);
    expect((await h.engine.path(h.chatId)).last.text, 'AB');
  });

  test('completion with no observers persists result and idle reconnect does not replay events', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final call = h.model.prepare();
    final first = T24Events(h.engine.send(h.chatId, 'question'));
    await call.listening.future;
    await first.detach();
    call.add(const ModelText('entirely away'));
    call.add(const ModelUsage(TavernUsage(promptTokens: 10, cacheHitTokens: 4, completionTokens: 7)));
    await call.finish();
    await t24Pump();
    expect((await h.engine.inspectTurn(h.chatId))!.status, TavernInspectionStatus.completed);
    expect(await h.engine.resumeTurn(h.chatId).toList(), isEmpty);
    await h.reopen();
    expect(await h.engine.resumeTurn(h.chatId).toList(), isEmpty);
    final last = (await h.engine.path(h.chatId)).last;
    expect(last.text, 'entirely away');
    expect(last.reportedUsage!.cacheHitTokens, 4);
    expect((await h.engine.inspectTurn(h.chatId))!.status, TavernInspectionStatus.completed);
  });

  test('continued message reconnect includes old body and new call usage only', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final original = await h.reply('OLD', usage: const TavernUsage(promptTokens: 99));
    final call = h.model.prepare();
    final first = T24Events(h.engine.continueReply(h.chatId, original.nodeId));
    await call.listening.future;
    call.add(const ModelText('+A'));
    await first.detach();
    final second = T24Events(h.engine.resumeTurn(h.chatId));
    call.add(const ModelUsage(TavernUsage(promptTokens: 12, cacheHitTokens: 2, completionTokens: 3)));
    call.add(const ModelText('+B'));
    await call.finish();
    await second.done.future;
    final snapshot = second.values.first as TavernTurnSnapshot;
    expect(snapshot.generationType, 'continue');
    expect(snapshot.message!.nodeId, original.nodeId);
    expect(snapshot.message!.text, 'OLD+A');
    expect(snapshot.message!.reportedUsage, isNull);
    final done = second.values.whereType<TavernTurnDone>().single.message;
    expect(done.text, 'OLD+A+B');
    expect(done.reportedUsage!.promptTokens, 12);
  });

  test('regenerated sibling remains one turn while its first observer is absent', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final original = await h.reply('old answer');
    final call = h.model.prepare();
    final first = T24Events(h.engine.regenerate(h.chatId, original.nodeId));
    await call.listening.future;
    call.add(const ModelText('new'));
    await first.detach();
    final second = T24Events(h.engine.resumeTurn(h.chatId));
    call.add(const ModelText(' answer'));
    await call.finish();
    await second.done.future;
    final snapshot = second.values.first as TavernTurnSnapshot;
    expect(snapshot.generationType, 'regenerate');
    expect(snapshot.message!.nodeId, isNot(original.nodeId));
    expect(snapshot.message!.parentId, original.parentId);
    expect(second.values.whereType<TavernTurnDone>().single.message.siblingCount, 2);
  });

  test('impersonation reconnect returns temporary user body without adding chat nodes', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final before = await h.engine.path(h.chatId);
    final call = h.model.prepare();
    final first = T24Events(h.engine.impersonate(h.chatId));
    await call.listening.future;
    call.add(const ModelText('I'));
    await first.detach();
    final second = T24Events(h.engine.resumeTurn(h.chatId));
    call.add(const ModelText(' agree'));
    await call.finish();
    await second.done.future;
    final snapshot = second.values.first as TavernTurnSnapshot;
    expect(snapshot.generationType, 'impersonate');
    expect(snapshot.message!.role, TavernRole.user);
    expect(snapshot.message!.nodeId, startsWith('temporary-'));
    expect(snapshot.message!.text, 'I');
    expect(second.values.whereType<TavernTurnDone>().single.message.text, 'I agree');
    expect((await h.engine.path(h.chatId)).map((m) => m.nodeId), before.map((m) => m.nodeId));
  });

  test('reasoning gate still applies while no page observes the turn', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final call = h.model.prepare();
    final first = T24Events(h.engine.send(h.chatId, 'question'));
    await call.listening.future;
    await first.detach();
    call.add(const ModelReasoning('must not leak'));
    final second = T24Events(h.engine.resumeTurn(h.chatId));
    call.add(const ModelText('answer'));
    await call.finish();
    await second.done.future;
    expect((second.values.first as TavernTurnSnapshot).message!.reasoning, isNull);
    expect(second.values.whereType<TavernReasoningDelta>(), isEmpty);
    expect(second.values.whereType<TavernTurnDone>().single.message.reasoning, isNull);
  });

  test('reconnected observer gets one transport failure and durable partial', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final call = h.model.prepare();
    final first = T24Events(h.engine.send(h.chatId, 'question'));
    await call.listening.future;
    await first.detach();
    call.add(const ModelText('partial'));
    final second = T24Events(h.engine.resumeTurn(h.chatId));
    call.fail(TavernFailure.network, 'offline fixture');
    await second.done.future;
    expect((second.values.first as TavernTurnSnapshot).message!.text, 'partial');
    final failure = second.values.whereType<TavernTurnFailed>().single;
    expect(failure.kind, TavernFailure.network);
    expect(failure.partial!.text, 'partial');
    expect(second.values.whereType<TavernTurnDone>(), isEmpty);
    expect((await h.engine.inspectTurn(h.chatId))!.status, TavernInspectionStatus.failed);
  });

  test('detached turn is still busy and a tree mutation cancels it before editing', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final call = h.model.prepare();
    final first = T24Events(h.engine.send(h.chatId, 'question'));
    await call.listening.future;
    call.add(const ModelText('partial'));
    await t24Pump();
    final id = first.values.whereType<TavernTurnStarted>().single.message.nodeId;
    await first.detach();
    final busy = await h.engine.send(h.chatId, 'second').toList();
    expect(busy.whereType<TavernTurnFailed>().single.kind, TavernFailure.busy);
    final second = T24Events(h.engine.resumeTurn(h.chatId));
    await h.engine.edit(h.chatId, id, 'edited');
    await second.done.future;
    expect(second.values.whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    expect((await h.engine.path(h.chatId)).last.text, 'edited');
    expect(h.model.generated, 1);
  });

  test('close cannot be held by a paused reconnect observer', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final call = h.model.prepare();
    final first = T24Events(h.engine.send(h.chatId, 'question'));
    await call.listening.future;
    call.add(const ModelText('partial'));
    await first.detach();
    final second = T24Events(h.engine.resumeTurn(h.chatId));
    second.subscription.pause();
    await h.engine.close().timeout(const Duration(seconds: 3));
    expect(call.cancellation!.isCancelled, isTrue);
    second.subscription.resume();
    await second.done.future;
    expect(second.values.first, isA<TavernTurnSnapshot>());
    expect(second.values.whereType<TavernTurnFailed>().single.partial!.text, 'partial');
  });

  test('a delayed resume listener binds the turn active at listen time, not stream creation', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final firstCall = h.model.prepare();
    final first = T24Events(h.engine.send(h.chatId, 'first question'));
    await firstCall.listening.future;
    final delayed = h.engine.resumeTurn(h.chatId);
    firstCall.add(const ModelText('first answer'));
    await firstCall.finish();
    await first.done.future;
    final oldId = first.values.whereType<TavernTurnDone>().single.message.nodeId;

    final secondCall = h.model.prepare();
    final second = T24Events(h.engine.send(h.chatId, 'second question'));
    final resumed = T24Events(delayed);
    final laterIdle = h.engine.resumeTurn(h.chatId);
    await secondCall.listening.future;
    secondCall.add(const ModelText('second answer'));
    await secondCall.finish();
    await Future.wait([second.done.future, resumed.done.future]);
    expect((resumed.values.first as TavernTurnSnapshot).message, isNull);
    expect(resumed.values.whereType<TavernTurnStarted>().single.message.nodeId, isNot(oldId));
    expect(resumed.values.whereType<TavernTurnDone>().single.message.text, 'second answer');
    expect(await laterIdle.toList(), isEmpty);
    expect(h.model.generated, 2);
  });
}
