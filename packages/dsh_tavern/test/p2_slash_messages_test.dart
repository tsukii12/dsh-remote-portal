import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_slash_test_support.dart';

void main() {
  test('manual phases use the right regex placement and run body macros once', () async {
    final h = await slashFixture();
    final actor = await h.card('Context actor');
    final speaker = await h.card('Other actor');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.engine.setSettings({
      'globalRegexScripts': [_messageRegex('user', 'SRC', 'USER', 1), _messageRegex('slash', 'SRC', 'AS', 3)],
    });
    const body = '  SRC {{char}} {{incglobalvar::manualCount}}  ';
    final sent = _object(
      await slashRun(h, context.id, '/send name="" return=object {{arg::body}}', arguments: const {'body': body}),
    );
    final asRow = _object(
      await slashRun(
        h,
        context.id,
        '/sendas name="Other actor" return=object {{arg::body}}',
        arguments: const {'body': body},
      ),
    );
    final sys = _object(
      await slashRun(h, context.id, '/sys name="" return=object {{arg::body}}', arguments: const {'body': body}),
    );
    final note = _object(
      await slashRun(h, context.id, '/comment return=object {{arg::body}}', arguments: const {'body': body}),
    );
    expect(sent['mes'], 'USER Context actor 1');
    expect(sent['name'], '');
    expect(sent['is_user'], isTrue);
    expect(asRow['mes'], 'AS Context actor 2');
    expect(asRow['name'], 'Other actor');
    expect(sys['mes'], 'SRC Context actor 3');
    expect(sys['name'], '');
    expect(note['mes'], 'SRC Context actor 4');
    expect(note['name'], 'Note');
    final path = await h.engine.path(chat);
    expect(path.map((m) => m.role), [TavernRole.user, TavernRole.character, TavernRole.narrator, TavernRole.system]);
    expect(path.map((m) => m.speakerCharacterId), [null, speaker, null, null]);
    expect(scriptMap(sys['extra'])['type'], 'narrator');
    expect(scriptMap(note['extra'])['type'], 'comment');
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value['manualCount'], 4);
    expect(scriptMap((await h.settingsDocument())['globalVariables'])['manualCount'], 4);
    h.expectNoGeneration();
  });

  test('bias is taken before user regex and after sendas regex while empty pages still save', () async {
    final h = await slashFixture();
    final actor = await h.card('Bias phases');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.engine.setSettings({
      'globalRegexScripts': [_messageRegex('bias-user', 'OLD', 'NEW', 1), _messageRegex('bias-as', 'OLD', 'NEW', 3)],
    });
    const body = '{{bias "OLD"}}';
    final user = _object(
      await slashRun(h, context.id, '/send return=object {{arg::body}}', arguments: const {'body': body}),
    );
    final actorRow = _object(
      await slashRun(h, context.id, '/sendas return=object {{arg::body}}', arguments: const {'body': body}),
    );
    final narrator = _object(
      await slashRun(h, context.id, '/sys return=object {{arg::body}}', arguments: const {'body': body}),
    );
    expect(scriptMap(user['extra'])['bias'], ' OLD');
    expect(scriptMap(actorRow['extra'])['bias'], ' NEW');
    expect(scriptMap(narrator['extra'])['bias'], ' OLD');
    expect(user['mes'], '');
    final path = await h.engine.path(chat);
    expect(path, hasLength(3));
    expect(path.map((m) => m.hidden), [false, true, true]);
    expect(path.map((m) => m.role), [TavernRole.user, TavernRole.character, TavernRole.narrator]);
    expect(path[1].speakerCharacterId, actor);
    // These Dart escapes become actual LF characters before the public call.
    // Fixed HB accepts the token but keeps its brackets because /^\[.*\]$/
    // does not match across LF; the differently named inline partial is absent.
    const lineBreakName = '{{#*inline "p\nq"}}{{bias "HIT"}}{{/inline}}{{> [p\nq]}}';
    const ordinaryName = '{{#*inline "p"}}{{bias "HIT"}}{{/inline}}{{> [p]}}';
    final missingPartial = _object(
      await slashRun(h, context.id, '/send return=object {{arg::body}}', arguments: const {'body': lineBreakName}),
    );
    final ordinaryPartial = _object(
      await slashRun(h, context.id, '/send return=object {{arg::body}}', arguments: const {'body': ordinaryName}),
    );
    expect(scriptMap(missingPartial['extra']).containsKey('bias'), isFalse);
    expect(scriptMap(ordinaryPartial['extra'])['bias'], ' HIT');
    final ordinaryElsePrefix = _object(
      await slashRun(
        h,
        context.id,
        '/send return=object {{arg::body}}',
        arguments: const {'body': '{{bias "BEFORE"}}{{elseif}}'},
      ),
    );
    expect(scriptMap(ordinaryElsePrefix['extra'])['bias'], ' BEFORE');
    // The fixed quoted-token rule can backtrack, leaving the trailing
    // backslash in the literal; final bias is space, A, backslash.
    const backtrackedQuote = r'{{bias "A\"}}';
    final quotedTail = _object(
      await slashRun(h, context.id, '/send return=object {{arg::body}}', arguments: const {'body': backtrackedQuote}),
    );
    expect((scriptMap(quotedTail['extra'])['bias'] as String).codeUnits, [0x20, 0x41, 0x5c]);
    expect((await h.engine.path(chat)), hasLength(7));
    h.expectNoGeneration();
  });

  test('insertion distinguishes positive zero negative zero explicit empty and append', () async {
    final h = await slashFixture();
    final actor = await h.card('Slots');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'BASE'),
    ]);
    expect((await slashRun(h, context.id, '/comment at=0 return=pipe FIRST')).pipe, 'FIRST');
    expect((await slashRun(h, context.id, '/comment at=-0 return=pipe LAST')).pipe, 'LAST');
    expect((await slashRun(h, context.id, '/comment at="" return=pipe EMPTY-SLOT')).pipe, 'EMPTY-SLOT');
    final empty = _object(
      await slashRun(h, context.id, '/comment return=object {{arg::blank}}', arguments: const {'blank': '\u00a0 \t'}),
    );
    expect(empty['mes'], '');
    expect((await h.engine.path(chat)).map((m) => m.text), ['EMPTY-SLOT', 'FIRST', 'BASE', 'LAST', '']);
    await h.reopen();
    expect((await h.engine.path(chat)).map((m) => m.text), ['EMPTY-SLOT', 'FIRST', 'BASE', 'LAST', '']);
    h.expectNoGeneration();
  });

  test('known invalid manual options fail before the handler text unit', () async {
    final h = await slashFixture();
    final actor = await h.card('Preflight');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await slashRun(h, context.id, '/setglobalvar key=earlier KEPT');
    const cases = <String, TavernScriptErrorCode>{
      'return=console': TavernScriptErrorCode.unsupportedOption,
      'return=""': TavernScriptErrorCode.unsupportedOption,
      'return=PIPE': TavernScriptErrorCode.unsupportedOption,
      'at=1.5': TavernScriptErrorCode.invalidArgument,
      'at=Infinity': TavernScriptErrorCode.invalidArgument,
      'at=-1': TavernScriptErrorCode.range,
    };
    for (final item in cases.entries) {
      final option = item.key;
      final execution = await h.bridge.triggerSlash(
        context.id,
        '/send $option {{arg::body}}',
        arguments: const {'body': '{{setglobalvar::handlerLeak::BAD}}TEXT'},
      );
      final error = await slashFailure(execution);
      expect(error.code, item.value, reason: option);
      expect(error.committed, isFalse, reason: option);
      expect(await h.engine.path(chat), isEmpty);
      expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'earlier': 'KEPT'});
    }
    h.expectNoGeneration();
  });

  test('real message INSERT failure retains already adopted handler macro effects', () async {
    final h = await slashFixture();
    final actor = await h.card('Separate units');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    h.inspect(
      (db) => db.execute("""
      CREATE TRIGGER slash_message_abort BEFORE INSERT ON nodes
      WHEN NEW.text = 'SQL-ABORT'
      BEGIN SELECT RAISE(ABORT, 'slash message fixture abort'); END
    """),
      writable: true,
    );
    try {
      final execution = await h.bridge.triggerSlash(
        context.id,
        '/send return=pipe {{arg::body}}',
        arguments: const {'body': '{{setglobalvar::kept::YES}}{{setvar::localKept::YES}}SQL-ABORT'},
      );
      final error = await slashFailure(execution);
      expect(error.code, TavernScriptErrorCode.storage);
      expect(error.committed, isTrue);
      final terminal = (await execution.events.toList()).single;
      expect(terminal.effects.committed, isTrue);
      expect(
        terminal.effects.entries.any(
          (effect) => effect.kind == TavernSlashEffectKind.storage && effect.state == TavernSlashEffectState.adopted,
        ),
        isTrue,
      );
      expect(
        terminal.effects.entries.any(
          (effect) => effect.operation == 'createSlashMessage' && effect.state == TavernSlashEffectState.failed,
        ),
        isTrue,
      );
    } finally {
      h.inspect((db) => db.execute('DROP TRIGGER slash_message_abort'), writable: true);
    }
    expect(await h.engine.path(chat), isEmpty);
    expect(await h.engine.searchChat(chat, 'SQL'), isEmpty);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'kept': 'YES'});
    expect((await h.bridge.getVariables(context.id, scriptChat)).value, {'localKept': 'YES'});
    expect(scriptMap((await h.settingsDocument())['globalVariables']), {'kept': 'YES'});
    expect(
      h.inspect(
        (db) => scriptMap(
          jsonDecode(db.select('SELECT variables FROM chats WHERE id = ?', [chat]).single['variables'] as String),
        ),
      ),
      {'localKept': 'YES'},
    );
    await h.reopen();
    final fresh = await h.context(chat, characterId: actor);
    expect(await h.engine.path(chat), isEmpty);
    expect((await h.bridge.getVariables(fresh.id, scriptGlobal)).value, {'kept': 'YES'});
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value, {'localKept': 'YES'});
    h.expectNoGeneration();
  });

  test('all nine return modes preserve one captured source without expanding it again', () async {
    final h = await slashFixture();
    final actor = await h.card('Return modes');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    const opaque = '{{incglobalvar::displayLeak}}';
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'payload': opaque});
    final host = SlashHost();
    host.onInteract = (request, cancellation) async => TavernScriptUiResult(
      requestId: request.requestId,
      status: 'submitted',
      text: request.kind == 'echo' ? request.fields['text']! as String : null,
    );
    h.bridge.attachHost(host);
    const modes = [
      'none',
      'pipe',
      'object',
      'chat-html',
      'chat-text',
      'popup-html',
      'popup-text',
      'toast-html',
      'toast-text',
    ];
    for (final mode in modes) {
      final result = await slashRun(
        h,
        context.id,
        '/comment return=$mode {{arg::body}}',
        arguments: const {'body': '{{getglobalvar::payload}}'},
      );
      expect(result.effects.committed, isTrue);
      if (mode == 'pipe') {
        expect(result.pipe, opaque);
      } else if (mode == 'object') {
        expect(_object(result)['mes'], opaque);
      } else {
        expect(result.pipe, '');
      }
    }
    final pages = (await h.bridge.getChatMessages(context.id, const TavernMessageRange())).messages;
    expect(pages, hasLength(11));
    expect(pages.every((page) => page.message == opaque), isTrue);
    final displays = pages.where((page) => page.name == 'SillyTavern System').toList();
    expect(displays, hasLength(2));
    expect(displays.map((page) => page.nativeRole), everyElement(TavernRole.system));
    expect(displays.map((page) => page.extra['type']), ['generic', 'generic']);
    expect(displays.map((page) => page.extra['dshgo_display']), [
      {'textKind': 'html', 'renderMarkdown': true},
      {'textKind': 'plain', 'renderMarkdown': false},
    ]);
    expect(host.interactions.map((request) => request.kind), ['popup', 'popup', 'echo', 'echo']);
    expect(host.interactions.map((request) => request.fields['text']), everyElement(opaque));
    expect(host.interactions.map((request) => request.fields['textKind']), ['html', 'plain', 'html', 'plain']);
    expect(host.interactions.map((request) => request.fields['renderMarkdown']), [true, false, true, false]);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'payload': opaque});
    h.expectNoGeneration();
  });

  test('host and display SQL failures keep the first actual manual message', () async {
    final h = await slashFixture();
    final actor = await h.card('Display failure');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final missing = await h.bridge.triggerSlash(context.id, '/comment return=popup-html NOHOST');
    final missingError = await slashFailure(missing);
    expect(missingError.code, TavernScriptErrorCode.hostUnavailable);
    expect(missingError.committed, isTrue);
    expect((await h.engine.path(chat)).map((m) => m.text), ['NOHOST']);
    final host = SlashHost();
    host.onInteract = (request, cancellation) async => throw StateError('fixture display failure');
    h.bridge.attachHost(host);
    final failed = await h.bridge.triggerSlash(context.id, '/comment return=toast-text HOSTFAIL');
    final failedError = await slashFailure(failed);
    expect(failedError.code, TavernScriptErrorCode.hookFailure);
    expect(failedError.committed, isTrue);
    expect(host.interactions, hasLength(1));
    h.inspect(
      (db) => db.execute("""
      CREATE TRIGGER slash_display_abort BEFORE INSERT ON nodes
      WHEN NEW.speaker = 'SillyTavern System'
      BEGIN SELECT RAISE(ABORT, 'slash display fixture abort'); END
    """),
      writable: true,
    );
    try {
      final display = await h.bridge.triggerSlash(context.id, '/comment return=chat-text SQLDISPLAY');
      final error = await slashFailure(display);
      expect(error.code, TavernScriptErrorCode.storage);
      expect(error.committed, isTrue);
    } finally {
      h.inspect((db) => db.execute('DROP TRIGGER slash_display_abort'), writable: true);
    }
    expect((await h.engine.path(chat)).map((m) => m.text), ['NOHOST', 'HOSTFAIL', 'SQLDISPLAY']);
    expect(host.interactions, hasLength(1));
    h.expectNoGeneration();
  });

  test('message range numbers precede real native role and hidden filters', () async {
    final h = await slashFixture();
    final actor = await h.card('Filters');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(role: TavernScriptRole.user, name: 'Uname', message: 'U'),
      TavernScriptMessageDraft(
        role: TavernScriptRole.assistant,
        name: 'Aname',
        message: 'A',
        extra: {'type': 'narrator'},
      ),
      TavernScriptMessageDraft(
        role: TavernScriptRole.system,
        name: 'Cname',
        message: 'C',
        hidden: false,
        extra: {'type': 'comment'},
      ),
    ]);
    await h.engine.narrate(chat, 'N', speaker: 'Narr');
    expect((await slashRun(h, context.id, '/messages 00-03')).pipe, 'Uname: U\n\nAname: A\n\nNarr: N');
    expect((await slashRun(h, context.id, '/messages names=false role=system 0-3')).pipe, 'N');
    expect((await slashRun(h, context.id, '/messages names=false role=assistant 0-3')).pipe, 'A');
    expect((await slashRun(h, context.id, '/messages names=false role=assistant hidden=true 0-3')).pipe, 'A\n\nC');
    await slashRun(h, context.id, '/hide');
    await slashRun(h, context.id, '/hide name=" Aname " 0-3');
    expect((await slashRun(h, context.id, '/messages names=false 0-3')).pipe, 'U');
    await slashRun(h, context.id, '/unhide 01');
    expect((await slashRun(h, context.id, '/messages names=false 0-3')).pipe, 'U\n\nA');
    for (final range in ['-1', '1e0', '1x', '1-2-3', '1 - 2', '']) {
      final execution = await h.bridge.triggerSlash(
        context.id,
        '/messages {{arg::range}}',
        arguments: {'range': range},
      );
      expect((await slashFailure(execution)).code, TavernScriptErrorCode.invalidArgument);
    }
    for (final range in ['3-1', '4', '999999999999999999999999999999999']) {
      final execution = await h.bridge.triggerSlash(
        context.id,
        '/messages {{arg::range}}',
        arguments: {'range': range},
      );
      expect((await slashFailure(execution)).code, TavernScriptErrorCode.range);
    }
    expect((await slashRun(h, context.id, '/cut 2-3')).pipe, 'C\nN\n');
    expect((await h.engine.path(chat)).map((m) => m.text), ['U', 'A']);
    h.expectNoGeneration();
  });

  test('default tool cascade preflight accounts for adjacency after earlier selected removal', () async {
    final h = await slashFixture();
    final actor = await h.card('Tool adjacency');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(
        role: TavernScriptRole.system,
        message: 'TOOL',
        extra: {'tool_invocations': <Object?>[]},
      ),
      TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'U'),
      TavernScriptMessageDraft(role: TavernScriptRole.assistant, message: 'A'),
    ]);
    final before = await h.bridge.getChatMessages(context.id, const TavernMessageRange());
    final rejected = await h.bridge.triggerSlash(context.id, '/cut 1-2');
    final error = await slashFailure(rejected);
    expect(error.code, TavernScriptErrorCode.unsupportedCapability);
    expect(error.committed, isFalse);
    final untouched = await h.bridge.getChatMessages(context.id, const TavernMessageRange());
    expect(untouched.pathRevision, before.pathRevision);
    expect(untouched.messages.map((m) => m.message), ['TOOL', 'U', 'A']);
    final bad = await h.bridge.triggerSlash(context.id, '/del toolcalls=unknown 1');
    expect((await slashFailure(bad)).code, TavernScriptErrorCode.unsupportedOption);
    final removed = await slashRun(h, context.id, '/cut toolcalls=false 1-2');
    expect(removed.pipe, 'U\nA\n');
    expect((await h.engine.path(chat)).map((m) => m.text), ['TOOL']);
    h.expectNoGeneration();
  });

  test('manual receipt keeps its SQL snapshot and does not wait for its derived SENT acknowledgement', () async {
    final h = await slashFixture();
    final actor = await h.card('Receipt');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final held = Completer<void>();
    final edited = Completer<void>();
    addTearDown(() {
      if (!held.isCompleted) held.complete();
    });
    final host = SlashHost();
    TavernScriptDispatch? sent;
    var acknowledged = false;
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'MESSAGE_SENT') {
        sent = request;
        await h.bridge.setChatMessages(context.id, [
          TavernScriptMessagePatch(ref: request.nodeRef!, fields: {'message': 'CHANGED'}),
        ]);
        edited.complete();
        await held.future;
        acknowledged = true;
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    final execution = await h.bridge.triggerSlash(context.id, '/send return=object ORIGINAL');
    final result = await execution.result;
    await edited.future;
    expect(_object(result)['mes'], 'ORIGINAL');
    expect((await h.engine.path(chat)).single.text, 'CHANGED');
    expect(sent!.args, [0]);
    expect(sent!.messageId, 0);
    expect(sent!.nodeRef!.nodeId, (await h.engine.path(chat)).single.nodeId);
    expect(acknowledged, isFalse);
    held.complete();
    h.expectNoGeneration();
    stdout.writeln('P2_B3_MESSAGES_READY');
  }, timeout: const Timeout(Duration(seconds: 15)));
}

ScriptJson _object(TavernSlashResult result) => scriptMap(jsonDecode(result.pipe));

ScriptJson _messageRegex(String id, String find, String replace, int placement) => {
  'id': id,
  'scriptName': id,
  'findRegex': find,
  'replaceString': replace,
  'trimStrings': <String>[],
  'placement': [placement],
  'disabled': false,
  'markdownOnly': false,
  'promptOnly': false,
  'runOnEdit': true,
  'substituteRegex': 0,
  'minDepth': null,
  'maxDepth': null,
};
