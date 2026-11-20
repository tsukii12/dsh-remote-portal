import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_slash_test_support.dart';

// New public WI regressions. Literal oracles come from the accepted H/D/A2/A3
// contract and fixed ST/Fuse sources, not private definitions or a WI projection.
void main() {
  test('chat books resolve source names and canonical bindings before lazy creation options', () async {
    final h = await slashFixture();
    final actor = await h.card('Book names');
    final seedChat = await h.emptyChat(actor);
    final seed = await h.context(seedChat, characterId: actor);
    final a = await _rawBook(h, seed.id, 'CANON', {
      'name': 'Shared',
      'entries': {
        '0': {
          'uid': 11,
          'key': ['needle'],
          'content': 'A',
        },
      },
    });
    final b = await _rawBook(h, seed.id, 'Bsource', {
      'name': 'CANON',
      'entries': {
        '0': {
          'uid': 22,
          'key': ['needle'],
          'content': 'B',
        },
      },
    });
    final c = await _rawBook(h, seed.id, 'Csource', {
      'name': 'Shared',
      'entries': {
        '0': {
          'uid': 33,
          'key': ['needle'],
          'content': 'C',
        },
      },
    });
    expect((await slashRun(h, seed.id, '/findentry file=CANON needle')).pipe, '11');
    await _noBookCreationFailure(
      h,
      seed.id,
      seedChat,
      '/findentry file=Shared needle',
      TavernScriptErrorCode.ambiguousName,
    );

    final canonicalChat = await _canonicalChat(h, actor, 'CANON', a);
    await h.engine.bindLorebooks([b, c], source: WorldInfoSource.chat, chatId: canonicalChat);
    final canonical = await h.context(canonicalChat, characterId: actor);
    final canonicalBefore = _chatColumns(h, canonicalChat);
    final booksBefore = await _bookIds(h);
    for (final source in const [
      '/getchatbook',
      '/getchatbook create=true name=""',
      '/getchatbook create=true name={: /setglobalvar key=unused BAD :}',
    ]) {
      final result = await slashRun(h, canonical.id, source);
      expect(result.pipe, 'CANON');
      expect(result.effects.committed, isFalse);
      expect(_chatColumns(h, canonicalChat), canonicalBefore);
      expect(await _bookIds(h), booksBefore);
    }
    expect((await h.bridge.getVariables(canonical.id, scriptGlobal)).value, <String, Object?>{});
    expect((await slashRun(h, canonical.id, '/findentry file=CANON needle')).pipe, '11');

    final singleChat = await h.emptyChat(actor);
    await h.engine.bindLorebooks([b], source: WorldInfoSource.chat, chatId: singleChat);
    final single = await h.context(singleChat, characterId: actor);
    final singleBefore = _chatColumns(h, singleChat);
    final selected = await slashRun(h, single.id, '/getchatbook create=false');
    expect(selected.pipe, 'Bsource');
    expect(selected.effects.committed, isFalse);
    expect(_chatColumns(h, singleChat), singleBefore);
    expect((await _exportedMetadata(h, singleChat)).containsKey('world_info'), isFalse);

    final multiChat = await h.emptyChat(actor);
    await h.engine.bindLorebooks([b, c], source: WorldInfoSource.chat, chatId: multiChat);
    final multi = await h.context(multiChat, characterId: actor);
    await _noBookCreationFailure(
      h,
      multi.id,
      multiChat,
      '/getchatbook create=false',
      TavernScriptErrorCode.ambiguousName,
    );

    final emptyChat = await h.emptyChat(actor);
    final empty = await h.context(emptyChat, characterId: actor);
    final emptyBefore = _chatColumns(h, emptyChat);
    final absent = await slashRun(h, empty.id, '/getchatbook create=false name=""');
    expect(absent.pipe, '');
    expect(absent.effects.committed, isFalse);
    expect(_chatColumns(h, emptyChat), emptyBefore);
    expect(await _bookIds(h), booksBefore);
    await _noBookCreationFailure(h, empty.id, emptyChat, '/getchatbook name=""', TavernScriptErrorCode.invalidArgument);
    await _noBookCreationFailure(h, empty.id, emptyChat, '/getchatbook name=CANON', TavernScriptErrorCode.duplicateId);

    // Native chat IDs use ASCII UUID characters, so this case needs no copied
    // sanitizer: the actual base name is under 64 characters and already valid.
    final baseName = 'Chat Book $emptyChat';
    expect(baseName.length, 46);
    expect(RegExp(r'^[A-Za-z0-9 -]+$').hasMatch(baseName), isTrue);
    final occupied = (await h.engine.importLorebook(
      jsonEncode({'name': 'Occupied display', 'entries': <String, Object?>{}}),
      fileName: '$baseName.json',
    )).book.id;
    final created = await slashRun(h, empty.id, '/getchatbook');
    final createdName = '$baseName (1)';
    expect(created.pipe, createdName);
    expect(created.effects.committed, isTrue);
    final settings = _chatSettings(h, emptyChat);
    final createdId = scriptMap(settings['stLorebookIds'])[createdName]! as String;
    expect({a, b, c, occupied}.contains(createdId), isFalse);
    expect(scriptMap(settings['lorebooks'])['chat'], [createdId]);
    expect((await _exportedMetadata(h, emptyChat))['world_info'], createdName);
    final ref = TavernScriptBookRef.standalone(bookId: createdId);
    expect((await h.bridge.readBook(empty.id, ref)).book, {'entries': <String, Object?>{}});
    final envelope = await _bookEnvelope(h, createdId);
    expect(envelope['stWorldName'], createdName);
    expect(envelope['book'], {'entries': <String, Object?>{}});
    expect(
      (await h.bridge.getContextBooks(
        empty.id,
      )).where((binding) => binding.source == TavernScriptBookSource.chat).map((binding) => binding.ref).toList(),
      [ref],
    );
    expect(await _bookIds(h), {...booksBefore, occupied, createdId});
    final createdColumns = _chatColumns(h, emptyChat);
    final again = await slashRun(h, empty.id, '/getchatbook');
    expect(again.pipe, createdName);
    expect(again.effects.committed, isFalse);
    expect(_chatColumns(h, emptyChat), createdColumns);

    await h.reopen();
    final fresh = await h.context(emptyChat, characterId: actor);
    final freshCanonical = await h.context(canonicalChat, characterId: actor);
    expect((await slashRun(h, fresh.id, '/getchatbook')).pipe, createdName);
    expect((await h.bridge.readBook(fresh.id, ref)).book, {'entries': <String, Object?>{}});
    expect(_chatColumns(h, emptyChat), createdColumns);
    expect((await slashRun(h, freshCanonical.id, '/getchatbook name=""')).pipe, 'CANON');
    expect(_chatColumns(h, canonicalChat), canonicalBefore);
    expect((await slashRun(h, freshCanonical.id, '/findentry file=CANON needle')).pipe, '11');
    h.expectNoGeneration();
  });

  test('chat book file adoption survives a real target chat metadata rollback with exact partial facts', () async {
    final h = await slashFixture();
    final actor = await h.card('Chat book partial');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final before = _chatColumns(h, chat);
    expect(await _bookIds(h), isEmpty);
    final sqlChat = chat.replaceAll("'", "''");
    var needsCleanup = true;
    void removeTrigger() {
      if (needsCleanup) {
        h.inspect((db) => db.execute('DROP TRIGGER IF EXISTS slash_chatbook_abort'), writable: true);
        needsCleanup = false;
      }
    }

    addTearDown(removeTrigger);
    late final String orphanId;
    try {
      h.inspect(
        (db) => db.execute("""
        CREATE TRIGGER slash_chatbook_abort BEFORE UPDATE OF metadata ON chats
        WHEN NEW.id = '$sqlChat' AND NEW.metadata <> OLD.metadata
        BEGIN SELECT RAISE(ABORT, 'slash chatbook fixture abort'); END
      """),
        writable: true,
      );
      final execution = await h.bridge.triggerSlash(context.id, '/getchatbook name=PartialBook');
      final failure = await slashFailure(execution);
      expect(failure.code, TavernScriptErrorCode.storage);
      expect(failure.committed, isTrue);
      final partial = failure.issues.singleWhere((issue) => issue.code == 'chatBookPartial');
      expect(partial.committed, isTrue);
      expect(partial.stage, 'handler');
      expect(partial.cancelled, isFalse);
      final details = partial.details;
      orphanId = details['bookId']! as String;
      final version = details['version']! as String;
      expect(orphanId, isNotEmpty);
      expect(version, isNotEmpty);
      expect(details['name'], 'PartialBook');
      expect(details['bindingAttempted'], isTrue);
      expect(details['bindingStarted'], isTrue);
      expect(details['bindingAdopted'], isFalse);
      final bindingTarget = <String, Object?>{
        'kind': 'chatBookBinding',
        'chatId': chat,
        'bookId': orphanId,
        'name': 'PartialBook',
      };
      expect(details['bindingTarget'], bindingTarget);
      final terminal = (await execution.events.toList()).single;
      expect(terminal.isSnapshot, isTrue);
      expect(terminal.status, TavernSlashStatus.failed);
      expect(terminal.effects.committed, isTrue);
      final effects = terminal.effects.entries
          .where((effect) => effect.kind == TavernSlashEffectKind.storage && effect.operation == 'getchatbook')
          .toList();
      final fileEffects = effects.where((effect) => effect.target['kind'] == 'book').toList();
      final sqlEffects = effects.where((effect) => effect.target['kind'] == 'chatBookBinding').toList();
      expect(fileEffects.map((effect) => effect.state).toList(), [
        TavernSlashEffectState.started,
        TavernSlashEffectState.adopted,
      ]);
      expect(sqlEffects.map((effect) => effect.state).toList(), [
        TavernSlashEffectState.started,
        TavernSlashEffectState.failed,
      ]);
      expect(fileEffects.last.index, lessThan(sqlEffects.first.index));
      final ref = TavernScriptBookRef.standalone(bookId: orphanId);
      for (final effect in fileEffects) {
        expect(effect.target, {'kind': 'book', 'ref': ref.toJson()});
        expect(effect.stage, TavernSlashEffectStage.handler);
        expect(effect.details['carrier'], 'file');
      }
      expect(fileEffects.last.committed, isTrue);
      expect(fileEffects.last.version, version);
      for (final effect in sqlEffects) {
        expect(effect.target, bindingTarget);
        expect(effect.stage, TavernSlashEffectStage.handler);
        expect(effect.details['carrier'], 'sql');
        expect(effect.committed, isFalse);
      }
      expect(sqlEffects.last.details['code'], 'storage');
      final summary = failure.issues.singleWhere((issue) => issue.code == 'slashExecution');
      expect(summary.committed, isTrue);
      expect(summary.details['effects'], terminal.effects.toJson());
      expect(_chatColumns(h, chat), before);
      final saved = await h.bridge.readBook(context.id, ref);
      expect(saved.book, {'entries': <String, Object?>{}});
      expect(saved.version, version);
      final envelope = await _bookEnvelope(h, orphanId);
      expect(envelope['stWorldName'], 'PartialBook');
      expect(envelope['book'], {'entries': <String, Object?>{}});
      expect(await _bookIds(h), {orphanId});
    } finally {
      removeTrigger();
    }
    expect(_chatColumns(h, chat), before);
    await h.reopen();
    final fresh = await h.context(chat, characterId: actor);
    expect((await h.bridge.readBook(fresh.id, TavernScriptBookRef.standalone(bookId: orphanId))).book, {
      'entries': <String, Object?>{},
    });
    expect(_chatColumns(h, chat), before);
    expect((await slashRun(h, fresh.id, '/getchatbook create=false')).pipe, '');
    expect(
      (await h.bridge.getContextBooks(fresh.id)).where((binding) => binding.source == TavernScriptBookSource.chat),
      isEmpty,
    );
    expect(await _bookIds(h), {orphanId});
    h.expectNoGeneration();
  });

  test('entry creation clones the complete literal template and uses raw property holes and locators', () async {
    final h = await slashFixture();
    final actor = await h.card('Entry template');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final id = await _rawBook(h, context.id, 'Template', {
      'name': 'Template display',
      'vendor': {
        'keep': [null, 1],
      },
      'entries': {
        '0': {'uid': 900, 'content': 'ZERO', 'vendor': 'keep0'},
        '2': {'uid': 1, 'content': 'TWO', 'vendor': 'keep2'},
      },
    });
    final ref = TavernScriptBookRef.standalone(bookId: id);
    const expectedNew = <String, Object?>{
      'uid': 1,
      'key': ['alpha,beta'],
      'keysecondary': [],
      'comment': 'alpha,beta',
      'content': 'BODY',
      'constant': false,
      'vectorized': false,
      'selective': true,
      'selectiveLogic': 0,
      'addMemo': true,
      'order': 100,
      'position': 0,
      'disable': false,
      'ignoreBudget': false,
      'excludeRecursion': false,
      'preventRecursion': false,
      'matchPersonaDescription': false,
      'matchCharacterDescription': false,
      'matchCharacterPersonality': false,
      'matchCharacterDepthPrompt': false,
      'matchScenario': false,
      'matchCreatorNotes': false,
      'delayUntilRecursion': 0,
      'probability': 100,
      'useProbability': true,
      'depth': 4,
      'outletName': '',
      'group': '',
      'groupOverride': false,
      'groupWeight': 100,
      'scanDepth': null,
      'caseSensitive': null,
      'matchWholeWords': null,
      'useGroupScoring': null,
      'automationId': '',
      'role': 0,
      'sticky': null,
      'cooldown': null,
      'delay': null,
      'triggers': [],
    };
    final first = await slashRun(h, context.id, '/createentry file=Template key="alpha,beta" BODY');
    expect(first.pipe, '1');
    expect(first.effects.committed, isTrue);
    var raw = (await h.bridge.readBook(context.id, ref)).book;
    expect(raw, {
      'name': 'Template display',
      'vendor': {
        'keep': [null, 1],
      },
      'entries': {
        '0': {'uid': 900, 'content': 'ZERO', 'vendor': 'keep0'},
        '2': {'uid': 1, 'content': 'TWO', 'vendor': 'keep2'},
        '1': expectedNew,
      },
    });
    final blank = await slashRun(h, context.id, '/createentry file=Template');
    expect(blank.pipe, '3');
    expect(blank.effects.committed, isTrue);
    final expectedBlank = <String, Object?>{
      ...expectedNew,
      'uid': 3,
      'key': <Object?>[],
      'comment': '',
      'content': '',
      'addMemo': false,
    };
    raw = (await h.bridge.readBook(context.id, ref)).book;
    expect(scriptMap(raw['entries'])['3'], expectedBlank);
    final changed = await slashRun(h, context.id, '/setentryfield file=Template uid=0 field=content CHANGED');
    expect(changed.pipe, '');
    expect(changed.effects.committed, isTrue);
    final expected = <String, Object?>{
      'name': 'Template display',
      'vendor': {
        'keep': [null, 1],
      },
      'entries': {
        '0': {'uid': 900, 'content': 'CHANGED', 'vendor': 'keep0'},
        '2': {'uid': 1, 'content': 'TWO', 'vendor': 'keep2'},
        '1': expectedNew,
        '3': expectedBlank,
      },
    };
    expect((await h.bridge.readBook(context.id, ref)).book, expected);
    expect((await slashRun(h, context.id, '/findentry file=Template field=content CHANGED')).pipe, '900');
    await h.reopen();
    final fresh = await h.context(chat, characterId: actor);
    expect((await h.bridge.readBook(fresh.id, ref)).book, expected);
    expect(jsonDecode(await h.engine.exportLorebook(id)), expected);
    h.expectNoGeneration();
  });

  test(
    'entry setters keep current types strict original UID and real character identity without rejected writes',
    () async {
      final h = await slashFixture();
      final actor = await h.card('Types owner');
      final alpha = await h.card('Display Alpha');
      await h.engine.setCharacterIdentity(alpha, avatarFilename: 'Alpha.png', tagIds: ['actual-tag-id']);
      final deseret = await h.card('\u{10428}');
      await h.engine.setCharacterIdentity(deseret, avatarFilename: 'Deseret.png');
      final chat = await h.emptyChat(actor);
      final context = await h.context(chat, characterId: actor);
      final id = await _rawBook(h, context.id, 'Types', {
        'name': 'Types display',
        'vendor': {
          'outer': [null, 'keep'],
        },
        'entries': {
          '0': {
            'uid': 77,
            'order': 'old-string',
            'depth': 4,
            'constant': true,
            'content': 'BEFORE',
            'key': ['before'],
            'keysecondary': ['before'],
            'vendor': {'entry': true},
            'characterFilter': {
              'isExclude': false,
              'names': ['before'],
              'tags': ['old-tag'],
            },
          },
        },
        'originalData': {
          'vendor': 'original',
          'entries': [
            {
              'uid': 0,
              'content': 'NUMERIC',
              'extensions': {'stay': 'numeric'},
              'vendor': 'numeric',
            },
            {
              'uid': '0',
              'content': 'FIRST',
              'extensions': {'stay': 'first'},
              'vendor': 'first',
            },
            {
              'uid': '0',
              'content': 'SECOND',
              'extensions': {'stay': 'second'},
              'vendor': 'second',
            },
          ],
        },
      });
      final ref = TavernScriptBookRef.standalone(bookId: id);
      // NFD keeps these two isolated surrogate units on opposite sides of U+0301.
      // Removing that mark makes U+10400; the next String lowercase stage maps it
      // to U+10428. Only this transient argument is ill formed; the stored card
      // name and the resolved real avatar are ordinary well-formed strings.
      final names = await slashRun(
        h,
        context.id,
        '/setentryfield file=Types uid=0 field=characterFilterNames {{arg::body}}',
        arguments: {
          'body': String.fromCharCodes(const [0xd801, 0x0301, 0xdc00]),
        },
      );
      expect(names.pipe, '');
      expect(names.effects.committed, isTrue);
      final matched = scriptMap(scriptMap((await h.bridge.readBook(context.id, ref)).book['entries'])['0']);
      expect(scriptMap(matched['characterFilter'])['names'], ['Deseret']);
      final fields = <String, String>{
        'order': '3',
        'scanDepth': '3',
        'depth': '3',
        'constant': 'off',
        'key': '["one",2,null,true]',
        'keysecondary': ' alpha, , beta , ',
        'triggers': '["normal","bogus","quiet","normal"]',
        'content': 'BODY',
        'characterFilterNames': 'Alpha,Alpha.png,Display Alpha',
        'characterFilterExclude': 'ON',
        'characterFilterTags': '[]',
      };
      for (final field in fields.entries) {
        final result = await slashRun(
          h,
          context.id,
          '/setentryfield file=Types uid=0 field=${field.key} {{arg::body}}',
          arguments: {'body': field.value},
        );
        expect(result.pipe, '');
        expect(result.effects.committed, isTrue);
      }
      _expectTypedBook((await h.bridge.readBook(context.id, ref)).book);
      await _unchangedBookFailure(
        h,
        context.id,
        ref,
        '/setentryfield file=Types uid=0 field=characterFilterTags SomeTag',
        TavernScriptErrorCode.unsupportedCapability,
      );
      await _unchangedBookFailure(
        h,
        context.id,
        ref,
        '/setentryfield file=Types uid=0 field=depth Infinity',
        TavernScriptErrorCode.invalidArgument,
      );
      await _unchangedBookFailure(
        h,
        context.id,
        ref,
        '/setentryfield file=Types uid=0 field=vendor OVERWRITE',
        TavernScriptErrorCode.unsupportedOption,
      );
      await _unchangedBookFailure(
        h,
        context.id,
        ref,
        '/setentryfield file=Types uid=0 field=characterFilterNames "Types owner"',
        TavernScriptErrorCode.unsupportedCapability,
      );
      _expectTypedBook((await h.bridge.readBook(context.id, ref)).book);
      await h.reopen();
      final fresh = await h.context(chat, characterId: actor);
      _expectTypedBook((await h.bridge.readBook(fresh.id, ref)).book);
      _expectTypedBook(scriptMap(jsonDecode(await h.engine.exportLorebook(id))));
      h.expectNoGeneration();
    },
  );

  test('findentry keeps property order boolean fields full lowercase and all 32 bit chunks', () async {
    final h = await slashFixture();
    final actor = await h.card('Small Fuse vectors');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final id = await _rawBook(h, context.id, 'Search', {
      'entries': {
        '10': {
          'uid': 10,
          'key': ['same'],
          'order': 0,
        },
        '2': {
          'uid': 0,
          'key': ['same'],
          'disable': true,
          'order': 999,
        },
      },
    });
    final ref = TavernScriptBookRef.standalone(bookId: id);
    expect(scriptMap((await h.bridge.readBook(context.id, ref)).book['entries']).keys.toList(), ['10', '2']);
    await _readOnlySearch(h, context.id, ref, '/findentry file=Search same', '0');
    await h.bridge.replaceBook(context.id, ref, {
      'entries': {
        '0': {'uid': 41, 'constant': true},
        '1': {'uid': 42, 'constant': false},
      },
    });
    await _readOnlySearch(h, context.id, ref, '/findentry file=Search field=constant " ON "', '41');
    await _readOnlySearch(h, context.id, ref, '/findentry file=Search field=constant off', '42');
    const a32 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const query64 =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    expect(a32.length, 32);
    expect(query64.length, 64);
    await h.bridge.replaceBook(context.id, ref, {
      'entries': {
        '0': {
          'uid': 73,
          'key': [a32],
        },
      },
    });
    await _readOnlySearch(h, context.id, ref, '/findentry file=Search $query64', '73');
    // Only the second query chunk matches, at its exact expected offset 32.
    // This distinguishes full chunk traversal from keeping the first 32 bits.
    const secondOnly64 =
        'cccccccccccccccccccccccccccccccc'
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    expect(secondOnly64.length, 64);
    await h.bridge.replaceBook(context.id, ref, {
      'entries': {
        '0': {
          'uid': 74,
          'key': [secondOnly64],
        },
      },
    });
    await _readOnlySearch(h, context.id, ref, '/findentry file=Search $query64', '74');
    // Fixed Fuse uses ECMAScript default lowercase on both query and indexed
    // text. Final_Sigma is contextual; ordinary simple per-code-point casing
    // would leave one mismatch in these two-code-unit strings (1/2 > 0.3).
    await h.bridge.replaceBook(context.id, ref, {
      'entries': {
        '0': {
          'uid': 81,
          'key': ['\u03bf\u03c2'],
        },
      },
    });
    await _readOnlySearch(h, context.id, ref, '/findentry file=Search \u039f\u03a3', '81');
    await h.bridge.replaceBook(context.id, ref, {
      'entries': {
        '0': {
          'uid': 82,
          'key': ['\u039f\u03a3'],
        },
      },
    });
    await _readOnlySearch(h, context.id, ref, '/findentry file=Search \u03bf\u03c2', '82');
    // U+0130 has a full lowercase expansion to i + COMBINING DOT ABOVE.
    // An earlier plain-i entry must not win by simple casing or accent folding.
    await h.bridge.replaceBook(context.id, ref, {
      'entries': {
        '0': {
          'uid': 83,
          'key': ['i'],
        },
        '1': {
          'uid': 84,
          'key': ['i\u0307'],
        },
      },
    });
    await _readOnlySearch(h, context.id, ref, '/findentry file=Search \u0130', '84');
    await h.bridge.replaceBook(context.id, ref, {
      'entries': {
        '0': {
          'uid': 85,
          'key': ['i'],
        },
        '1': {
          'uid': 86,
          'key': ['\u0130'],
        },
      },
    });
    await _readOnlySearch(h, context.id, ref, '/findentry file=Search i\u0307', '86');
    // This consumer must retain accents and canonical representation. The
    // separate Names matching consumer performs NFD/mark removal; Fuse does not.
    await h.bridge.replaceBook(context.id, ref, {
      'entries': {
        '0': {
          'uid': 87,
          'key': ['e'],
        },
        '1': {
          'uid': 88,
          'key': ['e\u0301'],
        },
        '2': {
          'uid': 89,
          'key': ['\u00c9'],
        },
      },
    });
    await _readOnlySearch(h, context.id, ref, '/findentry file=Search \u00e9', '89');
    h.expectNoGeneration();
    stdout.writeln('P2_B3_WORLDINFO_READY');
  });
}

Future<String> _rawBook(ScriptFixture h, String contextId, String sourceName, ScriptJson raw) async {
  final id = (await h.engine.importLorebook(
    jsonEncode({'entries': <String, Object?>{}}),
    fileName: '$sourceName.json',
  )).book.id;
  await h.bridge.replaceBook(contextId, TavernScriptBookRef.standalone(bookId: id), raw);
  return id;
}

Future<Set<String>> _bookIds(ScriptFixture h) async => {for (final book in await h.engine.listLorebooks()) book.id};

ScriptJson _chatColumns(ScriptFixture h, String chatId) => h.inspect((db) {
  final row = db.select('SELECT metadata, settings FROM chats WHERE id = ?', [chatId]).single;
  return {'metadata': row['metadata'], 'settings': row['settings']};
});

ScriptJson _chatSettings(ScriptFixture h, String chatId) =>
    scriptMap(jsonDecode(_chatColumns(h, chatId)['settings']! as String));

Future<ScriptJson> _bookEnvelope(ScriptFixture h, String bookId) async =>
    scriptMap(jsonDecode(await File('${h.root.path}/lorebooks/$bookId.json').readAsString()));

Future<ScriptJson> _exportedMetadata(ScriptFixture h, String chatId) async {
  final file = (await h.engine.exportChat(chatId)).single;
  return scriptMap(StChatDocument.decode(file.fileName, file.bytes).header['chat_metadata']);
}

Future<String> _canonicalChat(ScriptFixture h, String actor, String name, String bookId) async {
  final imported = await h.engine.importChats(
    actor,
    [
      TavernChatFile(
        fileName: 'canonical.jsonl',
        bytes: StChatDocument(
          fileName: 'canonical.jsonl',
          header: {
            'user_name': 'User',
            'character_name': 'Book names',
            'chat_metadata': {'world_info': name},
          },
          messages: [],
        ).encode(),
      ),
    ],
    lorebookIds: {name: bookId},
  );
  return imported.chatIds.single;
}

Future<void> _noBookCreationFailure(
  ScriptFixture h,
  String contextId,
  String chatId,
  String source,
  TavernScriptErrorCode code,
) async {
  final columns = _chatColumns(h, chatId);
  final ids = await _bookIds(h);
  final error = await slashFailure(await h.bridge.triggerSlash(contextId, source));
  expect(error.code, code);
  expect(error.committed, isFalse);
  expect(_chatColumns(h, chatId), columns);
  expect(await _bookIds(h), ids);
}

Future<void> _unchangedBookFailure(
  ScriptFixture h,
  String contextId,
  TavernScriptBookRef ref,
  String source,
  TavernScriptErrorCode code,
) async {
  final before = await h.bridge.readBook(contextId, ref);
  final execution = await h.bridge.triggerSlash(contextId, source);
  final error = await slashFailure(execution);
  expect(error.code, code);
  expect(error.committed, isFalse);
  final terminal = (await execution.events.toList()).single;
  expect(terminal.effects.committed, isFalse);
  expect(terminal.effects.entries.where((effect) => effect.state == TavernSlashEffectState.adopted), isEmpty);
  final after = await h.bridge.readBook(contextId, ref);
  expect(after.book, before.book);
  expect(after.version, before.version);
}

Future<void> _readOnlySearch(
  ScriptFixture h,
  String contextId,
  TavernScriptBookRef ref,
  String source,
  String expected,
) async {
  final before = await h.bridge.readBook(contextId, ref);
  final result = await slashRun(h, contextId, source);
  expect(result.pipe, expected);
  expect(result.effects.committed, isFalse);
  expect(result.effects.entries.where((effect) => effect.state == TavernSlashEffectState.adopted), isEmpty);
  final after = await h.bridge.readBook(contextId, ref);
  expect(after.book, before.book);
  expect(after.version, before.version);
}

void _expectTypedBook(ScriptJson raw) {
  expect(raw['name'], 'Types display');
  expect(raw['vendor'], {
    'outer': [null, 'keep'],
  });
  final entries = scriptMap(raw['entries']);
  expect(entries.keys.toList(), ['0']);
  final entry = scriptMap(entries['0']);
  expect(entry, {
    'uid': 77, 'order': '3', 'scanDepth': '3', 'depth': 3, 'constant': false, 'content': 'BODY',
    'key': ['one', '2', 'null', 'true'], 'keysecondary': ['alpha', 'beta'],
    'triggers': ['normal', 'quiet', 'normal'], 'vendor': {'entry': true},
    'characterFilter': {
      'isExclude': true,
      'names': ['Alpha'],
      'tags': <Object?>[],
    },
    // Fixed setter initializes a missing virtual field before its filter branch.
    // These fields are not part of the separate createentry template.
    'characterFilterNames': <Object?>[], 'characterFilterExclude': false, 'characterFilterTags': <Object?>[],
  });
  expect(entry['order'], isA<String>());
  expect(entry['scanDepth'], isA<String>());
  expect(entry['depth'], isA<num>());
  expect(raw['originalData'], {
    'vendor': 'original',
    'entries': [
      {
        'uid': 0,
        'content': 'NUMERIC',
        'extensions': {'stay': 'numeric'},
        'vendor': 'numeric',
      },
      {
        'uid': '0',
        'content': 'BODY',
        'extensions': {
          'stay': 'first',
          'scan_depth': '3',
          'depth': 3,
          'triggers': ['normal', 'quiet', 'normal'],
        },
        'vendor': 'first',
        'insertion_order': '3',
        'constant': false,
        'keys': ['one', '2', 'null', 'true'],
        'secondary_keys': ['alpha', 'beta'],
        'character_filter': {
          'isExclude': true,
          'names': ['Alpha'],
          'tags': <Object?>[],
        },
      },
      {
        'uid': '0',
        'content': 'SECOND',
        'extensions': {'stay': 'second'},
        'vendor': 'second',
      },
    ],
  });
}
