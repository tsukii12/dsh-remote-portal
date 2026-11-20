import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('import keeps exact source and unknown data without choosing a default', () async {
    final h = await _open();
    const text = '\uFEFF{\r\n  "temperature":0.3,"foreign":{"v":[1,"猫"]}}\r\n';
    final imported = await h.engine.importPreset(text, fileName: 'community.json');
    expect(imported.preset.sourceText, text);
    expect(imported.preset.name, 'community');
    expect((await h.engine.presetSelection()).effectivePresetId, isNull);
    final copy = imported.preset.raw;
    (copy['foreign']! as Map<String, Object?>)['v'] = false;
    expect((await h.engine.preset(imported.preset.id))!.raw['foreign'], {
      'v': [1, '猫'],
    });
    await h.engine.updatePreset(imported.preset.id, {'top_p': 0.7});
    await h.reopen();
    final restored = (await h.engine.preset(imported.preset.id))!;
    expect(restored.sourceText, text);
    expect(restored.raw['foreign'], {
      'v': [1, '猫'],
    });
    expect(restored.raw['top_p'], 0.7);
  });

  test('failed validation reports item path and creates no record', () async {
    final h = await _open();
    await expectLater(
      h.engine.importPreset(
        jsonEncode({
          'prompts': [
            {'identifier': 'bad', 'role': 'tool', 'content': 'P'},
          ],
        }),
      ),
      throwsA(
        isA<TavernPresetImportError>().having(
          (e) => e.issues.any((i) => i.path == r'$.prompts[0].role' && i.identifier == 'bad'),
          'item',
          isTrue,
        ),
      ),
    );
    expect(await h.engine.listPresets(), isEmpty);
  });

  test('watch emits summaries for import edit and delete', () async {
    final h = await _open();
    final iterator = StreamIterator(h.engine.watchPresets());
    addTearDown(iterator.cancel);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, isEmpty);
    final next = iterator.moveNext();
    final preset = await h.add('A', 0.2);
    expect(await next, isTrue);
    expect(iterator.current.single.id, preset.id);
    expect(iterator.current.single, isNot(isA<TavernPreset>()));
    final edited = iterator.moveNext();
    await h.engine.updatePreset(preset.id, {}, name: 'renamed');
    expect(await edited, isTrue);
    expect(iterator.current.single.name, 'renamed');
    final deleted = iterator.moveNext();
    await h.engine.deletePreset(preset.id);
    expect(await deleted, isTrue);
    expect(iterator.current, isEmpty);
  });

  test('chat binding overrides default and null binding restores inheritance', () async {
    final h = await _open();
    final a = await h.add('A', 0.2);
    final b = await h.add('B', 0.8);
    final first = await h.chat();
    final second = await h.chat();
    await h.engine.setDefaultPreset(a.id);
    await h.engine.bindPreset(first, b.id);
    expect((await h.request(first))['temperature'], 0.8);
    expect((await h.request(second))['temperature'], 0.2);
    await h.engine.setSettings({'preset': null, 'kept': 9}, chatId: first);
    await h.engine.bindPreset(first, null);
    expect((await h.engine.presetSelection(chatId: first)).source, PresetSelectionSource.globalDefault);
    expect((await h.engine.readSettings(chatId: first))['kept'], 9);
    expect((await h.request(first))['temperature'], 0.2);
    await h.reopen();
    expect((await h.engine.presetSelection(chatId: first)).effectivePresetId, a.id);
  });
  test('sampling overrides apply after selection and leave stored raw intact', () async {
    final h = await _open();
    final preset = await h.add('A', 0.2, {'foreign': 'saved'});
    final chat = await h.chat();
    await h.engine.setDefaultPreset(preset.id);
    await h.engine.setSettings({
      'presetOverrides': {'temperature': 0.4, 'top_p': 0.8},
    });
    await h.engine.setSettings({
      'presetOverrides': {
        'temperature': 0.9,
        'openai_max_tokens': '77',
        'openai_max_context': '2048',
        'foreign': 'ignored',
      },
    }, chatId: chat);
    final chosen = _chosen(await h.engine.readSettings(chatId: chat));
    expect(chosen['temperature'], 0.9);
    expect(chosen['foreign'], 'saved');
    final request = await h.request(chat);
    expect(request['temperature'], 0.9);
    expect(request['top_p'], 0.8);
    expect(request['max_tokens'], '77');
    expect((await h.engine.preset(preset.id))!.raw['temperature'], 0.2);
    await h.reopen();
    expect(_chosen(await h.engine.readSettings(chatId: chat))['temperature'], 0.9);
  });

  test('legacy chat patch never merges an inherited global record', () async {
    final h = await _open();
    final global = await h.add('Global', 0.2, {'foreign': 'global', 'main_prompt': 'GLOBAL'});
    await h.engine.setDefaultPreset(global.id);
    final chat = await h.chat();
    await h.engine.setSettings({
      'preset': {'temperature': 0.6},
    }, chatId: chat);
    expect(_chosen(await h.engine.readSettings(chatId: chat)), {'temperature': 0.6});
    expect((await h.request(chat))['temperature'], 0.6);
    await h.reopen();
    expect(_chosen(await h.engine.readSettings(chatId: chat)), {'temperature': 0.6});
  });

  for (final scoped in [false, true]) {
    test('legacy patch merges explicit ${scoped ? 'chat' : 'global'} record', () async {
      final h = await _open();
      final preset = await h.add('A', 0.2, {
        'nested': {'keep': 1, 'change': 2},
      });
      final chat = await h.chat();
      if (scoped) {
        await h.engine.bindPreset(chat, preset.id);
      } else {
        await h.engine.setDefaultPreset(preset.id);
      }
      await h.engine.setSettings({
        'preset': {
          'nested': {'change': 3},
          'temperature': 0.7,
        },
        'other': 8,
      }, chatId: scoped ? chat : null);
      final settings = await h.engine.readSettings(chatId: scoped ? chat : null);
      expect(_chosen(settings)['nested'], {'keep': 1, 'change': 3});
      expect(settings['other'], 8);
      expect((await h.request(chat))['temperature'], 0.7);
      expect((await h.engine.preset(preset.id))!.raw['temperature'], 0.2);
      await h.reopen();
      expect(_chosen(await h.engine.readSettings(chatId: scoped ? chat : null))['temperature'], 0.7);
    });
  }
  for (final scoped in [false, true]) {
    test('setPreset replaces explicit ${scoped ? 'chat' : 'global'} selection', () async {
      final h = await _open();
      final old = await h.add('A', 0.2, {'foreign': 'old'});
      final chat = await h.chat();
      if (scoped) {
        await h.engine.bindPreset(chat, old.id);
      } else {
        await h.engine.setDefaultPreset(old.id);
      }
      await h.engine.setPreset(ChatPreset({'temperature': 0.55}), chatId: scoped ? chat : null);
      expect(_chosen(await h.engine.readSettings(chatId: chat)), {'temperature': 0.55});
      expect((await h.request(chat))['temperature'], 0.55);
    });
  }

  for (final scoped in [false, true]) {
    test('explicit null in ${scoped ? 'chat' : 'global'} settings remains a tombstone', () async {
      final h = await _open();
      final preset = await h.add('A', 0.2);
      final chat = await h.chat();
      await h.engine.setDefaultPreset(preset.id);
      if (scoped) await h.engine.bindPreset(chat, preset.id);
      await h.engine.setSettings({'preset': null}, chatId: scoped ? chat : null);
      expect((await h.engine.presetSelection(chatId: chat)).effectivePresetId, isNull);
      final value = (await h.engine.readSettings(chatId: scoped ? chat : null))['preset'];
      expect(value, scoped ? isEmpty : isNull);
      expect((await h.request(chat))['temperature'], 1);
      await h.reopen();
      expect((await h.engine.presetSelection(chatId: chat)).effectivePresetId, isNull);
      expect((await h.request(chat))['temperature'], 1);
    });
  }

  test('queued edits take fresh records and snapshot caller maps', () async {
    final h = await _open();
    final preset = await h.add('A', 0.2, {
      'nested': {'keep': 1},
    });
    final patch = <String, Object?>{
      'nested': {'first': 2},
    };
    final first = h.engine.updatePreset(preset.id, patch);
    (patch['nested']! as Map<String, Object?>)['first'] = 999;
    final second = h.engine.updatePreset(preset.id, {
      'nested': {'second': 3},
    });
    await Future.wait([first, second]);
    expect((await h.engine.preset(preset.id))!.raw['nested'], {'keep': 1, 'first': 2, 'second': 3});
  });
  test('prompt helpers preserve entry fields and unrelated order groups', () async {
    final h = await _open();
    final preset = await h.add('A', 0.2, {
      'prompts': [
        {
          'identifier': 'a',
          'role': 'system',
          'content': 'A',
          'foreign': {'keep': 1},
        },
        {'identifier': 'b', 'role': 'assistant', 'content': 'B'},
      ],
      'prompt_order': [
        {
          'character_id': 9,
          'foreignGroup': 5,
          'order': [
            {'identifier': 'a', 'enabled': false},
          ],
        },
        {
          'character_id': 100001,
          'foreignGroup': 7,
          'order': [
            {'identifier': 'a', 'enabled': false, 'foreignEntry': 3},
            {'identifier': 'b', 'enabled': true},
          ],
        },
      ],
    });
    await h.engine.updatePresetPrompt(preset.id, 'a', {
      'content': 'EDIT',
      'foreign': {'new': 2},
    });
    await h.engine.setPresetOrder(preset.id, ['b', 'a']);
    await h.engine.setPresetPromptEnabled(preset.id, 'a', true);
    final raw = (await h.engine.preset(preset.id))!.raw;
    final prompts = raw['prompts']! as List<Object?>;
    expect((prompts.first! as Map<String, Object?>)['foreign'], {'keep': 1, 'new': 2});
    expect((prompts.first! as Map<String, Object?>)['content'], 'EDIT');
    final groups = raw['prompt_order']! as List<Object?>;
    expect(groups.first, {
      'character_id': 9,
      'foreignGroup': 5,
      'order': [
        {'identifier': 'a', 'enabled': false},
      ],
    });
    expect((groups.last! as Map<String, Object?>)['order'], [
      {'identifier': 'b', 'enabled': true},
      {'identifier': 'a', 'enabled': true, 'foreignEntry': 3},
    ]);
    await expectLater(h.engine.setPresetOrder(preset.id, ['a', 'a']), throwsArgumentError);
    await expectLater(h.engine.setPresetPromptEnabled(preset.id, 'unknown', true), throwsArgumentError);
    await expectLater(h.engine.updatePresetPrompt(preset.id, 'a', {'identifier': 'renamed'}), throwsArgumentError);
    expect((await h.engine.preset(preset.id))!.raw, raw);
  });

  test('editing legacy main content removes its shadowing legacy key', () async {
    final h = await _open();
    final preset = await h.add('A', 0.2, {'main_prompt': 'OLD', 'unknown': 'kept'});
    await h.engine.updatePresetPrompt(preset.id, 'main', {'content': 'NEW'});
    final edited = (await h.engine.preset(preset.id))!;
    expect(edited.raw.containsKey('main_prompt'), isFalse);
    expect(edited.raw['unknown'], 'kept');
    expect(edited.sourceText, contains('OLD'));
    await h.engine.setDefaultPreset(preset.id);
    final request = jsonEncode(await h.request(await h.chat()));
    expect(request, contains('NEW'));
    expect(request, isNot(contains('OLD')));
  });

  test('legacy tolerant records export without imposing new import validation', () async {
    final h = await _open();
    final raw = {
      'prompts': [
        {'identifier': 'odd', 'role': 7, 'content': false},
      ],
      'foreign': [1, null],
      'extensions': {
        'dshgo': {'presetEnvelope': 'legacy-opaque'},
      },
    };
    await h.engine.setPreset(ChatPreset(raw));
    final id = (await h.engine.presetSelection()).effectivePresetId!;
    expect(jsonDecode(await h.engine.exportPreset(id)), raw);
    await expectLater(h.engine.importPreset(jsonEncode(raw)), throwsA(isA<TavernPresetImportError>()));
  });
  test('invalid bind leaves a running turn intact', () async {
    final h = await _open();
    final chat = await h.chat();
    final started = h.model.holdNext();
    final running = h.engine.send(chat, 'Q').toList();
    await started;
    await expectLater(h.engine.bindPreset(chat, 'missing'), throwsStateError);
    h.model.release();
    expect((await running).whereType<TavernTurnDone>(), hasLength(1));
  });

  test('binding a different preset cancels and awaits the active turn', () async {
    final h = await _open();
    final preset = await h.add('A', 0.4);
    final chat = await h.chat();
    final started = h.model.holdNext();
    final running = h.engine.send(chat, 'Q').toList();
    await started;
    await h.engine.bindPreset(chat, preset.id);
    expect((await running).whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    expect((await h.request(chat))['temperature'], 0.4);
  });

  test('deleting a former default cancels turns that captured it before a switch', () async {
    final h = await _open();
    final a = await h.add('A', 0.2);
    final b = await h.add('B', 0.8);
    await h.engine.setDefaultPreset(a.id);
    final chat = await h.chat();
    final started = h.model.holdNext();
    final running = h.engine.send(chat, 'Q').toList();
    await started;
    await h.engine.setDefaultPreset(b.id);
    await h.engine.deletePreset(a.id);
    expect((await running).whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    expect((await h.engine.presetSelection(chatId: chat)).effectivePresetId, b.id);
    expect((await h.request(chat))['temperature'], 0.8);
  });

  test('editing a library record keeps the admitted request snapshot', () async {
    final h = await _open();
    final preset = await h.add('A', 0.2);
    await h.engine.setDefaultPreset(preset.id);
    final chat = await h.chat();
    final started = h.model.holdNext();
    final running = h.engine.send(chat, 'Q').toList();
    await started;
    await h.engine.updatePreset(preset.id, {'temperature': 0.9});
    h.model.release();
    expect((await running).whereType<TavernTurnDone>(), hasLength(1));
    expect(h.model.bodies.first['temperature'], 0.2);
    expect((await h.request(chat))['temperature'], 0.9);
  });

  test('global legacy bridge blocks new admission during its file commit', () async {
    final h = await _open();
    final chat = await h.chat();
    final writing = h.engine.setSettings({
      'preset': {'temperature': 0.3},
      'other': 'new',
    });
    // The preset queue starts in the first microtask; the file queue and real
    // filesystem are still pending. No timing sleeps or platform hooks.
    await Future<void>.value();
    final blocked = await h.engine.send(chat, 'must not start').toList();
    expect(blocked.whereType<TavernTurnFailed>().single.kind, TavernFailure.busy);
    expect(h.model.bodies, isEmpty);
    await writing;
    expect((await h.request(chat))['temperature'], 0.3);
  });
  for (final replacement in <Object?>[
    {'temperature': 0.9},
    null,
  ]) {
    test('global SQL failure keeps prior selection after file commit: $replacement', () async {
      final h = await _open();
      final preset = await h.add('A', 0.2);
      await h.engine.setDefaultPreset(preset.id);
      final chat = await h.chat();
      h.sql(
        "CREATE TRIGGER reject_default BEFORE UPDATE ON preset_preferences BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      await expectLater(
        h.engine.setSettings({'preset': replacement, 'other': 'persisted'}),
        throwsA(isA<SqliteException>()),
      );
      expect((await h.engine.presetSelection()).effectivePresetId, preset.id);
      expect(await h.engine.listPresets(), hasLength(1));
      expect((await h.engine.readSettings())['other'], 'persisted');
      final file = jsonDecode(await File('${h.directory.path}/settings.json').readAsString()) as Map<String, Object?>;
      expect((file['settings']! as Map<String, Object?>)['preset'], replacement == null ? null : _raw(0.9));
      expect((await h.request(chat))['temperature'], 0.2);
      h.sql('DROP TRIGGER reject_default');
      await h.reopen();
      expect((await h.engine.readSettings())['other'], 'persisted');
      expect((await h.engine.presetSelection()).effectivePresetId, preset.id);
      expect((await h.request(chat))['temperature'], 0.2);
    });
  }

  test('global file failure never commits the SQL bridge', () async {
    final h = await _open();
    final preset = await h.add('A', 0.2);
    await h.engine.setDefaultPreset(preset.id);
    final chat = await h.chat();
    final blocker = Directory('${h.directory.path}/settings.json.writing');
    await blocker.create();
    await expectLater(
      h.engine.setSettings({
        'preset': {'temperature': 0.9},
      }),
      throwsA(isA<FileSystemException>()),
    );
    expect((await h.engine.presetSelection()).effectivePresetId, preset.id);
    expect(await h.engine.listPresets(), hasLength(1));
    await blocker.delete();
    await h.reopen();
    expect((await h.request(chat))['temperature'], 0.2);
  });

  test('chat bridge SQL failure rolls back settings record and binding together', () async {
    final h = await _open();
    final preset = await h.add('A', 0.2);
    final chat = await h.chat();
    await h.engine.bindPreset(chat, preset.id);
    await h.engine.setSettings({'other': 'old'}, chatId: chat);
    h.sql(
      "CREATE TRIGGER reject_binding BEFORE UPDATE OF preset_id ON chats WHEN NEW.preset_id IS NOT OLD.preset_id BEGIN SELECT RAISE(ABORT,'fixture'); END",
    );
    await expectLater(
      h.engine.setSettings({
        'preset': {'temperature': 0.9},
        'other': 'new',
      }, chatId: chat),
      throwsA(isA<SqliteException>()),
    );
    expect((await h.engine.presetSelection(chatId: chat)).effectivePresetId, preset.id);
    expect((await h.engine.readSettings(chatId: chat))['other'], 'old');
    expect(await h.engine.listPresets(), hasLength(1));
    h.sql('DROP TRIGGER reject_binding');
    await h.reopen();
    expect((await h.engine.readSettings(chatId: chat))['other'], 'old');
    expect((await h.request(chat))['temperature'], 0.2);
  });
  for (final scoped in [false, true]) {
    test('legacy ${scoped ? 'chat' : 'global'} map bridge retains the complete package shell', () async {
      final h = await _open();
      final source = jsonEncode(_wrapper(_raw(0.2)));
      final original = (await h.engine.importPreset(source)).preset;
      final chat = await h.chat();
      if (scoped) {
        await h.engine.bindPreset(chat, original.id);
      } else {
        await h.engine.setDefaultPreset(original.id);
      }
      await h.engine.setSettings({
        'preset': {'temperature': 0.7},
      }, chatId: scoped ? chat : null);
      final id = (await h.engine.presetSelection(chatId: chat)).effectivePresetId!;
      expect(id, isNot(original.id));
      final derived = (await h.engine.preset(id))!;
      expect(derived.name, original.name);
      expect(derived.envelope!['outerUnknown'], {
        'keep': [1, 2],
      });
      expect(derived.envelope!['tools'], {
        'version': 99,
        'future': [true, null],
      });
      final envelopePreset = derived.envelope!['preset']! as Map<String, Object?>;
      expect(envelopePreset['wrapperUnknown'], 3);
      expect((envelopePreset['data']! as Map<String, Object?>)['temperature'], 0.7);
      final roundtrip = (await h.engine.importPreset(await h.engine.exportPreset(id))).preset;
      expect(roundtrip.envelope!['outerUnknown'], {
        'keep': [1, 2],
      });
      expect(roundtrip.raw['temperature'], 0.7);
      expect((await h.engine.preset(original.id))!.sourceText, source);
    });
  }

  test('renaming a package updates its preserved name for native export roundtrip', () async {
    final h = await _open();
    final original = (await h.engine.importPreset(jsonEncode(_wrapper(_raw(0.2))))).preset;
    await h.engine.updatePreset(original.id, {}, name: 'Renamed');
    final imported = (await h.engine.importPreset(await h.engine.exportPreset(original.id))).preset;
    expect(imported.name, 'Renamed');
    expect((imported.envelope!['metadata']! as Map<String, Object?>)['unknown'], 7);
  });
  test('delete clears native library bindings and default across reopen', () async {
    final h = await _open();
    final preset = await h.add('A', 0.2);
    final bound = await h.chat();
    final inherited = await h.chat();
    await h.engine.setDefaultPreset(preset.id);
    await h.engine.bindPreset(bound, preset.id);
    await h.engine.deletePreset(preset.id);
    expect(await h.engine.preset(preset.id), isNull);
    for (final chat in [bound, inherited]) {
      final selection = await h.engine.presetSelection(chatId: chat);
      expect(selection.boundPresetId, isNull);
      expect(selection.defaultPresetId, isNull);
      expect((await h.request(chat))['temperature'], 1);
    }
    await h.reopen();
    expect(await h.engine.listPresets(), isEmpty);
  });

  test('delete preserves legacy inline fallback as a separate configuration', () async {
    final h = await _open();
    await h.engine.setPreset(ChatPreset({'temperature': 0.35, 'main_prompt': 'LEGACY'}));
    final chat = await h.chat();
    final id = (await h.engine.presetSelection()).effectivePresetId!;
    await h.engine.deletePreset(id);
    expect((await h.engine.presetSelection()).source, PresetSelectionSource.globalInline);
    expect((await h.request(chat))['temperature'], 0.35);
    expect(jsonEncode(h.model.bodies.last), contains('LEGACY'));
    await h.reopen();
    expect((await h.request(chat))['temperature'], 0.35);
  });

  test('dangling legacy binding is diagnosed and falls through without rewrite', () async {
    final h = await _open();
    final preset = await h.add('A', 0.2);
    await h.engine.setDefaultPreset(preset.id);
    final chat = await h.chat();
    h.sql('UPDATE chats SET preset_id = ? WHERE id = ?', ['gone', chat]);
    final selection = await h.engine.presetSelection(chatId: chat);
    expect(selection.boundPresetId, 'gone');
    expect(selection.missingPresetIds, ['gone']);
    expect(selection.effectivePresetId, preset.id);
    expect((await h.request(chat))['temperature'], 0.2);
    expect((await h.engine.presetSelection(chatId: chat)).boundPresetId, 'gone');
    await h.engine.deletePreset('gone');
    expect((await h.engine.presetSelection(chatId: chat)).boundPresetId, isNull);
  });

  test('preserved connection fields never select the model endpoint', () async {
    final h = await _open();
    final preset = await h.add('A', 0.2, {
      'custom_url': 'https://untrusted.invalid',
      'reverse_proxy': 'https://other.invalid',
      'proxy_password': 'fixture-not-a-real-key',
      'deepseek_model': 'different',
    });
    await h.engine.setDefaultPreset(preset.id);
    final body = await h.request(await h.chat());
    expect(h.model.urls.single, 'https://configured.invalid');
    expect(body['model'], 'deepseek-flash');
    expect(jsonEncode(body), isNot(contains('fixture-not-a-real-key')));
    expect((await h.engine.preset(preset.id))!.raw['proxy_password'], 'fixture-not-a-real-key');
  });
  test('selected reasoning prefill expands once and stays out of stored output', () async {
    final h = await _open();
    h.engine.configure(TavernModelConfig(apiKey: () async => 'fixture-key', thinking: true));
    final wrapper = _wrapper(
      _raw(0.2, {'dsh_prefill_target': 'reasoning', 'assistant_prefill': '{{incvar::prefillCount}}PREFIX'}),
    );
    (wrapper['prefill']! as Map<String, Object?>)['enabled'] = true;
    final preset = (await h.engine.importPreset(jsonEncode(wrapper))).preset;
    await h.engine.setDefaultPreset(preset.id);
    final chat = await h.chat();
    expect(h.engine.variables(chat).containsKey('prefillCount'), isFalse);
    final body = await h.request(chat);
    final last = (body['messages']! as List<Object?>).last! as Map<String, Object?>;
    expect(last['prefix'], isTrue);
    expect(last['reasoning_content'], '1PREFIX');
    expect(last['content'], '');
    expect(h.engine.variables(chat)['prefillCount'], 1);
    expect((await h.engine.path(chat)).last.text, 'OK');
    expect((await h.engine.path(chat)).last.reasoning, isNull);
    expect((await h.engine.inspectTurn(chat))!.prompt!.afterPostProcessing.last.tokens, greaterThan(0));
    await h.reopen();
    expect(h.engine.variables(chat)['prefillCount'], 1);
    expect((await h.engine.path(chat)).last.text, 'OK');
  });

  test('continue keeps original content without evaluating enhanced prefill', () async {
    final h = await _open();
    h.engine.configure(TavernModelConfig(apiKey: () async => 'fixture-key', thinking: true));
    final wrapper = _wrapper(
      _raw(0.2, {
        'continue_prefill': true,
        'dsh_prefill_target': 'reasoning',
        'assistant_prefill': '{{incvar::shouldNotRun}}NEW',
      }),
    );
    (wrapper['prefill']! as Map<String, Object?>)['enabled'] = true;
    final preset = (await h.engine.importPreset(jsonEncode(wrapper))).preset;
    await h.engine.setDefaultPreset(preset.id);
    final chat = await h.chat();
    final greeting = (await h.engine.path(chat)).single;
    final events = await h.engine.continueReply(chat, greeting.nodeId).toList();
    expect(events.whereType<TavernTurnDone>(), hasLength(1));
    final last = (h.model.bodies.single['messages']! as List<Object?>).last! as Map<String, Object?>;
    expect(last['content'], 'G');
    expect(last.containsKey('reasoning_content'), isFalse);
    expect(h.engine.variables(chat).containsKey('shouldNotRun'), isFalse);
    expect((await h.engine.inspectTurn(chat))!.prompt!.excluded.any((e) => e.reason.contains('continue')), isTrue);
  });
  test('export-owned carrier cannot be silently changed by new or bridged edits', () async {
    final h = await _open();
    final original = (await h.engine.importPreset(jsonEncode(_wrapper(_raw(0.2))))).preset;
    final imported = (await h.engine.importPreset(await h.engine.exportPreset(original.id))).preset;
    await h.engine.setDefaultPreset(imported.id);
    await h.engine.updatePreset(imported.id, imported.raw);
    final patch = <String, Object?>{
      'extensions': {
        'dshgo': {
          'presetEnvelope': {
            'outerUnknown': {'changed': 4},
          },
        },
      },
    };
    await expectLater(h.engine.updatePreset(imported.id, patch), throwsArgumentError);
    await expectLater(h.engine.setSettings({'preset': patch}), throwsArgumentError);
    await expectLater(h.engine.updatePreset(imported.id, {'extensions': null}), throwsArgumentError);
    expect((await h.engine.preset(imported.id))!.raw, imported.raw);
    expect((await h.engine.presetSelection()).effectivePresetId, imported.id);
    expect(await h.engine.listPresets(), hasLength(2));
  });
}

Map<String, Object?> _wrapper(Map<String, Object?> raw) => {
  'format': 'dsh-preset-enhance',
  'version': 1,
  'metadata': {'name': 'Package', 'unknown': 7},
  'preset': {'format': 'sillytavern', 'data': raw, 'wrapperUnknown': 3},
  'prefill': {
    'enabled': false,
    'toolCalls': true,
    'removeNonOfficialTools': false,
    'postToolPrefix': {'mode': 'inherit', 'text': ''},
    'foreign': 8,
  },
  'tools': {
    'version': 99,
    'future': [true, null],
  },
  'outerUnknown': {
    'keep': [1, 2],
  },
};

Future<_Harness> _open() async {
  final directory = await Directory.systemTemp.createTemp('dsh-t20-engine-');
  final h = _Harness(directory);
  await h.open();
  addTearDown(() async {
    await h.engine.close();
    await directory.delete(recursive: true);
  });
  return h;
}

class _Harness {
  _Harness(this.directory);
  final Directory directory;
  final model = _Model();
  late TavernEngine engine;
  Future<void> open() async {
    engine = await TavernEngine.openDirectory(
      directory,
      modelClient: model,
      config: TavernModelConfig(apiKey: () async => 'fixture-key', baseUrl: 'https://configured.invalid'),
      clock: () => DateTime.utc(2026, 11, 10),
      random: () => 0.25,
    );
  }

  Future<void> reopen() async {
    await engine.close();
    await open();
  }

  Future<String> chat() async {
    final card = await engine.importCard(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'spec': 'chara_card_v3',
            'spec_version': '3.0',
            'data': {
              'name': 'Guide',
              'description': '',
              'personality': '',
              'scenario': '',
              'first_mes': 'G',
              'mes_example': '',
              'creator_notes': '',
              'system_prompt': '',
              'post_history_instructions': '',
              'alternate_greetings': <String>[],
              'tags': <String>[],
              'creator': '',
              'character_version': '',
              'extensions': <String, Object?>{},
            },
          }),
        ),
      ),
    );
    return engine.createChat(card.id);
  }

  Future<TavernPreset> add(String name, double temperature, [Map<String, Object?> fields = const {}]) async =>
      (await engine.importPreset(jsonEncode(_raw(temperature, fields)), fileName: '$name.json')).preset;
  void sql(String statement, [List<Object?> parameters = const []]) {
    final db = sqlite3.open('${directory.path}/tavern.sqlite3');
    try {
      db.execute(statement, parameters);
    } finally {
      db.close();
    }
  }

  Future<Map<String, Object?>> request(String chat) async {
    final events = await engine.send(chat, 'Q').toList();
    expect(events.whereType<TavernTurnDone>(), hasLength(1));
    return model.bodies.last;
  }
}

Map<String, Object?> _raw(double temperature, [Map<String, Object?> fields = const {}]) => {
  'temperature': temperature,
  'stream_openai': true,
  'openai_max_context': 4095,
  'openai_max_tokens': 64,
  ...fields,
};

Map<String, Object?> _chosen(Map<String, Object?> settings) => settings['preset']! as Map<String, Object?>;

class _Model extends TavernModelClient {
  final bodies = <Map<String, Object?>>[];
  final urls = <String>[];
  Completer<void>? _hold;
  Completer<void>? _started;
  Future<void> holdNext() {
    _hold = Completer<void>();
    _started = Completer<void>();
    return _started!.future;
  }

  void release() {
    if (_hold != null && !_hold!.isCompleted) _hold!.complete();
  }

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) async* {
    bodies.add(jsonDecode(jsonEncode(body)) as Map<String, Object?>);
    urls.add(config.baseUrl);
    final held = _hold;
    if (held != null && !held.isCompleted) {
      _started?.complete();
      yield const ModelText('part');
      try {
        await cancellation.wait(held.future);
      } finally {
        _hold = null;
      }
    }
    yield const ModelText('OK');
    yield const ModelFinished('stop');
  }
}
