import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// Real facade, files, SQLite and both macro engines. Only the model is scripted.
void main() {
  test('legacy manual variable names keep NEL keys distinct through persistence', () async {
    final h = await _open(mode: 'legacy');
    final greeting = (await h.engine.path(h.chatId)).single;
    final ready = await h.engine.sendOnly(h.chatId, 'READY');
    expect(ready.text, 'READY');
    final collision = await h.engine.sendOnly(
      h.chatId,
      '{{setvar::KEY::A}}{{setvar::\u0085KEY::B}}{{getvar::KEY}}/{{getvar::\u0085KEY}}',
    );
    expect(
      {'text': collision.text, 'variables': h.engine.variables(h.chatId)},
      {
        'text': 'A/B',
        'variables': {'KEY': 'A', '\u0085KEY': 'B'},
      },
    );
    // Legacy executes whole passes in set/add/inc/dec/get order.
    final arithmetic = await h.engine.sendOnly(
      h.chatId,
      '{{setvar::COUNT::plain}}{{setvar::\u0085COUNT::2}}{{addvar::\u0085COUNT::3}}'
      '{{incvar::\u0085COUNT}}/{{decvar::\u0085COUNT}}/{{getvar::\u0085COUNT}}',
    );
    expect(arithmetic.text, '6/5/5');
    const local = {'KEY': 'A', '\u0085KEY': 'B', 'COUNT': 'plain', '\u0085COUNT': 5};
    expect(h.engine.variables(h.chatId), local);
    final global = await h.engine.sendOnly(h.chatId, '{{setglobalvar::\u0085KEY::GLOBAL}}{{getglobalvar::\u0085KEY}}');
    expect(global.text, 'GLOBAL');
    expect(h.engine.globalVariables, {'\u0085KEY': 'GLOBAL'});
    expect(h.engine.variables(h.chatId), local);
    await h.reopen();
    expect(h.engine.variables(h.chatId), local);
    expect(h.engine.globalVariables, {'\u0085KEY': 'GLOBAL'});
    expect((await h.engine.path(h.chatId)).map((node) => (node.nodeId, node.text)), [
      (greeting.nodeId, 'G'),
      (ready.nodeId, 'READY'),
      (collision.nodeId, 'A/B'),
      (arithmetic.nodeId, '6/5/5'),
      (global.nodeId, 'GLOBAL'),
    ]);
    expect(h.model.generated, 0);
  });

  test('modern manual shorthand values preserve NEL after evaluation and persistence', () async {
    final h = await _open();
    final greeting = (await h.engine.path(h.chatId)).single;
    final ready = await h.engine.sendOnly(h.chatId, 'READY');
    expect(ready.text, 'READY');
    final value = await h.engine.sendOnly(h.chatId, '{{.x = \u0085VALUE}}{{.x}}');
    expect(
      {'text': value.text, 'variables': h.engine.variables(h.chatId)},
      {
        'text': '\u0085VALUE',
        'variables': {'x': '\u0085VALUE'},
      },
    );
    final spaces = await h.engine.sendOnly(h.chatId, '{{.spaces = \u00a0\ufeffVALUE\ufeff\u00a0}}{{.spaces}}');
    expect(spaces.text, 'VALUE');
    final inside = await h.engine.sendOnly(h.chatId, '{{.inside = V\u0085ALUE}}{{.inside}}');
    expect(inside.text, 'V\u0085ALUE');
    final nested = await h.engine.sendOnly(h.chatId, '{{.nested = {{getvar::x}}}}{{.nested}}');
    expect(nested.text, '\u0085VALUE');
    const local = {'x': '\u0085VALUE', 'spaces': 'VALUE', 'inside': 'V\u0085ALUE', 'nested': '\u0085VALUE'};
    expect(h.engine.variables(h.chatId), local);
    await h.reopen();
    expect(h.engine.variables(h.chatId), local);
    expect((await h.engine.path(h.chatId)).map((node) => (node.nodeId, node.text)), [
      (greeting.nodeId, 'G'),
      (ready.nodeId, 'READY'),
      (value.nodeId, '\u0085VALUE'),
      (spaces.nodeId, 'VALUE'),
      (inside.nodeId, 'V\u0085ALUE'),
      (nested.nodeId, '\u0085VALUE'),
    ]);
    expect(h.model.generated, 0);
  });

  for (final mode in ['modern', 'legacy']) {
    test('$mode sendOnly random lists preserve NEL and JavaScript trim rules', () async {
      final h = await _open(mode: mode);
      final greeting = (await h.engine.path(h.chatId)).single;
      final ready = await h.engine.sendOnly(h.chatId, 'READY');
      expect(ready.text, 'READY');

      final nel = await h.engine.sendOnly(h.chatId, '{{random::\u0085KEY}}');
      expect(nel.text.codeUnits, [133, 75, 69, 89]);

      // Identical comma choices leave JS whitespace inside the modern
      // parser's outer slice, so the list helper itself still has to trim.
      final spaces = await h.engine.sendOnly(
        h.chatId,
        '{{random::\u00a0\ufeffKEY\ufeff\u00a0,\u00a0\ufeffKEY\ufeff\u00a0}}',
      );
      expect(spaces.text, 'KEY');
      final inside = await h.engine.sendOnly(h.chatId, '{{random::K\u0085EY}}');
      expect(inside.text, 'K\u0085EY');

      // The single-colon form reaches modern's one-argument list splitter.
      // Legacy deliberately preserves spaces in its remaining :: branch.
      final split = await h.engine.sendOnly(h.chatId, '{{random: \u0085KEY :: \u0085KEY }}');
      final splitText = mode == 'legacy' ? ' \u0085KEY ' : '\u0085KEY';
      expect(split.text, splitText);
      final pick = await h.engine.sendOnly(h.chatId, '{{pick::\u0085KEY}}');
      expect(pick.text, '\u0085KEY');

      await h.reopen();
      expect((await h.engine.path(h.chatId)).map((node) => (node.nodeId, node.text)), [
        (greeting.nodeId, 'G'),
        (ready.nodeId, 'READY'),
        (nel.nodeId, '\u0085KEY'),
        (spaces.nodeId, 'KEY'),
        (inside.nodeId, 'K\u0085EY'),
        (split.nodeId, splitText),
        (pick.nodeId, '\u0085KEY'),
      ]);
      expect(h.model.generated, 0);
    });

    test('$mode sendOnly datetimeformat era tokens persist the context year', () async {
      final h = await _open(mode: mode);
      final Tavern facade = h.engine;
      final greeting = (await facade.path(h.chatId)).single;
      final ready = await facade.sendOnly(h.chatId, 'READY');
      expect(ready.text, 'READY');
      final input = mode == 'legacy' ? '{{datetimeformat N|y|YYYY}}' : '{{datetimeformat::N|y|YYYY}}';
      final era = await facade.sendOnly(h.chatId, input);
      // T24's fixed UTC clock is 2026-11-10; unsupported N/y remain literal on S2.
      expect(era.text, 'AD|2026|2026');
      final expected = [(greeting.nodeId, 'G'), (ready.nodeId, 'READY'), (era.nodeId, 'AD|2026|2026')];
      expect((await facade.path(h.chatId)).map((message) => (message.nodeId, message.text)), expected);
      await h.reopen();
      expect((await h.engine.path(h.chatId)).map((message) => (message.nodeId, message.text)), expected);
      expect(h.model.generated, 0);
    });

    test('$mode sendOnly datetimeformat escapes whole tokens and persists literal output', () async {
      final h = await _open(mode: mode);
      final Tavern facade = h.engine;
      String dateMacro(String pattern) =>
          mode == 'legacy' ? '{{datetimeformat $pattern}}' : '{{datetimeformat::$pattern}}';
      final greeting = (await facade.path(h.chatId)).single;
      final ready = await facade.sendOnly(h.chatId, 'READY');
      expect(ready.text, 'READY');
      final month = await facade.sendOnly(h.chatId, dateMacro(r'\MM'));
      // The old one-character escape produces M plus a month number, never MM.
      expect(month.text, 'MM');
      final literals = await facade.sendOnly(h.chatId, dateMacro(r'\YYYY|\LLLL'));
      expect(literals.text, 'YYYY|LLLL');
      final expected = [
        (greeting.nodeId, 'G'),
        (ready.nodeId, 'READY'),
        (month.nodeId, 'MM'),
        (literals.nodeId, 'YYYY|LLLL'),
      ];
      expect((await facade.path(h.chatId)).map((message) => (message.nodeId, message.text)), expected);
      await h.reopen();
      expect((await h.engine.path(h.chatId)).map((message) => (message.nodeId, message.text)), expected);
      expect(h.model.generated, 0);
    });

    test('$mode manual card description preserves JavaScript whitespace through persistence', () async {
      final h = await _open(mode: mode);
      final greeting = (await h.engine.path(h.chatId)).single;
      await h.engine.updateCharacterFields(h.characterId, {'description': '\u0085D'});
      expect((await h.engine.characterFields(h.characterId))!['description'], '\u0085D');
      final ready = await h.engine.sendOnly(h.chatId, 'READY');
      expect(ready.text, 'READY');
      final nel = await h.engine.sendOnly(h.chatId, '{{description}}');
      expect(nel.text.codeUnits, [133, 68]);
      const spaced = '\u00a0\ufeffD\ufeff\u00a0';
      await h.engine.updateCharacterFields(h.characterId, {'description': spaced});
      final spaces = await h.engine.sendOnly(h.chatId, '{{description}}');
      expect(spaces.text, 'D');
      expect((await h.engine.characterFields(h.characterId))!['description'], spaced);
      await h.engine.updateCharacterFields(h.characterId, {'description': 'D\u0085X'});
      final inside = await h.engine.sendOnly(h.chatId, '{{description}}');
      expect(inside.text, 'D\u0085X');
      await h.reopen();
      expect((await h.engine.characterFields(h.characterId))!['description'], 'D\u0085X');
      expect((await h.engine.path(h.chatId)).map((node) => (node.nodeId, node.text)), [
        (greeting.nodeId, 'G'),
        (ready.nodeId, 'READY'),
        (nel.nodeId, '\u0085D'),
        (spaces.nodeId, 'D'),
        (inside.nodeId, 'D\u0085X'),
      ]);
      expect(h.model.generated, 0);
    });

    test(
      '$mode sendOnly applies input regex before one whole-body expansion and stores whitespace and empty input',
      () async {
        final h = await _open(mode: mode);
        final Tavern facade = h.engine;
        final persona = await facade.createPersona(name: 'Selected Persona', description: 'persona');
        await facade.bindPersona(h.chatId, persona.id);
        await h.engine.setSettings({
          'globalRegexScripts': [
            _script('input-order', 'RAW', '{{setvar::inputPhase::ready}}DONE', [1]),
          ],
        });
        final greeting = (await facade.path(h.chatId)).single;
        const input = ' \tRAW {{getvar::inputPhase}}/{{incvar::once}}|{{input}} \n';
        final message = await facade.sendOnly(h.chatId, input);
        // Regex replacement prepares inputPhase before the whole-body getter.
        // Swapping those stages would render the getter while still unset.
        // A second whole-body expansion would evaluate the macro text inserted
        // by input and increment once again in both macro engines.
        expect(message.text, ' \tDONE ready/1|$input \n');
        expect(message.role, TavernRole.user);
        expect(message.speaker, 'Selected Persona');
        expect(message.hidden, isFalse);
        expect(message.parentId, greeting.nodeId);
        expect(h.engine.variables(h.chatId)['inputPhase'], 'ready');
        expect(h.engine.variables(h.chatId)['once'], 1);
        final named = await facade.sendOnly(h.chatId, '{{user}}');
        expect(named.text, 'Selected Persona');
        final empty = await facade.sendOnly(h.chatId, '');
        expect(empty.text, '');
        expect(empty.parentId, named.nodeId);
        expect((await facade.path(h.chatId)).map((node) => node.nodeId), [
          greeting.nodeId,
          message.nodeId,
          named.nodeId,
          empty.nodeId,
        ]);
        expect(h.engine.variables(h.chatId)['once'], 1);
        expect(message.usage, isNull);
        expect(message.reportedUsage, isNull);
        expect(h.model.generated, 0);
        expect(await facade.inspectTurn(h.chatId), isNull);
        await h.reopen();
        expect((await h.engine.path(h.chatId)).last.nodeId, empty.nodeId);
        expect(h.engine.variables(h.chatId)['once'], 1);
      },
    );

    test('$mode narrate uses all JS trim characters keeps NEL and bypasses input and slash regex', () async {
      final h = await _open(mode: mode);
      await h.engine.setGlobalVariables({'inputRegex': 0, 'slashRegex': 0});
      await h.engine.setSettings({
        'globalRegexScripts': [
          _script('must-not-run-input', 'NARRATE', '{{incglobalvar::inputRegex}}BROKEN', [1]),
          _script('must-not-run-slash', 'NARRATE', '{{incglobalvar::slashRegex}}BROKEN', [3]),
        ],
      });
      final edge = String.fromCharCodes(const [
        0x0009,
        0x000a,
        0x000b,
        0x000c,
        0x000d,
        0x0020,
        0x00a0,
        0x1680,
        0x2000,
        0x2001,
        0x2002,
        0x2003,
        0x2004,
        0x2005,
        0x2006,
        0x2007,
        0x2008,
        0x2009,
        0x200a,
        0x2028,
        0x2029,
        0x202f,
        0x205f,
        0x3000,
        0xfeff,
      ]);
      final first = await h.engine.narrate(h.chatId, '${edge}NARRATE {{incvar::n}}$edge');
      expect(first.text, 'NARRATE 1');
      expect(first.speaker, 'System');
      expect(first.role, TavernRole.narrator);
      expect(first.hidden, isFalse);
      final rawInput = '$edge{{input}}$edge';
      final inserted = await h.engine.narrate(h.chatId, rawInput);
      // Trim applies before expansion only. Whitespace returned by a macro
      // remains in the saved body instead of being trimmed a second time.
      expect(inserted.text, rawInput);
      expect(inserted.parentId, first.nodeId);
      final nelText = '\u0085${edge}NARRATE$edge\u0085';
      final nel = await h.engine.narrate(h.chatId, nelText);
      expect(nel.text, nelText);
      expect(nel.parentId, inserted.nodeId);
      expect(h.engine.globalVariables, {'inputRegex': 0, 'slashRegex': 0});
      expect(h.engine.variables(h.chatId)['n'], 1);
      final exported = await _exported(h.engine, h.chatId, first.nodeId);
      expect(exported.row['is_user'], isFalse);
      expect(exported.row['is_system'], isFalse);
      expect(_map(exported.row['extra'])['type'], 'narrator');
      expect(_map(_map(_map(exported.row['extra'])['dshgo'])['chatJsonl'])['role'], 'narrator');
      final files = await h.engine.exportChat(h.chatId);
      final imported = await h.engine.importChats(h.characterId, files);
      final restored = await h.engine.path(imported.chatIds.single);
      expect(restored.skip(1).map((node) => node.role), [
        TavernRole.narrator,
        TavernRole.narrator,
        TavernRole.narrator,
      ]);
      expect(restored[2].text, rawInput);
      expect(restored.last.text, nelText);
      expect(h.model.generated, 0);
      expect(await h.engine.inspectTurn(h.chatId), isNull);
    });
  }

  test('modern main turn sends prepared NEL description to the actual provider', () async {
    final h = await _open();
    await h.engine.updateCharacterFields(h.characterId, {'description': '\u0085D'});
    expect((await h.engine.characterFields(h.characterId))!['description'], '\u0085D');
    h.engine.configure(TavernModelConfig(apiKey: () async => 'fixture-key', model: 'fixture-model', deepseek: false));
    // The ordinary Q has no card macro. The enabled t24Preset description
    // marker must receive prepareCharacterFields, not a lazy macro getter.
    final call = h.model.prepare();
    final events = T24Events(h.engine.send(h.chatId, 'Q'));
    await Future.any<void>([call.listening.future, events.done.future]);
    expect(call.cancellation, isNotNull, reason: 'The main turn must reach modelClient.generate.');
    try {
      expect(h.model.generated, 1);
      expect(call.body!['messages'], [
        {'role': 'system', 'content': '\u0085D'},
        {'role': 'assistant', 'content': 'G'},
        {'role': 'user', 'content': 'Q'},
      ]);
    } finally {
      call.add(const ModelText('OK'));
      await call.finish();
      await events.done.future;
    }
    expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
    expect(events.values.whereType<TavernTurnDone>().single.message.text, 'OK');
    expect(h.model.generated, 1);
  });

  test('narrator names preserve explicit empty and literal values before metadata and System fallback', () async {
    final h = await _open();
    final chat = await _import(h, 'voice.jsonl', [_row('G')], metadata: {'narrator_name': 'Header Voice'});
    final metadata = await h.engine.narrate(chat, 'metadata');
    final empty = await h.engine.narrate(chat, 'empty', speaker: '');
    final literal = await h.engine.narrate(chat, 'literal', speaker: '{{user}}');
    expect(metadata.speaker, 'Header Voice');
    expect(empty.speaker, '');
    expect(literal.speaker, '{{user}}');
    for (final value in <Object?>['', 7]) {
      final fallbackChat = await _import(h, 'fallback-$value.jsonl', [_row('G')], metadata: {'narrator_name': value});
      expect((await h.engine.narrate(fallbackChat, 'fallback')).speaker, 'System');
    }
    final exported = await _exported(h.engine, chat, empty.nodeId);
    expect(exported.row['name'], '');
    expect(_map(exported.row['extra'])['type'], 'narrator');
    expect(h.model.generated, 0);
  });

  test(
    'modern manual messages do not separately prepare card WI or prompt and retain the previous inspection',
    () async {
      final h = await _open();
      final reply = await h.reply('finished', usage: const TavernUsage(promptTokens: 8, completionTokens: 2));
      final inspection = _inspection(await h.engine.inspectTurn(h.chatId));
      final original = (await h.engine.path(h.chatId)).first.text;
      await _phaseSentinels(h);
      h.engine.configure(
        TavernModelConfig(
          apiKey: () async {
            throw StateError('Manual messages must not request credentials.');
          },
          model: 'fixture-model',
        ),
      );
      final user = await h.engine.sendOnly(h.chatId, 'DIRECT USER');
      final narrator = await h.engine.narrate(h.chatId, ' DIRECT NARRATOR ');
      expect(user.parentId, reply.nodeId);
      expect(narrator.parentId, user.nodeId);
      expect(narrator.text, 'DIRECT NARRATOR');
      expect(h.engine.globalVariables, _phaseZeros);
      expect((await h.engine.path(h.chatId)).first.text, original);
      expect(h.model.generated, 1);
      expect(_inspection(await h.engine.inspectTurn(h.chatId)), inspection);
      expect(await h.engine.inspectTurn(h.chatId, nodeId: user.nodeId), isNull);
      expect(await h.engine.inspectTurn(h.chatId, nodeId: narrator.nodeId), isNull);
      for (final manual in [user, narrator]) {
        expect(manual.usage, isNull);
        expect(manual.reportedUsage, isNull);
      }
      expect(
        (await h.engine.path(h.chatId)).singleWhere((node) => node.nodeId == reply.nodeId).reportedUsage!.promptTokens,
        8,
      );
    },
  );

  test('legacy retains its own eager card reads without an extra history WI prompt or model stage', () async {
    final h = await _open(mode: 'legacy');
    const rawHistory = 'G={{incglobalvar::historyPhase}}';
    final chat = await _import(
      h,
      'legacy-source.jsonl',
      [
        _row(rawHistory, state: {'variables': <String, Object?>{}, 'stChatId': 'LegacyStable', 'stChatIdHash': 0}),
      ],
      metadata: {'chat_id_hash': 999},
    );
    await _phaseSentinels(h);
    await h.engine.sendOnly(chat, 'DIRECT USER');
    expect(h.engine.globalVariables, {..._phaseZeros, 'cardPhase': 1, 'greetingPhase': 1});
    await h.engine.narrate(chat, ' DIRECT NARRATOR ');
    expect(h.engine.globalVariables, {..._phaseZeros, 'cardPhase': 2, 'greetingPhase': 2});
    expect((await h.engine.path(chat)).first.text, rawHistory);
    final state = await _currentState(h.engine, chat);
    expect(state['stChatId'], 'LegacyStable');
    // Existing legacy semantics treat cached zero as falsy and compute the
    // same identity hash even when the text contains no pick macro.
    expect(state['stChatIdHash'], MacroEngine.stringHash('LegacyStable'));
    expect(h.model.generated, 0);
    expect(await h.engine.inspectTurn(chat), isNull);
    await h.reopen();
    expect((await h.engine.path(chat)).first.text, rawHistory);
    expect(h.engine.globalVariables, {..._phaseZeros, 'cardPhase': 2, 'greetingPhase': 2});
  });

  test(
    'manual append waits for partial cancellation writeback and inherits its terminal variables and inspection',
    () async {
      final h = await _open();
      await h.engine.setSettings({
        'globalRegexScripts': [
          _script('terminal-count', r'^[\s\S]+$', r'{{incvar::n}}|$0', [2]),
        ],
      });
      final call = h.model.prepare();
      final events = T24Events(h.engine.send(h.chatId, '{{setvar::n::4}}Q'));
      await call.listening.future;
      call.add(const ModelText('PARTIAL'));
      call.add(const ModelUsage(TavernUsage(promptTokens: 13, completionTokens: 2)));
      await t24Pump();
      final reply = events.values.whereType<TavernTurnStarted>().single.message;
      // path returns the persisted checkpoint, not uncheckpointed live text.
      // The event proves that the model's partial body was already received.
      expect(events.values.whereType<TavernTextDelta>().map((event) => event.text).join(), 'PARTIAL');
      final manual = await h.engine.sendOnly(h.chatId, '{{incvar::n}}manual|{{lastMessage}}');
      await events.done.future;
      expect(call.cancellation!.isCancelled, isTrue);
      expect(events.values.whereType<TavernTurnDone>(), isEmpty);
      expect(events.values.whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
      expect(manual.parentId, reply.nodeId);
      expect(manual.text, '6manual|5|PARTIAL');
      expect(h.engine.variables(h.chatId)['n'], 6);
      final storedReply = (await h.engine.path(h.chatId)).singleWhere((node) => node.nodeId == reply.nodeId);
      expect(storedReply.text, '5|PARTIAL');
      expect(storedReply.reportedUsage!.promptTokens, 13);
      final inspection = (await h.engine.inspectTurn(h.chatId, nodeId: reply.nodeId))!;
      expect(inspection.status, TavernInspectionStatus.failed);
      expect(inspection.failure, TavernFailure.cancelled);
      expect(_inspection(await h.engine.inspectTurn(h.chatId)), _inspection(inspection));
      expect(await h.engine.inspectTurn(h.chatId, nodeId: manual.nodeId), isNull);
      expect(h.model.generated, 1);
      await h.reopen();
      expect((await h.engine.path(h.chatId)).last.nodeId, manual.nodeId);
      expect(h.engine.variables(h.chatId)['n'], 6);
      expect(_inspection(await h.engine.inspectTurn(h.chatId)), _inspection(inspection));
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'selected imported branch keeps its source timer decorator greeting and zero hash through both manual roles',
    () async {
      final h = await _open();
      final branchOld = _branchState(7, 0, 'BranchStable');
      final branchNew = _branchState(30, 42, 'OtherSwipe');
      final leafRow = <String, Object?>{
        ..._row('B-old', state: branchOld),
        'swipes': ['B-old', 'B-new'],
        'swipe_id': 0,
        'swipe_info': [
          {
            'extra': {
              'dshgo': {'tavernState': branchOld},
            },
          },
          {
            'extra': {
              'dshgo': {'tavernState': branchNew},
            },
          },
        ],
      };
      final main = _document(
        'Main.jsonl',
        [_row('MAIN', state: _branchState(99, 999, 'MainStable'))],
        metadata: {'chat_id_hash': 999, 'narrator_name': 'Main Voice'},
      );
      final branch = _document(
        'Branch.jsonl',
        [_row('B-root', state: _branchState(3, 0, 'BranchStable')), leafRow],
        metadata: {'main_chat': 'Main', 'chat_id_hash': 999, 'narrator_name': 'Branch Voice'},
      );
      final imported = await h.engine.importChats(h.characterId, [
        TavernChatFile(fileName: main.fileName, bytes: main.encode()),
        TavernChatFile(fileName: branch.fileName, bytes: branch.encode()),
      ]);
      final chat = imported.chatIds.single;
      final mainRoot = (await h.engine.path(chat)).single;
      await h.engine.selectSibling(chat, mainRoot.nodeId, 1);
      final oldLeaf = (await h.engine.path(chat)).last;
      await h.engine.selectSibling(chat, oldLeaf.nodeId, 1);
      expect(h.engine.variables(chat)['n'], 30);
      await h.engine.selectSibling(chat, oldLeaf.nodeId, 0);
      final before = await _currentState(h.engine, chat);
      expect(before['stChatIdHash'], 0);
      expect(before['chatJsonlSourceFile'], isA<String>());
      final user = await h.engine.sendOnly(chat, '{{incvar::n}} manual');
      final narrator = await h.engine.narrate(chat, ' NEXT ');
      expect(user.text, '8 manual');
      expect(narrator.speaker, 'Branch Voice');
      expect(narrator.parentId, user.nodeId);
      final after = await _currentState(h.engine, chat);
      for (final key in [
        'stChatId',
        'stChatIdHash',
        'chatJsonlSourceFile',
        'timedWorldInfo',
        'decoratorState',
        'greetingIndex',
      ]) {
        expect(after[key], before[key], reason: key);
      }
      expect(after['variables'], {'n': 8});
      expect(h.model.generated, 0);
      expect(await h.engine.inspectTurn(chat), isNull);
      await h.reopen();
      expect((await h.engine.path(chat)).last.nodeId, narrator.nodeId);
      expect(await _currentState(h.engine, chat), after);
    },
  );

  test('manual append at a soft-deleted empty path keeps the new selection when the old root is undone', () async {
    final h = await _open();
    final chat = await _import(
      h,
      'empty-zero.jsonl',
      [
        _row(
          'OLD',
          state: {
            'variables': {'old': 7},
            'stChatId': 'OldIdentity',
            'stChatIdHash': 0,
          },
        ),
      ],
      metadata: {'chat_id_hash': 0},
    );
    final old = (await h.engine.path(chat)).single;
    final token = await h.engine.deleteFrom(chat, old.nodeId);
    expect(await h.engine.path(chat), isEmpty);
    final manual = await h.engine.narrate(chat, ' {{incvar::fresh}}|{{lastMessage}} ');
    expect(manual.parentId, isNull);
    expect(manual.text, '1|');
    expect(h.engine.variables(chat), {'fresh': 1});
    expect((await _currentState(h.engine, chat))['stChatIdHash'], 0);
    expect(await h.engine.undoDeleteFrom(chat, token), isTrue);
    final path = await h.engine.path(chat);
    expect(path.map((node) => node.nodeId), [manual.nodeId]);
    expect(path.single.siblingCount, 2);
    expect(h.engine.variables(chat), {'fresh': 1});
    expect(h.model.generated, 0);
    await h.reopen();
    expect((await h.engine.path(chat)).single.nodeId, manual.nodeId);
    expect(h.engine.variables(chat), {'fresh': 1});
    expect((await _currentState(h.engine, chat))['stChatIdHash'], 0);
  });

  test(
    'a real input regex preparation failure saves changed globals before returning without publishing local state',
    () async {
      final h = await _open();
      await _baseline(h);
      await h.engine.setGlobalVariables({'g': 0});
      await h.engine.setSettings({'globalRegexScripts': _failureScripts()});
      final before = _snapshot(h);
      final inspection = _inspection(await h.engine.inspectTurn(h.chatId));
      final failure = await _failure(h.engine.sendOnly(h.chatId, 'ax'));
      _expectRegexFailure(failure.error);
      expect(failure.stack.toString().trim(), isNotEmpty);
      expect(h.engine.globalVariables, {'g': 1});
      // Verify the disk before close: a later unrelated write cannot satisfy it.
      expect(await _diskGlobals(h), {'g': 1});
      expect(h.engine.variables(h.chatId), {'local': 'saved'});
      expect(_snapshot(h), before);
      expect(_inspection(await h.engine.inspectTurn(h.chatId)), inspection);
      expect(h.model.generated, 1);
      await h.reopen();
      expect(h.engine.globalVariables, {'g': 1});
      expect(h.engine.variables(h.chatId), {'local': 'saved'});
      expect(_snapshot(h), before);
      expect(_inspection(await h.engine.inspectTurn(h.chatId)), inspection);
    },
  );

  test(
    'legacy preparation skips an unchanged-global save and exposes both real errors after a changed-global save fails',
    () async {
      final h = await _open(mode: 'legacy');
      await _baseline(h);
      await h.engine.setGlobalVariables({'g': 0});
      await h.engine.setSettings({'globalRegexScripts': _failureScripts()});
      final before = _snapshot(h);
      final inspection = _inspection(await h.engine.inspectTurn(h.chatId));
      final blocker = Directory('${h.root.path}/settings.json.writing');
      await blocker.create();

      // The first script only matches ax. With x, the same real capture error
      // occurs before globals change; the blocked save must never be attempted.
      final unchanged = await _failure(h.engine.sendOnly(h.chatId, 'x'));
      _expectRegexFailure(unchanged.error);
      expect(unchanged.error.toString(), isNot(contains('Saving global variables also failed')));
      expect(h.engine.globalVariables, {'g': 0});
      expect(await _diskGlobals(h), {'g': 0});
      expect(_snapshot(h), before);

      final failure = await _failure(h.engine.sendOnly(h.chatId, 'ax'));
      final dynamic carrier = failure.error;
      expect(carrier.operation as String, 'sendOnly');
      _expectRegexFailure(carrier.createError as Object);
      final saveError = carrier.saveError as Object;
      expect(saveError, isA<FileSystemException>());
      expect((saveError as FileSystemException).path, endsWith('settings.json.writing'));
      for (final stack in [carrier.createStackTrace as StackTrace, carrier.saveStackTrace as StackTrace]) {
        expect(stack.toString().trim(), isNotEmpty);
      }
      expect(failure.error.toString(), contains('sendOnly failed'));
      expect(failure.error.toString(), contains('Saving global variables also failed'));
      expect(h.engine.globalVariables, {'g': 1});
      expect(await _diskGlobals(h), {'g': 0});
      expect(h.engine.variables(h.chatId), {'local': 'saved'});
      expect(_snapshot(h), before);
      expect(_inspection(await h.engine.inspectTurn(h.chatId)), inspection);
      expect(h.model.generated, 1);

      // close waits for the failed queue but does not silently retry the write.
      await h.engine.close();
      expect(await _diskGlobals(h), {'g': 0});
      await blocker.delete();
      await h.reopen();
      expect(h.engine.globalVariables, {'g': 0});
      expect(h.engine.variables(h.chatId), {'local': 'saved'});
      expect(_snapshot(h), before);
      expect(_inspection(await h.engine.inspectTurn(h.chatId)), inspection);
    },
  );

  test(
    'successful narrator preparation with a blocked global save returns the filesystem error and appends nothing',
    () async {
      final h = await _open();
      await _baseline(h);
      await h.engine.setGlobalVariables({'g': 0});
      final before = _snapshot(h);
      final inspection = _inspection(await h.engine.inspectTurn(h.chatId));
      final blocker = Directory('${h.root.path}/settings.json.writing');
      await blocker.create();
      final failure = await _failure(
        h.engine.narrate(h.chatId, '{{incglobalvar::g}}{{setvar::local::uncommitted}}manual'),
      );
      expect(failure.error, isA<FileSystemException>());
      expect((failure.error as FileSystemException).path, endsWith('settings.json.writing'));
      expect(failure.error.toString(), isNot(contains('narrate failed:')));
      expect(h.engine.globalVariables, {'g': 1});
      expect(await _diskGlobals(h), {'g': 0});
      expect(h.engine.variables(h.chatId), {'local': 'saved'});
      expect(_snapshot(h), before);
      expect(_inspection(await h.engine.inspectTurn(h.chatId)), inspection);
      expect(h.model.generated, 1);
      await h.engine.close();
      await blocker.delete();
      await h.reopen();
      expect(h.engine.globalVariables, {'g': 0});
      expect(h.engine.variables(h.chatId), {'local': 'saved'});
      expect(_snapshot(h), before);
      expect(_inspection(await h.engine.inspectTurn(h.chatId)), inspection);
    },
  );

  test(
    'a variables UPDATE failure after append rolls back tree state and inspection while saved globals survive',
    () async {
      final h = await _open();
      final oldReply = await _baseline(h);
      await h.engine.setGlobalVariables({'g': 0});
      final before = _snapshot(h);
      final inspection = _inspection(await h.engine.inspectTurn(h.chatId));
      _db(
        h,
        (db) => db.execute('''CREATE TRIGGER reject_manual_variables BEFORE UPDATE OF variables ON chats
      WHEN EXISTS (SELECT 1 FROM nodes WHERE chat_id = NEW.id AND text = '1manual')
      BEGIN SELECT RAISE(ABORT, 'manual_variables_after_append'); END'''),
      );
      final failure = await _failure(
        h.engine.sendOnly(h.chatId, '{{incglobalvar::g}}{{setvar::local::uncommitted}}manual'),
      );
      expect(failure.error, isA<SqliteException>());
      expect(failure.error.toString(), contains('manual_variables_after_append'));
      expect(h.engine.globalVariables, {'g': 1});
      expect(await _diskGlobals(h), {'g': 1});
      expect(h.engine.variables(h.chatId), {'local': 'saved'});
      expect(_snapshot(h), before);
      expect(_inspection(await h.engine.inspectTurn(h.chatId)), inspection);
      _db(h, (db) {
        db.execute("INSERT INTO nodes_fts(nodes_fts, rank) VALUES('integrity-check', 1)");
        db.execute('DROP TRIGGER reject_manual_variables');
      });
      await h.reopen();
      expect(h.engine.globalVariables, {'g': 1});
      expect(h.engine.variables(h.chatId), {'local': 'saved'});
      expect(_snapshot(h), before);
      expect(_inspection(await h.engine.inspectTurn(h.chatId)), inspection);
      final retry = await h.engine.sendOnly(h.chatId, '{{setvar::local::retry}}retry');
      expect(retry.parentId, oldReply.nodeId);
      expect(retry.text, 'retry');
      expect(h.engine.variables(h.chatId), {'local': 'retry'});
      expect(h.engine.globalVariables, {'g': 1});
      expect(_inspection(await h.engine.inspectTurn(h.chatId)), inspection);
      expect(h.model.generated, 1);
    },
  );

  test(
    'missing chats and a closed engine reject both manual operations without creating a message or calling the model',
    () async {
      final h = await _open();
      final before = _snapshot(h);
      await expectLater(h.engine.sendOnly('missing', 'manual'), throwsStateError);
      await expectLater(h.engine.narrate('missing', 'manual'), throwsStateError);
      expect(_snapshot(h), before);
      expect(h.model.generated, 0);
      await h.engine.close();
      // Admission may throw before returning a Future, so capture both forms.
      await expectLater(Future<TavernMessage>.sync(() => h.engine.sendOnly(h.chatId, 'manual')), throwsStateError);
      await expectLater(Future<TavernMessage>.sync(() => h.engine.narrate(h.chatId, 'manual')), throwsStateError);
      expect(_snapshot(h), before);
      expect(h.model.generated, 0);
    },
  );
}

Future<T24Harness> _open({String mode = 'modern'}) async {
  final h = await T24Harness.open();
  addTearDown(h.dispose);
  await h.engine.setSettings({'macroEngine': mode});
  return h;
}

Map<String, Object?> _script(String id, String pattern, String replacement, List<int> placements) => {
  'id': id,
  'scriptName': id,
  'findRegex': pattern,
  'replaceString': replacement,
  'trimStrings': <String>[],
  'placement': placements,
  'disabled': false,
  'markdownOnly': false,
  'promptOnly': false,
  'runOnEdit': false,
  'substituteRegex': 0,
  'minDepth': null,
  'maxDepth': null,
};

List<Map<String, Object?>> _failureScripts() => [
  _script('global-before-failure', r'^ax$', '{{incglobalvar::g}}{{setvar::local::uncommitted}}ax', [1]),
  _script('fail-after-global', '(?<n>x)', r'$4', [1]),
];

const _phaseZeros = <String, Object?>{
  'cardPhase': 0,
  'greetingPhase': 0,
  'historyPhase': 0,
  'wiPhase': 0,
  'promptPhase': 0,
};

Future<void> _phaseSentinels(T24Harness h) async {
  await h.engine.setGlobalVariables(_phaseZeros);
  await h.engine.updateCharacterFields(h.characterId, {
    'description': '{{incglobalvar::cardPhase}}',
    'first_mes': 'CARD{{incglobalvar::greetingPhase}}',
  });
  await h.engine.addCharacterBookEntry(h.characterId, {
    'keys': <String>[],
    'enabled': true,
    'constant': true,
    'content': '{{incglobalvar::wiPhase}}WI',
    'insertion_order': 100,
    'position': 'before_char',
    'extensions': {'useProbability': false},
  });
  final raw = t24Preset().raw;
  raw['prompts'] = [
    for (final value in raw['prompts']! as List<Object?>)
      <String, Object?>{
        ..._map(value),
        if (_map(value)['identifier'] == 'main') 'content': '{{incglobalvar::promptPhase}}',
      },
  ];
  await h.engine.setPreset(ChatPreset(raw));
}

Map<String, Object?> _map(Object? value) => value is Map<String, Object?> ? value : <String, Object?>{};

StChatDocument _document(
  String fileName,
  List<Map<String, Object?>> rows, {
  Map<String, Object?> metadata = const {},
}) => StChatDocument(
  fileName: fileName,
  header: {'user_name': 'User', 'character_name': 'Guide', 'chat_metadata': metadata},
  messages: rows,
);

Map<String, Object?> _row(String text, {Map<String, Object?>? state}) => {
  'name': 'Guide',
  'is_user': false,
  'is_system': false,
  'send_date': T24Harness.at.toIso8601String(),
  'mes': text,
  if (state != null)
    'extra': {
      'dshgo': {'tavernState': state},
    },
};

Future<String> _import(
  T24Harness h,
  String fileName,
  List<Map<String, Object?>> rows, {
  Map<String, Object?> metadata = const {},
}) async {
  final document = _document(fileName, rows, metadata: metadata);
  return (await h.engine.importChats(h.characterId, [
    TavernChatFile(fileName: fileName, bytes: document.encode()),
  ])).chatIds.single;
}

Future<({StChatDocument document, Map<String, Object?> row})> _exported(
  TavernEngine engine,
  String chatId,
  String nodeId,
) async {
  for (final file in await engine.exportChat(chatId)) {
    final document = StChatDocument.decode(file.fileName, file.bytes);
    for (final row in document.messages) {
      if (_map(_map(_map(row['extra'])['dshgo'])['chatJsonl'])['nodeId'] == nodeId) {
        return (document: document, row: row);
      }
    }
  }
  throw TestFailure('Export did not contain node $nodeId.');
}

Future<Map<String, Object?>> _currentState(TavernEngine engine, String chatId) async {
  final leaf = (await engine.path(chatId)).last;
  final exported = await _exported(engine, chatId, leaf.nodeId);
  return _map(_map(_map(exported.row['extra'])['dshgo'])['tavernState']);
}

Map<String, Object?> _branchState(int n, int hash, String identity) => {
  'variables': {'n': n},
  'stChatId': identity,
  'stChatIdHash': hash,
  'timedWorldInfo': {
    'sticky': {
      'fixture.1': {'hash': 123, 'start': 1, 'end': 8, 'protected': false},
    },
    'cooldown': <String, Object?>{},
    'delay': <String, Object?>{},
  },
  'decoratorState': {
    '123': {'matches': 7, 'lastMessageCount': 4},
  },
  'greetingIndex': 7,
};

String _inspection(TavernTurnInspection? inspection) => jsonEncode(inspection?.toJson());

Future<TavernMessage> _baseline(T24Harness h) async {
  final reply = await h.reply('baseline', usage: const TavernUsage(promptTokens: 9, completionTokens: 2));
  await h.engine.edit(h.chatId, reply.nodeId, '{{setvar::local::saved}}baseline');
  expect(h.engine.variables(h.chatId), {'local': 'saved'});
  expect(await h.engine.inspectTurn(h.chatId), isNotNull);
  return reply;
}

T _db<T>(T24Harness h, T Function(Database) action) {
  final db = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    return action(db);
  } finally {
    db.close();
  }
}

String _snapshot(T24Harness h) => _db(
  h,
  (db) => jsonEncode({
    for (final table in ['chats', 'nodes', 'node_states', 'deleted_subtrees'])
      table: db
          .select('SELECT * FROM $table ORDER BY ${table == 'node_states' ? 'node_id' : 'id'}')
          .map((row) => Map<String, Object?>.from(row))
          .toList(),
  }),
);

Future<Map<String, Object?>> _diskGlobals(T24Harness h) async =>
    _map(_map(jsonDecode(await File('${h.root.path}/settings.json').readAsString()))['globalVariables']);

Future<({Object error, StackTrace stack})> _failure<T>(Future<T> action) async {
  try {
    await action;
  } catch (error, stack) {
    return (error: error, stack: stack);
  }
  throw TestFailure('Expected the manual operation to fail.');
}

void _expectRegexFailure(Object error) {
  expect(error, isA<StateError>());
  expect(error.toString(), contains('ST regex fail-after-global:'));
  expect(error.toString(), contains(r'$4 resolves to the named-groups object'));
}
