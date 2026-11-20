import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_slash_test_support.dart';

// Newly authored tests. These do not recover the unavailable earlier 29 tests.
void main() {
  test('a genuine scoped closure survives public pipe projection and runs exactly once', () async {
    final h = await slashFixture();
    final actor = await h.card('Typed pipe');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    var draws = 0;
    h.onRandom = () {
      draws++;
    };
    final execution = await h.bridge.triggerSlash(
      context.id,
      'f={: /pass {{incglobalvar::called}}{{random::A::B}} :} '
      '/pass {{var::f}} | /run',
    );
    final events = ScriptEvents(execution.events);
    final result = await execution.result;
    await events.done.future;
    expect(result.pipe, '1A');
    expect(result.completion, TavernSlashCompletion.completed);
    expect(result.effects.committed, isTrue);
    expect(draws, 1);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'called': 1});
    expect(
      events.values.where((event) => event.kind == TavernSlashExecutionEventKind.command && event.pipe == '[Closure]'),
      hasLength(1),
    );
    expect(events.values.where((event) => event.kind == TavernSlashExecutionEventKind.failed), isEmpty);
    final late = await execution.events.toList();
    expect(late, hasLength(1));
    expect(late.single.kind, TavernSlashExecutionEventKind.snapshot);
    expect(late.single.pipe, '1A');
    expect(draws, 1);
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
    stdout.writeln('P2_B3_TYPED_READY');
  });

  test('opaque text equal to the old private marker cannot acquire a local closure', () async {
    final h = await slashFixture();
    final actor = await h.card('Opaque marker');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final host = SlashHost()..onResolve = (_, _) async => null;
    h.bridge.attachHost(host);
    const marker = '\u0000dshgoSlash:0\u0000';
    final execution = await h.bridge.triggerSlash(
      context.id,
      'f={: /setglobalvar key=called BAD | /pass TYPED_TARGET :} '
      '/run {{setvar::sink::{{var::f}}}}{{arg::marker}}',
      arguments: const {'marker': marker},
    );
    final error = await slashFailure(execution);
    expect(error.code, TavernScriptErrorCode.notFound);
    expect(error.committed, isTrue);
    expect(host.resolutions, hasLength(1));
    expect(host.resolutions.single.label, marker);
    expect((await h.bridge.getVariables(context.id, scriptChat)).value['sink'], '[Closure]');
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value.containsKey('called'), isFalse);
    await h.reopen();
    final reopened = await h.context(chat, characterId: actor);
    expect((await h.bridge.getVariables(reopened.id, scriptChat)).value['sink'], '[Closure]');
    expect((await h.bridge.getVariables(reopened.id, scriptGlobal)).value.containsKey('called'), isFalse);
    h.expectNoGeneration();
  });

  test('an ordinary setvar getvar roundtrip cannot restore a callable without knowing its marker', () async {
    final h = await slashFixture();
    final actor = await h.card('String roundtrip');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final host = SlashHost()..onResolve = (_, _) async => null;
    h.bridge.attachHost(host);
    final execution = await h.bridge.triggerSlash(
      context.id,
      'f={: /setglobalvar key=called BAD | /pass TYPED_TARGET :} '
      '/run {{setvar::sink::{{var::f}}}}{{getvar::sink}}',
    );
    final error = await slashFailure(execution);
    expect(error.code, TavernScriptErrorCode.notFound);
    expect(error.committed, isTrue);
    expect(host.resolutions, hasLength(1));
    expect(host.resolutions.single.label, '[Closure]');
    expect((await h.bridge.getVariables(context.id, scriptChat)).value['sink'], '[Closure]');
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value.containsKey('called'), isFalse);
    await h.reopen();
    final reopened = await h.context(chat, characterId: actor);
    expect((await h.bridge.getVariables(reopened.id, scriptChat)).value['sink'], '[Closure]');
    expect((await h.bridge.getVariables(reopened.id, scriptGlobal)).value.containsKey('called'), isFalse);
    h.expectNoGeneration();
  });

  test('a public closure projection reused as an argument follows ordinary reference lookup', () async {
    final h = await slashFixture();
    final actor = await h.card('Public projection');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    var draws = 0;
    h.onRandom = () {
      draws++;
    };
    final projected = await slashRun(h, context.id, '/pass {: /pass {{setglobalvar::called::BAD}}{{random::A::B}} :}');
    expect(projected.pipe, '[Closure]');
    expect(projected.effects.committed, isFalse);
    expect(draws, 0);
    final host = SlashHost()..onResolve = (_, _) async => null;
    h.bridge.attachHost(host);
    final execution = await h.bridge.triggerSlash(
      context.id,
      'f={: /pass {{setglobalvar::called::BAD}}{{random::A::B}} :} /run {{arg::text}}',
      arguments: {'text': projected.pipe},
    );
    final error = await slashFailure(execution);
    expect(error.code, TavernScriptErrorCode.notFound);
    expect(error.committed, isFalse);
    expect(host.resolutions.single.label, '[Closure]');
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value.containsKey('called'), isFalse);
    expect(draws, 0);
    h.expectNoGeneration();
  });

  test('ordinary if consumes the selected closure as text and evaluates each selected effect once', () async {
    final h = await slashFixture();
    final actor = await h.card('Selected ordinary if');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final host = SlashHost()..onResolve = (_, _) async => null;
    h.bridge.attachHost(host);
    var draws = 0;
    h.onRandom = () {
      draws++;
    };
    final execution = await h.bridge.triggerSlash(
      context.id,
      'f={: /setglobalvar key=body BAD :} /run '
      '{{if::true}}{{setglobalvar::chosen::{{incglobalvar::count}}}}'
      '{{setglobalvar::draw::{{random::A::B}}}}{{var::f}}'
      '{{else}}{{setglobalvar::unselected::BAD}}{{random::A::B}}{{/if}}',
    );
    final error = await slashFailure(execution);
    expect(error.code, TavernScriptErrorCode.notFound);
    expect(error.committed, isTrue);
    expect(host.resolutions, hasLength(1));
    expect(host.resolutions.single.label, '[Closure]');
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'count': 1, 'chosen': '1', 'draw': 'A'});
    expect(draws, 1);
    h.expectNoGeneration();
  });

  test('ordinary if leaves its unselected typed branch and side effects unevaluated', () async {
    final h = await slashFixture();
    final actor = await h.card('Unselected ordinary if');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    var draws = 0;
    h.onRandom = () {
      draws++;
    };
    final result = await slashRun(
      h,
      context.id,
      'f={: /pass {{setglobalvar::body::BAD}} :} /pass '
      '{{if::false}}{{setglobalvar::unselected::BAD}}{{random::A::B}}{{var::f}}'
      '{{else}}TEXT{{/if}}',
    );
    expect(result.pipe, 'TEXT');
    expect(result.effects.committed, isFalse);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, isEmpty);
    expect(draws, 0);
    h.expectNoGeneration();
  });

  test('ordinary fallback and adjacent text processors never create typed identity', () async {
    final h = await slashFixture();
    final actor = await h.card('String processing');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final fallback = await slashRun(
      h,
      context.id,
      'f={: /pass {{setglobalvar::body::BAD}} :} /pass {{unknown::{{var::f}}}}',
    );
    expect(fallback.pipe, '{{unknown::[Closure]}}');
    final braces = await slashRun(
      h,
      context.id,
      '/pass {{arg::left}}{{arg::right}}',
      arguments: const {'left': '\\', 'right': '{'},
    );
    expect(braces.pipe, '{');
    final trim = await slashRun(
      h,
      context.id,
      '/pass {{arg::left}}{{arg::right}}',
      arguments: const {'left': '\n{{tr', 'right': 'im}}\nX'},
    );
    expect(trim.pipe, 'X');
    expect(await h.bridge.substituteMacros(context.id, '{{var::f}}|{{arg::literal}}'), '{{var::f}}|{{arg::literal}}');
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, isEmpty);
    h.expectNoGeneration();
  });

  test('a composite containing a real closure fails at its producer and preserves the safe snapshot', () async {
    final h = await slashFixture();
    final actor = await h.card('Composite boundary');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    const source =
        'f={: /pass {{setglobalvar::body::BAD}} :} '
        '/pass KEEP | /pass {{arg::left}}{{var::f}}{{arg::right}}';
    final execution = await h.bridge.triggerSlash(context.id, source, arguments: const {'left': '\\', 'right': '{'});
    final events = ScriptEvents(execution.events);
    final error = await slashFailure(execution);
    await events.done.future;
    expect(error.code, TavernScriptErrorCode.shapeMismatch);
    expect(error.committed, isFalse);
    expect(error.sourceSpan, isNotNull);
    expect(error.sourceSpan!.start, source.lastIndexOf('/pass'));
    final terminal = events.values.singleWhere((event) => event.kind == TavernSlashExecutionEventKind.failed);
    expect(terminal.pipe, isNull);
    expect(terminal.error!.code, TavernScriptErrorCode.shapeMismatch);
    final late = await execution.events.toList();
    expect(late, hasLength(1));
    expect(late.single.kind, TavernSlashExecutionEventKind.snapshot);
    expect(late.single.status, TavernSlashStatus.failed);
    expect(late.single.pipe, 'KEEP');
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, isEmpty);
    h.expectNoGeneration();
  });

  test('modern indexed lexical values keep leading zeros while the selected legacy lookup ignores its index', () async {
    final h = await slashFixture();
    final actor = await h.card('Scoped modes');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    const source = 'x=["007","B"] /pass {{var::x::0}}';
    expect((await slashRun(h, context.id, source)).pipe, '007');
    expect((await slashRun(h, context.id, '/pass {{var::missing}}')).pipe, '');
    await h.engine.setSettings({'macroEngine': 'legacy'});
    expect((await slashRun(h, context.id, source)).pipe, '["007","B"]');
    final missing = await slashFailure(await h.bridge.triggerSlash(context.id, '/pass {{var::missing}}'));
    expect(missing.committed, isFalse);
    expect(missing.sourceSpan, isNotNull);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, isEmpty);
    h.expectNoGeneration();
  });
}
