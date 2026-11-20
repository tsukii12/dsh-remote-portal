import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_slash_test_support.dart';

void main() {
  test('persistent injection ids and listing retain raw data without consuming macro random', () async {
    final h = await slashFixture();
    final actor = await h.card('Persistent raw');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    var randomCalls = 0;
    h.onRandom = () {
      randomCalls++;
    };
    const rawId = ' a_b/| ';
    const opaque = '{{incglobalvar::notNow}}';
    final first = await slashRun(
      h,
      context.id,
      '/inject id={{arg::id}} position=none depth=0 role=user scan=true {{arg::body}}',
      arguments: const {'id': rawId, 'body': opaque},
    );
    expect(first.pipe, rawId);
    expect(first.effects.committed, isTrue);
    expect(_injectionEffect(first).target, {
      'sourceRef': {'kind': 'persistent', 'chatId': chat, 'rawId': rawId},
    });
    await slashRun(h, context.id, '/inject id=2 TWO');
    await slashRun(h, context.id, '/inject id=1 ONE');
    final autoA = (await slashRun(h, context.id, '/inject AUTO-A')).pipe;
    final autoB = (await slashRun(h, context.id, '/inject id="" AUTO-B')).pipe;
    expect(autoA, isNotEmpty);
    expect(autoB, isNotEmpty);
    expect(autoB, isNot(autoA));
    final expected = <String, Object?>{
      rawId: _entry(opaque, position: -1, depth: 0, role: 1, scan: true),
      '2': _entry('TWO'),
      '1': _entry('ONE'),
      autoA: _entry('AUTO-A'),
      autoB: _entry('AUTO-B'),
    };
    expect(await _entries(h, context.id), expected);
    final listed = await slashRun(h, context.id, '/listinjects return=pipe');
    expect(
      listed.pipe,
      [
        '### Script injections:',
        '* **1**: <code>ONE</code> (IN_PROMPT, depth: 4, scan: false, role: 0)',
        '* **2**: <code>TWO</code> (IN_PROMPT, depth: 4, scan: false, role: 0)',
        '* **$rawId**: <code>$opaque</code> (NONE, depth: 0, scan: true, role: 1)',
        '* **$autoA**: <code>AUTO-A</code> (IN_PROMPT, depth: 4, scan: false, role: 0)',
        '* **$autoB**: <code>AUTO-B</code> (IN_PROMPT, depth: 4, scan: false, role: 0)',
      ].join('\n'),
    );
    expect(randomCalls, 0);
    expect(h.engine.globalVariables.containsKey('notNow'), isFalse);
    expect(await _exportedEntries(h, chat), expected);
    await h.reopen();
    final fresh = await h.context(chat, characterId: actor);
    expect(await _entries(h, fresh.id), expected);
    expect(h.engine.globalVariables.containsKey('notNow'), isFalse);
    h.expectNoGeneration();
  });

  test('malformed persistent carriers and eager listing fail before every return-mode output', () async {
    final h = await slashFixture();
    final actor = await h.card('Persistent shapes');
    for (final bad in <Object?>[null, <Object?>[], 'not-an-object']) {
      final chat = await _metadataChat(h, actor, {'script_injects': bad});
      final context = await h.context(chat, characterId: actor);
      final before = _rawMetadata(h, chat);
      for (final command in const ['/listinjects return=object', '/inject id=new VALUE', '/flushinjects']) {
        final execution = await h.bridge.triggerSlash(context.id, command);
        final failure = await slashFailure(execution);
        expect(failure.code, TavernScriptErrorCode.shapeMismatch);
        expect(failure.committed, isFalse);
        expect(_rawMetadata(h, chat), before);
      }
    }
    final raw = <String, Object?>{
      'null-entry': null,
      'closure': {
        'value': 'LITERAL',
        'position': 1,
        'depth': 0,
        'filter': '{: /echo must-not-run :}',
        'futureField': <Object?>['retained'],
      },
    };
    final chat = await _metadataChat(h, actor, {'script_injects': raw});
    final context = await h.context(chat, characterId: actor);
    final before = _rawMetadata(h, chat);
    for (final mode in const [
      'none',
      'pipe',
      'object',
      'chat-html',
      'chat-text',
      'popup-html',
      'popup-text',
      'toast-html',
      'toast-text',
    ]) {
      final execution = await h.bridge.triggerSlash(context.id, '/listinjects return=$mode');
      final failure = await slashFailure(execution);
      expect(failure.code, TavernScriptErrorCode.shapeMismatch);
      expect(failure.committed, isFalse);
      expect(_rawMetadata(h, chat), before);
      expect(await h.engine.path(chat), isEmpty);
    }
    final views = await h.bridge.listInjections(context.id);
    final closure = views.singleWhere((view) => view.sourceRef['rawId'] == 'closure');
    expect(closure.filterStatus, 'unsupportedPersistent');
    expect(closure.raw, raw['closure']);
    expect(closure.injection!.filter, isNull);
    final validRaw = <String, Object?>{'closure': raw['closure']};
    final validChat = await _metadataChat(h, actor, {'script_injects': validRaw});
    final valid = await h.context(validChat, characterId: actor);
    expect(await _entries(h, valid.id), validRaw);
    final none = await slashRun(h, valid.id, '/listinjects return=none', pipe: 'OLD');
    expect(none.pipe, '');
    expect(none.effects.committed, isFalse);
    expect(
      (await slashRun(h, valid.id, '/listinjects return=pipe')).pipe,
      '### Script injections:\n* **closure**: <code>LITERAL</code> (IN_CHAT, depth: 0, scan: false, role: 0)',
    );
    expect(await _bridgeEntries(h, valid.id), validRaw);
    h.expectNoGeneration();
  });

  test('persistent flush and absent empty removal never delete transient or once registrations', () async {
    final h = await slashFixture();
    final actor = await h.card('Separate sources');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await slashRun(h, context.id, '/inject id=same position=chat depth=0 PERSISTENT');
    await slashRun(h, context.id, '/inject id={{arg::id}} KEEP', arguments: const {'id': ' keep '});
    final transient = await h.bridge.injectPrompts(context.id, [
      TavernScriptInjection(id: 'same', content: 'TRANSIENT', depth: 0),
    ]);
    final once = await h.bridge.injectPrompts(context.id, [
      TavernScriptInjection(id: 'once', content: 'ONCE', depth: 0),
    ], once: true);
    final exact = await slashRun(h, context.id, '/flushinjects {{arg::id}}', arguments: const {'id': ' keep '});
    expect(exact.pipe, '');
    expect((await _entries(h, context.id)).keys, ['same']);
    await slashRun(h, context.id, '/flushinjects');
    expect(await _entries(h, context.id), isEmpty);
    final before = _rawMetadata(h, chat);
    final absent = await slashRun(h, context.id, '/inject id=missing {{arg::empty}}', arguments: const {'empty': ''});
    expect(absent.pipe, 'missing');
    expect(absent.effects.committed, isFalse);
    expect(absent.effects.entries.where((effect) => effect.kind == TavernSlashEffectKind.injection), isEmpty);
    expect(_rawMetadata(h, chat), before);
    final views = await h.bridge.listInjections(context.id);
    expect(views, hasLength(2));
    expect(views.every((view) => view.source == TavernScriptInjectionSource.transient), isTrue);
    final remaining = views.singleWhere((view) => view.injection!.id == 'same');
    final remainingOnce = views.singleWhere((view) => view.injection!.id == 'once');
    expect(remaining.injection!.content, 'TRANSIENT');
    expect(remaining.registrationVersion, transient.registrations.single.registrationVersion);
    expect(remaining.once, isFalse);
    expect(remainingOnce.injection!.content, 'ONCE');
    expect(remainingOnce.registrationVersion, once.registrations.single.registrationVersion);
    expect(remainingOnce.once, isTrue);
    expect(remainingOnce.claimed, isFalse);
    expect(await _exportedEntries(h, chat), isEmpty);
    expect(
      (await slashRun(h, context.id, '/listinjects return=pipe')).pipe,
      '### Script injections:\nNo script injections for the current chat',
    );
    h.expectNoGeneration();
  });

  test('a same-payload persistent commit invalidates captured preparation before key or once claim', () async {
    final h = await slashFixture();
    final actor = await h.card('Persistent incarnation');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final first = await slashRun(h, context.id, '/inject id=same position=chat depth=0 SAME');
    final firstVersion = _injectionEffect(first).version;
    expect(firstVersion, isNotNull);
    final rawBefore = await _entries(h, context.id);
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final host = GenerationHost();
    host.onInvoke = (request, cancellation) async {
      expect(request.kind, 'filter');
      expect(request.ref.callbackId, 'hold');
      if (!entered.isCompleted) entered.complete();
      await release.future;
      return TavernScriptCallbackResult(requestId: request.requestId, status: 'completed', value: true);
    };
    h.bridge.attachHost(host);
    final lease = await h.bridge.injectPrompts(context.id, [
      TavernScriptInjection(
        id: 'hold-once',
        content: 'ONCE',
        depth: 0,
        filter: TavernScriptCallbackRef(contextId: context.id, instanceId: context.instanceId, callbackId: 'hold'),
      ),
    ], once: true);
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernScriptRawRequest(
        generationId: 'persistent-incarnation',
        orderedPrompts: const [TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'Q')],
      ),
    );
    await generationSignal(generation, entered.future);
    h.expectNoGeneration();
    final replacement = await slashRun(h, context.id, '/inject id=same position=chat depth=0 SAME');
    expect(replacement.effects.committed, isTrue);
    expect(_injectionEffect(replacement).version, isNot(firstVersion));
    expect(await _entries(h, context.id), rawBefore);
    release.complete();
    final failure = await generationFailure(generation);
    expect(failure.code, TavernScriptErrorCode.revisionConflict);
    expect(failure.committed, isFalse);
    expect(host.invocations, hasLength(1));
    final view = (await h.bridge.listInjections(
      context.id,
    )).singleWhere((view) => view.source == TavernScriptInjectionSource.transient);
    expect(view.registrationVersion, lease.registrations.single.registrationVersion);
    expect(view.once, isTrue);
    expect(view.claimed, isFalse);
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
  }, timeout: const Timeout(Duration(seconds: 15)));

  test(
    'failed real metadata SQL leaves the preceding persistent incarnation adopted only by its own execution',
    () async {
      final h = await slashFixture();
      final actor = await h.card('Injection SQL');
      final chat = await h.emptyChat(actor);
      final context = await h.context(chat, characterId: actor);
      await slashRun(h, context.id, '/inject id=old position=chat depth=0 OLD');
      final beforeRaw = _rawMetadata(h, chat);
      final beforeEntries = await _entries(h, context.id);
      h.inspect(
        (db) => db.execute("""
      CREATE TRIGGER slash_injection_abort BEFORE UPDATE OF metadata ON chats
      WHEN NEW.metadata <> OLD.metadata
      BEGIN SELECT RAISE(ABORT, 'slash injection fixture abort'); END
    """),
        writable: true,
      );
      try {
        final execution = await h.bridge.triggerSlash(context.id, '/inject id=new NEW');
        final failure = await slashFailure(execution);
        expect(failure.code, TavernScriptErrorCode.storage);
        expect(failure.committed, isFalse);
        final terminal = (await execution.events.toList()).single;
        expect(terminal.effects.committed, isFalse);
        expect(
          terminal.effects.entries.any(
            (effect) =>
                effect.kind == TavernSlashEffectKind.storage &&
                effect.operation == 'inject' &&
                effect.state == TavernSlashEffectState.failed,
          ),
          isTrue,
        );
        expect(terminal.effects.entries.where((effect) => effect.state == TavernSlashEffectState.adopted), isEmpty);
      } finally {
        h.inspect((db) => db.execute('DROP TRIGGER slash_injection_abort'), writable: true);
      }
      expect(_rawMetadata(h, chat), beforeRaw);
      expect(await _entries(h, context.id), beforeEntries);
      expect(await _exportedEntries(h, chat), beforeEntries);
      h.expectNoGeneration();
    },
  );

  test(
    'persistent mutations follow the selected imported header and survive reopen without overwriting its sibling',
    () async {
      final h = await slashFixture();
      final actor = await h.card('Selected source');
      final imported = await h.engine.importChats(actor, [
        _sourceFile('main.jsonl', {
          'script_injects': {'shared': _entry('MAIN', position: 1, depth: 0)},
        }),
        _sourceFile('branch.jsonl', {
          'main_chat': 'main',
          'script_injects': {'shared': _entry('BRANCH', position: 1, depth: 0)},
        }),
      ]);
      final chat = imported.chatIds.single;
      final main = await h.engine.path(chat);
      expect(main.first.siblingCount, 2);
      final context = await h.context(chat, characterId: actor);
      expect(scriptMap((await _entries(h, context.id))['shared'])['value'], 'MAIN');
      await slashRun(h, context.id, '/inject id=shared position=chat depth=0 CHANGED_MAIN');
      expect(await _bridgeEntries(h, context.id), {'shared': _entry('CHANGED_MAIN', position: 1, depth: 0)});
      await h.engine.selectSibling(chat, main.first.nodeId, 1);
      expect(scriptMap((await _entries(h, context.id))['shared'])['value'], 'BRANCH');
      expect(await _bridgeEntries(h, context.id), {'shared': _entry('BRANCH', position: 1, depth: 0)});
      await slashRun(h, context.id, '/inject id=branchOnly BRANCH-ONLY');
      expect(await _bridgeEntries(h, context.id), {
        'shared': _entry('BRANCH', position: 1, depth: 0),
        'branchOnly': _entry('BRANCH-ONLY'),
      });
      await h.engine.selectSibling(chat, main.first.nodeId, 0);
      expect(await _entries(h, context.id), {'shared': _entry('CHANGED_MAIN', position: 1, depth: 0)});
      await h.reopen();
      final fresh = await h.context(chat, characterId: actor);
      expect(await _entries(h, fresh.id), {'shared': _entry('CHANGED_MAIN', position: 1, depth: 0)});
      expect(await _bridgeEntries(h, fresh.id), {'shared': _entry('CHANGED_MAIN', position: 1, depth: 0)});
      await h.engine.selectSibling(chat, main.first.nodeId, 1);
      expect(await _entries(h, fresh.id), {
        'shared': _entry('BRANCH', position: 1, depth: 0),
        'branchOnly': _entry('BRANCH-ONLY'),
      });
      expect(await _bridgeEntries(h, fresh.id), {
        'shared': _entry('BRANCH', position: 1, depth: 0),
        'branchOnly': _entry('BRANCH-ONLY'),
      });
      final exported = await h.engine.exportChat(chat);
      final byName = {for (final file in exported) file.fileName: StChatDocument.decode(file.fileName, file.bytes)};
      expect(scriptMap(scriptMap(byName['main.jsonl']!.header['chat_metadata'])['script_injects']), {
        'shared': _entry('CHANGED_MAIN', position: 1, depth: 0),
      });
      expect(scriptMap(scriptMap(byName['branch.jsonl']!.header['chat_metadata'])['script_injects']), {
        'shared': _entry('BRANCH', position: 1, depth: 0),
        'branchOnly': _entry('BRANCH-ONLY'),
      });
      h.expectNoGeneration();
      stdout.writeln('P2_B3_INJECTIONS_READY');
    },
  );
}

TavernSlashEffect _injectionEffect(TavernSlashResult result) => result.effects.entries.singleWhere(
  (effect) => effect.kind == TavernSlashEffectKind.injection && effect.state == TavernSlashEffectState.adopted,
);

ScriptJson _entry(String value, {int position = 0, int depth = 4, int role = 0, bool scan = false}) => {
  'value': value,
  'position': position,
  'depth': depth,
  'role': role,
  'scan': scan,
  'filter': '',
};

Future<ScriptJson> _entries(ScriptFixture h, String contextId) async =>
    scriptMap(jsonDecode((await slashRun(h, contextId, '/listinjects return=object')).pipe));

Future<ScriptJson> _bridgeEntries(ScriptFixture h, String contextId) async => {
  for (final view in await h.bridge.listInjections(contextId))
    if (view.source == TavernScriptInjectionSource.persistent) view.sourceRef['rawId']! as String: view.raw,
};

String _rawMetadata(ScriptFixture h, String chatId) =>
    h.inspect((db) => db.select('SELECT metadata FROM chats WHERE id = ?', [chatId]).single['metadata'] as String);

Future<ScriptJson> _exportedEntries(ScriptFixture h, String chatId) async {
  final file = (await h.engine.exportChat(chatId)).single;
  final document = StChatDocument.decode(file.fileName, file.bytes);
  return scriptMap(scriptMap(document.header['chat_metadata'])['script_injects']);
}

Future<String> _metadataChat(ScriptFixture h, String character, ScriptJson metadata) async {
  final imported = await h.engine.importChats(character, [
    TavernChatFile(
      fileName: 'injections.jsonl',
      bytes: StChatDocument(
        fileName: 'injections.jsonl',
        header: {'user_name': 'User', 'character_name': 'Fixture', 'chat_metadata': metadata},
        messages: [],
      ).encode(),
    ),
  ]);
  return imported.chatIds.single;
}

TavernChatFile _sourceFile(String name, ScriptJson metadata) => TavernChatFile(
  fileName: name,
  bytes: StChatDocument(
    fileName: name,
    header: {'user_name': 'User', 'character_name': 'Fixture', 'chat_metadata': metadata},
    messages: [
      {
        'name': 'User',
        'is_user': true,
        'is_system': false,
        'mes': 'same question',
        'send_date': '2026-11-12T05:00:00.000Z',
      },
      {
        'name': 'Fixture',
        'is_user': false,
        'is_system': false,
        'mes': 'same answer',
        'send_date': '2026-11-12T05:00:01.000Z',
      },
    ],
  ).encode(),
);
