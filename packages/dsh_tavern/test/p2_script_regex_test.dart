import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

void main() {
  test('regex query preserves four source identities and source switches without deduplicating ST ids', () async {
    final h = await generationFixture(allowModel: false);
    await h.engine.setSettings({
      'globalRegexScripts': [_rule('/A/g', 'B')],
    });
    final managed = (await h.engine.importRegexScripts(jsonEncode(_rule('/B/g', 'C')))).scripts.single;
    final presetRaw = scriptPreset().raw;
    presetRaw['extensions'] = {
      'regex_scripts': [_rule('/C/g', 'D')],
    };
    final preset = (await h.engine.importPreset(jsonEncode(presetRaw))).preset.id;
    final character = await h.card(
      'Regex sources',
      extensions: {
        'regex_scripts': [_rule('/D/g', 'E')],
      },
    );
    final chat = await h.emptyChat(character);
    await h.engine.bindPreset(chat, preset);
    final context = await h.context(chat, characterId: character);
    final all = await h.bridge.getTavernRegexes(context.id, TavernScriptRegexQuery());
    expect(all, hasLength(4));
    expect(all.map((rule) => rule.stId), everyElement('same-st-id'));
    expect(all.map((rule) => rule.sourceRef['kind']), ['inlineGlobal', 'managedGlobal', 'preset', 'character']);
    expect(all.map((rule) => rule.source), [
      TavernScriptRegexSource.global,
      TavernScriptRegexSource.global,
      TavernScriptRegexSource.preset,
      TavernScriptRegexSource.character,
    ]);
    expect(all.map((rule) => rule.engineId), [null, managed.id, null, null]);
    expect(all.every((rule) => rule.enabled && rule.effective), isTrue);
    all.first.raw['replaceString'] = 'MUTATED COPY';
    all.first.sourceRef['kind'] = 'MUTATED COPY';
    final again = await h.bridge.getTavernRegexes(context.id, TavernScriptRegexQuery());
    expect(again.first.raw['replaceString'], 'B');
    expect(again.first.sourceRef['kind'], 'inlineGlobal');
    for (final phase in [RegexPhase.prompt, RegexPhase.display]) {
      final result = await h.bridge.formatAsTavernRegexedString(
        context.id,
        'A',
        source: RegexPlacement.aiOutput,
        destination: phase,
      );
      expect(result.text, 'E');
      expect(result.replacements, 4);
      expect(result.warnings, isEmpty);
    }
    await h.engine.setSettings({'presetRegexEnabled': false, 'characterRegexEnabled': false}, chatId: chat);
    final disabledSources = await h.bridge.getTavernRegexes(context.id, TavernScriptRegexQuery());
    expect(disabledSources.every((rule) => rule.enabled), isTrue);
    expect(disabledSources.map((rule) => rule.effective), [true, true, false, false]);
    expect(await h.bridge.getTavernRegexes(context.id, TavernScriptRegexQuery(effectiveOnly: true)), hasLength(2));
    final otherRaw = scriptPreset().raw;
    otherRaw['extensions'] = {
      'regex_scripts': [_rule('/C/g', 'OTHER')],
    };
    final other = (await h.engine.importPreset(jsonEncode(otherRaw))).preset.id;
    final explicit = await h.bridge.getTavernRegexes(
      context.id,
      TavernScriptRegexQuery(sources: {TavernScriptRegexSource.preset}, presetId: other),
    );
    expect(explicit.single.raw['replaceString'], 'OTHER');
    final stillBound = await h.bridge.getTavernRegexes(
      context.id,
      TavernScriptRegexQuery(sources: {TavernScriptRegexSource.preset}),
    );
    expect(stillBound.single.raw['replaceString'], 'D');
    expect(stillBound.single.sourceRef['resourceId'], preset);
    h.expectNoGeneration();
    stdout.writeln('P2_B2_REGEX_READY');
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('both formatter phases isolate local global hash and random effects from runtime and disk', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Detached regex', greeting: 'A');
    final chat = await h.engine.createChat(character);
    final node = (await h.engine.path(chat)).single.nodeId;
    final context = await h.context(chat, characterId: character, nodeId: node);
    final local = await h.bridge.replaceVariables(context.id, scriptChat, {'local': 0});
    final global = await h.bridge.replaceVariables(context.id, scriptGlobal, {'global': 0});
    await h.engine.setSettings({
      'globalRegexScripts': [
        _rule('/A/g', '{{incvar::local}}/{{incglobalvar::global}}/{{pick::x::y}}/{{random::r::s}}'),
      ],
    });
    final nodesBefore = generationNodes(h, chat);
    final metadataBefore = h.inspect(
      (db) => db.select('SELECT metadata FROM chats WHERE id = ?', [chat]).single['metadata'],
    );
    final settingsBefore = await File('${h.root.path}/settings.json').readAsBytes();
    var mainRandomCalls = 0;
    h.onRandom = () {
      mainRandomCalls++;
    };
    for (final phase in [RegexPhase.prompt, RegexPhase.display]) {
      final first = await h.bridge.formatAsTavernRegexedString(
        context.id,
        'A',
        source: RegexPlacement.aiOutput,
        destination: phase,
      );
      final second = await h.bridge.formatAsTavernRegexedString(
        context.id,
        'A',
        source: RegexPlacement.aiOutput,
        destination: phase,
      );
      expect(first.text, startsWith('1/1/'));
      expect(second.text, first.text);
      expect(first.replacements, 1);
      expect(first.warnings, isEmpty);
      expect(first.superseded, isFalse);
    }
    expect(mainRandomCalls, 0);
    final localAfter = await h.bridge.getVariables(context.id, scriptChat);
    final globalAfter = await h.bridge.getVariables(context.id, scriptGlobal);
    expect(localAfter.value, local.value);
    expect(localAfter.version, local.version);
    expect(globalAfter.value, global.value);
    expect(globalAfter.version, global.version);
    expect(generationNodes(h, chat), nodesBefore);
    expect(
      h.inspect((db) => db.select('SELECT metadata FROM chats WHERE id = ?', [chat]).single['metadata']),
      metadataBefore,
    );
    expect(await File('${h.root.path}/settings.json').readAsBytes(), settingsBefore);
    await h.reopen();
    final fresh = await h.context(chat, characterId: character, nodeId: node);
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value, local.value);
    expect((await h.bridge.getVariables(fresh.id, scriptGlobal)).value, global.value);
    expect(generationNodes(h, chat), nodesBefore);
    expect(
      h.inspect((db) => db.select('SELECT metadata FROM chats WHERE id = ?', [chat]).single['metadata']),
      metadataBefore,
    );
    h.expectNoGeneration();
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('undefined formatter depth is not zero and the public source and destination boundary is strict', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Depth');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.engine.setSettings({
      'globalRegexScripts': [
        _rule('/A/g', 'DEPTH', extra: {'minDepth': 7, 'maxDepth': 7}),
      ],
    });
    for (final phase in [RegexPhase.prompt, RegexPhase.display]) {
      expect(
        (await h.bridge.formatAsTavernRegexedString(
          context.id,
          'A',
          source: RegexPlacement.aiOutput,
          destination: phase,
        )).text,
        'DEPTH',
      );
      expect(
        (await h.bridge.formatAsTavernRegexedString(
          context.id,
          'A',
          source: RegexPlacement.aiOutput,
          destination: phase,
          depth: 0,
        )).text,
        'A',
      );
      expect(
        (await h.bridge.formatAsTavernRegexedString(
          context.id,
          'A',
          source: RegexPlacement.aiOutput,
          destination: phase,
          depth: 7,
        )).text,
        'DEPTH',
      );
      expect(
        (await h.bridge.formatAsTavernRegexedString(
          context.id,
          'A',
          source: RegexPlacement.userInput,
          destination: phase,
        )).text,
        'A',
      );
    }
    await expectLater(
      () => h.bridge.formatAsTavernRegexedString(context.id, 'A', source: 4, destination: RegexPhase.prompt),
      throwsA(scriptError(TavernScriptErrorCode.invalidArgument)),
    );
    await expectLater(
      () => h.bridge.formatAsTavernRegexedString(
        context.id,
        'A',
        source: RegexPlacement.aiOutput,
        destination: RegexPhase.writeBack,
      ),
      throwsA(scriptError(TavernScriptErrorCode.unsupportedOption)),
    );
    await expectLater(
      () => h.bridge.formatAsTavernRegexedString(
        context.id,
        'A',
        source: RegexPlacement.aiOutput,
        destination: RegexPhase.prompt,
        depth: double.infinity,
      ),
      throwsA(scriptError(TavernScriptErrorCode.invalidArgument)),
    );
    h.expectNoGeneration();
  });

  test('formatter diagnostics come from one execution and never preflight or repeat macro expansion', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Diagnostics');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.bridge.replaceVariables(context.id, scriptChat, {'pattern': 0, 'replacement': 0});
    await h.engine.setSettings({
      'globalRegexScripts': [
        _rule('/A/g', 'bad', extra: {'id': 'bad-shape', 'findRegex': 7}),
        _rule('/(/g', 'bad', extra: {'id': 'bad-pattern'}),
        _rule(
          '/{{incvar::pattern}}/g',
          r'{{incvar::replacement}}-$0',
          extra: {'id': 'single-pass', 'substituteRegex': 1},
        ),
      ],
    });
    final query = await h.bridge.getTavernRegexes(context.id, TavernScriptRegexQuery());
    expect(query.first.diagnostics.map((item) => item.code), contains('invalid-script'));
    for (final phase in [RegexPhase.prompt, RegexPhase.display]) {
      final result = await h.bridge.formatAsTavernRegexedString(
        context.id,
        '1 1',
        source: RegexPlacement.aiOutput,
        destination: phase,
      );
      expect(result.text, '1-1 2-1');
      expect(result.replacements, 2);
      expect(result.warnings.map((warning) => warning.ruleId), ['bad-shape', 'bad-pattern']);
      expect(result.warnings.first.reason, 'invalid-script');
      expect(result.warnings.last.reason, isNotEmpty);
      expect(result.warnings.map((warning) => warning.ruleIndex), [0, 1]);
      expect(result.superseded, isFalse);
    }
    expect((await h.bridge.getVariables(context.id, scriptChat)).value, {'pattern': 0, 'replacement': 0});
    h.expectNoGeneration();
  });
}

ScriptJson _rule(String pattern, String replacement, {ScriptJson extra = const {}}) => {
  'id': 'same-st-id',
  'scriptName': 'B2 rule',
  'findRegex': pattern,
  'replaceString': replacement,
  'trimStrings': <String>[],
  'placement': [RegexPlacement.aiOutput],
  'disabled': false,
  'markdownOnly': true,
  'promptOnly': true,
  'runOnEdit': false,
  'substituteRegex': 0,
  'minDepth': null,
  'maxDepth': null,
  ...extra,
};
