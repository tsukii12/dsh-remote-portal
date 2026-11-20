import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_slash_test_support.dart';

// Newly authored from the accepted B3 D.2/A1 contract, not recovered old tests.
void main() {
  test('variable getter keeps missing null whitespace and indexed JSON projections distinct', () async {
    final h = await slashFixture();
    final actor = await h.card('Getter projections');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final initial = <String, Object?>{
      'rawNull': null,
      'digits': '007',
      'blank': ' \t',
      'array': [1, 2],
      'object': {'x': 1},
      'textNull': 'null',
      'indexed': '[null,{"x":1},"007"]',
    };
    await h.bridge.replaceVariables(context.id, scriptChat, initial);
    final before = await h.bridge.getVariables(context.id, scriptChat);
    final cases = <String, String>{
      '/getvar absent': '',
      '/getvar rawNull': '0',
      '/getvar digits': '7',
      '/getvar blank': ' \t',
      '/getvar array': '1,2',
      '/getvar object': '[object Object]',
      '/getvar key=textNull index=x': '0',
      '/getvar key=indexed index=0': 'null',
      '/getvar key=indexed index=1': '{"x":1}',
      '/getvar key=indexed index=2': '7',
    };
    for (final entry in cases.entries) {
      final result = await slashRun(h, context.id, entry.key);
      expect(result.pipe, entry.value, reason: entry.key);
      expect(result.effects.committed, isFalse, reason: entry.key);
    }
    final after = await h.bridge.getVariables(context.id, scriptChat);
    expect(after.value, initial);
    expect(after.version, before.version);
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
  });

  test('setter fallback and unconsumed as preserve strings and actual global persistence', () async {
    final h = await slashFixture();
    final actor = await h.card('Setter presence');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.replaceVariables(context.id, scriptChat, {'': 'EMPTY_KEY'});
    final fallback = await slashRun(
      h,
      context.id,
      '/setvar key="" name=fallback {{arg::body}}',
      arguments: const {'body': '007'},
    );
    expect(fallback.pipe, '007');
    final plain = await slashRun(
      h,
      context.id,
      '/setvar key=plain as=number {{arg::body}}',
      arguments: const {'body': '007'},
    );
    expect(plain.pipe, '007');
    expect((await slashRun(h, context.id, '/getvar fallback')).pipe, '7');
    expect((await slashRun(h, context.id, '/getvar key="" fallback')).pipe, 'EMPTY_KEY');
    final global = await slashRun(h, context.id, '/setglobalvar key=global as=bool false');
    expect(global.pipe, 'false');
    expect((await h.bridge.getVariables(context.id, scriptChat)).value, {
      '': 'EMPTY_KEY',
      'fallback': '007',
      'plain': '007',
    });
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'global': 'false'});
    expect(scriptMap((await h.settingsDocument())['globalVariables']), {'global': 'false'});
    await h.reopen();
    final fresh = await h.context(chat, characterId: actor);
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value, {
      '': 'EMPTY_KEY',
      'fallback': '007',
      'plain': '007',
    });
    expect((await h.bridge.getVariables(fresh.id, scriptGlobal)).value, {'global': 'false'});
    h.expectNoGeneration();
  });

  test('indexed assignments serialize holes undefined length and converted values as owned JSON text', () async {
    final h = await slashFixture();
    final actor = await h.card('Indexed JSON');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final first = await slashRun(h, context.id, '/setvar key=items index=2 as=int 07tail');
    expect(first.pipe, '07tail');
    var values = (await h.bridge.getVariables(context.id, scriptChat)).value;
    expect(jsonDecode(values['items']! as String), [null, null, 7]);
    expect((await slashRun(h, context.id, '/getvar key=items index=2')).pipe, '7');
    await slashRun(h, context.id, '/setvar key=items index=0 as=none ignored');
    await slashRun(h, context.id, '/setvar key=items index=length as=number 1');
    await slashRun(h, context.id, '/setvar key=items index=-1 SIDE');
    await slashRun(h, context.id, '/setvar key=items index=1.5 FRACTION');
    await slashRun(h, context.id, '/setvar key=object index=name old');
    await slashRun(h, context.id, '/setvar key=object index=name as=undefined ignored');
    await slashRun(h, context.id, '/setvar key=object index=nullable as=dict null');
    await slashRun(h, context.id, '/setvar key=object index=number as=float 3.5tail');
    await slashRun(h, context.id, '/setvar key=nonfinite index=0 as=number not-a-number');
    values = (await h.bridge.getVariables(context.id, scriptChat)).value;
    expect(jsonDecode(values['items']! as String), [null]);
    expect(jsonDecode(values['object']! as String), {'nullable': null, 'number': 3.5});
    expect(jsonDecode(values['nonfinite']! as String), [null]);
    expect(values.values.every((value) => value is String), isTrue);
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
  });

  test('indexed compatibility no-ops preserve values and versions without erasing prior effects', () async {
    final h = await slashFixture();
    final actor = await h.card('Indexed no-op');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.replaceVariables(context.id, scriptChat, {'bad': 'not-json', 'primitive': '1', 'items': '[1,2]'});
    for (final source in const [
      '/setvar key=bad index=0 VALUE',
      '/setvar key=primitive index=x VALUE',
      '/setvar key=items index=length as=number 1.5',
    ]) {
      final before = await h.bridge.getVariables(context.id, scriptChat);
      final result = await slashRun(h, context.id, source);
      expect(result.pipe, source.endsWith('1.5') ? '1.5' : 'VALUE');
      expect(result.effects.committed, isFalse);
      final after = await h.bridge.getVariables(context.id, scriptChat);
      expect(after.value, before.value);
      expect(after.version, before.version);
    }
    final before = await h.bridge.getVariables(context.id, scriptChat);
    final prior = await slashRun(h, context.id, '/setglobalvar key=kept YES | /setvar key=bad index=0 VALUE');
    expect(prior.pipe, 'VALUE');
    expect(prior.effects.committed, isTrue);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'kept': 'YES'});
    expect((await h.bridge.getVariables(context.id, scriptChat)).version, before.version);
    h.expectNoGeneration();
  });

  test('indexed storage failure is not caught as a compatibility no-op after global adoption', () async {
    final h = await slashFixture();
    final actor = await h.card('Indexed SQL boundary');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.replaceVariables(context.id, scriptChat, {'blocked': '[]'});
    final before = await h.bridge.getVariables(context.id, scriptChat);
    final chatLiteral = chat.replaceAll("'", "''");
    h.inspect(
      (db) => db.execute('''
      CREATE TRIGGER slash_indexed_abort BEFORE UPDATE OF variables ON chats
      WHEN NEW.id = '$chatLiteral'
        AND json_extract(NEW.variables, '\$.blocked') IS NOT json_extract(OLD.variables, '\$.blocked')
      BEGIN SELECT RAISE(ABORT, 'slash indexed fixture abort'); END
    '''),
      writable: true,
    );
    try {
      final execution = await h.bridge.triggerSlash(
        context.id,
        '/setglobalvar key=kept YES | /setvar key=blocked index=0 CHANGED',
      );
      final error = await slashFailure(execution);
      expect(error.code, TavernScriptErrorCode.storage);
      expect(error.committed, isTrue);
      final terminal = (await execution.events.toList()).single;
      expect(terminal.effects.committed, isTrue);
      expect(
        terminal.effects.entries.any(
          (effect) => effect.kind == TavernSlashEffectKind.storage && effect.state == TavernSlashEffectState.failed,
        ),
        isTrue,
      );
    } finally {
      h.inspect((db) => db.execute('DROP TRIGGER IF EXISTS slash_indexed_abort'), writable: true);
    }
    final after = await h.bridge.getVariables(context.id, scriptChat);
    expect(after.value, {'blocked': '[]'});
    expect(after.version, before.version);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'kept': 'YES'});
    expect(scriptMap((await h.settingsDocument())['globalVariables']), {'kept': 'YES'});
    expect(
      h.inspect(
        (db) => scriptMap(
          jsonDecode(db.select('SELECT variables FROM chats WHERE id = ?', [chat]).single['variables'] as String),
        ),
      ),
      {'blocked': '[]'},
    );
    await h.reopen();
    final fresh = await h.context(chat, characterId: actor);
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value, {'blocked': '[]'});
    expect((await h.bridge.getVariables(fresh.id, scriptGlobal)).value, {'kept': 'YES'});
    h.expectNoGeneration();
  });

  test('a no-op leaves a held real updater valid while an indexed write causes a genuine CAS conflict', () async {
    final h = await slashFixture();
    final actor = await h.card('Indexed CAS');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.replaceVariables(context.id, scriptChat, {'bad': 'not-json', 'items': '[]'});
    final entered = [Completer<void>(), Completer<void>()];
    final release = [Completer<void>(), Completer<void>()];
    final pending = <Future<Object>>[];
    var calls = 0;
    addTearDown(() async {
      for (final gate in release) {
        if (!gate.isCompleted) gate.complete();
      }
      await Future.wait(pending);
    });
    for (var round = 0; round < 2; round++) {
      final index = round;
      final updater = h.bridge.updateVariablesWith(context.id, scriptChat, (value) async {
        calls++;
        entered[index].complete();
        await release[index].future;
        return {...value, 'round': index + 1};
      });
      final outcome = updater.then<Object>((value) => value, onError: (Object error, StackTrace stack) => error);
      pending.add(outcome);
      await entered[index].future;
      final result = await slashRun(
        h,
        context.id,
        index == 0 ? '/setvar key=bad index=0 NOOP' : '/setvar key=items index=0 NEW',
      );
      expect(result.effects.committed, index == 1);
      release[index].complete();
      final completed = await outcome;
      if (index == 0) {
        expect(completed, isA<TavernVariableSnapshot>());
        expect((completed as TavernVariableSnapshot).value['round'], 1);
      } else {
        expect(completed, isA<TavernScriptException>());
        final error = completed as TavernScriptException;
        expect(error.code, TavernScriptErrorCode.revisionConflict);
        expect(error.committed, isFalse);
      }
    }
    expect(calls, 2);
    final after = await h.bridge.getVariables(context.id, scriptChat);
    expect(after.value['round'], 1);
    expect(after.value['bad'], 'not-json');
    expect(jsonDecode(after.value['items']! as String), ['NEW']);
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
    stdout.writeln('P2_B3_VARIABLES_READY');
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('add appends its String body while inc appends numeric one to stored JSON arrays', () async {
    final h = await slashFixture();
    final actor = await h.card('Array add and inc');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.replaceVariables(context.id, scriptChat, {'byAdd': '[1]', 'byInc': '[1]'});
    final before = await h.bridge.getVariables(context.id, scriptChat);
    final added = await slashRun(h, context.id, '/addvar key=byAdd 2');
    expect(added.pipe, '1,2');
    expect(added.effects.committed, isTrue);
    final incremented = await slashRun(h, context.id, '/incvar byInc');
    expect(incremented.pipe, '1,1');
    expect(incremented.effects.committed, isTrue);
    final expected = {'byAdd': '[1,"2"]', 'byInc': '[1,1]'};
    final after = await h.bridge.getVariables(context.id, scriptChat);
    expect(after.value, expected);
    expect(after.version, isNot(before.version));
    expect((jsonDecode(after.value['byAdd']! as String) as List<Object?>)[1], isA<String>());
    expect((jsonDecode(after.value['byInc']! as String) as List<Object?>)[1], isA<num>());
    await h.reopen();
    final fresh = await h.context(chat, characterId: actor);
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value, expected);
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
  });
}
