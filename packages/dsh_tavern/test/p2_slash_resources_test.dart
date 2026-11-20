import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_slash_test_support.dart';

// Newly authored raw-carrier regressions. Expected data below is literal
// contract data, not a decoder or runtime WorldInfoBook projection.
void main() {
  test(
    'full character replacement preserves exact data envelope and imported container across reopen and ABA',
    () async {
      final h = await slashFixture();
      final envelope = <String, Object?>{
        'spec': 'chara_card_v3',
        'spec_version': '3.0',
        'envelopeVendor': {
          'keep': [1, null],
        },
        'data': {'name': 'Container source', 'extensions': <String, Object?>{}},
      };
      final original = await h.engine.importCard(
        Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
        fileName: 'Container.json',
      );
      final cards = <TavernCardFormat, String>{TavernCardFormat.json: original.id};
      for (final format in [TavernCardFormat.png, TavernCardFormat.charx]) {
        final bytes = await h.engine.exportCard(original.id, format: format);
        cards[format] = (await h.engine.importCard(bytes, fileName: 'Container.${format.name}')).id;
      }
      final expected = <String, Object?>{
        'name': 'Raw A',
        'modification_date': 17,
        'vendorNull': null,
        'vendorEmpty': <String, Object?>{},
        'extensions': <String, Object?>{},
      };
      final retained = <String, Map<String, List<int>>>{};
      final outerEnvelopes = <String, ScriptJson>{};
      for (final entry in cards.entries) {
        final id = entry.value;
        final before = await _cardEnvelope(h, id);
        final outside = {...before}..remove('data');
        outerEnvelopes[id] = outside;
        retained[id] = await _retainedCardFiles(h, id);
        final library = scriptMap(jsonDecode(await File('${h.root.path}/characters/$id/library.json').readAsString()));
        expect(library['sourceFormat'], entry.key.name);
        expect(retained[id]!.containsKey('original.${entry.key.name}'), isTrue);
        final context = await _resourceContext(h, id);
        final initial = await _characterPair(h, context.id);
        final mutable = scriptMap(jsonDecode(jsonEncode(expected)));
        final saving = h.bridge.replaceCharacterData(
          context.id,
          id,
          mutable,
          expectedVersion: initial['version']! as String,
        );
        mutable['name'] = 'CALLER MUTATED AFTER ENTRY';
        final summary = await saving;
        expect(summary.id, id);
        expect(summary.name, 'Raw A');
        final pair = await _characterPair(h, context.id);
        expect(pair['characterId'], id);
        expect(pair['data'], expected);
        expect(pair['version'], isNot(initial['version']));
        final detached = scriptMap(pair['data']);
        scriptMap(detached['vendorEmpty'])['leak'] = true;
        expect((await _characterPair(h, context.id))['data'], expected);
        final saved = await _cardEnvelope(h, id);
        expect(saved['data'], expected);
        saved.remove('data');
        expect(saved, outside);
        expect(await _retainedCardFiles(h, id), retained[id]);

        if (entry.key == TavernCardFormat.json) {
          expect(saved['envelopeVendor'], {
            'keep': [1, null],
          });
          final firstA = pair['version']! as String;
          await h.bridge.replaceCharacterData(context.id, id, {...expected, 'name': 'Raw B'}, expectedVersion: firstA);
          final second = await _characterPair(h, context.id);
          await h.bridge.replaceCharacterData(context.id, id, expected, expectedVersion: second['version']! as String);
          final restored = await _characterPair(h, context.id);
          expect(restored['data'], expected);
          expect(restored['version'], isNot(firstA));
          await expectLater(
            () => h.bridge.replaceCharacterData(context.id, id, {
              ...expected,
              'name': 'STALE MUST NOT SAVE',
            }, expectedVersion: firstA),
            throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
          );
          expect((await _characterPair(h, context.id))['data'], expected);
        }
      }
      final unbound = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'raw-no-actor'));
      expect((await h.bridge.snapshot(unbound.id)).resourceRefs.containsKey('characterData'), isFalse);
      await h.reopen();
      for (final id in cards.values) {
        final fresh = await _resourceContext(h, id);
        expect((await _characterPair(h, fresh.id))['data'], expected);
        final saved = await _cardEnvelope(h, id);
        expect(saved['data'], expected);
        saved.remove('data');
        expect(saved, outerEnvelopes[id]);
        expect(await _retainedCardFiles(h, id), retained[id]);
      }
      h.expectNoGeneration();
    },
  );

  test(
    'embedded raw and its token survive unrelated character variables and detect missing null and value ABA',
    () async {
      final h = await slashFixture();
      final actor = await h.card('Embedded independence');
      final chat = await h.emptyChat(actor);
      final context = await h.context(chat, characterId: actor);
      final ref = TavernScriptBookRef.embedded(characterId: actor);
      final rawA = <String, Object?>{
        'entries': <Object?>[
          {'id': 0, 'content': 'E'},
        ],
        'vendor': null,
      };
      final initial = await h.bridge.replaceBook(context.id, ref, rawA);
      final fullBefore = await _characterPair(h, context.id);
      await h.bridge.replaceVariables(context.id, scriptCharacter, {'x': 1});
      expect((await h.bridge.getVariables(context.id, scriptCharacter)).value, {'x': 1});
      final afterVariables = await h.bridge.readBook(context.id, ref);
      expect(afterVariables.book, rawA);
      expect(afterVariables.version, initial.version);
      expect(scriptMap((afterVariables.book['entries']! as List<Object?>).single).containsKey('use_regex'), isFalse);
      final fullAfter = await _characterPair(h, context.id);
      expect(fullAfter['version'], isNot(fullBefore['version']));
      final rawB = <String, Object?>{
        'entries': <Object?>[
          {'id': 0, 'content': 'B'},
        ],
        'vendor': null,
      };
      // The token captured before the unrelated write must still be accepted.
      final changed = await h.bridge.replaceBook(context.id, ref, rawB, expectedVersion: initial.version);
      final restored = await h.bridge.replaceBook(context.id, ref, rawA, expectedVersion: changed.version);
      expect(restored.book, rawA);
      expect(restored.version, isNot(initial.version));
      await expectLater(
        () => h.bridge.replaceBook(context.id, ref, rawB, expectedVersion: initial.version),
        throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
      );
      expect((await h.bridge.readBook(context.id, ref)).book, rawA);

      final beforeMissing = await _characterPair(h, context.id);
      final missingData = scriptMap(beforeMissing['data'])..remove('character_book');
      await h.bridge.replaceCharacterData(
        context.id,
        actor,
        missingData,
        expectedVersion: beforeMissing['version']! as String,
      );
      await expectLater(() => h.bridge.readBook(context.id, ref), throwsA(scriptError(TavernScriptErrorCode.notFound)));
      final beforeNull = await _characterPair(h, context.id);
      expect(scriptMap(beforeNull['data']).containsKey('character_book'), isFalse);
      await h.bridge.replaceCharacterData(context.id, actor, {
        ...scriptMap(beforeNull['data']),
        'character_book': null,
      }, expectedVersion: beforeNull['version']! as String);
      expect(scriptMap((await _characterPair(h, context.id))['data'])['character_book'], isNull);
      await expectLater(
        () => h.bridge.readBook(context.id, ref),
        throwsA(scriptError(TavernScriptErrorCode.shapeMismatch)),
      );
      await expectLater(
        () => h.bridge.replaceBook(context.id, ref, rawA, expectedVersion: restored.version),
        throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
      );
      final repaired = await h.bridge.replaceBook(context.id, ref, rawA);
      expect(repaired.book, rawA);
      expect(repaired.version, isNot(restored.version));
      await expectLater(
        () => h.bridge.replaceBook(context.id, ref, rawB, expectedVersion: restored.version),
        throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
      );
      await h.reopen();
      final fresh = await h.context(chat, characterId: actor);
      expect((await h.bridge.readBook(fresh.id, ref)).book, rawA);
      expect((await h.bridge.getVariables(fresh.id, scriptCharacter)).value, {'x': 1});
      expect(await h.engine.path(chat), isEmpty);
      h.expectNoGeneration();
    },
  );

  test('raw standalone object and array books retain their values and all five actual binding sources', () async {
    final h = await slashFixture();
    final alpha = await h.card('Sources Alpha');
    final beta = await h.card('Sources Beta');
    final chat = await h.emptyChat(alpha);
    final context = await h.context(chat, characterId: alpha);
    final stId = (await h.engine.importLorebook(
      jsonEncode({'name': 'Initial ST', 'entries': <String, Object?>{}}),
      fileName: 'Raw.json',
    )).book.id;
    final ccId = (await h.engine.importLorebook(
      jsonEncode({'name': 'Initial array', 'entries': <Object?>[]}),
      fileName: 'Array.json',
    )).book.id;
    final stRef = TavernScriptBookRef.standalone(bookId: stId);
    final ccRef = TavernScriptBookRef.standalone(bookId: ccId);
    final rawSt = <String, Object?>{
      'name': 'Raw display',
      'vendorNull': null,
      'vendorEmpty': <String, Object?>{},
      'entries': {
        '10': {
          'uid': 0,
          'key': ['never'],
          'comment': '[initvar]',
          'disable': true,
          'content': '{{incglobalvar::rawExecuted}}',
          'vendorNull': null,
        },
      },
    };
    final rawCc = <String, Object?>{
      'name': 'Array display',
      'vendorNull': null,
      'entries': <Object?>[
        {
          'id': 0,
          'keys': ['same'],
          'enabled': false,
          'content': 'FIRST',
        },
        {
          'id': 0,
          'keys': ['same'],
          'content': 'SECOND',
          'vendorNull': null,
        },
      ],
    };
    await h.bridge.replaceBook(context.id, stRef, rawSt);
    await h.bridge.replaceBook(context.id, ccRef, rawCc);
    final detached = (await h.bridge.readBook(context.id, stRef)).book;
    scriptMap(scriptMap(detached['entries'])['10'])['content'] = 'DETACHED ONLY';
    expect((await h.bridge.readBook(context.id, stRef)).book, rawSt);
    expect((await h.bridge.readBook(context.id, ccRef)).book, rawCc);
    expect(jsonDecode(await h.engine.exportLorebook(stId)), rawSt);
    expect(jsonDecode(await h.engine.exportLorebook(ccId)), rawCc);
    final embeddedAlpha = TavernScriptBookRef.embedded(characterId: alpha);
    final embeddedBeta = TavernScriptBookRef.embedded(characterId: beta);
    await h.bridge.replaceBook(context.id, embeddedAlpha, {
      'entries': <Object?>[
        {
          'id': 7,
          'keys': ['A'],
          'content': 'A',
        },
      ],
    });
    await h.bridge.replaceBook(context.id, embeddedBeta, {
      'entries': <Object?>[
        {
          'id': 7,
          'keys': ['B'],
          'content': 'B',
        },
      ],
    });
    final persona = await h.engine.createPersona(name: 'Actual persona');
    await h.engine.bindLorebooks([stId], source: WorldInfoSource.global);
    await h.engine.bindLorebooks([ccId], source: WorldInfoSource.persona, personaId: persona.id);
    await h.engine.bindLorebooks([ccId], source: WorldInfoSource.character, characterId: alpha);
    await h.engine.bindLorebooks([stId], source: WorldInfoSource.character, characterId: beta);
    await h.engine.bindLorebooks([stId], source: WorldInfoSource.chat, chatId: chat);
    await h.engine.bindPersona(chat, persona.id);
    final expectedSingle = [
      _binding(stRef, 'global'),
      _binding(ccRef, 'persona', personaId: persona.id),
      _binding(stRef, 'chat', chatId: chat),
      _binding(ccRef, 'character', characterId: alpha),
      _binding(embeddedAlpha, 'character', characterId: alpha),
    ];
    expect(_bindings(await h.bridge.getContextBooks(context.id)), unorderedEquals(expectedSingle));
    final group = await h.engine.createGroupChat(
      [alpha, beta],
      activation: TavernGroupActivation.manual,
      addGreetings: false,
    );
    await h.engine.updateGroupMember(group, beta, muted: true);
    await h.engine.bindPersona(group, persona.id);
    await h.engine.bindLorebooks([stId], source: WorldInfoSource.chat, chatId: group);
    final grouped = await h.context(group, characterId: alpha);
    final expectedGroup = [
      _binding(stRef, 'global'),
      _binding(ccRef, 'persona', personaId: persona.id),
      _binding(stRef, 'chat', chatId: group),
      _binding(ccRef, 'groupMember', chatId: group, characterId: alpha),
      _binding(embeddedAlpha, 'groupMember', chatId: group, characterId: alpha),
      _binding(stRef, 'groupMember', chatId: group, characterId: beta),
      _binding(embeddedBeta, 'groupMember', chatId: group, characterId: beta),
    ];
    expect(_bindings(await h.bridge.getContextBooks(grouped.id)), unorderedEquals(expectedGroup));
    expect(
      (await h.engine.groupChat(group))!.members.singleWhere((member) => member.characterId == beta).muted,
      isTrue,
    );
    for (final source in const [
      '/findentry file=Array needle',
      '/createentry file=Array key=needle BODY',
      '/setentryfield file=Array uid=0 field=content BODY',
    ]) {
      final error = await slashFailure(await h.bridge.triggerSlash(context.id, source));
      expect(error.code, TavernScriptErrorCode.unsupportedCapability);
    }
    expect((await h.bridge.readBook(context.id, ccRef)).book, rawCc);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, <String, Object?>{});
    expect((await h.bridge.getVariables(context.id, scriptChat)).value, <String, Object?>{});
    final removed = (await h.engine.importLorebook(
      jsonEncode({'name': 'Removed', 'entries': <String, Object?>{}}),
      fileName: 'Removed.json',
    )).book.id;
    await h.engine.deleteLorebook(removed);
    await expectLater(
      () => h.bridge.replaceBook(context.id, TavernScriptBookRef.standalone(bookId: removed), {
        'entries': <String, Object?>{},
      }),
      throwsA(scriptError(TavernScriptErrorCode.notFound)),
    );
    await h.reopen();
    final fresh = await h.context(chat, characterId: alpha);
    final freshGroup = await h.context(group, characterId: alpha);
    expect((await h.bridge.readBook(fresh.id, stRef)).book, rawSt);
    expect((await h.bridge.readBook(fresh.id, ccRef)).book, rawCc);
    expect(_bindings(await h.bridge.getContextBooks(fresh.id)), unorderedEquals(expectedSingle));
    expect(_bindings(await h.bridge.getContextBooks(freshGroup.id)), unorderedEquals(expectedGroup));
    expect(await h.engine.path(chat), isEmpty);
    expect(await h.engine.path(group), isEmpty);
    h.expectNoGeneration();
    stdout.writeln('P2_B3_RESOURCES_READY');
  });
}

Future<TavernScriptContext> _resourceContext(ScriptFixture h, String actor) =>
    h.bridge.openContext(TavernScriptContextSpec(instanceId: 'raw-$actor', characterId: actor));

Future<ScriptJson> _characterPair(ScriptFixture h, String contextId) async {
  final pair = scriptMap((await h.bridge.snapshot(contextId)).resourceRefs['characterData']);
  expect(pair.keys, unorderedEquals(['characterId', 'version', 'data']));
  expect(pair['version'], isA<String>());
  expect(pair['version'], isNotEmpty);
  return pair;
}

Future<ScriptJson> _cardEnvelope(ScriptFixture h, String actor) async =>
    scriptMap(jsonDecode(await File('${h.root.path}/characters/$actor/card.json').readAsString()));

Future<Map<String, List<int>>> _retainedCardFiles(ScriptFixture h, String actor) async {
  final result = <String, List<int>>{};
  for (final name in const [
    'library.json',
    'original.json',
    'original.png',
    'original.charx',
    'source.png',
    'portrait.png',
  ]) {
    final file = File('${h.root.path}/characters/$actor/$name');
    if (await file.exists()) {
      result[name] = await file.readAsBytes();
    }
  }
  return result;
}

ScriptJson _binding(TavernScriptBookRef ref, String source, {String? chatId, String? personaId, String? characterId}) =>
    {'ref': ref.toJson(), 'source': source, 'chatId': chatId, 'personaId': personaId, 'characterId': characterId};

List<ScriptJson> _bindings(List<TavernScriptBookBinding> bindings) => [
  for (final binding in bindings)
    _binding(
      binding.ref,
      binding.source.name,
      chatId: binding.chatId,
      personaId: binding.personaId,
      characterId: binding.characterId,
    ),
];
