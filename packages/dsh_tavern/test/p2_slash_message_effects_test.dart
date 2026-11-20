import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_slash_test_support.dart';

// Newly authored while the workspace is unavailable. This cloud source is a
// draft, not an applied or executed patch and not recovered historical tests.
void main() {
  test('messages returns saved text without display regex or macro adoption', () async {
    final h = await slashFixture();
    final actor = await h.card('Saved source');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(
        role: TavernScriptRole.assistant,
        name: 'Saved assistant',
        message: '{{incglobalvar::readLeak}} SRC',
        extra: {'keep': 'first'},
      ),
      TavernScriptMessageDraft(
        role: TavernScriptRole.user,
        name: 'Saved user',
        message: 'TAIL',
        extra: {
          'keep': [1, null],
        },
      ),
    ]);
    await h.engine.setSettings({
      'globalRegexScripts': [
        {
          'id': 'source-display-witness',
          'scriptName': 'source-display-witness',
          'findRegex': 'SRC',
          'replaceString': 'DISPLAY',
          'placement': [2],
          'trimStrings': <String>[],
          'disabled': false,
          'markdownOnly': true,
          'promptOnly': false,
          'runOnEdit': true,
          'substituteRegex': 0,
        },
      ],
    });
    final before = await _allMessages(h, context.id);
    final rowsBefore = generationNodes(h, chat);
    // This ordinary positive witness does not evaluate the stored macro text.
    final display = await h.bridge.formatAsTavernRegexedString(
      context.id,
      'SRC',
      source: 2,
      destination: RegexPhase.display,
    );
    expect(display.text, 'DISPLAY');

    final result = await slashRun(h, context.id, '/messages names=false 0-1');
    expect(result.pipe, '{{incglobalvar::readLeak}} SRC\n\nTAIL');
    expect(result.effects.committed, isFalse);
    expect(_pageState(await _allMessages(h, context.id)), _pageState(before));
    expect(generationNodes(h, chat), rowsBefore);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, isEmpty);
    h.expectNoGeneration();
    stdout.writeln('P2_B3_MESSAGE_EFFECTS_READY');
  });

  test('hide and unhide roll back their complete real hidden UPDATE on failure', () async {
    final h = await slashFixture();
    final actor = await h.card('Atomic hidden');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(
        role: TavernScriptRole.user,
        name: 'User name',
        message: 'USER',
        extra: {
          'keep': [1, null],
        },
      ),
      TavernScriptMessageDraft(
        role: TavernScriptRole.assistant,
        name: 'Assistant name',
        message: 'ASSISTANT',
        data: {'stable': 'data'},
        extra: {'keep': 'assistant'},
      ),
    ]);
    final original = await _allMessages(h, context.id);
    final originalPayloads = original.messages.map(_messagePayload).toList();
    final blockedId = original.messages.last.ref.nodeId.replaceAll("'", "''");
    for (final item in const [
      (command: 'hide', hidden: true, sqlValue: 1),
      (command: 'unhide', hidden: false, sqlValue: 0),
    ]) {
      final before = await _allMessages(h, context.id);
      final rowsBefore = generationNodes(h, chat);
      final selectedBefore = (await h.engine.path(chat)).map((m) => m.nodeId).toList();
      final value = item.sqlValue;
      h.inspect(
        (db) => db.execute("""
        CREATE TRIGGER b3_hidden_abort BEFORE UPDATE OF hidden ON nodes
        WHEN NEW.id = '$blockedId' AND NEW.hidden = $value
        BEGIN SELECT RAISE(ABORT, 'B3 hidden fixture abort'); END
      """),
        writable: true,
      );
      try {
        final command = item.command;
        final execution = await h.bridge.triggerSlash(context.id, '/$command 0-1');
        final error = await slashFailure(execution);
        expect(error.code, TavernScriptErrorCode.storage);
        expect(error.committed, isFalse);
        final terminal = (await execution.events.toList()).single;
        expect(terminal.effects.committed, isFalse);
        expect(
          terminal.effects.entries.where(
            (effect) => effect.kind == TavernSlashEffectKind.storage && effect.state == TavernSlashEffectState.adopted,
          ),
          isEmpty,
        );
        expect(_pageState(await _allMessages(h, context.id)), _pageState(before));
        expect(generationNodes(h, chat), rowsBefore);
        expect((await h.engine.path(chat)).map((m) => m.nodeId).toList(), selectedBefore);
      } finally {
        h.inspect((db) => db.execute('DROP TRIGGER IF EXISTS b3_hidden_abort'), writable: true);
      }
      final command = item.command;
      final success = await slashRun(h, context.id, '/$command 0-1');
      expect(success.pipe, '');
      final after = await _allMessages(h, context.id);
      expect(after.messages.map((m) => m.hidden), [item.hidden, item.hidden]);
      expect(generationNodes(h, chat).map((row) => row['hidden']), [value, value]);
      expect(after.messages.map(_messagePayload).toList(), originalPayloads);
    }
    await h.reopen();
    final fresh = await h.context(chat, characterId: actor);
    final reopened = await _allMessages(h, fresh.id);
    expect(reopened.messages.map((m) => m.hidden), [false, false]);
    expect(reopened.messages.map(_messagePayload).toList(), originalPayloads);
    h.expectNoGeneration();
  });

  test('cut and del keep count grammar and publish text only after real DELETE succeeds', () async {
    final h = await slashFixture();
    final actor = await h.card('Atomic deletion');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.createChatMessages(context.id, [
      for (final text in const ['A', 'B', 'C', 'D'])
        TavernScriptMessageDraft(
          role: TavernScriptRole.assistant,
          name: 'Page $text',
          message: text,
          extra: {'keep': text},
        ),
    ]);
    final before = await _allMessages(h, context.id);
    final rowsBefore = generationNodes(h, chat);
    final selectedBefore = (await h.engine.path(chat)).map((m) => m.nodeId).toList();
    final empty = await slashFailure(await h.bridge.triggerSlash(context.id, '/del'));
    expect(empty.code, TavernScriptErrorCode.unsupportedOption);
    expect(empty.committed, isFalse);
    const invalidCounts = <String, TavernScriptErrorCode>{
      ' \t\u00a0': TavernScriptErrorCode.invalidArgument,
      '0': TavernScriptErrorCode.invalidArgument,
      '-1': TavernScriptErrorCode.invalidArgument,
      '1.5': TavernScriptErrorCode.invalidArgument,
      'Infinity': TavernScriptErrorCode.invalidArgument,
      '5': TavernScriptErrorCode.range,
    };
    for (final item in invalidCounts.entries) {
      final error = await slashFailure(
        await h.bridge.triggerSlash(context.id, '/del {{arg::count}}', arguments: {'count': item.key}),
      );
      expect(error.code, item.value, reason: item.key);
      expect(error.committed, isFalse, reason: item.key);
      expect(_pageState(await _allMessages(h, context.id)), _pageState(before));
      expect(generationNodes(h, chat), rowsBefore);
    }
    final blockedId = before.messages[2].ref.nodeId.replaceAll("'", "''");
    h.inspect(
      (db) => db.execute("""
      CREATE TRIGGER b3_delete_abort BEFORE DELETE ON nodes
      WHEN OLD.id = '$blockedId'
      BEGIN SELECT RAISE(ABORT, 'B3 delete fixture abort'); END
    """),
      writable: true,
    );
    try {
      for (final source in const ['/cut 1-2', '/del 2e0']) {
        final execution = await h.bridge.triggerSlash(context.id, source, pipe: 'KEEP-PIPE');
        final error = await slashFailure(execution);
        expect(error.code, TavernScriptErrorCode.storage, reason: source);
        expect(error.committed, isFalse, reason: source);
        final terminal = (await execution.events.toList()).single;
        expect(terminal.pipe, 'KEEP-PIPE');
        expect(terminal.effects.committed, isFalse);
        expect(
          terminal.effects.entries.where(
            (effect) => effect.kind == TavernSlashEffectKind.storage && effect.state == TavernSlashEffectState.adopted,
          ),
          isEmpty,
        );
        expect(_pageState(await _allMessages(h, context.id)), _pageState(before));
        expect(generationNodes(h, chat), rowsBefore);
        expect((await h.engine.path(chat)).map((m) => m.nodeId).toList(), selectedBefore);
      }
    } finally {
      h.inspect((db) => db.execute('DROP TRIGGER IF EXISTS b3_delete_abort'), writable: true);
    }
    // del uses a finite positive integral JS Number, unlike the range grammar.
    expect((await slashRun(h, context.id, '/del 2e0')).pipe, 'C\nD\n');
    expect((await _allMessages(h, context.id)).messages.map((m) => m.message), ['A', 'B']);
    expect((await slashRun(h, context.id, '/cut 1')).pipe, 'B\n');
    final after = await _allMessages(h, context.id);
    expect(after.messages, hasLength(1));
    expect(_messagePayload(after.messages.single), _messagePayload(before.messages.first));
    await h.reopen();
    final fresh = await h.context(chat, characterId: actor);
    final reopened = await _allMessages(h, fresh.id);
    expect(reopened.messages, hasLength(1));
    expect(_messagePayload(reopened.messages.single), _messagePayload(before.messages.first));
    h.expectNoGeneration();
  });

  test('tool preflight allows selected tool pages unrelated history and explicit del off', () async {
    final h = await slashFixture();
    final actor = await h.card('Finite tool deletion');
    final cases = [
      (
        drafts: [
          TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'KEEP', extra: {'keep': 1}),
          TavernScriptMessageDraft(
            role: TavernScriptRole.system,
            message: 'TOOL',
            extra: {'tool_invocations': <Object?>[], 'keep': 2},
          ),
          TavernScriptMessageDraft(role: TavernScriptRole.assistant, message: 'A', extra: {'keep': 3}),
        ],
        source: '/cut 1-2',
        pipe: 'TOOL\nA\n',
        keep: [0],
      ),
      (
        drafts: [
          TavernScriptMessageDraft(
            role: TavernScriptRole.system,
            message: 'TOOL',
            extra: {'tool_invocations': <Object?>[], 'keep': 4},
          ),
          TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'U', extra: {'keep': 5}),
          TavernScriptMessageDraft(role: TavernScriptRole.assistant, message: 'A', extra: {'keep': 6}),
        ],
        source: '/del 1',
        pipe: 'A\n',
        keep: [0, 1],
      ),
      (
        drafts: [
          TavernScriptMessageDraft(
            role: TavernScriptRole.system,
            message: 'TOOL',
            extra: {'tool_invocations': <Object?>[], 'keep': 7},
          ),
          TavernScriptMessageDraft(role: TavernScriptRole.assistant, message: 'A', extra: {'keep': 8}),
        ],
        source: '/del toolcalls=" OFF " 1',
        pipe: 'A\n',
        keep: [0],
      ),
    ];
    for (final item in cases) {
      final chat = await h.emptyChat(actor);
      final context = await h.context(chat, characterId: actor);
      await h.bridge.createChatMessages(context.id, item.drafts);
      final before = await _allMessages(h, context.id);
      final tool = before.messages.singleWhere((message) => message.message == 'TOOL');
      expect(tool.nativeRole, TavernRole.system);
      expect(tool.extra['tool_invocations'], <Object?>[]);
      final expected = [for (final index in item.keep) before.messages[index]];
      final result = await slashRun(h, context.id, item.source);
      expect(result.pipe, item.pipe, reason: item.source);
      final after = await _allMessages(h, context.id);
      expect(after.messages.map(_messagePayload).toList(), expected.map(_messagePayload).toList(), reason: item.source);
      expect(after.messages.map((m) => m.hidden), expected.map((m) => m.hidden));
      expect(generationNodes(h, chat).map((row) => row['id']).toSet(), expected.map((m) => m.ref.nodeId).toSet());
    }
    h.expectNoGeneration();
  });

  test('public macro adopts file and SQL before its held cache ACK and String result', () async {
    final h = await slashFixture();
    final actor = await h.card('Public macro cache');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final host = ScriptHost();
    final entered = Completer<TavernScriptDispatch>();
    final release = Completer<void>();
    Future<String>? running;
    var finished = false;
    addTearDown(() async {
      if (!release.isCompleted) {
        release.complete();
      }
      final pending = running;
      if (pending != null) {
        if (!finished) {
          await h.bridge.closeContext(context.id);
        }
        try {
          await pending;
        } catch (_) {
          // The original awaited operation already owns its test failure.
        }
      }
    });
    host.onDispatch = (request, cancellation) async {
      if (request.kind == TavernScriptDispatchKind.cache && !entered.isCompleted) {
        final snapshot = await h.bridge.snapshot(context.id);
        final hasGlobal = snapshot.variableSnapshots.any(
          (value) => value.resolvedTarget.scope == TavernVariableScope.global && value.value['pubGlobal'] == 'G',
        );
        final hasLocal = snapshot.variableSnapshots.any(
          (value) =>
              value.resolvedTarget.scope == TavernVariableScope.chat &&
              value.resolvedTarget.chatId == chat &&
              value.value['pubLocal'] == 'L',
        );
        if (hasGlobal && hasLocal) {
          entered.complete(request);
          await release.future;
        }
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    final future = h.bridge
        .substituteMacros(context.id, '{{setglobalvar::pubGlobal::G}}{{setvar::pubLocal::L}}OK')
        .whenComplete(() {
          finished = true;
        });
    running = future;
    final delivery = await Future.any<TavernScriptDispatch>([
      entered.future,
      future.then<TavernScriptDispatch>(
        (_) => throw TestFailure('Public macro returned before the matching cache boundary.'),
      ),
    ]);
    expect(delivery.kind, TavernScriptDispatchKind.cache);
    expect(scriptMap((await h.settingsDocument())['globalVariables']), {'pubGlobal': 'G'});
    expect(_chatVariables(h, chat), {'pubLocal': 'L'});
    expect(finished, isFalse);
    expect(await h.engine.path(chat), isEmpty);
    release.complete();
    expect(await future, 'OK');
    expect(finished, isTrue);
    h.bridge.attachHost(null);
    await h.reopen();
    final fresh = await h.context(chat, characterId: actor);
    expect((await h.bridge.getVariables(fresh.id, scriptGlobal)).value, {'pubGlobal': 'G'});
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value, {'pubLocal': 'L'});
    h.expectNoGeneration();
  });

  test('public macro preserves a real global to SQL partial without replaying its random draw', () async {
    final h = await slashFixture();
    final actor = await h.card('Public macro partial');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, isEmpty);
    expect((await h.bridge.getVariables(context.id, scriptChat)).value, isEmpty);
    final storedBefore = _chatVariables(h, chat);
    final quotedChat = chat.replaceAll("'", "''");
    var draws = 0;
    h.onRandom = () {
      draws++;
    };
    h.inspect(
      (db) => db.execute("""
      CREATE TRIGGER b3_public_macro_abort BEFORE UPDATE OF variables ON chats
      WHEN NEW.id = '$quotedChat'
      BEGIN SELECT RAISE(ABORT, 'B3 public macro fixture abort'); END
    """),
      writable: true,
    );
    try {
      final error = await _macroFailure(
        h.bridge.substituteMacros(context.id, '{{incglobalvar::pubCount}}{{setvar::pubLocal::L}}{{random::A::B}}'),
      );
      expect(error.code, TavernScriptErrorCode.storage);
      expect(error.committed, isTrue);
      expect(error.executionId, isNull);
      expect(draws, 1);
      expect(scriptMap((await h.settingsDocument())['globalVariables']), {'pubCount': 1});
      expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'pubCount': 1});
      expect(_chatVariables(h, chat), storedBefore);
      expect((await h.bridge.getVariables(context.id, scriptChat)).value, isEmpty);
      expect(await h.engine.path(chat), isEmpty);
    } finally {
      h.inspect((db) => db.execute('DROP TRIGGER IF EXISTS b3_public_macro_abort'), writable: true);
    }
    await h.reopen();
    final fresh = await h.context(chat, characterId: actor);
    expect(scriptMap((await h.settingsDocument())['globalVariables']), {'pubCount': 1});
    expect((await h.bridge.getVariables(fresh.id, scriptGlobal)).value, {'pubCount': 1});
    expect(_chatVariables(h, chat), storedBefore);
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value, isEmpty);
    expect(await h.engine.path(chat), isEmpty);
    expect(draws, 1);
    h.expectNoGeneration();
  });
}

Future<TavernScriptMessagePage> _allMessages(ScriptFixture h, String contextId) =>
    h.bridge.getChatMessages(contextId, const TavernMessageRange(), hidden: TavernHiddenFilter.all);

ScriptJson _messagePayload(TavernScriptMessage message) => {
  'chatId': message.ref.chatId,
  'nodeId': message.ref.nodeId,
  'name': message.name,
  'role': message.role.name,
  'nativeRole': message.nativeRole.name,
  'message': message.message,
  'speakerCharacterId': message.speakerCharacterId,
  'extra': message.extra,
  'hasData': message.hasData,
  'rawData': message.rawData,
  'swipeId': message.swipeId,
};

ScriptJson _pageState(TavernScriptMessagePage page) => {
  'pathRevision': page.pathRevision,
  'totalPathLength': page.totalPathLength,
  'messages': [
    for (final message in page.messages)
      {..._messagePayload(message), 'messageId': message.messageId, 'hidden': message.hidden},
  ],
};

ScriptJson _chatVariables(ScriptFixture h, String chatId) => h.inspect(
  (db) => scriptMap(
    jsonDecode(db.select('SELECT variables FROM chats WHERE id = ?', [chatId]).single['variables'] as String),
  ),
);

Future<TavernScriptException> _macroFailure(Future<String> result) async {
  try {
    await result;
  } on TavernScriptException catch (error) {
    return error;
  }
  throw TestFailure('Expected a structured public macro failure.');
}
