import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_slash_test_support.dart';

void main() {
  test('private raw evaluates prefill then user then system and leaves registry ownership intact', () async {
    final h = await slashFixture(allowModel: true);
    final actor = await h.card('Raw actor', description: 'UNRELATED CARD');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final host = SlashHost();
    h.bridge.attachHost(host);
    await h.bridge.replaceVariables(context.id, scriptGlobal, {
      'PRE': '{{setglobalvar::order::P}}PREFILL',
      'SYS': '{{getglobalvar::order}}{{setglobalvar::order::PUS}}SYS',
    });
    final lease = await h.bridge.injectPrompts(context.id, [
      TavernScriptInjection(
        id: 'must-not-filter',
        content: 'UNRELATED REGISTRY',
        filter: TavernScriptCallbackRef(
          contextId: context.id,
          instanceId: context.instanceId,
          callbackId: 'not-called',
        ),
      ),
    ], once: true);
    final before = generationNodes(h, chat);
    final response = h.reply('RAW ANSWER');
    final script = await h.bridge.triggerSlash(
      context.id,
      '/genraw prefill=PRE system=SYS length=41 {{arg::payload}}',
      arguments: {'payload': '{{getglobalvar::order}}{{setglobalvar::order::PU}}USER'},
    );
    final wire = await slashSignal(script, response.seen.future);
    final result = await script.result;
    expect(wire.body, {
      ...scriptWire([
        {'role': 'system', 'content': 'PUSYS'},
        {'role': 'user', 'content': 'PUSER'},
        {'role': 'assistant', 'content': 'PREFILL'},
      ]),
      'max_tokens': 41,
    });
    expect(result.pipe, 'RAW ANSWER');
    expect(result.effects.committed, isTrue);
    expect(host.invocations, isEmpty);
    expect(host.interactions, isEmpty);
    final views = await h.bridge.listInjections(context.id);
    expect(views, hasLength(1));
    expect(views.single.leaseId, lease.leaseId);
    expect(views.single.claimed, isFalse);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value['order'], 'PUS');
    expect(scriptMap((await h.settingsDocument())['globalVariables'])['order'], 'PUS');
    expect(generationNodes(h, chat), before);
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
    stdout.writeln('P2_B3_GENERATION_READY');
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('raw empty callback preserves outer effects and skips unused values while whitespace still requests', () async {
    final h = await slashFixture(allowModel: true);
    final actor = await h.card('Empty raw');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final empty = await slashRun(
      h,
      context.id,
      '/genraw lock=true stop="not-json" length=1.5 system={: /pass UNUSED :} '
      'prefill="{{setglobalvar::outer::yes}}"',
    );
    expect(empty.pipe, '');
    expect(empty.effects.committed, isTrue);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'outer': 'yes'});
    h.expectNoGeneration();
    final typed = await h.bridge.triggerSlash(context.id, '/genraw {: /pass X :}');
    final typedFailure = await slashFailure(typed);
    expect(typedFailure.code, TavernScriptErrorCode.invalidArgument);
    expect(typedFailure.committed, isFalse);
    h.expectNoGeneration();
    final response = h.reply('SPACE ANSWER');
    final whitespace = await h.bridge.triggerSlash(context.id, '/genraw "   "');
    final wire = await slashSignal(whitespace, response.seen.future);
    expect(generationMessages(wire), [
      {'role': 'user', 'content': ''},
    ]);
    expect((await whitespace.result).pipe, 'SPACE ANSWER');
    expect(await h.engine.path(chat), isEmpty);
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test(
    'raw handler validates only consumed resolver values before key and preserves an empty prepared system',
    () async {
      final h = await slashFixture(allowModel: true);
      final actor = await h.card('Raw values');
      final chat = await h.emptyChat(actor);
      final context = await h.context(chat, characterId: actor);
      await h.bridge.replaceVariables(context.id, scriptGlobal, {
        'NUMERIC': '23',
        'EMPTY_SYSTEM': '{{setglobalvar::system_seen::yes}}',
      });
      for (final source in [
        '/genraw length=1.5 Q',
        '/genraw length=Infinity Q',
        '/genraw system=NUMERIC Q',
        '/genraw stop="[1]" Q',
        '/genraw stop="not-json" Q',
      ]) {
        final failure = await slashFailure(await h.bridge.triggerSlash(context.id, source));
        expect(failure.code, TavernScriptErrorCode.invalidArgument);
        expect(failure.committed, isFalse);
        h.expectNoGeneration();
      }
      final response = h.reply('PARAMETER ANSWER');
      final script = await h.bridge.triggerSlash(
        context.id,
        '/genraw instruct=on as=CHAR length=-3 system=EMPTY_SYSTEM Q',
      );
      final wire = await slashSignal(script, response.seen.future);
      expect(
        wire.body,
        scriptWire([
          {'role': 'system', 'content': ''},
          {'role': 'user', 'content': 'Q'},
        ]),
      );
      expect((await script.result).pipe, 'PARAMETER ANSWER');
      expect((await h.bridge.getVariables(context.id, scriptGlobal)).value['system_seen'], 'yes');
      expect(await h.engine.path(chat), isEmpty);
      expect(h.requests, hasLength(1));
      expect(h.keyReads, 1);
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'quiet repeats cleanup from original decoded text around reasoning while raw performs only one cleanup',
    () async {
      final h = await slashFixture(allowModel: true);
      final actor = await h.card('Output actor');
      final chat = await h.emptyChat(actor);
      final context = await h.context(chat, characterId: actor);
      h.engine.configure(
        TavernModelConfig(
          apiKey: h.config.apiKey,
          baseUrl: 'https://p2-script.invalid/v1',
          model: 'configured-deepseek',
          deepseek: true,
          thinking: true,
        ),
      );
      await h.engine.setSettings({
        'power_user': {
          'reasoning': {'auto_parse': true},
        },
        'globalRegexScripts': [
          _writeBack(
            'body',
            '/(ANSWER)/g',
            r'$1|{{getglobalvar::reason_seen}}|{{incglobalvar::out}}',
            RegexPlacement.aiOutput,
          ),
          _writeBack('reason', '/(R)/g', r'{{setglobalvar::reason_seen::yes}}$1', RegexPlacement.reasoning),
        ],
      });
      final before = generationNodes(h, chat);
      for (final command in ['gen', 'genraw']) {
        await h.bridge.replaceVariables(context.id, scriptGlobal, {'out': 0});
        final response = generationJsonResponse(h, {
          'choices': [
            {
              'index': 0,
              'message': {'role': 'assistant', 'content': '<think>I</think>ANSWER', 'reasoning_content': 'R'},
              'finish_reason': 'stop',
            },
          ],
        });
        final script = await h.bridge.triggerSlash(context.id, '/$command Q');
        await slashSignal(script, response.seen.future);
        final result = await script.result;
        if (command == 'gen') {
          expect(result.pipe, 'ANSWER|yes|2');
          expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'out': 2, 'reason_seen': 'yes'});
        } else {
          expect(result.pipe, '<think>I</think>ANSWER||1');
          expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'out': 1});
        }
        expect(result.effects.committed, isTrue);
        expect(generationNodes(h, chat), before);
      }
      expect(h.requests, hasLength(2));
      expect(h.keyReads, 2);
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test('permanent stops expand once for wire and afresh in both quiet cleanups', () async {
    final h = await slashFixture(allowModel: true);
    final actor = await h.card('Stop actor');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'stops': 0});
    await h.engine.setSettings({
      'power_user': {
        'custom_stopping_strings': jsonEncode(['{{incglobalvar::stops}}END']),
        'custom_stopping_strings_macro': true,
      },
    });
    final response = h.reply('BODY3E');
    final script = await h.bridge.triggerSlash(context.id, '/gen Q');
    final wire = await slashSignal(script, response.seen.future);
    expect(wire.body['stop'], ['1END']);
    final result = await script.result;
    expect(result.pipe, 'BODY');
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'stops': 3});
    expect(scriptMap((await h.settingsDocument())['globalVariables']), {'stops': 3});
    expect(await h.engine.path(chat), isEmpty);
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('output captures fresh variables after HTTP without replacing intervening adopted writes', () async {
    final h = await slashFixture(allowModel: true);
    final actor = await h.card('Fresh output');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'global': 1});
    await h.bridge.replaceVariables(context.id, scriptChat, {'local': 1});
    await h.engine.setSettings({
      'globalRegexScripts': [
        _writeBack('fresh', '/(ANSWER)/g', r'$1/{{incglobalvar::global}}/{{incvar::local}}', RegexPlacement.aiOutput),
      ],
    });
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final response = h.reply('ANSWER')..beforeResponse = () => release.future;
    final script = await h.bridge.triggerSlash(context.id, '/gen Q');
    await slashSignal(script, response.seen.future);
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'global': 10});
    await h.bridge.replaceVariables(context.id, scriptChat, {'local': 20});
    release.complete();
    final result = await script.result;
    expect(result.pipe, 'ANSWER/12/22');
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'global': 12});
    expect((await h.bridge.getVariables(context.id, scriptChat)).value, {'local': 22});
    expect(await h.engine.path(chat), isEmpty);
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
    await h.reopen();
    final fresh = await h.context(chat, characterId: actor);
    expect((await h.bridge.getVariables(fresh.id, scriptGlobal)).value, {'global': 12});
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value, {'local': 22});
    expect(await h.engine.path(chat), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('output global adoption survives real SQL failure and retains decoded child and accepted once', () async {
    final h = await slashFixture(allowModel: true);
    final actor = await h.card('Partial output');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'global': 1});
    await h.bridge.replaceVariables(context.id, scriptChat, {'local': 1});
    await h.bridge.injectPrompts(context.id, [
      TavernScriptInjection(id: 'accepted-before-output', content: 'ONCE'),
    ], once: true);
    await h.engine.setSettings({
      'globalRegexScripts': [
        _writeBack('partial', '/(ANSWER)/g', r'$1/{{incglobalvar::global}}/{{incvar::local}}', RegexPlacement.aiOutput),
      ],
    });
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final response = h.reply('ANSWER')..beforeResponse = () => release.future;
    final script = await h.bridge.triggerSlash(context.id, '/gen Q');
    await slashSignal(script, response.seen.future);
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'global': 10});
    await h.bridge.replaceVariables(context.id, scriptChat, {'local': 20});
    h.inspect(
      (db) => db.execute(
        'CREATE TRIGGER b3_output_fail BEFORE UPDATE OF variables ON chats '
        'WHEN NEW.variables <> OLD.variables BEGIN '
        "SELECT RAISE(ABORT, 'B3 output SQL failure'); END",
      ),
      writable: true,
    );
    release.complete();
    final failure = await slashFailure(script);
    expect(failure.code, TavernScriptErrorCode.storage);
    expect(failure.committed, isTrue);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'global': 12});
    expect(scriptMap((await h.settingsDocument())['globalVariables']), {'global': 12});
    expect((await h.bridge.getVariables(context.id, scriptChat)).value, {'local': 20});
    final terminal = await script.events.single;
    expect(terminal.kind, TavernSlashExecutionEventKind.snapshot);
    expect(terminal.status, TavernSlashStatus.failed);
    expect(terminal.effects.committed, isTrue);
    expect(terminal.partialGeneration!.text, 'ANSWER');
    final summary = failure.issues.singleWhere((issue) => issue.code == 'slashExecution');
    expect(scriptMap(summary.details['partialGeneration'])['text'], 'ANSWER');
    final view = (await h.bridge.listInjections(context.id)).single;
    expect(view.claimed, isTrue);
    expect(await h.engine.path(chat), isEmpty);
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
    h.inspect((db) => db.execute('DROP TRIGGER b3_output_fail'), writable: true);
    await h.reopen();
    final fresh = await h.context(chat, characterId: actor);
    expect((await h.bridge.getVariables(fresh.id, scriptGlobal)).value, {'global': 12});
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value, {'local': 20});
    expect(await h.engine.path(chat), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('empty raw cleanup discards only output intents after accepted input was persisted', () async {
    final h = await slashFixture(allowModel: true);
    final actor = await h.card('Empty output');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'stops': 0});
    await h.engine.setSettings({
      'power_user': {
        'custom_stopping_strings': jsonEncode(['{{incglobalvar::stops}}X']),
      },
    });
    final response = h.reply('2X');
    final script = await h.bridge.triggerSlash(context.id, '/genraw Q');
    final wire = await slashSignal(script, response.seen.future);
    expect(wire.body['stop'], ['1X']);
    final failure = await slashFailure(script);
    expect(failure.committed, isTrue);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'stops': 1});
    expect(scriptMap((await h.settingsDocument())['globalVariables']), {'stops': 1});
    final terminal = await script.events.single;
    expect(terminal.status, TavernSlashStatus.failed);
    expect(terminal.partialGeneration!.text, '2X');
    expect(await h.engine.path(chat), isEmpty);
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('private input and output macros use the empty composer projection for both flavors', () async {
    final h = await slashFixture(allowModel: true);
    final actor = await h.card('Composer actor');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final host = SlashHost();
    h.bridge.attachHost(host);
    await h.engine.setSettings({
      'globalRegexScripts': [_writeBack('composer', '/(ANSWER)/g', r'$1|{{input}}|', RegexPlacement.aiOutput)],
    });
    for (final command in ['gen', 'genraw']) {
      final response = h.reply('ANSWER');
      final script = await h.bridge.triggerSlash(
        context.id,
        '/$command {{arg::payload}}',
        arguments: {'payload': 'LEFT{{input}}RIGHT'},
      );
      final wire = await slashSignal(script, response.seen.future);
      final contents = generationMessages(wire).map((message) => message['content']).toList();
      expect(contents, contains('LEFTRIGHT'));
      expect(contents.whereType<String>().join('\n'), isNot(contains('{{input}}')));
      expect((await script.result).pipe, 'ANSWER||');
    }
    expect(host.interactions, isEmpty);
    expect(await h.engine.path(chat), isEmpty);
    expect(h.requests, hasLength(2));
    expect(h.keyReads, 2);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('quiet admits its first expanded bias using JavaScript whitespace in the actual HTTP request', () async {
    final h = await slashFixture(allowModel: true);
    final actor = await h.card('Quiet bias whitespace');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.engine.setSettings({
      'power_user': {'user_prompt_bias': '{{getglobalvar::biasText}}'},
    });
    ScriptJson readMetadata() => h.inspect(
      (db) => scriptMap(
        jsonDecode(db.select('SELECT metadata FROM chats WHERE id = ?', [chat]).single['metadata'] as String),
      ),
    );
    final initialMetadata = readMetadata();
    expect(initialMetadata.containsKey('timedWorldInfo'), isFalse);
    expect(initialMetadata.containsKey('decoratorState'), isFalse);
    // The source macro is nonblank in every case. Admission must use its
    // first expanded value. ECMAScript retains NEL but trims FEFF and ASCII.
    const cases = <(String, String, bool, String)>[
      ('NEL', '\u0085', true, '\u0085ANSWER'),
      ('FEFF', '\ufeff', false, 'ANSWER'),
      ('ASCII whitespace', ' \t\r\n ', false, 'ANSWER'),
    ];
    for (final (index, entry) in cases.indexed) {
      await h.bridge.replaceVariables(context.id, scriptGlobal, {'biasText': entry.$2});
      final response = h.reply('ANSWER');
      final execution = await h.bridge.triggerSlash(context.id, '/gen Q');
      final wire = await slashSignal(execution, response.seen.future);
      expect(
        wire.body,
        scriptWire([
          if (entry.$3) {'role': 'assistant', 'content': entry.$2},
          {'role': 'system', 'content': 'Q'},
        ]),
        reason: entry.$1,
      );
      final result = await execution.result;
      expect(result.pipe, entry.$4, reason: entry.$1);
      // Quiet performs real WI preparation even with no entries. The first
      // request initializes its durable timer/decorator state; the later
      // requests reuse it. This adoption is independent of bias whitespace.
      expect(result.effects.committed, index == 0, reason: entry.$1);
      final adoptions = result.effects.entries
          .where(
            (effect) => effect.kind == TavernSlashEffectKind.storage && effect.state == TavernSlashEffectState.adopted,
          )
          .toList();
      if (index == 0) {
        expect(adoptions, hasLength(2), reason: entry.$1);
        expect(
          adoptions.map((effect) => effect.details['field']),
          unorderedEquals(['timedWorldInfo', 'decoratorState']),
          reason: entry.$1,
        );
        for (final effect in adoptions) {
          expect(effect.stage, TavernSlashEffectStage.preparation, reason: entry.$1);
          expect(effect.operation, 'generate', reason: entry.$1);
          expect(effect.target, {'kind': 'chatState', 'chatId': chat}, reason: entry.$1);
          expect(effect.details['carrier'], 'sql', reason: entry.$1);
          expect(effect.committed, isTrue, reason: entry.$1);
          expect(effect.version, allOf(isA<String>(), isNotEmpty), reason: entry.$1);
        }
      } else {
        expect(adoptions, isEmpty, reason: entry.$1);
      }
      final metadata = readMetadata();
      expect(metadata['timedWorldInfo'], {'sticky': {}, 'cooldown': {}}, reason: entry.$1);
      expect(metadata['decoratorState'], <String, Object?>{}, reason: entry.$1);
      expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'biasText': entry.$2}, reason: entry.$1);
      expect(scriptMap((await h.settingsDocument())['globalVariables']), {'biasText': entry.$2}, reason: entry.$1);
    }
    expect(await h.engine.path(chat), isEmpty);
    expect(generationNodes(h, chat), isEmpty);
    expect(h.requests, hasLength(3));
    expect(h.keyReads, 3);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('private quiet can select a real nonmember actor while public B2 keeps its membership rule', () async {
    final h = await slashFixture(allowModel: true);
    final member = await h.card('Member');
    final muted = await h.card('Muted');
    final outside = await h.card('Outside');
    final chat = await h.engine.createGroupChat([member, muted], hostCharacterId: member, addGreetings: false);
    await h.engine.updateGroupMember(chat, muted, muted: true);
    final context = await h.context(chat, characterId: member);
    expect(await h.engine.path(chat), isEmpty);

    final publicChild = await h.bridge.generate(context.id, TavernScriptGenerateRequest(speakerCharacterId: outside));
    final publicFailure = await generationFailure(publicChild);
    expect(publicFailure.code, TavernScriptErrorCode.noContext);
    expect(publicFailure.committed, isFalse);
    h.expectNoGeneration();

    final response = h.reply('Outside: ANSWER\nMuted: SHOULD_BE_TRIMMED');
    final script = await h.bridge.triggerSlash(context.id, '/gen name=Outside as=char Q');
    await slashSignal(script, response.seen.future);
    expect((await script.result).pipe, 'ANSWER');
    final group = (await h.engine.groupChat(chat))!;
    expect(group.members.map((item) => item.characterId), [member, muted]);
    expect(group.members.singleWhere((item) => item.characterId == muted).muted, isTrue);
    expect(await h.engine.path(chat), isEmpty);
    expect(generationNodes(h, chat), isEmpty);
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
  }, timeout: const Timeout(Duration(seconds: 15)));
}

ScriptJson _writeBack(String id, String pattern, String replacement, int placement) => {
  'id': id,
  'scriptName': 'B3 output stage',
  'findRegex': pattern,
  'replaceString': replacement,
  'trimStrings': <String>[],
  'placement': [placement],
  'disabled': false,
  'markdownOnly': false,
  'promptOnly': false,
  'runOnEdit': false,
  'substituteRegex': 0,
  'minDepth': null,
  'maxDepth': null,
};
