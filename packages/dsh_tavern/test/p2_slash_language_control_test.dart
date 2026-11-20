import 'dart:async';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_slash_test_support.dart';

// Newly authored public-boundary tests; no historical unavailable test is recovered.
void main() {
  test('complete syntax and structural flags fail before any earlier command can write', () async {
    final h = await slashFixture();
    final actor = await h.card('Full parse');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final cases = <String, TavernScriptErrorCode>{
      '/setglobalvar key=before BAD | /if a=0 {: /pass "unterminated :}': TavernScriptErrorCode.invalidArgument,
      '/setglobalvar key=before BAD | /if a=0 {: /parser-flag\toff :}': TavernScriptErrorCode.unsupportedOption,
    };
    for (final entry in cases.entries) {
      final execution = await h.bridge.triggerSlash(context.id, entry.key);
      final error = await slashFailure(execution);
      expect(error.code, entry.value);
      expect(error.operation, 'parse');
      expect(error.committed, isFalse);
      expect(error.sourceSpan, isNotNull);
      expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, isEmpty);
    }
    h.expectNoGeneration();
  });

  test(
    'command admission rejects unknown names and closed options before their parameters but leaves lazy semantics dormant',
    () async {
      final h = await slashFixture();
      final actor = await h.card('Admission');
      final chat = await h.emptyChat(actor);
      final context = await h.context(chat, characterId: actor);
      var draws = 0;
      h.onRandom = () {
        draws++;
      };
      final unknown = await slashFailure(
        await h.bridge.triggerSlash(
          context.id,
          '/setglobalvar key=earlier OK | /unknown bad="{{setglobalvar::forbidden::BAD}}" {{random::A::B}}',
        ),
      );
      expect(unknown.code, TavernScriptErrorCode.unsupportedCommand);
      expect(unknown.committed, isTrue);
      final option = await slashFailure(
        await h.bridge.triggerSlash(context.id, '/pass bad="{{setglobalvar::forbidden::BAD}}" {{random::A::B}}'),
      );
      expect(option.code, TavernScriptErrorCode.unsupportedOption);
      expect(option.committed, isFalse);
      final lazy = await slashRun(
        h,
        context.id,
        '/if a=0 {: /unknown bad="{{setglobalvar::forbidden::BAD}}" :} | /pass DONE',
      );
      expect(lazy.pipe, 'DONE');
      expect(lazy.effects.committed, isFalse);
      expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'earlier': 'OK'});
      expect(draws, 0);
      h.expectNoGeneration();
    },
  );

  test('source spans retain UTF16 offsets and CRLF line coordinates with a safe failed snapshot', () async {
    final h = await slashFixture();
    final actor = await h.card('Source spans');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    const source = '/pass \u{1f600}\r\n| /unknown {{setglobalvar::bad::X}}';
    final execution = await h.bridge.triggerSlash(context.id, source);
    final error = await slashFailure(execution);
    expect(error.code, TavernScriptErrorCode.unsupportedCommand);
    final span = error.sourceSpan!;
    expect(span.start, source.indexOf('/unknown'));
    expect(span.end, source.length);
    expect(span.line, 2);
    expect(span.column, 3);
    final late = await execution.events.toList();
    expect(late, hasLength(1));
    expect(late.single.pipe, '\u{1f600}');
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, isEmpty);
    h.expectNoGeneration();
  });

  test('all root defaults precede opaque provided values and arg data does not declare lexical names', () async {
    final h = await slashFixture();
    final actor = await h.card('Root binding');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    const payload = '{{setglobalvar::leak::BAD}}OVERRIDE';
    final result = await slashRun(
      h,
      context.id,
      'x="{{setglobalvar::trace::D}}DEFAULT" '
      'y="{{getglobalvar::trace}}{{setglobalvar::trace::DY}}" '
      '/pass {{var::x}};{{var::y}};{{arg::x}};{{var::unused}};{{arg::unused}}',
      arguments: const {'x': payload, 'unused': 'DATA'},
    );
    expect(result.pipe, '$payload;D;$payload;;DATA');
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'trace': 'DY'});
    expect(result.effects.committed, isTrue);
    h.expectNoGeneration();
  });

  test(
    'lexical run adds its provided text phase while literal run ignores named overrides after evaluating them',
    () async {
      final h = await slashFixture();
      final actor = await h.card('Run binding');
      final chat = await h.emptyChat(actor);
      final context = await h.context(chat, characterId: actor);
      final lexical = await slashRun(
        h,
        context.id,
        'f={: x="{{setglobalvar::default::D}}DEFAULT" /pass {{var::x}};{{arg::x}} :} '
        '/run x={{arg::payload}} f',
        arguments: const {'x': 'ROOT', 'payload': '{{incglobalvar::p}}VALUE'},
      );
      expect(lexical.pipe, '1VALUE;ROOT');
      final literal = await slashRun(
        h,
        context.id,
        '/run x="{{setglobalvar::named::N}}OVERRIDE" '
        '{: x="{{setglobalvar::default::D}}DEFAULT" /pass {{var::x}} :}',
      );
      expect(literal.pipe, 'DEFAULT');
      expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'default': 'D', 'p': 1, 'named': 'N'});
      h.expectNoGeneration();
    },
  );

  test('host source uses its own opaque arg namespace and repeated exact args remain ordinary data', () async {
    final h = await slashFixture();
    final actor = await h.card('Host binding');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final host = SlashHost()
      ..onResolve = (_, _) async => const TavernResolvedSlash(
        assetId: 'binding-source',
        version: 'v1',
        source:
            'x="{{setglobalvar::default::D}}DEFAULT" '
            '/pass {{var::x}};{{arg::x}};{{arg::args}};{{arg::_scope}};{{arg::unused}}',
      );
    h.bridge.attachHost(host);
    const payload = '{{incglobalvar::p}}VALUE';
    final result = await slashRun(
      h,
      context.id,
      '/run x={{arg::payload}} args=A args=B _scope=DATA external',
      arguments: const {'payload': payload, 'unused': 'ROOT'},
    );
    expect(result.pipe, '$payload;$payload;A,B;DATA;');
    expect(host.resolutions, hasLength(1));
    expect(host.resolutions.single.setName, isNull);
    expect(host.resolutions.single.label, 'external');
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'default': 'D'});
    h.expectNoGeneration();
  });

  test(
    'implicit pipe suppression, child first commands, root break and return retain their distinct control rules',
    () async {
      final h = await slashFixture();
      final actor = await h.card('Pipe control');
      final chat = await h.emptyChat(actor);
      final context = await h.context(chat, characterId: actor);
      const cases = {
        '/pass ROOT | /pass': 'ROOT',
        '/pass ROOT || /pass': '',
        '/pass ROOT || /pass {{pipe}}': 'ROOT',
        '/pass ROOT | /run {: /pass :}': '',
        '/return ONE | /pass TWO': 'TWO',
        '/break ONE | /pass TWO': 'TWO',
      };
      for (final entry in cases.entries) {
        final result = await slashRun(h, context.id, entry.key);
        expect(result.pipe, entry.value, reason: entry.key);
        expect(result.effects.committed, isFalse);
      }
      h.expectNoGeneration();
    },
  );

  test('a lazy loop owns break while a reparsed text body root does not inherit that owner', () async {
    final h = await slashFixture();
    final actor = await h.card('Break ownership');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final lazy = await slashRun(
      h,
      context.id,
      '/times 3 {: /pass {{incglobalvar::lazy}} | /break STOP | /pass {{setglobalvar::after::BAD}} :}',
    );
    expect(lazy.pipe, 'STOP');
    final text = await slashRun(
      h,
      context.id,
      '/times 3 {{arg::body}}',
      arguments: const {'body': '/pass {{incglobalvar::text}} | /break STOP | /pass END'},
    );
    expect(text.pipe, 'END');
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'lazy': 1, 'text': 3});
    h.expectNoGeneration();
  });

  test('flushvar helper inherits the actual loop break owner and still completes its own deletion', () async {
    final h = await slashFixture();
    final actor = await h.card('Helper break');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.replaceVariables(context.id, scriptChat, {'remove': 'YES'});
    final result = await slashRun(
      h,
      context.id,
      '/times 3 {: /flushvar {: /break remove :} | /pass {{incglobalvar::after}} :} | /pass DONE',
    );
    expect(result.pipe, 'DONE');
    expect(result.effects.committed, isTrue);
    expect((await h.bridge.getVariables(context.id, scriptChat)).value, isEmpty);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, isEmpty);
    h.expectNoGeneration();
  });

  test(
    'abort from an immediate default preserves the selected later default phase and fixes an aborted result',
    () async {
      final h = await slashFixture();
      final actor = await h.card('Abort boundary');
      final chat = await h.emptyChat(actor);
      final context = await h.context(chat, characterId: actor);
      final execution = await h.bridge.triggerSlash(
        context.id,
        'x={: /abort quiet=false HALT :}() y="{{setglobalvar::afterAbort::yes}}" /pass DONE',
      );
      final result = await execution.result;
      expect(result.completion, TavernSlashCompletion.aborted);
      expect(result.pipe, '');
      expect(result.effects.committed, isTrue);
      expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'afterAbort': 'yes'});
      final issue = result.issues.singleWhere((issue) => issue.code == 'slashAbort');
      expect(issue.details['quiet'], isFalse);
      expect(issue.details['reason'], 'HALT');
      expect(h.bridge.stopScript(execution.id), isFalse);
      final late = await execution.events.toList();
      expect(late.single.status, TavernSlashStatus.aborted);
      expect(late.single.pipe, '');
      h.expectNoGeneration();
    },
  );

  test('hot identity and pure loop survive observer detach and host replacement until explicit stop', () async {
    final h = await slashFixture();
    final actor = await h.card('Hot lifecycle');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    const id = 'reusable-script-id';
    h.bridge.attachHost(SlashHost());
    var replaced = false;
    final drawAfterReplacement = Completer<void>();
    h.onRandom = () {
      if (replaced && !drawAfterReplacement.isCompleted) {
        drawAfterReplacement.complete();
      }
    };
    final execution = await h.bridge.triggerSlash(
      context.id,
      '/times guard=off 1000000000 {: /pass {{random::STEP::STEP}} :}',
      executionId: id,
    );
    addTearDown(() {
      h.bridge.stopScript(id);
    });
    final events = ScriptEvents(execution.events);
    await expectLater(
      h.bridge.triggerSlash(context.id, '/pass DUPLICATE', executionId: id),
      throwsA(scriptError(TavernScriptErrorCode.duplicateId)),
    );
    final first = await events.until(
      (event) => event.kind == TavernSlashExecutionEventKind.command && event.pipe == 'STEP',
    );
    final detached = execution.events.listen((_) {});
    await detached.cancel();
    replaced = true;
    h.bridge.attachHost(SlashHost());
    await slashSignal(execution, drawAfterReplacement.future);
    final later = await events.until(
      (event) => event.seq > first.seq && event.kind == TavernSlashExecutionEventKind.command && event.pipe == 'STEP',
    );
    expect(later.seq, greaterThan(first.seq));
    expect(h.bridge.stopScript(id), isTrue);
    final cancelled = await slashFailure(execution);
    expect(cancelled.code, TavernScriptErrorCode.cancelled);
    expect(cancelled.committed, isFalse);
    await events.done.future;
    final replacement = await slashRun(h, context.id, '/pass NEW', executionId: id);
    expect(replacement.pipe, 'NEW');
    final old = await execution.events.toList();
    expect(old, hasLength(1));
    expect(old.single.status, TavernSlashStatus.cancelled);
    expect(old.single.pipe, 'STEP');
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, isEmpty);
    h.expectNoGeneration();
    stdout.writeln('P2_B3_LANGUAGE_CONTROL_READY');
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('a hot handle can cancel a large source before any default effect is admitted', () async {
    final h = await slashFixture();
    final actor = await h.card('Parse cancellation');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final longName = List<String>.filled(65536, 'x').join();
    final execution = await h.bridge.triggerSlash(
      context.id,
      '$longName="{{setglobalvar::shouldNotRun::BAD}}" /pass DONE',
    );
    expect(h.bridge.stopScript(execution.id), isTrue);
    final error = await slashFailure(execution);
    expect(error.code, TavernScriptErrorCode.cancelled);
    expect(error.committed, isFalse);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, isEmpty);
    h.expectNoGeneration();
  }, timeout: const Timeout(Duration(seconds: 15)));
}
