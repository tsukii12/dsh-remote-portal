import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_slash_test_support.dart';

// Fourth-wave additions derived from the accepted B3 L.1-L.8 contract.
// These are new tests; the unavailable historical 29 tests remain unavailable.
void main() {
  test('delimiter escapes macro pipes and fixed comments preserve their public text boundary', () async {
    final h = await slashFixture();
    final actor = await h.card('Lexical boundaries');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    const cases = <String, String>{
      r'/pass A\|B | /pass {{pipe}}': 'A|B',
      r'/pass \n': r'\n',
      '/pass "A B"': 'A B',
      "/pass 'A B'": "'A B'",
      '/pass {{arg::bar}} | /pass {{pipe}}': 'LEFT|RIGHT',
      '/pass BEFORE | // ignored\n/setglobalvar key=leak BAD | /pass AFTER': 'AFTER',
      '/pass BEFORE | /# ignored\n/setglobalvar key=leak BAD | /pass AFTER': 'AFTER',
      '/* outer /* inner *| tail *| /pass AFTER': 'AFTER',
    };
    for (final entry in cases.entries) {
      final result = await slashRun(h, context.id, entry.key, arguments: const {'bar': 'LEFT|RIGHT'});
      expect(result.pipe, entry.value, reason: entry.key);
      expect(result.effects.committed, isFalse, reason: entry.key);
    }
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, isEmpty);
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
  });

  test('an unclosed fixed comment is a whole-source syntax failure before earlier effects', () async {
    final h = await slashFixture();
    final actor = await h.card('Comment EOF');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    for (final tail in ['// no pipe', '/# no pipe', '/* no star-pipe']) {
      final execution = await h.bridge.triggerSlash(context.id, '/setglobalvar key=before BAD | $tail');
      final error = await slashFailure(execution);
      expect(error.code, TavernScriptErrorCode.invalidArgument, reason: tail);
      expect(error.operation, 'parse', reason: tail);
      expect(error.committed, isFalse, reason: tail);
      expect(error.sourceSpan, isNotNull);
      expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, isEmpty);
    }
    h.expectNoGeneration();
  });

  test('repeated named values adopt in order before an immediate child and a fresh unnamed phase', () async {
    final h = await slashFixture();
    final actor = await h.card('Ordered named effects');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final result = await slashRun(
      h,
      context.id,
      '/setglobalvar key="{{setglobalvar::trace::BEFORE}}discarded" '
      'key={: /pass {{getglobalvar::trace}}{{setglobalvar::trace::AFTER}} :}() '
      '{{getglobalvar::trace}}',
    );
    expect(result.pipe, 'AFTER');
    expect(result.effects.committed, isTrue);
    const expected = {'trace': 'AFTER', 'BEFORE': 'AFTER'};
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, expected);
    expect(scriptMap((await h.settingsDocument())['globalVariables']), expected);
    expect(await h.engine.path(chat), isEmpty);
    await h.reopen();
    final fresh = await h.context(chat, characterId: actor);
    expect((await h.bridge.getVariables(fresh.id, scriptGlobal)).value, expected);
    h.expectNoGeneration();
  });

  test('empty programs clear incoming pipe after defaults while dormant missing initializers stay dormant', () async {
    final h = await slashFixture();
    final actor = await h.card('Empty programs');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    for (final source in ['', 'ordinary discarded text', '// discarded |']) {
      final result = await slashRun(h, context.id, source, pipe: 'INCOMING');
      expect(result.pipe, '');
      expect(result.effects.committed, isFalse);
    }
    final defaults = await slashRun(
      h,
      context.id,
      'x="{{setglobalvar::defaultOnly::KEPT}}"',
      pipe: 'INCOMING',
      arguments: const {'x': '{{setglobalvar::opaque::BAD}}'},
    );
    expect(defaults.pipe, '');
    expect(defaults.effects.committed, isTrue);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'defaultOnly': 'KEPT'});
    final missing = await slashFailure(await h.bridge.triggerSlash(context.id, 'x= /pass NEVER'));
    expect(missing.code, TavernScriptErrorCode.invalidArgument);
    expect(missing.committed, isFalse);
    expect(missing.sourceSpan, isNotNull);
    final dormant = await slashRun(h, context.id, '/if a=0 {: x= /pass NEVER :} | /pass KEPT');
    expect(dormant.pipe, 'KEPT');
    expect(dormant.effects.committed, isFalse);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'defaultOnly': 'KEPT'});
    h.expectNoGeneration();
  });

  test('condition aliases and literal scoped persistent resolution follow fixed numeric coercion', () async {
    final h = await slashFixture();
    final actor = await h.card('Condition values');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.replaceVariables(context.id, scriptChat, {'n': '007'});
    final before = await h.bridge.getVariables(context.id, scriptChat);
    const cases = <String, String>{
      '/if a=1 left=2 b=1 right=3 else={: /pass WRONG :} {: /pass FIRST :}': 'FIRST',
      '/if a=007 b=7 else={: /pass TEXT :} {: /pass NUMBER :}': 'NUMBER',
      '/if a=n b=7 else={: /pass TEXT :} {: /pass NUMBER :}': 'NUMBER',
      // Fixed Scope.getVariable coerces an unindexed numeric string too.
      'n=007 /if a=n b=7 else={: /pass TEXT :} {: /pass NUMBER :}': 'NUMBER',
      // A different scoped value still shadows the persistent n='007'.
      'n=8 /if a=n b=7 else={: /pass TEXT :} {: /pass NUMBER :}': 'TEXT',
      '/if a=\u039f\u03a3 b=\u03bf\u03c2 rule=eq else={: /pass WRONG :} {: /pass MATCH :}': 'MATCH',
      '/if a=\u03bf\u03c2 b=\u039f\u03a3 rule=neq else={: /pass MATCH :} {: /pass WRONG :}': 'MATCH',
      '/if a=\u039f\u03a3 b=\u03c2 rule=in else={: /pass WRONG :} {: /pass IN :}': 'IN',
      '/if a=\u039f\u03a3 b=\u03c2 rule=nin else={: /pass IN :} {: /pass WRONG :}': 'IN',
      '/if a=\u0130 b="i\u0307" rule=eq else={: /pass WRONG :} {: /pass EXPANDED :}': 'EXPANDED',
      '/if a=\u00c9 b=e rule=neq else={: /pass WRONG :} {: /pass DISTINCT :}': 'DISTINCT',
      '/if a=\u00c9 b="e\u0301" rule=eq else={: /pass DISTINCT :} {: /pass WRONG :}': 'DISTINCT',
    };
    for (final entry in cases.entries) {
      final result = await slashRun(h, context.id, entry.key);
      expect(result.pipe, entry.value, reason: entry.key);
      expect(result.effects.committed, isFalse);
    }
    final after = await h.bridge.getVariables(context.id, scriptChat);
    expect(after.value, before.value);
    expect(after.version, before.version);
    h.expectNoGeneration();
  });

  test('times uses Number integer syntax and its actual default guard without evaluating a zero body', () async {
    final h = await slashFixture();
    final actor = await h.card('Count admission');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    const cases = <String, String>{
      '/times 0x2 {: /pass {{timesIndex}} :}': '1',
      '/times 101 {: /pass {{timesIndex}} :}': '99',
      '/times guard=off 101 {: /pass {{timesIndex}} :}': '100',
      '/times -0 {: /pass {{setglobalvar::zeroBody::BAD}} :}': '',
      '/times 0': '',
    };
    for (final entry in cases.entries) {
      final result = await slashRun(h, context.id, entry.key);
      expect(result.pipe, entry.value, reason: entry.key);
      expect(result.effects.committed, isFalse);
    }
    for (final count in ['1.5', '-1', 'NaN', 'Infinity', '']) {
      final execution = await h.bridge.triggerSlash(
        context.id,
        '/times {{arg::count}} {: /pass {{setglobalvar::invalidBody::BAD}} :}',
        arguments: {'count': count},
      );
      final failure = await slashFailure(execution);
      expect(failure.code, TavernScriptErrorCode.invalidArgument, reason: count);
      expect(failure.committed, isFalse);
    }
    final bodyMissing = await slashFailure(await h.bridge.triggerSlash(context.id, '/times 1'));
    expect(bodyMissing.code, TavernScriptErrorCode.invalidArgument);
    expect(bodyMissing.committed, isFalse);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, isEmpty);
    h.expectNoGeneration();
    stdout.writeln('P2_B3_LANGUAGE_BOUNDARIES_READY');
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('legacy scoped macros match case exactly while lowercase lexical lookup remains available', () async {
    final h = await slashFixture();
    final actor = await h.card('Legacy scoped case');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.engine.setSettings({'macroEngine': 'legacy'});
    expect(scriptMap(jsonDecode(_rawMetadata(h, chat))).containsKey('chat_id_hash'), isFalse);
    final lower = await slashRun(h, context.id, 'x=VALUE /pass {{var::x}}');
    final afterLower = _rawMetadata(h, chat);
    expect(
      scriptMap(jsonDecode(afterLower))['chat_id_hash'],
      isA<num>().having((value) => value.isFinite, 'finite', isTrue),
    );
    _expectHashAdoption(lower, chat);
    final upper = await slashRun(h, context.id, 'x=VALUE /pass {{VAR::x}}');
    expect(lower.pipe, 'VALUE');
    expect(upper.pipe, '{{VAR::x}}');
    expect(lower.effects.committed, isTrue);
    expect(upper.effects.committed, isFalse);
    expect(upper.effects.entries.where((effect) => effect.state == TavernSlashEffectState.adopted), isEmpty);
    expect(_rawMetadata(h, chat), afterLower);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, isEmpty);
    expect((await h.bridge.getVariables(context.id, scriptChat)).value, isEmpty);
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
  });

  test('legacy typed closure return omits the previously consumed scalar prefix', () async {
    final h = await slashFixture();
    final actor = await h.card('Legacy closure prefix');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.engine.setSettings({'macroEngine': 'legacy'});
    expect(scriptMap(jsonDecode(_rawMetadata(h, chat))).containsKey('chat_id_hash'), isFalse);
    // Fixed SlashCommandClosure.substituteParams returns listValues, without
    // its earlier scalar done value, when it reaches a genuine Closure.
    final result = await slashRun(
      h,
      context.id,
      'f={: /pass BODY :} /pass {{arg::prefix}}{{var::f}} | /run {{pipe}}',
      arguments: const {'prefix': 'PREFIX'},
    );
    expect(result.pipe, 'BODY');
    expect(result.completion, TavernSlashCompletion.completed);
    expect(result.effects.committed, isTrue);
    _expectHashAdoption(result, chat);
    expect(
      scriptMap(jsonDecode(_rawMetadata(h, chat)))['chat_id_hash'],
      isA<num>().having((value) => value.isFinite, 'finite', isTrue),
    );
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, isEmpty);
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
  });

  test('the first raw assignment controls message quoting before duplicate values or macros resolve', () async {
    final h = await slashFixture();
    final actor = await h.card('Raw quote admission');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final stripped = await slashRun(h, context.id, '/comment raw=false raw=true return=pipe "quoted"');
    final kept = await slashRun(h, context.id, '/comment raw=true raw=false return=pipe "quoted"');
    final unresolved = await slashRun(
      h,
      context.id,
      '/comment raw="{{arg::raw}}" return=pipe "quoted"',
      arguments: const {'raw': 'false'},
    );
    expect(stripped.pipe, 'quoted');
    expect(kept.pipe, '"quoted"');
    expect(unresolved.pipe, '"quoted"');
    expect((await h.engine.path(chat)).map((message) => message.text), ['quoted', '"quoted"', '"quoted"']);
    expect((await h.engine.path(chat)).map((message) => message.role), everyElement(TavernRole.system));
    await h.reopen();
    expect((await h.engine.path(chat)).map((message) => message.text), ['quoted', '"quoted"', '"quoted"']);
    h.expectNoGeneration();
  });
}

String _rawMetadata(ScriptFixture h, String chatId) =>
    h.inspect((db) => db.select('SELECT metadata FROM chats WHERE id = ?', [chatId]).single['metadata'] as String);

void _expectHashAdoption(TavernSlashResult result, String chatId) {
  final adopted = result.effects.entries.where((effect) => effect.state == TavernSlashEffectState.adopted).toList();
  expect(adopted, hasLength(1));
  final effect = adopted.single;
  expect(effect.kind, TavernSlashEffectKind.storage);
  expect(effect.target, {'kind': 'stChatIdHash', 'chatId': chatId});
  expect(effect.committed, isTrue);
  expect(effect.details['carrier'], 'sql');
  expect(effect.version, isNotEmpty);
}
