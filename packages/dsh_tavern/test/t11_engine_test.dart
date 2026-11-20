import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

// Reconstructed for tavern2 from the recorded contracts, not the lost wave-1
// 25-test source. Real facade/SQLite/files/macros/regex/assembly; only model
// deltas and clock/random inputs are synthetic. No external API is contacted.
void main() {
  test('global, preset and card regex compose on greeting, user and final reply', () async {
    final h = await _open();
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('global', r'^x$', 'g', [1, 2]),
      ],
    });
    await h.engine.setPreset(
      _preset(
        regex: [
          _script('preset', r'^g$', 'p', [1, 2]),
        ],
      ),
    );
    final chat = await h.chat({
      'first_mes': 'x',
      'extensions': {
        'regex_scripts': [
          _script('card', r'^p$', 'c', [1, 2]),
        ],
      },
    });
    expect((await h.engine.path(chat)).single.text, 'c');
    h.model.reply('x');
    final events = await h.engine.send(chat, 'x').toList();
    expect(events.whereType<TavernTextDelta>().map((event) => event.text).join(), 'x');
    expect(_done(events).text, 'c');
    expect((await h.engine.path(chat)).map((message) => message.text), ['c', 'c', 'c']);
    await h.reopen();
    expect((await h.engine.path(chat)).map((message) => message.text), ['c', 'c', 'c']);
  });

  test('legacy global regex settings alias remains executable', () async {
    final h = await _open();
    final chat = await h.chat();
    await h.engine.setSettings({
      'regex': [
        _script('alias', r'^x$', 'alias', [2]),
      ],
    });
    h.model.reply('x');
    expect(_done(await h.engine.send(chat, 'Q').toList()).text, 'alias');
  });

  for (final c in [
    (name: 'all regex', setting: 'regexEnabled', expected: 'x'),
    (name: 'preset regex', setting: 'presetRegexEnabled', expected: 'g'),
    (name: 'card regex', setting: 'characterRegexEnabled', expected: 'p'),
    (name: 'this card', setting: 'disabledCharacterRegex', expected: 'p'),
  ]) {
    test('disabling ${c.name} has the documented scope', () async {
      final h = await _open();
      final card = await h.engine.importCard(
        _card({
          'first_mes': 'x',
          'extensions': {
            'regex_scripts': [
              _script('card', r'^p$', 'c', [2]),
            ],
          },
        }),
      );
      await h.engine.setSettings({
        'globalRegexScripts': [
          _script('global', r'^x$', 'g', [2]),
        ],
        c.setting: c.setting == 'disabledCharacterRegex' ? [card.id] : false,
      });
      await h.engine.setPreset(
        _preset(
          regex: [
            _script('preset', r'^g$', 'p', [2]),
          ],
        ),
      );
      final chat = await h.engine.createChat(card.id);
      expect((await h.engine.path(chat)).single.text, c.expected);
      h.model.reply('x');
      expect(_done(await h.engine.send(chat, 'Q').toList()).text, c.expected);
    });
  }

  test('disabled and display-only scripts do not write back; dual-only scripts reach prompts', () async {
    final h = await _open();
    final chat = await h.chat();
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('disabled', r'^x$', 'DISABLED', [1, 2], disabled: true),
        _script('display', r'^x$', 'DISPLAY', [1, 2], markdownOnly: true),
        _script('dual', r'^x$', 'PROMPT', [1, 2], markdownOnly: true, promptOnly: true),
      ],
    });
    h.model.reply('x');
    expect(_done(await h.engine.send(chat, 'x').toList()).text, 'x');
    expect((await h.engine.path(chat))[1].text, 'x');
    expect(_requestText(h.model.bodies.single), contains('PROMPT'));
    expect(_requestText(h.model.bodies.single), isNot(contains('DISPLAY')));
  });

  test('edit runs only runOnEdit writeback and commits its macros', () async {
    final h = await _open();
    final chat = await h.chat();
    final original = (await h.engine.path(chat)).single;
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('not-edit', r'^x$', 'WRONG', [2]),
        _script('edit', r'^x$', '{{incvar::edits}}x', [2], runOnEdit: true),
        _script('prompt', r'^1x$', 'WRONG_PROMPT', [2], promptOnly: true, runOnEdit: true),
      ],
    });
    await h.engine.edit(chat, original.nodeId, 'x');
    expect((await h.engine.path(chat)).single.text, '1x');
    expect(h.engine.variables(chat)['edits'], 1);
    await h.reopen();
    expect((await h.engine.path(chat)).single.text, '1x');
    expect(h.engine.variables(chat)['edits'], 1);
  });

  test('prompt-only regex copies visible history and never evaluates hidden history', () async {
    final h = await _open();
    final chat = await h.importChat([_row('raw-visible', user: true), _row('raw-hidden', hidden: true)]);
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('prompt', '^raw', '{{incvar::seen}}P', [1, 2], promptOnly: true),
      ],
    });
    h.model.reply('OK');
    _done(await h.engine.send(chat, 'QUESTION').toList());
    expect(_requestText(h.model.bodies.single), contains('1P-visible'));
    expect(_requestText(h.model.bodies.single), isNot(contains('raw-hidden')));
    expect(h.engine.variables(chat)['seen'], 1);
    final path = await h.engine.path(chat);
    expect(path.first.text, 'raw-visible');
    expect(path[1].text, 'raw-hidden');
    expect(path[1].hidden, isTrue);
  });

  test('continue uses depth minus one while a later ordinary turn uses positive depth', () async {
    final h = await _open();
    final chat = await h.importChat([_row('U', user: true), _row('RAW')]);
    final reply = (await h.engine.path(chat)).last;
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('depth', '^RAW', 'PROMPT', [2], promptOnly: true, minDepth: 0),
      ],
    });
    h.model.reply('+');
    expect(_done(await h.engine.continueReply(chat, reply.nodeId).toList()).text, 'RAW+');
    expect(_requestText(h.model.bodies.single), contains('RAW'));
    expect(_requestText(h.model.bodies.single), isNot(contains('PROMPT')));
    h.model.reply('OK');
    _done(await h.engine.send(chat, 'NEXT').toList());
    expect(_requestText(h.model.bodies.last), contains('PROMPT+'));
    expect((await h.engine.path(chat)).firstWhere((message) => message.nodeId == reply.nodeId).text, 'RAW+');
  });

  test('maxDepth zero transforms only the latest prompt message', () async {
    final h = await _open();
    final chat = await h.importChat([_row('raw-old', user: true), _row('A')]);
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('latest', '^raw', 'P', [1], promptOnly: true, maxDepth: 0),
      ],
    });
    h.model.reply('OK');
    _done(await h.engine.send(chat, 'raw-new').toList());
    final request = _requestText(h.model.bodies.single);
    expect(request, contains('raw-old'));
    expect(request, contains('P-new'));
    expect(request, isNot(contains('P-old')));
    expect((await h.engine.path(chat))[2].text, 'raw-new');
  });

  test('world-info prompt regex runs after recursion and does not rescan transformed text', () async {
    final h = await _open();
    final chat = await h.chat({
      'character_book': {
        'name': 'probe-book',
        'entries': [_entry(1, 'beacon', 'raw-world'), _entry(2, 'recursion-key', 'UNEXPECTED')],
      },
    });
    await h.engine.setSettings({
      'worldInfo': {'world_info_recursive': true, 'world_info_budget': 100},
      'globalRegexScripts': [
        _script('world', r'^raw-world$', 'recursion-key', [5], promptOnly: true),
      ],
    });
    h.model.reply('OK');
    _done(await h.engine.send(chat, 'beacon').toList());
    expect(h.engine.inspect(chat)!.worldInfo.activated.map((hit) => hit.uid), ['1']);
    expect(_requestText(h.model.bodies.single), contains('recursion-key'));
    expect(_requestText(h.model.bodies.single), isNot(contains('UNEXPECTED')));
  });

  test('world-info placement with only writeback enabled does not change prompt content', () async {
    final h = await _open();
    final chat = await h.chat({
      'character_book': {
        'name': 'probe-book',
        'entries': [_entry(1, 'beacon', 'raw-world')],
      },
    });
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('world', r'^raw-world$', 'WRONG', [5]),
      ],
    });
    h.model.reply('OK');
    _done(await h.engine.send(chat, 'beacon').toList());
    expect(_requestText(h.model.bodies.single), contains('raw-world'));
    expect(_requestText(h.model.bodies.single), isNot(contains('WRONG')));
  });

  test('native depth-zero assistant and system retain ST order in the final DeepSeek request', () async {
    final h = await _open();
    final chat = await h.chat({
      'character_book': {
        'name': 'native-depth',
        'entries': [
          {
            ..._entry(1, 'unused', 'A'),
            'constant': true,
            'extensions': {'position': 4, 'depth': 0, 'role': 2},
          },
          {
            ..._entry(2, 'unused', 'S'),
            'constant': true,
            'extensions': {'position': 4, 'depth': 0, 'role': 0},
          },
        ],
      },
    });
    h.model.reply('OK');
    _done(await h.engine.send(chat, 'Q').toList());
    // Native ST depth injection orders A before S. The DeepSeek pass then
    // converts the non-leading system message to user without moving A.
    expect(h.model.bodies.single['messages'], [
      {'role': 'assistant', 'content': 'G'},
      {'role': 'user', 'content': 'Q'},
      {'role': 'assistant', 'content': 'A'},
      {'role': 'user', 'content': 'S'},
    ]);
    expect(h.engine.inspect(chat)!.worldInfo.activated.every((hit) => !hit.assistantPrefill), isTrue);
  });

  test('mixed native and V3 depth-zero entries move only explicit prefill to the final request tail', () async {
    final h = await _open();
    final chat = await h.chat({
      'character_book': {
        'name': 'mixed-depth',
        'entries': [
          {
            ..._entry(1, 'unused', 'A'),
            'constant': true,
            'extensions': {'position': 4, 'depth': 0, 'role': 2},
          },
          {..._entry(2, 'unused', '@@depth 0\n@@role assistant\nV'), 'constant': true},
          {
            ..._entry(3, 'unused', 'S'),
            'constant': true,
            'extensions': {'position': 4, 'depth': 0, 'role': 0},
          },
        ],
      },
    });
    h.model.reply('OK');
    _done(await h.engine.send(chat, 'Q').toList());
    expect(h.model.bodies.single['messages'], [
      {'role': 'assistant', 'content': 'G'},
      {'role': 'user', 'content': 'Q'},
      {'role': 'assistant', 'content': 'A'},
      {'role': 'user', 'content': 'S'},
      {'role': 'assistant', 'content': 'V', 'prefix': true},
    ]);
    expect(h.engine.inspect(chat)!.worldInfo.activated.where((hit) => hit.assistantPrefill).map((hit) => hit.uid), [
      '2',
    ]);
  });

  test('terminal replacement sees the complete raw model reply as lastMessage', () async {
    final h = await _open();
    final chat = await h.chat();
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('raw-history', r'^x$', '{{lastMessage}}/{{incvar::writes}}', [2]),
      ],
    });
    h.model.reply('x');
    expect(_done(await h.engine.send(chat, 'NOT_THE_REPLY').toList()).text, 'x/1');
    expect(h.engine.variables(chat)['writes'], 1);
    await h.reopen();
    expect((await h.engine.path(chat)).last.text, 'x/1');
    expect(h.engine.variables(chat)['writes'], 1);
  });

  test('terminal reasoning failure restores that phase variables globals hash and raw buffers', () async {
    final h = await _open();
    final chat = await h.chat();
    await h.engine.setGlobalVariables({'baseline': 4});
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('body-first', r'^x$', '{{pick::a::b}}{{incvar::body}}{{incglobalvar::g}}', [2]),
        _script('bad-reasoning', '(?<n>r)', r'$4', [6]),
      ],
    });
    h.model.reply('x', reasoning: 'r');
    final events = await h.engine.send(chat, '{{setvar::prepared::kept}}QUESTION').toList();
    expect(events.whereType<TavernTurnDone>(), isEmpty);
    final failed = events.whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.server);
    expect(failed.partial!.text, 'x');
    expect(failed.partial!.reasoning, 'r');
    expect(h.engine.variables(chat)['prepared'], 'kept');
    expect(h.engine.variables(chat).containsKey('body'), isFalse);
    expect(h.engine.globalVariables, {'baseline': 4});
    expect((await _header(h.engine, chat)).containsKey('chat_id_hash'), isFalse);
    await h.reopen();
    expect((await h.engine.path(chat)).last.text, 'x');
    expect((await h.engine.path(chat)).last.reasoning, 'r');
    expect(h.engine.variables(chat), {'prepared': 'kept'});
    expect(h.engine.globalVariables, {'baseline': 4});
  });

  test('network failure with partial output applies body and reasoning writeback once', () async {
    final h = await _open();
    final chat = await h.chat();
    await h.engine.setSettings({
      'globalRegexScripts': [_counter(2, 'bodyWrites'), _counter(6, 'reasoningWrites')],
    });
    h.model.reply(
      'x',
      reasoning: 'r',
      failure: const TavernModelException(TavernFailure.network, 'fixture-disconnect'),
    );
    final events = await h.engine.send(chat, 'Q').toList();
    final failure = events.whereType<TavernTurnFailed>().single;
    expect(events.whereType<TavernTurnDone>(), isEmpty);
    expect(failure.kind, TavernFailure.network);
    expect(failure.partial!.text, '1|x');
    expect(failure.partial!.reasoning, '1|r');
    expect(h.engine.variables(chat), {'bodyWrites': 1, 'reasoningWrites': 1});
    await h.reopen();
    expect((await h.engine.path(chat)).last.text, '1|x');
    expect((await h.engine.path(chat)).last.reasoning, '1|r');
    expect(h.engine.variables(chat), {'bodyWrites': 1, 'reasoningWrites': 1});
  });

  test('stop after a partial body writes the terminal transformation once', () async {
    final h = await _open();
    final chat = await h.chat();
    await h.engine.setSettings({
      'globalRegexScripts': [_counter(2, 'writes')],
    });
    final held = h.model.hold();
    final events = <TavernEvent>[];
    final bodySeen = Completer<void>();
    final ended = Completer<void>();
    h.engine.send(chat, 'Q').listen((event) {
      events.add(event);
      if (event is TavernTextDelta && !bodySeen.isCompleted) {
        bodySeen.complete();
      }
    }, onDone: ended.complete);
    await held.listening.future;
    held.source.add(const ModelText('x'));
    await bodySeen.future;
    h.engine.stop(chat);
    await ended.future;
    final failed = events.whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.cancelled);
    expect(failed.partial!.text, '1|x');
    expect(h.engine.variables(chat)['writes'], 1);
    await held.source.close();
    await h.reopen();
    expect((await h.engine.path(chat)).last.text, '1|x');
    expect(h.engine.variables(chat)['writes'], 1);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('impersonation uses user placement and persists terminal variables without editing the tree', () async {
    final h = await _open();
    final chat = await h.chat();
    final before = await h.engine.path(chat);
    await h.engine.setSettings({
      'globalRegexScripts': [
        _counter(1, 'draftWrites'),
        _script('not-ai', r'^1\|x$', 'WRONG', [2]),
      ],
    });
    h.model.reply('x');
    final draft = _done(await h.engine.impersonate(chat).toList());
    expect(draft.text, '1|x');
    expect(draft.role, TavernRole.user);
    final after = await h.engine.path(chat);
    expect(after.map((message) => message.nodeId), before.map((message) => message.nodeId));
    expect(after.map((message) => message.text), before.map((message) => message.text));
    expect(h.engine.variables(chat)['draftWrites'], 1);
    final exported = await _document(h.engine, chat);
    final state = _map(_map(_map(exported.messages.last['extra'])['dshgo'])['tavernState']);
    expect(_map(state['variables'])['draftWrites'], 1);
    await h.reopen();
    expect((await h.engine.path(chat)).map((message) => message.text), before.map((message) => message.text));
    expect(h.engine.variables(chat)['draftWrites'], 1);
  });

  test('failed no-output impersonation leaves context variables and tree unchanged', () async {
    final h = await _open();
    final chat = await h.importChat(
      [_row('KEEP')],
      metadata: {
        'variables': {'n': 7},
      },
    );
    final before = await h.engine.path(chat);
    await h.engine.setSettings({
      'globalRegexScripts': [_counter(1, 'draftWrites')],
    });
    h.model.reply('', failure: const TavernModelException(TavernFailure.network, 'fixture-before-output'));
    final failed = (await h.engine.impersonate(chat).toList()).whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.network);
    expect(failed.partial, isNull);
    expect(h.engine.variables(chat), {'n': 7});
    expect((await h.engine.path(chat)).map((message) => message.nodeId), before.map((message) => message.nodeId));
    await h.reopen();
    expect(h.engine.variables(chat), {'n': 7});
    expect((await h.engine.path(chat)).map((message) => message.text), ['KEEP']);
  });

  test('empty-chat impersonation persists sticky state and variables for the next send after reopening', () async {
    var roll = 0.0;
    var draws = 0;
    final h = await _open(
      random: () {
        draws++;
        return roll;
      },
    );
    final chat = await h.chat({
      'character_book': {
        'name': 'empty-sticky',
        'entries': [
          {
            ..._entry(1, 'unused', 'STICKY'),
            'constant': true,
            'extensions': {'useProbability': true, 'probability': 50, 'sticky': 3},
          },
        ],
      },
    });
    await h.engine.deleteFrom(chat, (await h.engine.path(chat)).single.nodeId);
    await h.engine.setSettings({
      'globalRegexScripts': [_counter(1, 'draftWrites')],
    });
    h.model.reply('draft');
    expect(_done(await h.engine.impersonate(chat).toList()).text, '1|draft');
    expect(await h.engine.path(chat), isEmpty);
    expect(h.engine.variables(chat)['draftWrites'], 1);
    expect(h.engine.inspect(chat)!.worldInfo.activated.single.probabilityRoll, 0);
    expect(draws, 1);
    final metadata = await _header(h.engine, chat);
    expect(_map(_map(metadata['timedWorldInfo'])['sticky']), hasLength(1));
    expect(_map(metadata['decoratorState']).values.map((value) => _map(value)['matches']), [1]);
    roll = 0.9;
    await h.reopen();
    expect(await h.engine.path(chat), isEmpty);
    expect(h.engine.variables(chat)['draftWrites'], 1);
    h.model.reply('OK');
    _done(await h.engine.send(chat, 'Q').toList());
    expect(_requestText(h.model.bodies.last), contains('STICKY'));
    expect(h.engine.inspect(chat)!.worldInfo.activated.single.probabilityRoll, isNull);
    expect(draws, 1, reason: 'Sticky admission bypasses the otherwise failing probability draw.');
    expect(h.engine.variables(chat)['draftWrites'], 2);
    expect((await h.engine.path(chat)).map((message) => message.text), ['2|Q', 'OK']);
    final after = await _header(h.engine, chat);
    expect(_map(after['decoratorState']).values.map((value) => _map(value)['matches']), [2]);
  });

  test('regenerating the first node does not borrow terminal metadata for its null parent', () async {
    var draws = 0;
    final h = await _open(
      random: () {
        draws++;
        return 0.9;
      },
    );
    final book = <String, Object?>{
      'name': 'root-regeneration',
      'entries': [
        {
          ..._entry(1, 'unused', 'TERMINAL_STICKY'),
          'constant': true,
          'extensions': {'useProbability': true, 'probability': 50, 'sticky': 3},
        },
      ],
    };
    final card = await h.engine.importCard(_card({'character_book': book}));
    final entry = WorldInfoBook.fromJson(
      id: '${card.id}:card',
      source: WorldInfoSource.character,
      json: book,
    ).entries.single;
    final document = StChatDocument(
      fileName: 'root.jsonl',
      header: {
        'chat_metadata': {
          'variables': {'terminalOnly': 7},
          'timedWorldInfo': {
            'sticky': {
              entry.stKey: {'hash': entry.stHash, 'start': -1, 'end': 3, 'protected': false},
            },
          },
          'decoratorState': {
            '${entry.stHash}': {'matches': 2, 'lastMessageCount': 0},
          },
        },
      },
      messages: [_row('G')],
    );
    final chat = (await h.engine.importChats(card.id, [
      TavernChatFile(fileName: document.fileName, bytes: document.encode()),
    ])).chatIds.single;
    final greeting = (await h.engine.path(chat)).single;
    expect(h.engine.variables(chat), {'terminalOnly': 7});
    await h.reopen();
    h.model.reply('REGEN');
    _done(await h.engine.regenerate(chat, greeting.nodeId).toList());
    // This source timer would be active at count zero if terminal metadata
    // leaked into the absent parent; it must not bypass probability.
    expect(h.engine.inspect(chat)!.worldInfo.activated, isEmpty);
    expect(_requestText(h.model.bodies.single), isNot(contains('TERMINAL_STICKY')));
    expect(draws, 1);
    expect(h.engine.variables(chat), isEmpty);
    final metadata = await _header(h.engine, chat);
    expect(_map(_map(metadata['timedWorldInfo'])['sticky']), isEmpty);
    expect(_map(metadata['decoratorState']), isEmpty);
  });

  for (final c in [
    (name: 'default modern', settings: <String, Object?>{}, expected: 'V'),
    (name: 'explicit legacy', settings: <String, Object?>{'macroEngine': 'legacy'}, expected: '{{.n}}'),
    (name: 'experimental false', settings: <String, Object?>{'experimental_macro_engine': false}, expected: '{{.n}}'),
    (
      name: 'explicit modern overrides flag',
      settings: <String, Object?>{'macroEngine': 'modern', 'experimental_macro_engine': false},
      expected: 'V',
    ),
  ]) {
    test('macro engine selector: ${c.name}', () async {
      final h = await _open();
      final chat = await h.importChat(
        [_row('G')],
        metadata: {
          'variables': {'n': 'V'},
        },
      );
      await h.engine.setSettings(c.settings, chatId: chat);
      h.model.reply('OK');
      _done(await h.engine.send(chat, '{{.n}}').toList());
      expect((await h.engine.path(chat))[1].text, c.expected);
    });
  }

  test('zero cache is retained by modern and bridged through legacy to the next modern turn', () async {
    final h = await _open();
    final chat = await h.importChat([_row('G')], fileName: 'Review.jsonl', metadata: {'chat_id_hash': 0});
    h.model.reply('OK');
    _done(await h.engine.send(chat, _pick).toList());
    expect((await h.engine.path(chat))[1].text, 'a');
    expect((await _header(h.engine, chat))['chat_id_hash'], 0);
    await h.engine.setSettings({'macroEngine': 'legacy'}, chatId: chat);
    h.model.reply('OK');
    _done(await h.engine.send(chat, _pick).toList());
    expect((await h.engine.path(chat))[3].text, 'c');
    expect((await _header(h.engine, chat))['chat_id_hash'], 3994932676295448);
    await h.engine.setSettings({'macroEngine': 'modern'}, chatId: chat);
    h.model.reply('OK');
    _done(await h.engine.send(chat, _pick).toList());
    expect((await h.engine.path(chat))[5].text, 'd');
    await h.reopen();
    expect((await _header(h.engine, chat))['chat_id_hash'], 3994932676295448);
  });

  test('pick reroll metadata participates in facade seed and repeats deterministically', () async {
    final h = await _open();
    final one = await h.importChat(
      [_row('G')],
      fileName: 'one.jsonl',
      metadata: {'chat_id_hash': 42, 'pick_reroll_seed': 1},
    );
    final two = await h.importChat(
      [_row('G')],
      fileName: 'two.jsonl',
      metadata: {'chat_id_hash': 42, 'pick_reroll_seed': 2},
    );
    for (final c in [(one, 'i'), (two, 'j'), (one, 'i')]) {
      h.model.reply('OK');
      _done(await h.engine.send(c.$1, _pick).toList());
      final path = await h.engine.path(c.$1);
      expect(path[path.length - 2].text, c.$2);
      expect((await _header(h.engine, c.$1))['chat_id_hash'], 42);
    }
  });

  test('public settings deeply merge maps replace arrays and retain null with detached reads', () async {
    final h = await _open();
    final chat = await h.chat();
    final Tavern facade = h.engine;
    await facade.setSettings({
      'nested': {'keep': 1, 'value': 2},
      'array': [1, 2],
      'nullable': {'old': true},
    });
    await facade.setSettings({
      'nested': {'value': 3},
      'array': [9],
      'nullable': null,
    }, chatId: chat);
    final view = await facade.readSettings(chatId: chat);
    expect(view['nested'], {'keep': 1, 'value': 3});
    expect(view['array'], [9]);
    expect(view.containsKey('nullable'), isTrue);
    expect(view['nullable'], isNull);
    (view['nested']! as Map<String, Object?>)['keep'] = 99;
    (view['array']! as List<Object?>).add(10);
    expect((await facade.readSettings(chatId: chat))['nested'], {'keep': 1, 'value': 3});
    expect((await facade.readSettings())['array'], [1, 2]);
    await h.reopen();
    expect((await h.engine.readSettings(chatId: chat))['array'], [9]);
    expect((await h.engine.readSettings(chatId: chat)).containsKey('nullable'), isTrue);
  });

  test('settings capture caller JSON at invocation before asynchronous persistence', () async {
    final h = await _open();
    final patch = <String, Object?>{
      'owned': {'value': 1},
      'array': <Object?>[1],
    };
    final writing = h.engine.setSettings(patch);
    (patch['owned']! as Map<String, Object?>)['value'] = 99;
    (patch['array']! as List<Object?>).add(99);
    await writing;
    expect((await h.engine.readSettings())['owned'], {'value': 1});
    expect((await h.engine.readSettings())['array'], [1]);
  });

  test('readSettings overlays source metadata between global and per-chat settings', () async {
    final h = await _open();
    await h.engine.setSettings({'scenarioOverride': 'GLOBAL'});
    final chat = await h.importChat([_row('G')], metadata: {'scenario': 'SOURCE'});
    expect((await h.engine.readSettings(chatId: chat))['scenarioOverride'], 'SOURCE');
    await h.engine.setSettings({'scenarioOverride': 'CHAT'}, chatId: chat);
    expect((await h.engine.readSettings(chatId: chat))['scenarioOverride'], 'CHAT');
    expect((await h.engine.readSettings())['scenarioOverride'], 'GLOBAL');
  });

  test('global regex updates take effect on the next turn without cancelling the current snapshot', () async {
    final h = await _open();
    final chat = await h.chat();
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('old', r'^x$', 'OLD', [2]),
      ],
    });
    final held = h.model.hold();
    final running = h.engine.send(chat, 'Q').toList();
    await held.listening.future;
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('new', r'^x$', 'NEW', [2]),
      ],
    });
    expect(h.model.cancellations.last.isCancelled, isFalse);
    held.source.add(const ModelText('x'));
    held.source.add(const ModelFinished('stop'));
    await held.source.close();
    expect(_done(await running).text, 'OLD');
    h.model.reply('x');
    expect(_done(await h.engine.send(chat, 'NEXT').toList()).text, 'NEW');
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('chat settings wait for cancellation and finish the old turn under its captured regex', () async {
    final h = await _open();
    final chat = await h.chat();
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('old', r'^x$', 'OLD', [2]),
      ],
    });
    final held = h.model.hold();
    final events = <TavernEvent>[];
    final bodySeen = Completer<void>();
    final ended = Completer<void>();
    h.engine.send(chat, 'Q').listen((event) {
      events.add(event);
      if (event is TavernTextDelta && !bodySeen.isCompleted) {
        bodySeen.complete();
      }
    }, onDone: ended.complete);
    await held.listening.future;
    held.source.add(const ModelText('x'));
    await bodySeen.future;
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('new', r'^x$', 'NEW', [2]),
      ],
    }, chatId: chat);
    await ended.future;
    expect(h.model.cancellations.last.isCancelled, isTrue);
    final failed = events.whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.cancelled);
    expect(failed.partial!.text, 'OLD');
    expect((await h.engine.path(chat)).last.text, 'OLD');
    await held.source.close();
    h.model.reply('x');
    expect(_done(await h.engine.send(chat, 'NEXT').toList()).text, 'NEW');
  }, timeout: const Timeout(Duration(seconds: 15)));
}

const _pick = '{{pick::a::b::c::d::e::f::g::h::i::j}}';
final _at = DateTime.utc(2026, 11, 10, 12);

Future<_Harness> _open({double Function()? random}) async {
  final directory = await Directory.systemTemp.createTemp('dsh-t11-engine-');
  final model = _Model();
  final config = TavernModelConfig(
    apiKey: () async => 'fixture-key',
    model: 'fixture-model',
    deepseek: true,
    thinking: true,
  );
  final draw = random ?? () => 0.25;
  final engine = await TavernEngine.openDirectory(
    directory,
    config: config,
    modelClient: model,
    clock: () => _at,
    random: draw,
  );
  final h = _Harness(directory, config, model, engine, draw);
  addTearDown(h.dispose);
  await engine.setPreset(_preset());
  return h;
}

class _Harness {
  _Harness(this.directory, this.config, this.model, this.engine, this.random);
  final Directory directory;
  final TavernModelConfig config;
  final _Model model;
  TavernEngine engine;
  final double Function() random;

  Future<String> chat([Map<String, Object?> data = const {}]) async {
    final card = await engine.importCard(_card(data));
    return engine.createChat(card.id);
  }

  Future<String> importChat(
    List<Map<String, Object?>> rows, {
    String fileName = 'main.jsonl',
    Map<String, Object?> metadata = const {},
  }) async {
    final card = await engine.importCard(_card());
    final document = StChatDocument(
      fileName: fileName,
      header: {'user_name': 'unused', 'character_name': 'unused', 'chat_metadata': metadata},
      messages: rows,
    );
    return (await engine.importChats(card.id, [
      TavernChatFile(fileName: fileName, bytes: document.encode()),
    ])).chatIds.single;
  }

  Future<void> reopen() async {
    await engine.close();
    engine = await TavernEngine.openDirectory(
      directory,
      config: config,
      modelClient: model,
      clock: () => _at,
      random: random,
    );
  }

  Future<void> dispose() async {
    await engine.close();
    for (final held in model.held) {
      if (!held.source.isClosed) {
        unawaited(held.source.close());
      }
    }
    await directory.delete(recursive: true);
  }
}

class _Held {
  _Held() {
    source = StreamController<ModelDelta>(sync: true, onListen: listening.complete);
  }
  final listening = Completer<void>();
  late final StreamController<ModelDelta> source;
}

class _Model extends TavernModelClient {
  final plans = Queue<Stream<ModelDelta>>();
  final bodies = <Map<String, Object?>>[];
  final cancellations = <ModelCancellation>[];
  final held = <_Held>[];

  void reply(String text, {String? reasoning, TavernModelException? failure}) {
    Stream<ModelDelta> response() async* {
      if (reasoning != null) {
        yield ModelReasoning(reasoning);
      }
      if (text.isNotEmpty) {
        yield ModelText(text);
      }
      if (failure != null) {
        throw failure;
      }
      yield const ModelFinished('stop');
    }

    plans.add(response());
  }

  _Held hold() {
    final value = _Held();
    held.add(value);
    plans.add(value.source.stream);
    return value;
  }

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    bodies.add(_map(body));
    cancellations.add(cancellation);
    if (plans.isEmpty) {
      throw StateError('No synthetic model response was queued.');
    }
    return plans.removeFirst();
  }
}

TavernMessage _done(List<TavernEvent> events) {
  expect(events.whereType<TavernTurnFailed>(), isEmpty);
  return events.whereType<TavernTurnDone>().single.message;
}

String _requestText(Map<String, Object?> body) =>
    (body['messages']! as List<Object?>).map((value) => _map(value)['content']).join('\n');
Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? jsonDecode(jsonEncode(value)) as Map<String, Object?> : {};
Future<StChatDocument> _document(TavernEngine engine, String chat) async {
  final file = (await engine.exportChat(chat)).first;
  return StChatDocument.decode(file.fileName, file.bytes);
}

Future<Map<String, Object?>> _header(TavernEngine engine, String chat) async =>
    _map((await _document(engine, chat)).header['chat_metadata']);

Map<String, Object?> _row(String text, {bool user = false, bool hidden = false}) => {
  'name': user ? 'User' : 'Guide',
  'is_user': user,
  'is_system': hidden,
  'send_date': _at.toIso8601String(),
  'mes': text,
};
Map<String, Object?> _entry(int id, String key, String content) => {
  'id': id,
  'keys': [key],
  'content': content,
  'enabled': true,
  'insertion_order': 100,
  'position': 'before_char',
  'extensions': <String, Object?>{},
};
Map<String, Object?> _counter(int placement, String name) =>
    _script(name, r'^([\s\S]+)$', '{{incvar::$name}}|\$1', [placement]);
Map<String, Object?> _script(
  String name,
  String pattern,
  String replacement,
  List<int> placement, {
  bool disabled = false,
  bool markdownOnly = false,
  bool promptOnly = false,
  bool runOnEdit = false,
  num? minDepth,
  num? maxDepth,
}) => {
  'id': name,
  'scriptName': name,
  'findRegex': pattern,
  'replaceString': replacement,
  'placement': placement,
  'trimStrings': <String>[],
  'disabled': disabled,
  'markdownOnly': markdownOnly,
  'promptOnly': promptOnly,
  'runOnEdit': runOnEdit,
  'substituteRegex': 0,
  'minDepth': minDepth,
  'maxDepth': maxDepth,
};

ChatPreset _preset({List<Map<String, Object?>> regex = const []}) {
  const identifiers = [
    'worldInfoBefore',
    'main',
    'worldInfoAfter',
    'charDescription',
    'charPersonality',
    'scenario',
    'personaDescription',
    'dialogueExamples',
    'chatHistory',
    'jailbreak',
  ];
  return ChatPreset({
    'openai_max_context': 4096,
    'openai_max_tokens': 256,
    'stream_openai': true,
    'names_behavior': 0,
    'continue_prefill': true,
    'continue_postfix': '',
    'new_chat_prompt': '',
    'new_group_chat_prompt': '',
    'new_example_chat_prompt': '',
    'continue_nudge_prompt': '',
    'group_nudge_prompt': '',
    'send_if_empty': '',
    'wi_format': '{0}',
    'personality_format': '{0}',
    'scenario_format': '{0}',
    'extensions': {'regex_scripts': regex},
    'prompts': [
      for (final id in identifiers)
        {
          'identifier': id,
          'name': id,
          'role': 'system',
          'system_prompt': id == 'main' || id == 'jailbreak',
          'marker': id != 'main' && id != 'jailbreak',
          'content': '',
        },
    ],
    'prompt_order': [
      {
        'character_id': 100001,
        'order': [
          for (final id in identifiers) {'identifier': id, 'enabled': true},
        ],
      },
    ],
  });
}

Uint8List _card([Map<String, Object?> data = const {}]) => Uint8List.fromList(
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
        ...data,
      },
    }),
  ),
);
