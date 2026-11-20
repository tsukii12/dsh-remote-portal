import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_slash_test_support.dart';

// New public protocol tests, not recovery of the unavailable historical tests.
// Oracles are master D.8/P.9 and the fixed public effect/ownership contract.
void main() {
  test('input sends typed fields and distinguishes answers cancellation and malformed replies', () async {
    final h = await slashFixture();
    final actor = await h.card('Input protocol');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final host = SlashHost();
    h.bridge.attachHost(host);
    const body = '<b>INPUT BODY</b>';
    host.onInteract = (request, _) async =>
        TavernScriptUiResult(requestId: request.requestId, status: 'submitted', text: 'ACTUAL ANSWER');
    final first = await slashRun(h, context.id, '/input {{arg::body}}', arguments: const {'body': body});
    final request = host.interactions.single;
    expect(request.kind, 'input');
    expect(request.contextId, context.id);
    expect(request.executionId, first.id);
    expect(request.fields, {
      'text': body,
      'textKind': 'html',
      'renderMarkdown': false,
      'defaultValue': '',
      'rows': 4,
      'wide': false,
      'large': false,
      'okButton': 'Ok',
    });
    expect(request.fields['rows'], isA<int>());
    final detached = request.fields;
    detached['rows'] = 999;
    expect(request.fields['rows'], 4);
    _settledUi(first, request, 'ACTUAL ANSWER', 'submitted', committed: false);
    await slashRun(
      h,
      context.id,
      '/input default="" rows=128 wide=true large=true okButton="" {{arg::body}}',
      arguments: const {'body': body},
    );
    expect(host.interactions.last.fields, {
      'text': body,
      'textKind': 'html',
      'renderMarkdown': false,
      'defaultValue': '',
      'rows': 128,
      'wide': true,
      'large': true,
      'okButton': '',
    });
    expect(host.interactions.last.fields['rows'], isA<int>());
    for (final status in ['cancelled', 'dismissed']) {
      host.onInteract = (request, _) async =>
          TavernScriptUiResult(requestId: request.requestId, status: status, text: 'NOT AN ANSWER');
      final result = await slashRun(h, context.id, '/input BODY');
      _settledUi(result, host.interactions.last, '', status, committed: false);
    }
    for (final mode in ['missingText', 'wrongRequest', 'unknownStatus', 'error', 'throw']) {
      host.onInteract = (request, _) async {
        if (mode == 'throw') throw StateError('Fixture UI failure');
        return TavernScriptUiResult(
          requestId: mode == 'wrongRequest' ? 'another-request' : request.requestId,
          status: mode == 'unknownStatus'
              ? 'selected'
              : mode == 'error'
              ? 'error'
              : 'submitted',
          text: mode == 'missingText' ? null : 'UNACCEPTED',
        );
      };
      final failure = await _uiFailure(h, context.id, '/input BODY');
      expect(failure.code, mode == 'throw' ? TavernScriptErrorCode.hookFailure : TavernScriptErrorCode.shapeMismatch);
      expect(failure.committed, isFalse);
    }
    expect(host.interactions.map((r) => r.requestId).toSet().length, host.interactions.length);
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
  });

  test('buttons resolve chat then global then literal and keep duplicate whitespace labels exact', () async {
    final h = await slashFixture();
    final actor = await h.card('Buttons protocol');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'labels': '["GLOBAL"]'});
    await h.bridge.replaceVariables(context.id, scriptChat, {'labels': '["same","same"," "]'});
    final host = SlashHost();
    h.bridge.attachHost(host);
    host.onInteract = (request, _) async =>
        TavernScriptUiResult(requestId: request.requestId, status: 'submitted', buttonIndex: 1, label: 'same');
    final first = await slashRun(h, context.id, 'labels=LEXICAL /buttons labels=labels BODY');
    expect(host.interactions.single.kind, 'buttons');
    expect(host.interactions.single.fields, {
      'text': 'BODY',
      'textKind': 'html',
      'renderMarkdown': false,
      'buttonLabels': ['same', 'same', ' '],
    });
    _settledUi(first, host.interactions.last, 'same', 'submitted', committed: false);
    host.onInteract = (request, _) async =>
        TavernScriptUiResult(requestId: request.requestId, status: 'submitted', buttonIndex: 2, label: ' ');
    expect((await slashRun(h, context.id, '/buttons labels=labels BODY')).pipe, ' ');
    for (final mode in ['missingIndex', 'negative', 'tooLarge', 'wrongLabel']) {
      host.onInteract = (request, _) async => TavernScriptUiResult(
        requestId: request.requestId,
        status: 'submitted',
        buttonIndex: mode == 'missingIndex'
            ? null
            : mode == 'negative'
            ? -1
            : mode == 'tooLarge'
            ? 3
            : 0,
        label: mode == 'wrongLabel' ? 'same ' : null,
      );
      final failure = await _uiFailure(h, context.id, '/buttons labels=labels BODY');
      expect(failure.code, TavernScriptErrorCode.shapeMismatch);
      expect(failure.committed, isFalse);
    }
    for (final status in ['cancelled', 'dismissed']) {
      host.onInteract = (request, _) async => TavernScriptUiResult(requestId: request.requestId, status: status);
      final result = await slashRun(h, context.id, '/buttons labels=labels BODY');
      _settledUi(result, host.interactions.last, '', status, committed: false);
    }
    await h.bridge.replaceVariables(context.id, scriptChat, {});
    host.onInteract = (request, _) async =>
        TavernScriptUiResult(requestId: request.requestId, status: 'submitted', buttonIndex: 0);
    expect((await slashRun(h, context.id, 'labels=LEXICAL /buttons labels=labels BODY')).pipe, 'GLOBAL');
    expect(host.interactions.last.fields['buttonLabels'], ['GLOBAL']);
    expect(
      (await slashRun(
        h,
        context.id,
        '/buttons labels={{arg::labels}} BODY',
        arguments: const {'labels': '["LITERAL"]'},
      )).pipe,
      'LITERAL',
    );
    expect(host.interactions.last.fields['buttonLabels'], ['LITERAL']);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'labels': '["GLOBAL"]'});
    expect((await h.bridge.getVariables(context.id, scriptChat)).value, isEmpty);
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
  });

  test('popup maps its captured result switch without trusting reply text or custom status codes', () async {
    final h = await slashFixture();
    final actor = await h.card('Popup protocol');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final host = SlashHost();
    h.bridge.attachHost(host);
    const body = '<i>POPUP BODY</i>';
    for (final resultMode in [false, true]) {
      for (final status in ['submitted', 'cancelled', 'dismissed']) {
        host.onInteract = (request, _) async =>
            TavernScriptUiResult(requestId: request.requestId, status: status, text: 'IGNORE THIS TEXT');
        final result = await slashRun(
          h,
          context.id,
          resultMode ? '/popup result=true {{arg::body}}' : '/popup {{arg::body}}',
          arguments: const {'body': body},
        );
        final request = host.interactions.last;
        expect(request.kind, 'popup');
        expect(request.fields, {
          'text': body,
          'textKind': 'html',
          'renderMarkdown': false,
          'wide': false,
          'large': false,
          'scroll': true,
          'okButton': 'OK',
        });
        final pipe = !resultMode
            ? body
            : status == 'submitted'
            ? '1'
            : status == 'cancelled'
            ? '0'
            : '';
        _settledUi(result, request, pipe, status, committed: false);
      }
    }
    host.onInteract = (request, _) async => TavernScriptUiResult(requestId: request.requestId, status: 'submitted');
    expect(
      (await slashRun(
        h,
        context.id,
        '/popup header=TITLE wide=true large=true scroll=false okButton="" result=true BODY',
      )).pipe,
      '1',
    );
    expect(host.interactions.last.fields, {
      'text': 'BODY',
      'textKind': 'html',
      'renderMarkdown': false,
      'wide': true,
      'large': true,
      'scroll': false,
      'okButton': '',
      'title': 'TITLE',
    });
    for (final wrongId in [false, true]) {
      host.onInteract = (request, _) async => TavernScriptUiResult(
        requestId: wrongId ? '' : request.requestId,
        status: wrongId ? 'submitted' : 'custom-button-7',
      );
      expect((await _uiFailure(h, context.id, '/popup result=true BODY')).code, TavernScriptErrorCode.shapeMismatch);
    }
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
  });

  test('echo confirms actual display text with exact fields while empty text never invokes UI', () async {
    final h = await slashFixture();
    final actor = await h.card('Echo protocol');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final host = SlashHost();
    h.bridge.attachHost(host);
    final empty = await slashRun(h, context.id, '/echo severity=NOT_CONSUMED');
    expect(empty.pipe, '');
    expect(empty.effects.committed, isFalse);
    expect(empty.issues, isEmpty);
    expect(host.interactions, isEmpty);
    host.onInteract = (request, _) async =>
        TavernScriptUiResult(requestId: request.requestId, status: 'submitted', text: 'ACTUAL DISPLAY');
    final plain = await slashRun(h, context.id, '/echo {{arg::body}}', arguments: const {'body': '<b>PLAIN</b>'});
    expect(host.interactions.single.fields, {
      'text': '<b>PLAIN</b>',
      'textKind': 'plain',
      'renderMarkdown': false,
      'severity': 'info',
      'awaitDismissal': false,
    });
    _settledUi(plain, host.interactions.last, 'ACTUAL DISPLAY', 'submitted', committed: true);
    host.onInteract = (request, _) async =>
        TavernScriptUiResult(requestId: request.requestId, status: 'dismissed', text: 'ACTUAL HTML');
    final html = await slashRun(
      h,
      context.id,
      '/echo title=TITLE severity=LOUD escapeHtml=false awaitDismissal=true {{arg::body}}',
      arguments: const {'body': '<b>HTML</b>'},
    );
    expect(host.interactions.last.fields, {
      'text': '<b>HTML</b>',
      'textKind': 'html',
      'renderMarkdown': false,
      'severity': 'info',
      'awaitDismissal': true,
      'title': 'TITLE',
    });
    expect(html.issues.where((issue) => issue.code == 'invalidSeverity'), hasLength(1));
    expect(host.interactions, hasLength(2));
    _settledUi(html, host.interactions.last, 'ACTUAL HTML', 'dismissed', committed: true);
    for (final status in ['submitted', 'dismissed', 'cancelled']) {
      host.onInteract = (request, _) async => TavernScriptUiResult(requestId: request.requestId, status: status);
      final failure = await _uiFailure(h, context.id, '/echo BODY');
      expect(
        failure.code,
        status == 'cancelled' ? TavernScriptErrorCode.cancelled : TavernScriptErrorCode.shapeMismatch,
      );
      expect(failure.committed, isFalse);
    }
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
  });

  test('setinput sends composer text alone and requires a matching submitted actual value', () async {
    final h = await slashFixture();
    final actor = await h.card('Composer protocol');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final host = SlashHost();
    h.bridge.attachHost(host);
    host.onInteract = (request, _) async =>
        TavernScriptUiResult(requestId: request.requestId, status: 'submitted', text: 'ACTUAL COMPOSER');
    final result = await slashRun(h, context.id, '/setinput REQUESTED COMPOSER');
    final request = host.interactions.single;
    expect(request.kind, 'setInput');
    expect(request.fields, {'text': 'REQUESTED COMPOSER'});
    _settledUi(result, request, 'ACTUAL COMPOSER', 'submitted', committed: true);
    for (final mode in ['missingText', 'wrongRequest', 'cancelled', 'dismissed']) {
      host.onInteract = (request, _) async => TavernScriptUiResult(
        requestId: mode == 'wrongRequest' ? 'obsolete-request' : request.requestId,
        status: mode == 'cancelled' || mode == 'dismissed' ? mode : 'submitted',
        text: mode == 'missingText' ? null : 'UNCONFIRMED',
      );
      final failure = await _uiFailure(h, context.id, '/setinput BODY');
      expect(
        failure.code,
        mode == 'cancelled' || mode == 'dismissed'
            ? TavernScriptErrorCode.cancelled
            : TavernScriptErrorCode.shapeMismatch,
      );
      expect(failure.committed, isFalse);
    }
    expect(await h.engine.path(chat), isEmpty);
    expect((await h.bridge.getVariables(context.id, scriptChat)).value, isEmpty);
    h.expectNoGeneration();
  });

  test('hostless and invalid UI commands fail precisely before hidden displays or argument effects', () async {
    final h = await slashFixture();
    final actor = await h.card('UI admission');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    for (final source in [
      '/input BODY',
      '/buttons labels={{arg::labels}} BODY',
      '/popup BODY',
      '/echo BODY',
      '/setinput BODY',
    ]) {
      final failure = await _uiFailure(h, context.id, source, arguments: const {'labels': '["OK"]'});
      expect(failure.code, TavernScriptErrorCode.hostUnavailable);
      expect(failure.committed, isFalse);
    }
    final host = SlashHost()
      ..onInteract = (_, _) async => throw TestFailure('Invalid command must not call the UI host.');
    h.bridge.attachHost(host);
    for (final (source, code) in [
      ('/input rows=0 BODY', TavernScriptErrorCode.invalidArgument),
      ('/input rows=1.5 BODY', TavernScriptErrorCode.invalidArgument),
      ('/input rows=NaN BODY', TavernScriptErrorCode.invalidArgument),
      ('/input placeholder="" {{incglobalvar::uiOops}}', TavernScriptErrorCode.unsupportedOption),
      ('/echo timeout="" {{incglobalvar::uiOops}}', TavernScriptErrorCode.unsupportedOption),
      ('/setinput title="" BODY', TavernScriptErrorCode.unsupportedOption),
    ]) {
      expect((await _uiFailure(h, context.id, source)).code, code);
    }
    for (final (labels, code) in [
      ('[]', TavernScriptErrorCode.invalidArgument),
      ('[""]', TavernScriptErrorCode.invalidArgument),
      ('[1]', TavernScriptErrorCode.invalidArgument),
      ('{"x":1}', TavernScriptErrorCode.invalidArgument),
      ('{broken', TavernScriptErrorCode.invalidJson),
    ]) {
      expect(
        (await _uiFailure(h, context.id, '/buttons labels={{arg::labels}} BODY', arguments: {'labels': labels})).code,
        code,
      );
    }
    expect(host.interactions, isEmpty);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, isEmpty);
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
  });

  test('stopped UI freezes its terminal while a late confirmation cannot take over a reused id', () async {
    final h = await slashFixture();
    final actor = await h.card('UI ownership');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final host = SlashHost();
    final seen = List.generate(2, (_) => Completer<TavernScriptUiRequest>());
    final replies = List.generate(2, (_) => Completer<TavernScriptUiResult>());
    final tokens = <TavernScriptCancellation>[];
    final outcomes = <Future<Object>>[];
    var cleaning = false;
    host.onInteract = (request, token) {
      if (cleaning) return Future.value(TavernScriptUiResult(requestId: request.requestId, status: 'cancelled'));
      final index = host.interactions.length - 1;
      if (index >= seen.length) throw TestFailure('Unexpected additional UI interaction.');
      tokens.add(token);
      seen[index].complete(request);
      return replies[index].future;
    };
    h.bridge.attachHost(host);
    final watch = ScriptEvents(h.bridge.watchEvents(chatId: chat));
    addTearDown(() async {
      cleaning = true;
      h.bridge.stopScript('reused-ui');
      for (var i = 0; i < replies.length && i < host.interactions.length; i++) {
        if (!replies[i].isCompleted) {
          replies[i].complete(TavernScriptUiResult(requestId: host.interactions[i].requestId, status: 'cancelled'));
        }
      }
      await Future.wait(outcomes);
    });
    final old = await h.bridge.triggerSlash(context.id, '/setinput OLD REQUEST', executionId: 'reused-ui');
    outcomes.add(old.result.then<Object>((value) => value, onError: (Object error, StackTrace _) => error));
    final oldRequest = await slashSignal(old, seen[0].future);
    expect(h.bridge.stopScript('reused-ui'), isTrue);
    final failure = await slashFailure(old);
    expect(failure.code, TavernScriptErrorCode.cancelled);
    expect(failure.committed, isFalse);
    final terminal = await old.events.single;
    final frozen = jsonEncode(terminal.effects.toJson());
    expect(terminal.status, TavernSlashStatus.cancelled);
    expect(tokens[0].isCancelled, isTrue);
    final current = await h.bridge.triggerSlash(context.id, '/setinput NEW REQUEST', executionId: 'reused-ui');
    outcomes.add(current.result.then<Object>((value) => value, onError: (Object error, StackTrace _) => error));
    final newRequest = await slashSignal(current, seen[1].future);
    expect(newRequest.requestId, isNot(oldRequest.requestId));
    replies[0].complete(
      TavernScriptUiResult(requestId: oldRequest.requestId, status: 'submitted', text: 'LATE OLD ACTUAL'),
    );
    final late = await slashSignal(
      current,
      watch.until(
        (event) =>
            event.phase == 'late' &&
            event.dispatch.namespace == 'slash' &&
            event.dispatch.name == 'HOST_OPERATION' &&
            event.dispatch.args.any(
              (value) =>
                  value is Map<String, Object?> &&
                  value['requestId'] == oldRequest.requestId &&
                  value['kind'] == 'setInput' &&
                  value['operation'] == 'interact' &&
                  value['status'] == 'submitted',
            ),
      ),
    );
    expect(late.committed, isTrue);
    expect(tokens[1].isCancelled, isFalse);
    final afterLate = await old.events.single;
    expect(jsonEncode(afterLate.effects.toJson()), frozen);
    expect(afterLate.lastSeq, terminal.lastSeq);
    expect(afterLate.status, TavernSlashStatus.cancelled);
    replies[1].complete(
      TavernScriptUiResult(requestId: newRequest.requestId, status: 'submitted', text: 'CURRENT ACTUAL'),
    );
    final result = await current.result;
    _settledUi(result, newRequest, 'CURRENT ACTUAL', 'submitted', committed: true);
    expect(h.bridge.stopScript('reused-ui'), isFalse);
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
    stdout.writeln('P2_B3_UI_READY');
  }, timeout: const Timeout(Duration(seconds: 15)));
}

Future<TavernScriptException> _uiFailure(
  ScriptFixture h,
  String contextId,
  String source, {
  Map<String, String> arguments = const {},
}) async => slashFailure(await h.bridge.triggerSlash(contextId, source, arguments: arguments));

void _settledUi(
  TavernSlashResult result,
  TavernScriptUiRequest request,
  String pipe,
  String status, {
  required bool committed,
}) {
  expect(result.pipe, pipe);
  expect(result.effects.committed, committed);
  final settled = result.effects.entries
      .where((entry) => entry.kind == TavernSlashEffectKind.ui && entry.state != TavernSlashEffectState.requested)
      .single;
  expect(settled.target, {'requestId': request.requestId, 'kind': request.kind});
  expect(settled.details['status'], status);
  expect(settled.state, status == 'cancelled' ? TavernSlashEffectState.cancelled : TavernSlashEffectState.completed);
  expect(settled.committed, committed);
  expect(result.effects.entries.where((entry) => entry.kind == TavernSlashEffectKind.storage), isEmpty);
}
