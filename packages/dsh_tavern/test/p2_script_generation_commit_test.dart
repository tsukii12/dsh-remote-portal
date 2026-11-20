import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

void main() {
  test('a real global file failure leaves chat unstarted and reports no invented persisted target', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('File failure');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'global': 'old'});
    await h.bridge.replaceVariables(context.id, scriptChat, {'local': 'old'});
    final originalFile = await File('${h.root.path}/settings.json').readAsBytes();
    final blocker = Directory('${h.root.path}/settings.json.writing');
    await blocker.create();
    try {
      final generation = await h.bridge.generateRaw(
        context.id,
        _input('file-failure', '{{setglobalvar::global::new}}{{setvar::local::new}}Q'),
      );
      final error = await generationFailure(generation);
      expect(error.code, TavernScriptErrorCode.storage);
      expect(error.committed, isFalse);
      final receipt = _receipt(error);
      expect(receipt['preparationAccepted'], isTrue);
      expect(receipt['phase'], 'global');
      expect(receipt['failedTarget'], 'global');
      expect(receipt['persistedTargets'], isEmpty);
      expect(receipt['claimedInjectionVersions'], isEmpty);
      expect((receipt['skippedTargets']! as List<Object?>).map((item) => scriptMap(item)['targetKind']), ['chat']);
      expect(await File('${h.root.path}/settings.json').readAsBytes(), originalFile);
      expect(h.engine.globalVariables, {'global': 'old'});
      expect((await h.bridge.getVariables(context.id, scriptChat)).value['local'], 'old');
      expect(generationNodes(h, chat), isEmpty);
    } finally {
      await blocker.delete(recursive: true);
    }
    await h.reopen();
    final fresh = await h.context(chat, characterId: character);
    expect(h.engine.globalVariables, {'global': 'old'});
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value['local'], 'old');
    expect(await File('${h.root.path}/settings.json').readAsBytes(), originalFile);
    h.expectNoGeneration();
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('global rename survives a real group SQL rollback with an exact partial receipt and no hidden node', () async {
    final h = await generationFixture();
    final host = await h.card('Group host', extensions: scriptStateExtension(initial: 2));
    final actor = await h.card('Group actor');
    final chat = await h.engine.createGroupChat([host, actor], addGreetings: false);
    final context = await h.context(chat, characterId: host);
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'global': 'old'});
    await h.bridge.replaceVariables(context.id, scriptChat, {'local': 'old'});
    final groupBefore = h.inspect(
      (db) => db.select('SELECT initial_state FROM group_chats WHERE chat_id = ?', [chat]).single['initial_state'],
    );
    final stateBefore = (await h.engine.readState(chat)).values;
    final chatBefore = h.inspect(
      (db) => Map<String, Object?>.from(
        db.select('SELECT variables, metadata, current_leaf_id, selected_root_id FROM chats WHERE id = ?', [
          chat,
        ]).single,
      ),
    );
    await h.bridge.injectPrompts(context.id, [
      TavernScriptInjection(id: 'accepted-once', content: '', position: TavernScriptInjectionPosition.scanOnly),
    ], once: true);
    h.inspect(
      (db) => db.execute(
        "CREATE TRIGGER reject_background_chat BEFORE UPDATE OF variables ON chats "
        "WHEN NEW.variables <> OLD.variables BEGIN SELECT RAISE(ABORT, 'B2 actual SQL rollback'); END",
      ),
      writable: true,
    );
    final generation = await h.bridge.generateRaw(
      context.id,
      _input('sql-partial', '{{setglobalvar::global::new}}{{setvar::local::new}}Q'),
    );
    final error = await generationFailure(generation);
    expect(error.code, TavernScriptErrorCode.storage);
    expect(error.committed, isTrue);
    final receipt = _receipt(error);
    expect(receipt['preparationAccepted'], isTrue);
    expect(receipt['phase'], 'chat');
    expect(receipt['failedTarget'], 'chat');
    expect(receipt['persistedTargets'], [
      {'targetKind': 'global', 'status': 'written'},
    ]);
    expect(receipt['claimedInjectionVersions'], hasLength(1));
    expect(receipt['skippedTargets'], isEmpty);
    expect((await h.settingsDocument())['globalVariables'], {'global': 'new'});
    expect(h.engine.globalVariables, {'global': 'new'});
    expect(
      h.inspect(
        (db) => db.select('SELECT initial_state FROM group_chats WHERE chat_id = ?', [chat]).single['initial_state'],
      ),
      groupBefore,
    );
    expect(
      h.inspect(
        (db) => Map<String, Object?>.from(
          db.select('SELECT variables, metadata, current_leaf_id, selected_root_id FROM chats WHERE id = ?', [
            chat,
          ]).single,
        ),
      ),
      chatBefore,
    );
    expect((await h.bridge.getVariables(context.id, scriptChat)).value['local'], 'old');
    expect((await h.engine.readState(chat)).values, stateBefore);
    expect((await h.bridge.listInjections(context.id)).single.claimed, isTrue);
    expect(generationNodes(h, chat), isEmpty);
    expect(h.requests, isEmpty);
    expect(h.keyReads, 0);
    h.inspect((db) => db.execute('DROP TRIGGER reject_background_chat'), writable: true);
    await h.reopen();
    final fresh = await h.context(chat, characterId: host);
    expect(h.engine.globalVariables, {'global': 'new'});
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value['local'], 'old');
    expect(
      h.inspect(
        (db) => db.select('SELECT initial_state FROM group_chats WHERE chat_id = ?', [chat]).single['initial_state'],
      ),
      groupBefore,
    );
    // A distinct later call can commit to the actual empty-group carrier.
    // Missing key occurs after those effects, so there is still no fake node.
    h.engine.configure(
      TavernModelConfig(
        apiKey: () async {
          h.keyReads++;
          return null;
        },
        baseUrl: h.config.baseUrl,
        model: h.config.model,
        deepseek: true,
      ),
    );
    final later = await h.bridge.generateRaw(
      fresh.id,
      _input('empty-group-commit', '{{setglobalvar::global::new}}{{setvar::local::new}}Q'),
    );
    final laterError = await generationFailure(later);
    expect(laterError.modelFailure, TavernFailure.noKey);
    expect(laterError.committed, isTrue);
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value['local'], 'new');
    expect((await h.engine.readState(chat)).values, stateBefore);
    expect(generationNodes(h, chat), isEmpty);
    expect(h.requests, isEmpty);
    expect(h.keyReads, 1);
    await h.reopen();
    final reopened = await h.context(chat, characterId: host);
    expect((await h.bridge.getVariables(reopened.id, scriptChat)).value['local'], 'new');
    expect((await h.engine.readState(chat)).values, stateBefore);
    expect(generationNodes(h, chat), isEmpty);
    stdout.writeln('P2_B2_COMMIT_READY');
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('same-value global SET and absent DELETE are accepted intents despite an unchanged JSON projection', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Root intent');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    final before = await h.bridge.replaceVariables(context.id, scriptGlobal, {'same': 'old'});
    final fileBefore = await File('${h.root.path}/settings.json').readAsBytes();
    h.engine.configure(
      TavernModelConfig(
        apiKey: () async {
          h.keyReads++;
          return null;
        },
        baseUrl: h.config.baseUrl,
        model: h.config.model,
        deepseek: true,
      ),
    );
    final inputs = ['{{setglobalvar::same::old}}Q', '{{deleteglobalvar::absent}}Q'];
    for (var index = 0; index < inputs.length; index++) {
      final generation = await h.bridge.generateRaw(context.id, _input('same-json-$index', inputs[index]));
      final failure = await generationFailure(generation);
      expect(failure.modelFailure, TavernFailure.noKey);
      expect(failure.committed, isTrue);
      final receipt = _receipt(failure);
      expect(receipt['preparationAccepted'], isTrue);
      expect(receipt['phase'], 'key');
      expect(receipt['persistedTargets'], [
        {'targetKind': 'global', 'status': 'adopted'},
      ]);
      expect(receipt['claimedInjectionVersions'], isEmpty);
      final after = await h.bridge.getVariables(context.id, scriptGlobal);
      expect(after.value, before.value);
      expect(after.version, before.version);
      expect(await File('${h.root.path}/settings.json').readAsBytes(), fileBefore);
      expect(generationNodes(h, chat), isEmpty);
      expect(h.requests, isEmpty);
      expect(h.keyReads, index + 1);
    }
    await h.reopen();
    expect(h.engine.globalVariables, before.value);
    expect(generationNodes(h, chat), isEmpty);
  });

  test(
    'actual global commits through ABA invalidate a captured preparation even when its JSON returns equal',
    () async {
      final h = await generationFixture(allowModel: false);
      final character = await h.card('Global ABA');
      final chat = await h.emptyChat(character);
      final context = await h.context(chat, characterId: character);
      final initial = await h.bridge.replaceVariables(context.id, scriptGlobal, {'value': 0});
      final host = GenerationHost();
      host.onInvoke = (request, cancellation) async {
        await h.bridge.replaceVariables(context.id, scriptGlobal, {'value': 1});
        await h.bridge.replaceVariables(context.id, scriptGlobal, {'value': 0});
        return TavernScriptCallbackResult(requestId: request.requestId, status: 'completed', value: true);
      };
      h.bridge.attachHost(host);
      final generation = await h.bridge.generateRaw(
        context.id,
        _input('global-aba', '{{setglobalvar::background::new}}Q', filter: _filter(context)),
      );
      final failure = await generationFailure(generation);
      expect(failure.code, TavernScriptErrorCode.revisionConflict);
      expect(failure.committed, isFalse);
      expect(_receipt(failure)['preparationAccepted'], isFalse);
      final after = await h.bridge.getVariables(context.id, scriptGlobal);
      expect(after.value, initial.value);
      expect(after.version, isNot(initial.version));
      expect(h.engine.globalVariables.containsKey('background'), isFalse);
      expect(host.invocations, hasLength(1));
      h.expectNoGeneration();
    },
  );
  test('runtime global adoption invalidates preparation even when Infinity and null share the public JSON', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Runtime adoption');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.engine.setGlobalVariables({'inf': 0});
    await h.engine.narrate(chat, '{{addglobalvar::inf::Infinity}}seed');
    expect(h.engine.globalVariables['inf'], double.infinity);
    final before = await h.bridge.getVariables(context.id, scriptGlobal);
    expect(before.value, {'inf': null});
    expect((await h.settingsDocument())['globalVariables'], {'inf': null});
    final nodesBefore = generationNodes(h, chat);
    expect(nodesBefore, hasLength(1));
    final host = GenerationHost();
    host.onInvoke = (request, cancellation) async {
      final adopted = await h.bridge.replaceVariables(context.id, scriptGlobal, before.value);
      expect(adopted.value, before.value);
      expect(adopted.version, before.version);
      expect(h.engine.globalVariables['inf'], isNull);
      return TavernScriptCallbackResult(requestId: request.requestId, status: 'completed', value: true);
    };
    h.bridge.attachHost(host);
    final generation = await h.bridge.generateRaw(
      context.id,
      _input('runtime-adoption', '{{setglobalvar::background::new}}Q', filter: _filter(context)),
    );
    final failure = await generationFailure(generation);
    expect(failure.code, TavernScriptErrorCode.revisionConflict);
    expect(failure.committed, isFalse);
    expect(_receipt(failure)['preparationAccepted'], isFalse);
    expect(_receipt(failure)['persistedTargets'], isEmpty);
    expect(h.engine.globalVariables, {'inf': null});
    final after = await h.bridge.getVariables(context.id, scriptGlobal);
    expect(after.value, before.value);
    expect(after.version, before.version);
    expect(generationNodes(h, chat), nodesBefore);
    expect(host.invocations, hasLength(1));
    h.expectNoGeneration();
  });

  test('actual local commits through ABA invalidate only the prepared local target', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Local ABA');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    final initial = await h.bridge.replaceVariables(context.id, scriptChat, {'value': 0});
    final host = GenerationHost();
    host.onInvoke = (request, cancellation) async {
      await h.bridge.replaceVariables(context.id, scriptChat, {'value': 1});
      await h.bridge.replaceVariables(context.id, scriptChat, {'value': 0});
      return TavernScriptCallbackResult(requestId: request.requestId, status: 'completed', value: true);
    };
    h.bridge.attachHost(host);
    final generation = await h.bridge.generateRaw(
      context.id,
      _input('local-aba', '{{setvar::background::new}}Q', filter: _filter(context)),
    );
    final failure = await generationFailure(generation);
    expect(failure.code, TavernScriptErrorCode.revisionConflict);
    expect(failure.committed, isFalse);
    expect(_receipt(failure)['preparationAccepted'], isFalse);
    final after = await h.bridge.getVariables(context.id, scriptChat);
    expect(after.value, initial.value);
    expect(after.version, isNot(initial.version));
    expect(after.value.containsKey('background'), isFalse);
    expect(host.invocations, hasLength(1));
    h.expectNoGeneration();
  });

  test('a selection round trip is observed even when the same leaf is selected again before acceptance', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Selection ABA', greeting: 'S');
    final chat = await h.engine.createChat(character);
    final context = await h.context(chat, characterId: character);
    final original = (await h.bridge.getChatMessages(context.id, const TavernMessageRange())).messages.single.ref;
    await h.bridge.setChatMessages(context.id, [
      TavernScriptMessagePatch(
        ref: original,
        fields: {
          'swipes': ['S', 'T'],
          'swipeId': 0,
        },
      ),
    ]);
    await h.bridge.replaceVariables(context.id, scriptChat, {'value': 'old'});
    await h.bridge.selectSwipe(context.id, original, 1);
    await h.bridge.replaceVariables(context.id, scriptChat, {'value': 'old'});
    await h.bridge.selectSwipe(context.id, original, 0);
    final before = (await h.bridge.getChatMessages(context.id, const TavernMessageRange(), includeSwipes: true));
    final host = GenerationHost();
    host.onInvoke = (request, cancellation) async {
      await h.bridge.selectSwipe(context.id, original, 1);
      await h.bridge.selectSwipe(context.id, original, 0);
      return TavernScriptCallbackResult(requestId: request.requestId, status: 'completed', value: true);
    };
    h.bridge.attachHost(host);
    final generation = await h.bridge.generateRaw(
      context.id,
      _input('selection-aba', '{{setvar::value::new}}Q', filter: _filter(context)),
    );
    expect((await generationFailure(generation)).code, TavernScriptErrorCode.revisionConflict);
    final after = await h.bridge.getChatMessages(context.id, const TavernMessageRange(), includeSwipes: true);
    expect(after.messages.single.ref, original);
    expect(after.messages.single.message, 'S');
    expect(
      after.messages.single.swipes.map((swipe) => swipe.ref),
      before.messages.single.swipes.map((swipe) => swipe.ref),
    );
    expect(after.pathRevision, isNot(before.pathRevision));
    expect((await h.engine.readVariables(chat))['value'], 'old');
    expect(host.invocations, hasLength(1));
    h.expectNoGeneration();
  });

  test(
    'local preparation merges with later message data and anchors to the current leaf rather than an iframe historical node',
    () async {
      final h = await generationFixture();
      final character = await h.card('Narrow merge', greeting: 'HISTORY', extensions: scriptStateExtension(initial: 2));
      final chat = await h.engine.createChat(character);
      final historical = (await h.engine.path(chat)).single.nodeId;
      final setup = await h.context(chat, characterId: character, instanceId: 'setup');
      final inheritedData = (await h.bridge.getVariables(
        setup.id,
        TavernVariableTarget(
          scope: TavernVariableScope.message,
          messageRef: TavernScriptMessageRef(chatId: chat, nodeId: historical),
        ),
      )).value;
      await h.bridge.createChatMessages(setup.id, [
        TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'U'),
        TavernScriptMessageDraft(
          role: TavernScriptRole.assistant,
          message: 'CURRENT',
          data: {...inheritedData, 'foreign': 'before'},
        ),
      ]);
      final current = (await h.bridge.getChatMessages(
        setup.id,
        const TavernMessageRange(first: -1),
      )).messages.single.ref;
      await h.engine.setStateValue(chat, '/count', 999);
      await h.bridge.replaceVariables(setup.id, scriptChat, {'counter': 0});
      final stateBefore = (await h.engine.readState(chat)).values;
      final auditBefore = (await h.engine.readAgentRuns(chat)).map((run) => run.id).toList();
      final idsBefore = (await h.engine.path(chat)).map((message) => message.nodeId).toList();
      final context = await h.context(
        chat,
        characterId: character,
        nodeId: historical,
        instanceId: 'historical-iframe',
      );
      final target = TavernVariableTarget(scope: TavernVariableScope.message, messageRef: current);
      final oldData = (await h.bridge.getVariables(setup.id, target)).value;
      final host = GenerationHost();
      host.onInvoke = (request, cancellation) async {
        await h.bridge.replaceVariables(setup.id, target, {
          ...oldData,
          'foreign': ['latest'],
          'stat_data': {'hp': 7},
        });
        return TavernScriptCallbackResult(requestId: request.requestId, status: 'completed', value: true);
      };
      h.bridge.attachHost(host);
      final response = h.reply('BACKGROUND');
      final generation = await h.bridge.generateRaw(
        context.id,
        _input('narrow-merge', '{{incvar::counter}}/{{lastMessage}}', filter: _filter(context)),
      );
      final wire = await generationRequest(generation, response);
      final result = await generation.result;
      expect(generationMessages(wire), [
        {'role': 'user', 'content': '1/CURRENT'},
      ]);
      expect(result.origin.nodeAnchor, current);
      expect(result.origin.nodeAnchor!.nodeId, isNot(historical));
      expect((await h.engine.path(chat)).map((message) => message.nodeId), idsBefore);
      expect((await h.engine.readVariables(chat))['counter'], 1);
      expect((await h.bridge.getVariables(setup.id, target)).value, {
        ...oldData,
        'foreign': ['latest'],
        'stat_data': {'hp': 7},
      });
      expect((await h.engine.readState(chat)).values, stateBefore);
      expect((await h.engine.readAgentRuns(chat)).map((run) => run.id), auditBefore);
      expect(host.invocations, hasLength(1));
      await h.reopen();
      final fresh = await h.context(chat, characterId: character);
      expect((await h.engine.readVariables(chat))['counter'], 1);
      expect((await h.bridge.getVariables(fresh.id, target)).value, {
        ...oldData,
        'foreign': ['latest'],
        'stat_data': {'hp': 7},
      });
      expect((await h.engine.readState(chat)).values, stateBefore);
      expect((await h.engine.readAgentRuns(chat)).map((run) => run.id), auditBefore);
      expect(generationNodes(h, chat), hasLength(3));
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
}

TavernScriptRawRequest _input(String id, String input, {TavernScriptCallbackRef? filter}) => TavernScriptRawRequest(
  generationId: id,
  userInput: input,
  orderedPrompts: const [TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.userInput)],
  injects: [
    if (filter != null)
      TavernScriptInjection(id: 'gate', content: '', position: TavernScriptInjectionPosition.scanOnly, filter: filter),
  ],
);

TavernScriptCallbackRef _filter(TavernScriptContext context) =>
    TavernScriptCallbackRef(contextId: context.id, instanceId: context.instanceId, callbackId: 'capture-boundary');

ScriptJson _receipt(TavernScriptException failure) =>
    failure.issues.singleWhere((issue) => issue.code == 'generationPreparation').details;
